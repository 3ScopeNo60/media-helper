import Foundation

/// Installs and updates the two helper programs Media Helper depends on, into
/// `~/Library/Application Support/Media Helper/Tools/`:
///
///  * `yt-dlp`            the official standalone macOS build from github.com/yt-dlp
///                        (checked against the SHA-256 list published with the release)
///  * `ffmpeg`, `ffprobe` static builds from Martin Riedl's build server
///                        (checked against the SHA-256 file published beside each download)
enum ToolInstaller {

    static let ytdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    static let ytdlpSumsURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!

    /// ffmpeg.martin-riedl.de redirects "latest release" to the newest numbered build.
    static func ffmpegURL(tool: String, appleSilicon: Bool) -> URL {
        URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(appleSilicon ? "arm64" : "amd64")/release/\(tool).zip")!
    }

    /// Decided when the app runs, so an Intel build running on Apple Silicon still gets the right download.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    // MARK: What's missing

    static var needsDownloader: Bool { !Tools.isManaged("yt-dlp") }
    static var needsConverter: Bool { !(Tools.isManaged("ffmpeg") && Tools.isManaged("ffprobe")) }

    // MARK: Installing the downloader

    static func installDownloader(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let work = try AppPaths.makeWorkDir()
        defer { try? fm.removeItem(at: work) }
        let file = work.appendingPathComponent("yt-dlp_macos")
        try await FileDownloader.download(ytdlpURL, to: file, onProgress: progress)

        let sums = try await FileDownloader.fetchText(ytdlpSumsURL)
        guard let expected = Checksum.expectedHash(in: sums, forFile: "yt-dlp_macos") else {
            throw HelperError.message("Couldn't check the downloader's checksum, so it was not installed.")
        }
        guard try Checksum.sha256Hex(of: file) == expected else {
            throw HelperError.message("The downloader didn't match its published checksum, so it was not installed.")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try await makeRunnable(file, versionArgs: ["--version"])
        try place(file, as: "yt-dlp")
    }

    // MARK: Installing the converter

    static func installConverter(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let work = try AppPaths.makeWorkDir()
        defer { try? fm.removeItem(at: work) }
        let tools = ["ffmpeg", "ffprobe"]
        var built: [(String, URL)] = []
        for (i, tool) in tools.enumerated() {
            let zip = work.appendingPathComponent("\(tool).zip")
            let final = try await FileDownloader.download(ffmpegURL(tool: tool, appleSilicon: isAppleSilicon), to: zip,
                                                          onProgress: { progress((Double(i) + $0) / Double(tools.count)) })
            // The site publishes "<download address>.sha256" next to each file.
            guard let final, final.host == "ffmpeg.martin-riedl.de", let sumURL = URL(string: final.absoluteString + ".sha256") else {
                throw HelperError.message("The converter download came from an unexpected place, so it was not installed.")
            }
            let sumText = try await FileDownloader.fetchText(sumURL)
            guard let expected = Checksum.expectedHash(in: sumText) else {
                throw HelperError.message("Couldn't check the converter's checksum, so it was not installed.")
            }
            guard try Checksum.sha256Hex(of: zip) == expected else {
                throw HelperError.message("The converter didn't match its published checksum, so it was not installed.")
            }
            let out = work.appendingPathComponent("unzipped-\(tool)", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let unzip = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
            let binary = out.appendingPathComponent(tool)
            guard unzip.succeeded, fm.fileExists(atPath: binary.path) else {
                throw HelperError.message("The converter download couldn't be unpacked.")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try await makeRunnable(binary, versionArgs: ["-version"])
            built.append((tool, binary))
        }
        for (name, file) in built { try place(file, as: name) }
    }

    // MARK: Updating the downloader

    private static let gate = UpdateGate()

    /// Brings the downloader up to date: `yt-dlp -U` on our own copy, or installs our own
    /// copy if only a Homebrew one exists. Safe to call from several jobs at once.
    @discardableResult
    static func updateDownloader() async throws -> String {
        if !gate.begin() {
            await gate.waitUntilIdle()
            return (await Tools.versions()).downloader ?? ""
        }
        defer { gate.end() }
        if Tools.isManaged("yt-dlp") {
            let r = try await ProcessRunner.run(Tools.managedPath("yt-dlp"), ["-U"])
            guard r.succeeded else {
                let tail = (r.stdout + r.stderr).split(separator: "\n").last.map(String.init) ?? ""
                throw HelperError.message("Couldn't update the downloader: \(tail.prefix(200))")
            }
        } else {
            try await installDownloader()
        }
        return (await Tools.versions()).downloader ?? ""
    }

    /// Jobs wait here while an update swaps the program underneath them.
    static func waitUntilNotUpdating() async { await gate.waitUntilIdle() }
    static var isUpdating: Bool { gate.isBusy }

    // MARK: Helpers

    /// Runs the program once. If macOS refuses (killed by a signal), signs it ad hoc and tries again.
    private static func makeRunnable(_ file: URL, versionArgs: [String]) async throws {
        var r = try await ProcessRunner.run(file.path, versionArgs)
        if !r.succeeded {
            _ = try await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", file.path])
            _ = try await ProcessRunner.run("/usr/bin/codesign", ["-s", "-", "--force", file.path])
            r = try await ProcessRunner.run(file.path, versionArgs)
        }
        guard r.succeeded else {
            throw HelperError.message("A helper program was installed but wouldn't start on this Mac.")
        }
    }

    private static func place(_ file: URL, as name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.toolsDir, withIntermediateDirectories: true)
        let dest = AppPaths.toolsDir.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: file, to: dest)
    }
}

/// A one-at-a-time flag with an async wait.
final class UpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; if busy { return false }; busy = true; return true }
    func end() { lock.lock(); busy = false; lock.unlock() }
    func waitUntilIdle() async { while isBusy { try? await Task.sleep(nanoseconds: 200_000_000) } }
}
