import Foundation

enum AudioFormat: String, CaseIterable, Identifiable, Equatable {
    case mp3, m4a
    var id: String { rawValue }
    var ext: String { rawValue }
    var title: String { self == .mp3 ? "MP3" : "M4A" }
}

/// Runs ffmpeg with machine-readable progress.
enum FFmpegRunner {
    static func run(arguments: [String], duration: Double?, token: CancelToken?,
                    onProgress: @escaping (Double) -> Void) async throws -> ProcessResult {
        guard let ffmpeg = Tools.ffmpeg else { throw HelperError.message("The converter isn't ready yet.") }
        let args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        return try await ProcessRunner.run(ffmpeg, args, token: token, onStdoutLine: { line in
            if let s = FFmpegProgress.seconds(inLine: line), let f = FFmpegProgress.fraction(seconds: s, duration: duration) {
                onProgress(f)
            }
        })
    }

    /// Turns ffmpeg's complaints into plain words.
    static func explain(_ stderr: String) -> String {
        let l = stderr.lowercased()
        if l.contains("permission denied") { return "Media Helper isn't allowed to read or write that file." }
        if l.contains("no such file") { return "That file could not be found. It may have been moved or deleted." }
        if l.contains("invalid data found") || l.contains("moov atom not found") || l.contains("could not find codec") {
            return "That file couldn't be read. It may be damaged, or it may not be a video."
        }
        if l.contains("no space left") { return "There isn't enough space on this Mac to save the file." }
        if l.contains("does not contain any stream") || l.contains("matches no streams") { return "This video doesn't have any sound to save." }
        let last = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.last
        return last.map { "The conversion failed: \(String($0.prefix(200)))" } ?? "The conversion failed."
    }
}

enum MediaConverter {
    /// Video types accepted for Video → Audio (the six that matter, plus common extras).
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "wmv", "flv", "3gp", "mts", "m2ts", "ogv"]

    static func isSupportedVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }

    /// ffmpeg arguments (without the leading global options) to extract the sound.
    static func arguments(input: URL, output: URL, format: AudioFormat) -> [String] {
        var a = ["-y", "-i", input.path, "-vn", "-sn", "-dn", "-map", "0:a:0", "-map_metadata", "0"]
        switch format {
        case .mp3: a += ["-c:a", "libmp3lame", "-q:a", "0", "-id3v2_version", "3"]
        case .m4a: a += ["-c:a", "aac", "-b:a", "256k"]
        }
        a.append(output.path)
        return a
    }

    /// Converts one video to audio. `outputFolder == nil` means "next to the original".
    /// Returns the new file (never overwrites an existing one).
    static func convert(input: URL, format: AudioFormat, outputFolder: URL?, token: CancelToken,
                        onStatus: @escaping (String) -> Void = { _ in },
                        onProgress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: input.path) else {
            throw HelperError.message("That file could not be found or opened.")
        }
        let folder = outputFolder ?? input.deletingLastPathComponent()
        if outputFolder == nil, !fm.isWritableFile(atPath: folder.path) {
            throw HelperError.message("The folder with the original video is locked, so the audio can't be saved next to it. Choose a save folder instead.")
        }
        onStatus("Reading the video…")
        let info = try await MediaProbe.probe(input, token: token)
        guard info.hasAudio else { throw HelperError.message("This video doesn't have any sound to save.") }

        let work = try AppPaths.makeWorkDir()
        defer { try? fm.removeItem(at: work) }
        let temp = work.appendingPathComponent("audio." + format.ext)
        onStatus("Converting to \(format.title)…")
        let r = try await FFmpegRunner.run(arguments: arguments(input: input, output: temp, format: format),
                                           duration: info.duration, token: token, onProgress: onProgress)
        try token.throwIfCancelled()
        guard r.succeeded, fm.fileExists(atPath: temp.path) else { throw HelperError.message(FFmpegRunner.explain(r.stderr)) }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Naming.sanitize(input.deletingPathExtension().lastPathComponent, fallback: "Audio")
        let dest = Naming.uniqueURL(in: folder, baseName: base, ext: format.ext)
        do { try fm.moveItem(at: temp, to: dest) } catch {
            throw HelperError.message("The audio was made but couldn't be saved in that folder: \(error.localizedDescription)")
        }
        onProgress(1)
        return dest
    }
}
