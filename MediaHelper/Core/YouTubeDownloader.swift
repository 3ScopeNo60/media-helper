import Foundation

/// Downloads a YouTube video's audio or video with the managed downloader.
/// Adapted from Sonara's downloader: error explaining, progress parsing and
/// rate-limit / stale-tool detection are carried over.
enum YouTubeDownloader {

    enum VideoQuality: String, CaseIterable, Identifiable, Equatable {
        case best, p720, p480
        var id: String { rawValue }
        var maxHeight: Int { switch self { case .best: return 1080; case .p720: return 720; case .p480: return 480 } }
        var title: String { switch self { case .best: return "Best (up to 1080p)"; case .p720: return "720p"; case .p480: return "480p" } }

        /// H.264 video + AAC audio where YouTube has it (plays everywhere), else the best single MP4, else anything.
        var formatSelector: String {
            "bv*[vcodec^=avc1][height<=\(maxHeight)]+ba[ext=m4a]/b[ext=mp4][height<=\(maxHeight)]/b"
        }
    }

    enum Mode: Equatable {
        case audio(AudioFormat)
        case video(VideoQuality)
        var isAudio: Bool { if case .audio = self { return true }; return false }
    }

    struct Hooks {
        var title: (String) -> Void = { _ in }
        var progress: (Double) -> Void = { _ in }
        var status: (String) -> Void = { _ in }
    }

    struct Result {
        let url: URL
        let title: String
        /// Codecs of the saved file (video downloads), as ffprobe reports them.
        let videoCodec: String?
        let audioCodec: String?
        /// True when the video had to be re-encoded to H.264 + AAC after downloading.
        let reEncoded: Bool
    }

    // MARK: Command line

    static func arguments(mode: Mode, outputTemplate: String, ffmpegLocation: String?, link: String) -> [String] {
        // --ignore-config: a stray config file on the Mac can't change how we behave.
        // --no-playlist: a playlist link downloads just that one video.
        var a = ["--ignore-config", "--no-playlist", "--newline", "--progress", "--no-mtime",
                 "--socket-timeout", "30", "--write-info-json"]
        switch mode {
        case .audio(let f):
            a += ["-x", "--audio-format", f.rawValue, "--audio-quality", "0"]
        case .video(let q):
            a += ["-f", q.formatSelector, "--merge-output-format", "mp4"]
        }
        if let ffmpegLocation { a += ["--ffmpeg-location", ffmpegLocation] }
        a += ["-o", outputTemplate, "--", link]
        return a
    }

    // MARK: Links

