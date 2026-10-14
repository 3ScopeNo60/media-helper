import Foundation

/// Command-line flags. Normal launches have none; the QA flags exist so the
/// app's own code can be exercised headlessly (see README, "Testing").
enum Flags {
    static func value(_ name: String, in args: [String] = CommandLine.arguments) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Every value of a flag that may be repeated.
    static func values(_ name: String, in args: [String] = CommandLine.arguments) -> [String] {
        args.indices.compactMap { i in args[i] == name && i + 1 < args.count ? args[i + 1] : nil }
    }
    static func has(_ name: String, in args: [String] = CommandLine.arguments) -> Bool { args.contains(name) }
}

/// Where Media Helper keeps its own files.
enum AppPaths {
    /// ~/Library/Application Support/Media Helper (QA: overridden with `-supportDir`).
    static var supportDir: URL {
        if let o = Flags.value("-supportDir") { return URL(fileURLWithPath: o, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media Helper", isDirectory: true)
    }

    /// Holds the downloader and converter programs (QA: overridden with `-toolsDir`).
    static var toolsDir: URL {
        if let o = Flags.value("-toolsDir") { return URL(fileURLWithPath: o, isDirectory: true) }
        return supportDir.appendingPathComponent("Tools", isDirectory: true)
    }

    static var updatesDir: URL { supportDir.appendingPathComponent("Updates", isDirectory: true) }

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// A fresh scratch folder for one job. Partial files live here, never in the
    /// person's own folders, so cancelling or crashing can't leave junk behind.
    static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MediaHelper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The one error type the job code throws.
enum HelperError: LocalizedError, Equatable {
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled."
        case .message(let m): return m
        }
    }
}
