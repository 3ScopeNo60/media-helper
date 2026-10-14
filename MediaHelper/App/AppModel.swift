import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case download, convert
    var id: String { rawValue }
    var title: String { self == .download ? "Download from YouTube" : "Video → Audio" }
}

enum DownloadKind: String, CaseIterable, Identifiable {
    case audio, video
    var id: String { rawValue }
    var title: String { self == .audio ? "Audio" : "Video" }
}

@MainActor
@Observable
final class AppModel {
    let tools = ToolManager()
    let updates = UpdateManager.shared
    let downloads = JobQueue()
    let conversions = JobQueue()

    var section: AppSection = .download

    // Download tab
    var linksText = ""
    var skippedLines = 0
    var downloadKind: DownloadKind { didSet { save(downloadKind.rawValue, "downloadKind") } }
    var audioFormat: AudioFormat { didSet { save(audioFormat.rawValue, "audioFormat") } }
    var videoQuality: YouTubeDownloader.VideoQuality { didSet { save(videoQuality.rawValue, "videoQuality") } }

    // Video → Audio tab
    var convertFormat: AudioFormat { didSet { save(convertFormat.rawValue, "convertFormat") } }
    var convertNextToOriginal: Bool { didSet { UserDefaults.standard.set(convertNextToOriginal, forKey: "convertNextToOriginal") } }
    var skippedFiles = 0

    // Shared
    var saveFolder: URL {
        didSet { UserDefaults.standard.set(saveFolder.path, forKey: "saveFolderPath") }
    }

    var isBusy: Bool { downloads.isBusy || conversions.isBusy }

    init() {
        let d = UserDefaults.standard
        downloadKind = DownloadKind(rawValue: d.string(forKey: "downloadKind") ?? "") ?? .audio
        audioFormat = AudioFormat(rawValue: d.string(forKey: "audioFormat") ?? "") ?? .mp3
        videoQuality = YouTubeDownloader.VideoQuality(rawValue: d.string(forKey: "videoQuality") ?? "") ?? .best
        convertFormat = AudioFormat(rawValue: d.string(forKey: "convertFormat") ?? "") ?? .mp3
        convertNextToOriginal = d.bool(forKey: "convertNextToOriginal")
        if let p = d.string(forKey: "saveFolderPath"), FileManager.default.fileExists(atPath: p) {
            saveFolder = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            saveFolder = AppPaths.defaultSaveFolder
        }
    }

    private func save(_ value: String, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    /// Called once when the window first appears.
    func start() {
        let busy: () -> Bool = { [weak self] in self?.isBusy ?? false }
        updates.isBusy = busy
        let wait: () async -> Void = { await ToolInstaller.waitUntilNotUpdating() }
        downloads.beforeEachJob = wait
        tools.prepare()
        if Flags.has("-qaSection") || Flags.has("-qaAutoDownload") || Flags.has("-qaAutoConvert") {
            Task { [weak self] in await self?.runQAAutoActions() }
        }
        Task { [weak self] in
            // Check for app updates at launch and every 6 hours.
            while !Task.isCancelled {
                await self?.updates.check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Test hooks for screenshots: start real downloads/conversions at launch (they use the normal code paths).
    ///   -qaSection download|convert   -qaAutoDownload <link> [-qaAutoKind audio|video]   -qaAutoConvert <file> (repeatable)
    /// (Every value must follow its flag: a stray word on the command line is treated by macOS as a file to open.)
    private func runQAAutoActions() async {
        if let s = Flags.value("-qaSection"), let sec = AppSection(rawValue: s) { section = sec }
        while !tools.isReady { try? await Task.sleep(for: .milliseconds(300)) }
        if let link = Flags.value("-qaAutoDownload") {
            downloadKind = Flags.value("-qaAutoKind") == "video" ? .video : .audio
            linksText = link
            startDownloads()
        }
        let files = Flags.values("-qaAutoConvert").map { URL(fileURLWithPath: $0) }
        if !files.isEmpty { addVideos(files) }
    }

    var saveFolderName: String {
        let name = FileManager.default.displayName(atPath: saveFolder.path)
        return name.isEmpty ? saveFolder.lastPathComponent : name
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }

    // MARK: Downloads

    func startDownloads() {
        let parsed = YouTubeDownloader.parseLinks(linksText)
        skippedLines = parsed.skipped
        guard !parsed.links.isEmpty else { return }
        let mode: YouTubeDownloader.Mode = downloadKind == .audio ? .audio(audioFormat) : .video(videoQuality)
        let folder = saveFolder
        for link in parsed.links {
            let job = Job(title: "YouTube link", subtitle: link, isAudioOutput: downloadKind == .audio) { job in
                var hooks = YouTubeDownloader.Hooks()
                hooks.title = { job.report(title: $0) }
                hooks.progress = { job.report(progress: $0) }
                hooks.status = { job.report(status: $0) }
                let result = try await YouTubeDownloader.downloadWithAutoUpdate(
                    link: link, mode: mode, saveFolder: folder, token: job.token, hooks: hooks)
                return result.url
            }
            downloads.add(job)
        }
        linksText = ""
    }

    // MARK: Conversions

    /// Adds video files (or folders of them) to the conversion list.
    func addVideos(_ urls: [URL]) {
        var files: [URL] = []
        var skipped = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if MediaConverter.isSupportedVideo(k) { files.append(k) }
                }
            } else if MediaConverter.isSupportedVideo(url) { files.append(url) } else { skipped += 1 }
        }
        skippedFiles = skipped
        let format = convertFormat
        let nextToOriginal = convertNextToOriginal
        let folder = saveFolder
        for file in files {
            let job = Job(title: file.lastPathComponent, subtitle: nil, isAudioOutput: true) { job in
                try await MediaConverter.convert(
                    input: file, format: format, outputFolder: nextToOriginal ? nil : folder, token: job.token,
                    onStatus: { job.report(status: $0) }, onProgress: { job.report(progress: $0) })
            }
            conversions.add(job)
        }
        if !files.isEmpty { section = .convert }
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.title = "Choose videos"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { addVideos(panel.urls) }
    }

    // MARK: Misc

    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openSaveFolder() { NSWorkspace.shared.open(saveFolder) }

    func cancelEverything() {
        downloads.cancelAll(); conversions.cancelAll()
    }
}
