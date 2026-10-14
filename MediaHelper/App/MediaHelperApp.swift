import SwiftUI
import AppKit

@main
struct Entry {
    static func main() {
        if QA.runIfRequested() {
            dispatchMain()              // headless QA run: exits itself when done
        } else {
            MediaHelperApp.main()
        }
    }
}

struct MediaHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Media Helper", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Media Helper") { showAbout(model) }
                Button("Check for Updates…") { Task { await model.updates.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func showAbout(_ model: AppModel) {
        let v = model.tools.versions
        let text = """
        Download audio and video from YouTube, and turn videos into audio files.

        Tools: downloader \(v.downloader ?? "not installed"), converter \(v.converter ?? "not installed").
        """
        let credits = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting stops any running download or conversion and clears its partial files.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cancelEverything() }
        Thread.sleep(forTimeInterval: 0.3)
    }
}
