import Foundation

/// Lets a job stop every program it has started (and anything those started).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// False when already cancelled (the caller must not start the program).
    fileprivate func register(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        processes.append(p)
        return true
    }

    fileprivate func unregister(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        processes.removeAll { $0 === p }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = processes
        lock.unlock()
        for p in running { ProcessTree.terminate(p) }
    }

    func throwIfCancelled() throws { if isCancelled { throw HelperError.cancelled } }
}

enum ProcessTree {
    /// Stops a program and everything below it (the downloader starts the converter,
    /// and the standalone downloader starts a second copy of itself). Escalates to a
    /// hard kill if something ignores the polite request.
    static func terminate(_ p: Process) {
        guard p.isRunning else { return }
        let pids = [p.processIdentifier] + descendants(of: p.processIdentifier)
        for pid in pids.reversed() { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        q.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        q.standardOutput = pipe
        q.standardError = FileHandle.nullDevice
        guard (try? q.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        q.waitUntilExit()
        let kids = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { pid_t($0) }
        return kids + kids.flatMap { descendants(of: $0) }
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    /// True when the program was stopped by a signal (for example macOS refusing to run it).
    let killedBySignal: Bool
    var succeeded: Bool { status == 0 && !killedBySignal }
}

/// Collects a program's output and hands out complete lines as they arrive.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var text = Data()
    private let onLine: ((String) -> Void)?
    private let cap: Int

    init(onLine: ((String) -> Void)?, cap: Int = 4_000_000) { self.onLine = onLine; self.cap = cap }

    func feed(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        if text.count < cap { text.append(data) }
        pending.append(data)
        // Split on newline and carriage return (the downloader redraws progress with \r).
        while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<i]
            pending.removeSubrange(pending.startIndex...i)
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
        }
        lock.unlock()
        if let onLine { lines.forEach(onLine) }
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        if !rest.isEmpty, let onLine { onLine(String(decoding: rest, as: UTF8.self)) }
    }

    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: text, as: UTF8.self) }
}

enum ProcessRunner {
    /// A sane environment for every program we start: the app doesn't inherit a login
    /// shell, so PATH is set explicitly (our own tools first, then Homebrew, then system),
    /// output is UTF-8, and Python/dyld variables that could confuse the standalone
    /// downloader are removed.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("DYLD_") || k.hasPrefix("PYTHON") { env[k] = nil }
        env["PATH"] = [AppPaths.toolsDir.path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        env["LANG"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// Runs a program to completion. Standard output and error are both drained as the
    /// program runs (so a chatty program can never fill a pipe and stall). Lines are
    /// passed to the callbacks as they arrive.
    static func run(
        _ executable: String, _ arguments: [String],
        token: CancelToken? = nil,
        onStdoutLine: ((String) -> Void)? = nil,
        onStderrLine: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try token?.throwIfCancelled()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = LineCollector(onLine: onStdoutLine)
        let err = LineCollector(onLine: onStderrLine)

        let result: ProcessResult = try await withCheckedThrowingContinuation { cont in
            // Finish once: the program exited AND both pipes reached the end. If a
            // stray grandchild keeps a pipe open, give up waiting two seconds after exit.
            let lock = NSLock()
            var remaining = 3
            var finished = false
            let finish: () -> Void = {
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.finish(); err.finish()
                token?.unregister(process)
                cont.resume(returning: ProcessResult(
                    status: process.terminationStatus, stdout: out.string, stderr: err.string,
                    killedBySignal: process.terminationReason == .uncaughtSignal))
            }
            let oneDone: () -> Void = {
                lock.lock(); remaining -= 1; let all = remaining == 0; lock.unlock()
                if all { finish() }
            }
            func drain(_ pipe: Pipe, _ collector: LineCollector) {
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; oneDone() } else { collector.feed(d) }
                }
            }
            drain(outPipe, out); drain(errPipe, err)
            process.terminationHandler = { _ in
                oneDone()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish() }
            }
            let abort: (HelperError) -> Void = { error in
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                token?.unregister(process)
                cont.resume(throwing: error)
            }
            if let token, !token.register(process) { abort(.cancelled); return }
            do { try process.run() } catch {
                abort(.message("Couldn't start a helper program: \(error.localizedDescription)"))
            }
        }
        try token?.throwIfCancelled()
        return result
    }
}