    /// Accepts a pasted line and returns a usable web address, or nil if it isn't a link.
    static func normalizedLink(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            guard lower.hasPrefix("www.") || lower.hasPrefix("youtube.com") || lower.hasPrefix("m.youtube.com")
                    || lower.hasPrefix("youtu.be") || lower.hasPrefix("music.youtube.com") else { return nil }
            s = "https://" + s
        }
        guard let u = URL(string: s), let host = u.host, host.contains(".") else { return nil }
        return s
    }

    /// One link per line → (valid links, number of non-empty lines that weren't links).
    static func parseLinks(_ text: String) -> (links: [String], skipped: Int) {
        var links: [String] = [], skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let l = normalizedLink(t) { links.append(l) } else { skipped += 1 }
        }
        return (links, skipped)
    }

    // MARK: Downloading

    static func fetchTitle(link: String, token: CancelToken?) async -> String? {
        guard let tool = Tools.ytdlp else { return nil }
        let r = try? await ProcessRunner.run(tool, ["--ignore-config", "--no-playlist", "--simulate", "--print", "%(title)s", "--", link], token: token)
        guard let r, r.succeeded else { return nil }
        let t = r.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (t?.isEmpty == false && t != "NA") ? t : nil
    }

    /// Downloads one link into `saveFolder`. Work happens in a scratch folder and the
    /// finished file is moved in under its video title (never overwriting anything).
    static func download(link: String, mode: Mode, saveFolder: URL, token: CancelToken, hooks: Hooks = Hooks()) async throws -> Result {
        guard let tool = Tools.ytdlp else { throw HelperError.message("The downloader isn't ready yet.") }
        let fm = FileManager.default
        let work = try AppPaths.makeWorkDir()
        defer { try? fm.removeItem(at: work) }

        hooks.status("Getting video details…")
        var title = await fetchTitle(link: link, token: token)
        try token.throwIfCancelled()
        if let title { hooks.title(title) }

        let tracker = TrackerBox()
        let args = arguments(mode: mode, outputTemplate: work.appendingPathComponent("media.%(ext)s").path,
                             ffmpegLocation: Tools.ffmpegLocation, link: link)
        hooks.status("Downloading…")
        let r = try await ProcessRunner.run(tool, args, token: token, onStdoutLine: { line in
            guard let (f, stage) = tracker.handle(line) else { return }
            hooks.progress(f * 0.92)
            switch stage {
            case .downloading: hooks.status("Downloading…")
            case .merging: hooks.status("Joining picture and sound…")
            case .converting: hooks.status(mode.isAudio ? "Converting the sound…" : "Converting…")
            case .fixing: hooks.status("Finishing up…")
            }
        })
        try token.throwIfCancelled()
        guard r.succeeded else { throw HelperError.message(explain(r.stderr.isEmpty ? r.stdout : r.stderr)) }

        // The title can also come from the details file if the quick lookup failed.
        if title == nil, let data = try? Data(contentsOf: work.appendingPathComponent("media.info.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = obj["title"] as? String, !t.isEmpty {
            title = t
            hooks.title(t)
        }

        guard var produced = findOutput(in: work, preferredExt: mode.isAudio ? (mode.audioFormat?.ext ?? "mp3") : "mp4") else {
            throw HelperError.message("The download finished, but the file couldn't be found.")
        }

        var videoCodec: String?, audioCodec: String?, reEncoded = false
        if case .video = mode {
            hooks.status("Checking the video…")
            let info = try await MediaProbe.probe(produced, token: token)
            videoCodec = info.videoCodec; audioCodec = info.audioCodec
            let compatible = produced.pathExtension.lowercased() == "mp4" && info.videoCodec == "h264" && (info.audioCodec == "aac" || info.audioCodec == nil)
            if !compatible {
                // Rare: YouTube had no H.264 version. Convert so it still plays in PowerPoint, ProPresenter and QuickTime.
                hooks.status("Making it play everywhere…")
                let out = work.appendingPathComponent("compatible.mp4")
                let enc = try await FFmpegRunner.run(arguments: compatibleMP4Arguments(input: produced, output: out, hasAudio: info.hasAudio),
                                                     duration: info.duration, token: token,
                                                     onProgress: { hooks.progress(0.92 + $0 * 0.07) })
                try token.throwIfCancelled()
                guard enc.succeeded, fm.fileExists(atPath: out.path) else { throw HelperError.message(FFmpegRunner.explain(enc.stderr)) }
                produced = out
                let after = try await MediaProbe.probe(out, token: token)
                videoCodec = after.videoCodec; audioCodec = after.audioCodec; reEncoded = true
            }
        }

        try fm.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let name = Naming.sanitize(title ?? "YouTube video", fallback: "YouTube video")
        let dest = Naming.uniqueURL(in: saveFolder, baseName: name, ext: produced.pathExtension.lowercased())
        do { try fm.moveItem(at: produced, to: dest) } catch {
            throw HelperError.message("The file was downloaded but couldn't be saved in that folder: \(error.localizedDescription)")
        }
        hooks.progress(1)
        return Result(url: dest, title: title ?? name, videoCodec: videoCodec, audioCodec: audioCodec, reEncoded: reEncoded)
    }

    static func compatibleMP4Arguments(input: URL, output: URL, hasAudio: Bool) -> [String] {
        var a = ["-y", "-i", input.path, "-map", "0:v:0"]
        if hasAudio { a += ["-map", "0:a:0"] }
        a += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
              "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        if hasAudio { a += ["-c:a", "aac", "-b:a", "192k"] }
        a += ["-movflags", "+faststart", output.path]
        return a
    }

    static func findOutput(in dir: URL, preferredExt: String) -> URL? {
        let skip: Set<String> = ["part", "ytdl", "json", "temp", "tmp", "jpg", "jpeg", "png", "webp", "vtt", "srt"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("media.") && !skip.contains($0.pathExtension.lowercased()) }
        if let exact = files.first(where: { $0.pathExtension.lowercased() == preferredExt }) { return exact }
        return files.max { size($0) < size($1) }
    }

    private static func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// Thread-safe wrapper so the output-line callback can update one tracker.
    private final class TrackerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tracker = DownloadProgressTracker()
        func handle(_ line: String) -> (Double, DownloadProgressTracker.Stage)? {
            lock.lock(); defer { lock.unlock() }
            return tracker.handle(line: line) ? (tracker.fraction, tracker.stage) : nil
        }
    }

    // MARK: Out-of-date downloader handling

    /// Runs `attempt`; if it fails the way an out-of-date downloader does, updates the
    /// downloader and tries once more before giving up.
    static func retryingAfterUpdate<T>(
        attempt: () async throws -> T,
        update: () async throws -> Void,
        onUpdating: () -> Void = {}
    ) async throws -> T {
        do { return try await attempt() }
        catch let HelperError.message(m) where isOutdatedToolFailure(m) {
            onUpdating()
            do { try await update() } catch {
                throw HelperError.message("YouTube refused the download, and Media Helper couldn't update itself to fix it. Check the internet connection and try again.")
            }
            do { return try await attempt() }
            catch let HelperError.message(m2) where isOutdatedToolFailure(m2) {
                throw HelperError.message(stillRefusedMessage)
            }
        }
    }

    /// What the app and the QA runner both call: download, and if YouTube refuses in the
    /// way an out-of-date downloader does, update it and retry once.
    static func downloadWithAutoUpdate(link: String, mode: Mode, saveFolder: URL, token: CancelToken, hooks: Hooks = Hooks()) async throws -> Result {
        try await retryingAfterUpdate(
            attempt: { try await download(link: link, mode: mode, saveFolder: saveFolder, token: token, hooks: hooks) },
            update: { try await ToolInstaller.updateDownloader() },
            onUpdating: { hooks.status("Updating, then trying again…") })
    }

    // MARK: Error explaining (adapted from Sonara)

    /// Stable phrase marking "the downloader is stale" failures.
    static let outdatedToolHint = "YouTube refused the download — the downloader may be out of date."
    static let stillRefusedMessage = "YouTube still refused the download, even after an update. Please try again later."

    /// Stable phrase for "YouTube is rate-limiting us".
    static let rateLimitHint = "YouTube is limiting requests from this Mac"

    private static let pushbackMarkers = [
        "too many requests", "rate limit", "rate-limit", "ratelimit", "not a bot",
        "unusual traffic", "try again later", "temporarily blocked",
    ]

    /// True when YouTube is pushing back on volume rather than rejecting one video.
    static func isPushbackFailure(_ reason: String?) -> Bool {
        guard let reason else { return false }
        if reason.contains(rateLimitHint) { return true }
        let l = reason.lowercased()
        return pushbackMarkers.contains { l.contains($0) }
    }

    /// True when a failure is one an update would likely fix. Also matches raw output.
    static func isOutdatedToolFailure(_ reason: String?) -> Bool {
        guard let reason else { return false }
        if reason.contains(outdatedToolHint) { return true }
        let l = reason.lowercased()
        return staleMarkers.contains { l.contains($0) }
    }

    /// Phrases an out-of-date downloader produces when YouTube changes something.
    /// ("The page needs to be reloaded" is what a stale copy reports today.)
    private static let staleMarkers = [
        "403", "forbidden", "unable to download video data", "nsig extraction failed",
        "page needs to be reloaded", "unable to extract",
    ]

    /// Turns raw downloader stderr into something a person can act on. The downloader
    /// prints a multi-line "update me" banner before real failures, which would
    /// otherwise hide the actual cause.
    static func explain(_ stderr: String) -> String {
        let noise = ["It is strongly recommended", "You installed yt-dlp with",
                     "To suppress this warning", "Use that to update",
                     "Available version", "Current version", "yt-dlp is out of date"]
        let lines = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && line != "!" && !noise.contains { line.contains($0) } }
        let errors = lines.filter { $0.hasPrefix("ERROR:") }
        let core = (errors.isEmpty ? lines.suffix(2) : errors.suffix(2))
            .joined(separator: " ")
            .replacingOccurrences(of: "ERROR: ", with: "")
        let lower = stderr.lowercased()

        // Volume-based pushback first: temporary, and not the video's fault.
        if pushbackMarkers.contains(where: { lower.contains($0) }) {
            return rateLimitHint + " — wait a few minutes and try again."
        }
        if lower.contains("confirm your age") || lower.contains("age-restricted") || lower.contains("age restricted") {
            return "This video is age-restricted, so it can't be downloaded."
        }
        if staleMarkers.contains(where: { lower.contains($0) }) {
            return outdatedToolHint + " Media Helper will try to update it."
        }
        if lower.contains("sign in to confirm") {
            return "YouTube asked for a sign-in check on this video, so it can't be downloaded automatically."
        }
        if lower.contains("private video") || lower.contains("video unavailable") || lower.contains("this video is not available")
            || lower.contains("has been removed") || lower.contains("account associated with this video has been terminated") {
            return "That video is unavailable or private."
        }
        if lower.contains("members-only") || lower.contains("join this channel") {
            return "That video is for channel members only, so it can't be downloaded."
        }
        if lower.contains("live event will begin") || lower.contains("premieres in") || lower.contains("this live event") {
            return "That video hasn't started yet. Try again once it has been published."
        }
        if lower.contains("blocked it in your country") || lower.contains("not available in your country") {
            return "That video isn't available in this country."
        }
        if lower.contains("is not a valid url") || lower.contains("unsupported url") {
            return "That doesn't look like a link to a video."
        }
        if lower.contains("unable to download webpage") || lower.contains("name or service not known")
            || lower.contains("nodename nor servname") || lower.contains("network is unreachable")
            || lower.contains("temporary failure in name resolution") || lower.contains("timed out")
            || lower.contains("connection reset") || lower.contains("offline") {
            return "Couldn't reach YouTube. Check the internet connection and try again."
        }
        if lower.contains("no space left") { return "There isn't enough space on this Mac to save the file." }
        return core.isEmpty ? "The download failed." : String(core.prefix(300))
    }

    /// Extracts the last "NN.N%" percentage from a chunk of downloader output.
    static func lastPercent(in text: String) -> Double? {
        var result: Double?
        var scanner = Substring(text)
        while let r = scanner.range(of: #"\d{1,3}(\.\d+)?%"#, options: .regularExpression) {
            let token = scanner[r].dropLast()
            if let v = Double(token) { result = v }
            scanner = scanner[r.upperBound...]
        }
        return result
    }
}

private extension YouTubeDownloader.Mode {
    var audioFormat: AudioFormat? { if case .audio(let f) = self { return f }; return nil }
}
