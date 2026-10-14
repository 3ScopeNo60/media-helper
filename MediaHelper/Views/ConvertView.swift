import SwiftUI

struct ConvertView: View {
    @Environment(AppModel.self) private var model
    let dropTargeted: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc").font(.system(size: 30)).foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                Text("Drop video files here").font(.headline)
                Button("Choose Files…") { model.chooseVideos() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background((dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [7, 5])))

            HStack(spacing: 14) {
                Picker("Make:", selection: $model.convertFormat) {
                    ForEach(AudioFormat.allCases) { Text($0 == .mp3 ? "MP3 (works everywhere)" : "M4A").tag($0) }
                }
                .fixedSize()
                Picker("Put the audio:", selection: $model.convertNextToOriginal) {
                    Text("In my save folder").tag(false)
                    Text("Next to the original").tag(true)
                }
                .fixedSize()
                Spacer()
            }

            Text("Works with MP4, MOV, M4V, MKV, WEBM and AVI videos.").font(.caption).foregroundStyle(.secondary)
            if model.skippedFiles > 0 {
                Text("\(model.skippedFiles) \(model.skippedFiles == 1 ? "file wasn't a video" : "files weren't videos"), so \(model.skippedFiles == 1 ? "it was" : "they were") skipped.")
                    .font(.caption).foregroundStyle(.orange)
            }

            JobListView(queue: model.conversions, emptyText: "Your converted audio files will appear here.")
        }
    }
}
