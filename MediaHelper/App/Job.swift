import Foundation
import Observation

/// One row in a list: a download or a conversion.
@MainActor
@Observable
final class Job: Identifiable {
    enum Status: Equatable {
        case waiting
        case running
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    var title: String
    let subtitle: String?
    let isAudioOutput: Bool
    private(set) var status: Status = .waiting
    private(set) var statusText = "Waiting…"
    private(set) var progress = 0.0
    private(set) var outputURL: URL?
    let token = CancelToken()
    /// The work itself. Gets the job so it can report title/progress/status.
    let work: (Job) async throws -> URL

    init(title: String, subtitle: String? = nil, isAudioOutput: Bool, work: @escaping (Job) async throws -> URL) {
        self.title = title; self.subtitle = subtitle; self.isAudioOutput = isAudioOutput; self.work = work
    }

    var isActive: Bool { status == .waiting || status == .running }
    var isFinished: Bool { !isActive }

    // Called from background threads by the Core code; hop to the main actor.
    nonisolated func report(title: String) { Task { @MainActor in if self.status == .running { self.title = title } } }
    nonisolated func report(progress: Double) { Task { @MainActor in if self.status == .running { self.progress = max(self.progress, min(progress, 1)) } } }
    nonisolated func report(status: String) { Task { @MainActor in if self.status == .running { self.statusText = status } } }

    func markRunning() { status = .running; statusText = "Starting…" }
    func markDone(_ url: URL) { status = .done; outputURL = url; progress = 1; statusText = "Done" }
    func markFailed(_ message: String) { status = .failed(message); statusText = message }
    func markCancelled() { status = .cancelled; statusText = "Cancelled" }

    /// Stops the job: a waiting job is simply dropped; a running one has its programs
    /// stopped and its partial files removed by the code that was running it.
    func cancel() {
        switch status {
        case .waiting: markCancelled()
        case .running: statusText = "Cancelling…"; token.cancel()
        default: break
        }
    }
}

/// Runs jobs one at a time, in the order they were added.
@MainActor
@Observable
final class JobQueue {
    private(set) var jobs: [Job] = []
    private var runner: Task<Void, Never>?
    /// Called before each job starts (the app uses it to wait for the downloader to finish updating).
    var beforeEachJob: () async -> Void = {}

    var isBusy: Bool { jobs.contains { $0.isActive } }

    func add(_ job: Job) {
        jobs.append(job)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard runner == nil else { return }
        // Keep macOS from slowing the app down (App Nap) or sleeping while work is running,
        // even if the window is hidden behind another app.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Media Helper is downloading or converting")
        runner = Task { [weak self] in
            while let self, let next = self.jobs.first(where: { $0.status == .waiting }) {
                await self.process(next)
            }
            ProcessInfo.processInfo.endActivity(activity)
            self?.runner = nil
        }
    }

    private func process(_ job: Job) async {
        job.markRunning()
        await beforeEachJob()
        if job.token.isCancelled { job.markCancelled(); return }
        do {
            let url = try await job.work(job)
            job.markDone(url)
        } catch HelperError.cancelled {
            job.markCancelled()
        } catch {
            job.markFailed((error as? HelperError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func clearFinished() { jobs.removeAll { $0.isFinished } }
    func remove(_ job: Job) { if job.isFinished { jobs.removeAll { $0.id == job.id } } }
    func cancelAll() { jobs.forEach { $0.cancel() } }
    var hasFinished: Bool { jobs.contains { $0.isFinished } }
}
