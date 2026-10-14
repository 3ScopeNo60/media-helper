import Foundation
import AppKit
import Observation

/// Keeps Media Helper up to date from the project's public GitHub releases.
///
/// Safety rules, in order of importance:
///  1. Every download is checked against an Ed25519 signature made on the release
///     machine; the app carries only the public key. Anything else is refused.
///  2. Nothing installs by itself. The banner offers the update and a person clicks
///     Install, and only when no download or conversion is running.
///  3. The version being replaced is kept as a backup and put back if the swap fails.
@MainActor
@Observable
final class UpdateManager {
    static let shared = UpdateManager()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(version: String, notes: String)
        case installing(step: String, progress: Double?)
        case problem(String)
    }

    private(set) var state: State = .idle
    /// True when a person asked for the check (so "up to date" and problems are shown to them).
    private(set) var showsResult = false
    /// Set by the app: true while anything is being downloaded, converted or queued.
    var isBusy: () -> Bool = { false }
    /// What to do once the new copy is staged. The app quits; headless QA runs just exit.
    var quitForRelaunch: () -> Void = { NSApplication.shared.terminate(nil) }

    let currentVersion: AppVersion
    private var offer: UpdateOffer?

    init() {
        var v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        if let q = Flags.value("-currentVersion") { v = q }          // QA: pretend to be an older build
        currentVersion = AppVersion(v) ?? AppVersion("0")!
    }

    func dismissResult() {
        showsResult = false
        if case .upToDate = state { state = .idle }
        if case .problem = state { state = .idle }
    }

    // MARK: Configuration

    /// "owner/repository", built into the app (Info.plist `MediaHelperUpdateRepo`).
    static var repo: String {
        ((Bundle.main.object(forInfoDictionaryKey: "MediaHelperUpdateRepo") as? String) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The Ed25519 public key (base64) that downloads must be signed with.
    static var publicKey: String {
        if let k = Flags.value("-updateKey") { return k }            // QA only
        return ((Bundle.main.object(forInfoDictionaryKey: "MediaHelperUpdatePublicKey") as? String) ?? "").trimmingCharacters(in: .whitespaces)
    }

    static var feedURL: URL? {
        if let f = Flags.value("-updateFeed") { return localFeedURL(f) }   // QA only
        let parts = repo.split(separator: "/")
        guard parts.count == 2, !repo.contains(" ") else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")
    }

    /// QA: a web address, a path to a releases JSON file, or a folder containing `releases.json`.
    static func localFeedURL(_ value: String) -> URL? {
        if value.contains("://") { return URL(string: value) }
        var isDir: ObjCBool = false
        let path = (value as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: path).appendingPathComponent("releases.json")
        }
        return URL(fileURLWithPath: path)
    }

    var hasSource: Bool { Self.feedURL != nil }

    // MARK: Checking

    /// Looks for a newer release. Background checks stay quiet; ones a person asked for explain what happened.
    func check(userInitiated: Bool = false) async {
        if case .installing = state { return }
        if userInitiated { showsResult = true }
        guard let url = Self.feedURL else {
            if userInitiated { state = .problem("Updates aren't set up in this copy of Media Helper yet.") }
            return
        }
        guard !Self.publicKey.isEmpty else {
            if userInitiated { state = .problem("This copy of Media Helper has no update key, so it can't safely install updates.") }
            return
        }
        state = .checking
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try await URLSession.shared.data(for: request)
            if case .installing = state { return }        // an install began while we were asking; don't disturb it
            try Self.checkStatus(response)
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            if let best = UpdateFeed.bestOffer(in: releases, current: currentVersion) {
                offer = best
                state = .available(version: best.version.description, notes: best.notes)
            } else {
                offer = nil
                state = .upToDate(Date())
            }
        } catch {
            if case .installing = state { return }
            if userInitiated {
                state = .problem(Self.explain(error))
            } else {                                   // a quiet background check: keep what we knew
                state = offer.map { .available(version: $0.version.description, notes: $0.notes) } ?? .idle
            }
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        switch http.statusCode {
        case 404: throw UpdateError.message("The update source wasn't found.")
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            throw UpdateError.message("GitHub asked us to wait a while before checking again. Try again in an hour.")
        default: throw UpdateError.message("GitHub answered with an error (\(http.statusCode)).")
        }
    }

    private static func explain(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.localizedDescription }
        if let e = error as? HelperError { return e.localizedDescription }
        if (error as? URLError)?.code == .notConnectedToInternet || (error as? URLError)?.code == .timedOut {
            return "Couldn't reach GitHub. Check the internet connection."
        }
        return "Couldn't check for updates: \(error.localizedDescription)"
    }

    // MARK: Installing

    func install() async {
        guard case .available = state, let offer else { return }
        if isBusy() {
            state = .problem("Media Helper is busy. Wait until the current downloads and conversions have finished, then install the update.")
            showsResult = true
            return
        }
        do {
            let bundle = Bundle.main.bundleURL
            try Self.checkInstallLocation(bundle)

            state = .installing(step: "Downloading version \(offer.version)…", progress: 0)
            let fm = FileManager.default
            let updatesDir = AppPaths.updatesDir
            try fm.createDirectory(at: updatesDir, withIntermediateDirectories: true)
            let work = updatesDir.appendingPathComponent("download-\(offer.version)", isDirectory: true)
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            let zip = work.appendingPathComponent(offer.zip.name)
            try await FileDownloader.download(offer.zip.browserDownloadURL, to: zip) { p in
                Task { @MainActor in
                    if case .installing = self.state { self.state = .installing(step: "Downloading version \(offer.version)…", progress: p) }
                }
            }
            let sigFile = work.appendingPathComponent(offer.signature.name)
            try await FileDownloader.download(offer.signature.browserDownloadURL, to: sigFile)

            state = .installing(step: "Checking the download is genuine…", progress: nil)
            let digest = try UpdateVerifier.digest(of: zip)
            let signature = (try? String(contentsOf: sigFile, encoding: .utf8)) ?? ""
            guard UpdateVerifier.isValid(signatureBase64: signature, digest: digest, publicKeyBase64: Self.publicKey) else {
                throw UpdateError.message("The download didn't pass its security check, so it was NOT installed. Nothing has changed.")
            }

            state = .installing(step: "Preparing the new version…", progress: nil)
            let staged = try await Self.unpackAndValidate(zip: zip, version: offer.version, current: currentVersion, in: work)

            state = .installing(step: "Restarting…", progress: nil)
            try Self.launchSwap(newApp: staged, current: bundle)
            try await Task.sleep(for: .milliseconds(600))
            quitForRelaunch()
        } catch {
            state = .problem(Self.explain(error))
            showsResult = true
        }
    }

    /// The app can only replace itself where it lives: not from inside a disk image or a
    /// quarantined download (macOS runs those from a read-only copy), and not somewhere read-only.
    static func checkInstallLocation(_ bundle: URL) throws {
        if bundle.path.contains("/AppTranslocation/") || bundle.path.hasPrefix("/Volumes/") {
            throw UpdateError.message("Media Helper is running from a disk image or download. Drag it into the Applications folder, open it from there, then update.")
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            throw UpdateError.message("Media Helper can't replace itself in this folder. Move it to Applications (as an administrator) and try again.")
        }
    }

    /// Unzips and refuses anything that isn't this app at the signed version.
    static func unpackAndValidate(zip: URL, version: AppVersion, current: AppVersion, in dir: URL) async throws -> URL {
        let out = dir.appendingPathComponent("unpacked", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], failure: "The update couldn't be unpacked.")

        let app = out.appendingPathComponent("Media Helper.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.message("The update didn't contain Media Helper.")
        }
        guard (info["CFBundleIdentifier"] as? String) == Bundle.main.bundleIdentifier else {
            throw UpdateError.message("The update is for a different app, so it was not installed.")
        }
        guard let v = AppVersion((info["CFBundleShortVersionString"] as? String) ?? ""), v == version, v > current else {
            throw UpdateError.message("The update's version doesn't match what was announced, so it was not installed.")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                      failure: "The update's code signature is damaged, so it was not installed.")
        return app
    }

    /// Hands over to a tiny script that waits for this app to quit, swaps the
    /// bundles (keeping the old one as a backup), and reopens the app. If anything
    /// fails it puts the old version back and reopens that.
    static func launchSwap(newApp: URL, current: URL) throws {
        let backupDir = AppPaths.updatesDir.appendingPathComponent("Previous", isDirectory: true)
        let script = AppPaths.updatesDir.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        # Swaps in the new Media Helper once the old one has quit; restores the old one on any failure.
        pid="$1"; new="$2"; cur="$3"; backup="$4"; shift 4
        reopen() { if [ $# -gt 0 ]; then open "$cur" --args "$@"; else open "$cur"; fi; }
        while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
        mkdir -p "$backup"; rm -rf "${backup:?}/Media Helper.app"
        if mv "$cur" "$backup/Media Helper.app"; then
          if mv "$new" "$cur"; then reopen "$@"; exit 0; fi
          mv "$backup/Media Helper.app" "$cur"
        fi
        reopen "$@"
        exit 1
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Reopen with the settings flags this run had (none for a normal launch), so a
        // test copy keeps pointing at its test folders. Never carries the install trigger.
        var carry: [String] = []
        for flag in ["-supportDir", "-toolsDir", "-updateFeed", "-updateKey", "-currentVersion"] {
            if let v = Flags.value(flag) { carry += [flag, v] }
        }
        // Background it so it outlives this process, which is about to quit.
        p.arguments = ["-c", "nohup /bin/sh \"$@\" >/dev/null 2>&1 &", "_",
                       script.path, String(ProcessInfo.processInfo.processIdentifier),
                       newApp.path, current.path, backupDir.path] + carry
        try p.run()
        p.waitUntilExit()
    }

    private static func run(_ tool: String, _ args: [String], failure: String) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw UpdateError.message(failure) }
        }.value
    }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
