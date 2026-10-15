import SwiftUI

struct SlidesView: View {
    @Environment(AppModel.self) private var model
    let dropTargeted: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 30)).foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                Text("Drop PowerPoint, Keynote or PDF files here").font(.headline)
                Button("Choose Files…") { model.chooseSlides() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background((dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [7, 5])))

            HStack(spacing: 14) {
                Picker("Make:", selection: $model.slideFormat) {
                    ForEach(SlideImageFormat.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("Size:", selection: $model.slideSize) {
                    ForEach(SlideSize.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Start each name with:")
                TextField("optional, e.g. Sunday_", text: $model.slidePrefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                Spacer()
            }
            Text("Example: \(example)").font(.caption).foregroundStyle(.secondary)

            Text("Each file gets its own folder in your save folder, with one picture for every slide. PowerPoint files need Keynote, PowerPoint or LibreOffice on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.skippedSlideFiles > 0 {
                Text("\(model.skippedSlideFiles) \(model.skippedSlideFiles == 1 ? "file wasn't a PowerPoint, Keynote or PDF file" : "files weren't PowerPoint, Keynote or PDF files"), so \(model.skippedSlideFiles == 1 ? "it was" : "they were") skipped.")
                    .font(.caption).foregroundStyle(.orange)
            }

            JobListView(queue: model.slides, emptyText: "Your slide pictures will appear here.")
        }
    }

    private var example: String {
        SlideNaming.fileName(prefix: model.slidePrefix, name: "Sunday_Slides", number: 1, total: 12, ext: model.slideFormat.ext)
    }
}
