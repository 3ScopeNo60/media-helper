import Foundation

/// Finds the helper programs. Our own copies (in Application Support) are preferred;
/// Homebrew copies are only a fallback if installing ours failed.
enum Tools {
    static let homebrewDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func managedPath(_ name: String) -> String { AppPaths.toolsDir.appendingPathComponent(name).path }
    static func isManaged(_ name: String) -> Bool { FileManager.default.isExecutableFile(atPath: managedPath(name)) }

    static func path(for name: String) -> String? {
        if isManaged(name) { return managedPath(name) }
        return homebrewDirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The folder holding both ffmpeg and ffprobe, for the downloader's `--ffmpeg-location`.
    static var ffmpegLocation: String? {
        func both(_ dir: String) -> Bool {
            FileManager.default.isExecutableFile(atPath: dir + "/ffmpeg") && FileManager.default.isExecutableFile(atPath: dir + "/ffprobe")
        }
        if both(AppPaths.toolsDir.path) { return AppPaths.toolsDir.path }
        return homebrewDirs.first(where: both)
    }

    static var ytdlp: String? { path(for: "yt-dlp") }
    static var ffmpeg: String? { path(for: "ffmpeg") }
    static var hasEverything: Bool { ytdlp != nil && ffmpegLocation != nil }

    struct Versions: Equatable {
        var downloader: String?
        var converter: String?
    }

    static func versions() async -> Versions {
        var v = Versions()
        if let y = ytdlp, let r = try? await ProcessRunner.run(y, ["--version"]), r.succeeded {
            v.downloader = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
        }
        if let f = ffmpeg, let r = try? await ProcessRunner.run(f, ["-version"]), r.succeeded {
            v.converter = ffmpegVersion(fromBanner: r.stdout)
        }
        return v
    }

    /// "ffmpeg version 9.0.2-https://www.martin-riedl.de Copyright …" → "9.0.2"
    static func ffmpegVersion(fromBanner text: String) -> String? {
        guard let line = text.split(separator: "\n").first, let r = line.range(of: "version ") else { return nil }
        let token = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        if let m = token.range(of: #"^\d+(\.\d+)*"#, options: .regularExpression) { return String(token[m]) }
        return String(token.prefix(20))
    }
}
