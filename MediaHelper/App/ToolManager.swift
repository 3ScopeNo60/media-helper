import Foundation
import Observation

/// First-run setup and keeping the helper programs current.
@MainActor
@Observable
final class ToolManager {
    enum State: Equatable {
        case starting
        case settingUp(step: String, progress: Double?)
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var versions = Tools.Versions()
    private var task: Task<Void, Never>?

    var isReady: Bool { state == .ready }

    private static let lastCheckKey = "lastDownloaderUpdateCheck"
    private static let dayInSeconds: TimeInterval = 24 * 3600

    /// Installs whatever is missing (needs internet the first time), then quietly updates
    /// the downloader if it hasn't been checked for a day.
    func prepare() {
        guard task == nil else { return }
        state = .starting
        task = Task { [weak self] in
            await self?.runPrepare()
            self?.task = nil
        }
    }

    func retry() { prepare() }

    private func runPrepare() async {
        var lastError: String?
        var installedDownloaderNow = false

        if ToolInstaller.needsDownloader {
            state = .settingUp(step: "Getting the YouTube downloader…", progress: nil)
            do {
                try await ToolInstaller.installDownloader { p in Task { @MainActor in self.setStep("Getting the YouTube downloader…", p) } }
                installedDownloaderNow = true
            } catch { lastError = Self.describe(error) }
        }
        if ToolInstaller.needsConverter {
            state = .settingUp(step: "Getting the audio and video converter…", progress: nil)
            do {
                try await ToolInstaller.installConverter { p in Task { @MainActor in self.setStep("Getting the audio and video converter…", p) } }
            } catch { lastError = Self.describe(error) }
        }

        // Homebrew copies are accepted only as a fallback when installing our own failed.
        guard Tools.hasEverything else {
            state = .failed(lastError ?? "Media Helper couldn't finish setting up.")
            return
        }
        versions = await Tools.versions()
        state = .ready

        if installedDownloaderNow { recordCheck() } else { await silentUpdateIfDue() }
    }

    private func setStep(_ text: String, _ p: Double) {
        if case .settingUp = state { state = .settingUp(step: text, progress: p) }
    }

    private static func describe(_ error: Error) -> String {
        if (error as? URLError) != nil { return "Couldn't reach the internet. Check the connection and try again." }
        return (error as? HelperError)?.errorDescription ?? error.localizedDescription
    }

    private func recordCheck() {
        guard !Flags.has("-noRecordUpdateCheck") else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
    }

    /// Silent `yt-dlp -U` at launch when the last check was more than 24 hours ago.
    private func silentUpdateIfDue() async {
        guard Tools.isManaged("yt-dlp") else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.dayInSeconds { return }
        if (try? await ToolInstaller.updateDownloader()) != nil {
            recordCheck()
            versions = await Tools.versions()
        }
    }
}
