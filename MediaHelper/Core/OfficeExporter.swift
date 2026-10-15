import Foundation
import AppKit

/// Turns a PowerPoint or Keynote file into a PDF using whichever program is installed:
/// LibreOffice (runs invisibly), or PowerPoint / Keynote (driven with AppleScript).
///
/// PowerPoint and Keynote get a private copy of the file under a unique name, so the original is never
/// opened, locked or changed, and we can always find (and close) exactly our own document. The copy is
/// closed without saving, apps that weren't running before are quit again, and everything temporary is deleted.
/// Jobs run one at a time because these apps can't be driven in parallel.
enum OfficeExporter {
    static func exportPDF(input: URL, renderer: SlideRenderer, workDir: URL, token: CancelToken,
                          onStatus: @escaping (String) -> Void) async throws -> URL {
        switch renderer {
        case .libreOffice: return try await withLibreOffice(input: input, workDir: workDir, token: token)
        case .powerPoint, .keynote: return try await withApp(input: input, renderer: renderer, workDir: workDir, token: token, onStatus: onStatus)
        }
    }

    // MARK: LibreOffice

    static func libreOfficeArguments(input: URL, outDir: URL, profileDir: URL) -> [String] {
        ["--headless", "--norestore", "--nofirststartwizard", "-env:UserInstallation=\(profileDir.absoluteString)",
         "--convert-to", "pdf", "--outdir", outDir.path, input.path]
    }

    private static func withLibreOffice(input: URL, workDir: URL, token: CancelToken) async throws -> URL {
        guard let soffice = SlideRenderer.detectInstalled().libreOffice else { throw HelperError.message(SlideRenderer.missingMessage(forExtension: "pptx")) }
        let out = workDir.appendingPathComponent("lo-out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A private profile, so a LibreOffice window the person already has open can't get in the way.
        let profile = workDir.appendingPathComponent("lo-profile", isDirectory: true)
        let r = try await ProcessRunner.run(soffice.path, libreOfficeArguments(input: input, outDir: out, profileDir: profile), token: token)
        let pdf = out.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            throw HelperError.message("LibreOffice couldn't open that presentation. It may be damaged or locked with a password.")
        }
        _ = r
        return pdf
    }

    // MARK: PowerPoint and Keynote

