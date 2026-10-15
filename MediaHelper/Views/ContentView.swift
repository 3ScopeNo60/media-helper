import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            UpdateBanner()
            VStack(spacing: 14) {
                Picker("", selection: $model.section) {
                    ForEach(AppSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)

                // The slide tab needs none of the downloaded tools, so it is usable straight away.
                if !model.tools.isReady && model.section != .slides { SetupCard() }

                Group {
                    switch model.section {
                    case .download: DownloadView()
                    case .convert: ConvertView(dropTargeted: dropTargeted)
                    case .slides: SlidesView(dropTargeted: dropTargeted)
                    }
                }
                .disabled(!model.acceptsDrops())
                .opacity(model.acceptsDrops() ? 1 : 0.45)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Divider().padding(.top, 8)
            SaveFolderBar()
        }
        .frame(minWidth: 620, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard model.acceptsDrops() else { return false }
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers where p.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url); group.leave() } } else { group.leave() }
                }
            }
            group.notify(queue: .main) { model.handleDrop(urls) }
            return true
        }
        .task { model.start() }
    }
}

/// First-run setup / failure state.
struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            switch model.tools.state {
            case .failed(let message):
                Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Media Helper couldn't finish getting ready").font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Try Again") { model.tools.retry() }.buttonStyle(.borderedProminent).controlSize(.large)
            case .settingUp(let step, let progress):
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Getting ready… (one-time setup, needs internet)").font(.headline)
                    Text(step).font(.callout).foregroundStyle(.secondary)
                    if let progress { ProgressView(value: progress).frame(maxWidth: 260) }
                }
                Spacer()
            default:
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Getting ready… (one-time setup, needs internet)").font(.headline)
                    Text("Just a moment.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        Group {
            switch updates.state {
            case .available(let version, _):
                row(icon: "arrow.down.circle.fill", tint: .accentColor, text: "Version \(version) is available") {
                    Button("Install") { Task { await updates.install() } }.buttonStyle(.borderedProminent)
                }
            case .installing(let step, let progress):
                row(icon: "arrow.triangle.2.circlepath", tint: .accentColor, text: step) {
                    if let progress { ProgressView(value: progress).frame(width: 120) } else { ProgressView().controlSize(.small) }
                }
            case .upToDate where updates.showsResult:
                row(icon: "checkmark.circle.fill", tint: .green, text: "Media Helper is up to date (version \(updates.currentVersion)).") {
                    Button("OK") { updates.dismissResult() }
                }
            case .checking where updates.showsResult:
                row(icon: "magnifyingglass", tint: .secondary, text: "Checking for updates…") { ProgressView().controlSize(.small) }
            case .problem(let message) where updates.showsResult:
                row(icon: "exclamationmark.triangle.fill", tint: .orange, text: message) {
                    Button("OK") { updates.dismissResult() }
                }
            default:
                EmptyView()
            }
        }
    }

    private func row<Trailing: View>(icon: String, tint: Color, text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(tint.opacity(0.12))
    }
}

struct SaveFolderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text("Save to:").foregroundStyle(.secondary)
                Text(model.saveFolderName).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    .help(model.saveFolder.path)
                Button("Change…") { model.chooseSaveFolder() }
                Spacer()
                Button("Open Folder") { model.openSaveFolder() }.buttonStyle(.link)
            }
            ToolsFootnote()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

/// Small print: the helper programs' versions, for whoever is troubleshooting.
struct ToolsFootnote: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let v = model.tools.versions
        HStack {
            Text(footnote(v)).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
    }
    private func footnote(_ v: Tools.Versions) -> String {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard model.tools.isReady else { return "Media Helper \(app)" }
        return "Media Helper \(app)  ·  Tools: downloader \(v.downloader ?? "?"), converter \(v.converter ?? "?")"
    }
}
