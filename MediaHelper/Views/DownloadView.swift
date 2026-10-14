import SwiftUI

struct DownloadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste YouTube links below, one on each line.").font(.headline)

            TextEditor(text: $model.linksText)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .overlay(alignment: .topLeading) {
                    if model.linksText.isEmpty {
                        Text(verbatim: "https://www.youtube.com/watch?v=…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }

            HStack(spacing: 14) {
                Picker("Get:", selection: $model.downloadKind) {
                    ForEach(DownloadKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                if model.downloadKind == .audio {
                    Picker("Format:", selection: $model.audioFormat) {
                        ForEach(AudioFormat.allCases) { Text($0 == .mp3 ? "MP3 (works everywhere)" : "M4A").tag($0) }
                    }
                    .fixedSize()
                } else {
                    Picker("Quality:", selection: $model.videoQuality) {
                        ForEach(YouTubeDownloader.VideoQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Download") { model.startDownloads() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(YouTubeDownloader.parseLinks(model.linksText).links.isEmpty)
            }

            if model.downloadKind == .video {
                Text("Videos are saved as MP4 (H.264 video with AAC sound), which plays in PowerPoint, ProPresenter and QuickTime.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.skippedLines > 0 {
                Text("\(model.skippedLines) \(model.skippedLines == 1 ? "line wasn't" : "lines weren't") a link, so \(model.skippedLines == 1 ? "it was" : "they were") skipped.")
                    .font(.caption).foregroundStyle(.orange)
            }

            JobListView(queue: model.downloads, emptyText: "Your downloads will appear here.")
        }
    }
}
