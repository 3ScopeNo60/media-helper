import Foundation
import AppKit

/// Headless test entry points. These run the app's own code paths without a window:
///
///   -qaVersions
///   -qaInstallTools                                   install any missing tools (honours -toolsDir)
///   -qaDownload <link> audio|video [-qaFormat mp3|m4a] [-qaQuality best|720|480] [-qaCancelAfter <seconds>] -saveTo <folder>
///   -qaConvert <file> mp3|m4a  (-saveTo <folder> | -nextToOriginal)
///   -qaUpdateTool                                     update the downloader the way a stale-tool retry does
///   -qaUpdateCheck                                    uses -updateFeed / -updateKey / -currentVersion
///   -qaUpdateInstall                                  check, then install if an update is offered
enum QA {
    static let flags = ["-qaVersions", "-qaInstallTools", "-qaDownload", "-qaConvert", "-qaUpdateTool", "-qaUpdateCheck", "-qaUpdateInstall"]

    static func say(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    static func finish(_ code: Int32) -> Never { exit(code) }

    /// Starts the requested headless run. Returns false for a normal launch.
    static func runIfRequested() -> Bool {
        guard let flag = flags.first(where: { Flags.has($0) }) else { return false }
        Task { @MainActor in
            do { try await run(flag) } catch {
                say("QA_ERROR \((error as? HelperError)?.errorDescription ?? error.localizedDescription)")
                finish(1)
            }
        }
        return true
    }

    /// The word after the flag's value, e.g. `-qaDownload <link> audio`.
    private static func second(of flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 2 < a.count else { return nil }
        return a[i + 2]
    }

    @MainActor
    private static func run(_ flag: String) async throws {
        switch flag {
        case "-qaVersions":
            let v = await Tools.versions()
            say("QA_VERSIONS downloader=\(v.downloader ?? "none") converter=\(v.converter ?? "none")")
            finish(0)

        case "-qaInstallTools":
            if ToolInstaller.needsDownloader {
                say("Installing downloader…")
                try await ToolInstaller.installDownloader()
            }
            if ToolInstaller.needsConverter {
                say("Installing converter… (arch: \(ToolInstaller.isAppleSilicon ? "arm64" : "x86_64"))")
                try await ToolInstaller.installConverter()
            }
            let v = await Tools.versions()
            say("QA_INSTALLED toolsDir=\(AppPaths.toolsDir.path)")
            say("QA_VERSIONS downloader=\(v.downloader ?? "none") converter=\(v.converter ?? "none")")
            finish(Tools.hasEverything ? 0 : 1)

        case "-qaDownload":
            guard let link = Flags.value("-qaDownload"), let kind = second(of: "-qaDownload"),
                  let folder = Flags.value("-saveTo") else {
                throw HelperError.message("usage: -qaDownload <link> audio|video -saveTo <folder>")
            }
            let mode: YouTubeDownloader.Mode
            if kind == "audio" { mode = .audio(AudioFormat(rawValue: Flags.value("-qaFormat") ?? "mp3") ?? .mp3) }
            else { mode = .video(YouTubeDownloader.VideoQuality(rawValue: ["720": "p720", "480": "p480"][Flags.value("-qaQuality") ?? ""] ?? "best") ?? .best) }
            var hooks = YouTubeDownloader.Hooks()
            let lastStatus = StatusPrinter()
            hooks.status = { lastStatus.print("status: \($0)") }
            hooks.title = { say("title: \($0)") }
            hooks.progress = { lastStatus.progress($0) }
            let token = CancelToken()
            if let after = Flags.value("-qaCancelAfter").flatMap(Double.init) {
                DispatchQueue.global().asyncAfter(deadline: .now() + after) { say("QA_CANCEL requested"); token.cancel() }
            }
            let r: YouTubeDownloader.Result
            do {
                r = try await YouTubeDownloader.downloadWithAutoUpdate(
                    link: link, mode: mode, saveFolder: URL(fileURLWithPath: folder, isDirectory: true), token: token, hooks: hooks)
            } catch HelperError.cancelled {
                say("QA_CANCELLED")
                finish(0)
            }
            say("QA_RESULT \(r.url.path)")
            say("QA_TITLE \(r.title)")
            if kind == "video" { say("QA_CODECS video=\(r.videoCodec ?? "none") audio=\(r.audioCodec ?? "none") reEncoded=\(r.reEncoded)") }
            finish(0)

        case "-qaConvert":
            guard let file = Flags.value("-qaConvert"), let fmt = second(of: "-qaConvert"), let format = AudioFormat(rawValue: fmt) else {
                throw HelperError.message("usage: -qaConvert <file> mp3|m4a (-saveTo <folder> | -nextToOriginal)")
            }
            let folder = Flags.has("-nextToOriginal") ? nil : Flags.value("-saveTo").map { URL(fileURLWithPath: $0, isDirectory: true) }
            if folder == nil && !Flags.has("-nextToOriginal") { throw HelperError.message("Need -saveTo <folder> or -nextToOriginal") }
            let out = try await MediaConverter.convert(input: URL(fileURLWithPath: file), format: format, outputFolder: folder, token: CancelToken(),
                                                       onStatus: { _ in }, onProgress: { _ in })
            say("QA_RESULT \(out.path)")
            finish(0)

        case "-qaUpdateTool":
            let before = await Tools.versions().downloader ?? "none"
            let after = try await ToolInstaller.updateDownloader()
            say("QA_TOOL_UPDATE before=\(before) after=\(after)")
            finish(0)

        case "-qaUpdateCheck":
            let u = UpdateManager.shared
            await u.check(userInitiated: true)
            report(u.state)
            finish(0)

        case "-qaUpdateInstall":
            let u = UpdateManager.shared
            u.quitForRelaunch = { say("QA_UPDATE relaunching (swap script takes over)"); finish(0) }
            await u.check(userInitiated: true)
            report(u.state)
            guard case .available = u.state else { finish(2) }
            await u.install()
            report(u.state)          // only reached if the install did not go through
            finish(1)

        default: finish(64)
        }
    }

    @MainActor
    private static func report(_ s: UpdateManager.State) {
        switch s {
        case .available(let v, let notes): say("QA_UPDATE available version=\(v) notes=\(notes)")
        case .upToDate: say("QA_UPDATE up-to-date")
        case .problem(let m): say("QA_UPDATE problem: \(m)")
        case .idle: say("QA_UPDATE idle")
        case .checking: say("QA_UPDATE checking")
        case .installing(let step, _): say("QA_UPDATE installing: \(step)")
        }
    }

    /// Prints status changes and coarse progress without flooding the log.
    final class StatusPrinter: @unchecked Sendable {
        private let lock = NSLock()
        private var last = "", lastBucket = -1
        func print(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            if s != last { last = s; QA.say(s) }
        }
        func progress(_ p: Double) {
            lock.lock(); defer { lock.unlock() }
            let b = Int(p * 10)
            if b != lastBucket { lastBucket = b; QA.say("progress: \(Int(p * 100))%") }
        }
    }
}