    private static func withApp(input: URL, renderer: SlideRenderer, workDir: URL, token: CancelToken,
                                onStatus: @escaping (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let installed = SlideRenderer.detectInstalled()
        guard let appURL = renderer == .powerPoint ? installed.powerPoint : installed.keynote else {
            throw HelperError.message(SlideRenderer.missingMessage(forExtension: renderer == .keynote ? "key" : "pptx"))
        }
        let bundleID = renderer == .powerPoint ? SlideRenderer.powerPointID : SlideRenderer.keynoteID
        let title = renderer.title

        // A private copy under a name nothing else has.
        let tag = "mh" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let copyDir = workDir.appendingPathComponent("copy", isDirectory: true)
        try fm.createDirectory(at: copyDir, withIntermediateDirectories: true)
        let niceName = String(Naming.sanitize(input.deletingPathExtension().lastPathComponent, fallback: "Slides").prefix(60))
        let copy = copyDir.appendingPathComponent("\(niceName) \(tag).\(input.pathExtension.lowercased())")
        do { try fm.copyItem(at: input, to: copy) } catch {
            throw HelperError.message("That file couldn't be read: \(error.localizedDescription)")
        }
        // Files that came from the internet would open "protected" and refuse to export.
        _ = removexattr(copy.path, "com.apple.quarantine", 0)

        // Where the app saves its PDF. PowerPoint is sandboxed: it may only write to files a person gave it,
        // and anywhere else it stops with a "Grant File Access" box that needs someone to click. The one thing
        // its sandbox does allow is writing to an existing file whose name starts with "~$" (Office's own
        // lock files), so the PDF is saved into one of those, in our private scratch folder.
        var pdf = workDir.appendingPathComponent("slides.pdf")
        if renderer == .powerPoint {
            pdf = workDir.appendingPathComponent("~$MediaHelper-\(tag).pdf")
            fm.createFile(atPath: pdf.path, contents: Data())
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if !wasRunning { OfficeSession.shared.markLaunchedByUs(bundleID) }

        OfficeSession.shared.addOpen(bundleID: bundleID, renderer: renderer, tag: tag)
        var askedToOpen = false
        func cleanUp() async {
            await closeLeftovers(bundleID: bundleID, renderer: renderer, tag: tag, tries: askedToOpen ? 20 : 1)
            OfficeSession.shared.removeOpen(tag: tag)
        }

        do {
            try token.throwIfCancelled()
            // Opened the way a person would open it, which is what lets these sandboxed apps read the file.
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            askedToOpen = true
            do { _ = try await NSWorkspace.shared.open([copy], withApplicationAt: appURL, configuration: cfg) } catch {
                throw HelperError.message("\(title) couldn't open that presentation: \(error.localizedDescription)")
            }
            try token.throwIfCancelled()
            onStatus("Saving the slides from \(title)…")

            let scriptURL = workDir.appendingPathComponent("export.applescript")
            try script(for: renderer).write(to: scriptURL, atomically: true, encoding: .utf8)
            let r = try await ProcessRunner.run("/usr/bin/osascript", [scriptURL.path, tag, pdf.path], token: token)
            try token.throwIfCancelled()
            guard r.succeeded else { throw HelperError.message(explain(stderr: r.stderr, appTitle: title)) }
            guard let size = (try? fm.attributesOfItem(atPath: pdf.path))?[.size] as? Int, size > 0 else {
                throw HelperError.message("\(title) didn't save the slides. Try again, or open the file in \(title) to check it opens.")
            }
            let local = workDir.appendingPathComponent("slides-from-app.pdf")
            do { try fm.moveItem(at: pdf, to: local) } catch {
                throw HelperError.message("The slides were exported but couldn't be read back: \(error.localizedDescription)")
            }
            await cleanUp()
            return local
        } catch {
            await cleanUp()
            throw error
        }
    }

    /// One AppleScript for each app. Arguments: unique tag in the copy's name, PDF path.
    /// Waits for our copy to finish opening, saves it as a PDF, closes it without saving.
    static func script(for renderer: SlideRenderer) -> String {
        let id = renderer.bundleID ?? ""
        let (thing, count) = renderer == .powerPoint ? ("presentation", "presentations") : ("document", "documents")
        // PowerPoint can save as soon as the presentation exists; Keynote also needs its slides to have loaded.
        let waitForSlides = renderer == .powerPoint ? "exit repeat" : """
        try
                                if (count of slides of document foundName) > 0 then exit repeat
                            end try
        """
        let save = renderer == .powerPoint
            ? "save presentation foundName in (POSIX file outPath) as save as PDF"
            : "export document foundName to POSIX file outPath as PDF with properties {PDF image quality:Best}"
        return """
        on run argv
            set theTag to item 1 of argv
            set outPath to item 2 of argv
            with timeout of 1800 seconds
                tell application id "\(id)"
                    set foundName to missing value
                    repeat 240 times
                        try
                            repeat with i from 1 to (count of \(count))
                                if (name of \(thing) i) contains theTag then set foundName to (name of \(thing) i)
                            end repeat
                        end try
                        if foundName is not missing value then
                            \(waitForSlides)
                        end if
                        delay 0.5
                    end repeat
                    if foundName is missing value then error "The presentation did not open." number 9001
                    \(save)
                    close \(thing) foundName saving no
                end tell
            end timeout
        end run
        """
    }

    /// Closes our copy, waiting up to `tries` half-seconds for it to show up (an app that was just asked to open
    /// a file may not have opened it yet when the job is cancelled).
    private static func closeScript(bundleID: String, renderer: SlideRenderer, tries: Int) -> String {
        let noun = renderer == .powerPoint ? "presentations" : "documents"
        let single = renderer == .powerPoint ? "presentation" : "document"
        return """
        on run argv
            with timeout of 60 seconds
                repeat \(tries) times
                    set didClose to false
                    if application id "\(bundleID)" is running then
                        tell application id "\(bundleID)"
                            try
                                repeat with i from (count of \(noun)) to 1 by -1
                                    if (name of \(single) i) contains (item 1 of argv) then
                                        close \(single) i saving no
                                        set didClose to true
                                    end if
                                end repeat
                            end try
                        end tell
                    end if
                    if didClose then exit repeat
                    delay 0.5
                end repeat
            end timeout
        end run
        """
    }

    /// Closes our copy if something went wrong half way (or the job was cancelled).
    private static func closeLeftovers(bundleID: String, renderer: SlideRenderer, tag: String, tries: Int) async {
        // (No "is it running" check here: the app may still be starting up, and the script waits for it.)
        _ = await runInline(closeScript(bundleID: bundleID, renderer: renderer, tries: tries), [tag])
    }

    /// For when Media Helper itself is quitting: closes any copy still open, waiting a few seconds at most.
    static func closeLeftoversBlocking() {
        for item in OfficeSession.shared.openItems() where !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).isEmpty {
            guard let dir = try? AppPaths.makeWorkDir() else { continue }
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("s.applescript")
            guard (try? closeScript(bundleID: item.bundleID, renderer: item.renderer, tries: 6).write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = [file.path, item.tag]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { p.terminate() }
        }
    }

    /// Quits PowerPoint/Keynote again if this app was the one that started it and nothing else is open in it.
    /// Called when the slide list goes quiet (and at the end of a headless test run).
    static func quitAppsWeStarted() async {
        for id in OfficeSession.shared.takeLaunchedByUs() {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { continue }
            let noun = id == SlideRenderer.powerPointID ? "presentations" : "documents"
            let source = """
            on run argv
                with timeout of 20 seconds
                    tell application id "\(id)"
                        if (count of \(noun)) is 0 then quit
                    end tell
                end timeout
            end run
            """
            _ = await runInline(source, [])
        }
    }

    private static func runInline(_ source: String, _ args: [String]) async -> ProcessResult? {
        guard let dir = try? AppPaths.makeWorkDir() else { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.applescript")
        guard (try? source.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        return try? await ProcessRunner.run("/usr/bin/osascript", [file.path] + args)
    }

    /// Turns AppleScript's complaints into plain words.
    static func explain(stderr: String, appTitle: String) -> String {
        let s = stderr
        if s.contains("-1743") {
            return "Media Helper isn't allowed to control \(appTitle) yet. Open System Settings ▸ Privacy & Security ▸ Automation, turn on \(appTitle) under Media Helper, and try again."
        }
        if s.contains("9001") {
            return "\(appTitle) didn't finish opening the presentation. It may be locked with a password, damaged, or very large."
        }
        if s.contains("-1712") {
            return "\(appTitle) took too long. Check whether it is showing a message that needs an answer, then try again."
        }
        if s.contains("-128") {
            return "\(appTitle) asked a question that wasn't answered, so the slides weren't saved."
        }
        if s.contains("-600") || s.contains("-609") || s.contains("-10810") {
            return "\(appTitle) stopped unexpectedly. Try again."
        }
        let last = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.last
        return last.map { "\(appTitle) couldn't save the slides: \(String($0.prefix(200)))" } ?? "\(appTitle) couldn't save the slides."
    }
}

/// Remembers which apps Media Helper started itself, so it only quits those.
final class OfficeSession: @unchecked Sendable {
    static let shared = OfficeSession()
    private let lock = NSLock()
    private var launched = Set<String>()
    struct Open { let bundleID: String; let renderer: SlideRenderer; let tag: String }
    private var open: [Open] = []
    func addOpen(bundleID: String, renderer: SlideRenderer, tag: String) { lock.lock(); open.append(Open(bundleID: bundleID, renderer: renderer, tag: tag)); lock.unlock() }
    func removeOpen(tag: String) { lock.lock(); open.removeAll { $0.tag == tag }; lock.unlock() }
    func openItems() -> [Open] { lock.lock(); defer { lock.unlock() }; return open }
    func markLaunchedByUs(_ id: String) { lock.lock(); launched.insert(id); lock.unlock() }
    func takeLaunchedByUs() -> [String] { lock.lock(); defer { lock.unlock() }; let a = Array(launched); launched.removeAll(); return a }
}
