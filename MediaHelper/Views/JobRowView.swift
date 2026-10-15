import SwiftUI

struct JobRowView: View {
    let job: Job
    let onShow: (URL) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(.headline).lineLimit(1).truncationMode(.middle)
                if job.isActive {
                    ProgressView(value: job.status == .waiting ? 0 : job.progress)
                }
                Text(job.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = job.subtitle, job.title == "YouTube link" {
                    Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var actions: some View {
        switch job.status {
        case .waiting, .running:
            Button("Cancel") { job.cancel() }
        case .done:
            HStack {
                if let url = job.outputURL { Button("Show in Finder") { onShow(url) } }
                Button { onRemove() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from the list")
            }
        case .failed, .cancelled:
            Button { onRemove() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from the list")
        }
    }

    private var icon: String {
        switch job.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        default: return job.activeIcon ?? (job.isAudioOutput ? "waveform.circle" : "arrow.down.circle")
        }
    }
    private var tint: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }
    private var statusColor: Color {
        if case .failed = job.status { return .red }
        return .secondary
    }
}

struct JobListView: View {
    @Environment(AppModel.self) private var model
    let queue: JobQueue
    let emptyText: String

    var body: some View {
        VStack(spacing: 8) {
            if queue.jobs.isEmpty {
                Spacer()
                Text(emptyText).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.jobs) { job in
                            JobRowView(job: job, onShow: { model.showInFinder($0) }, onRemove: { queue.remove(job) })
                        }
                    }
                    .padding(.vertical, 2)
                }
                if queue.hasFinished {
                    HStack { Spacer(); Button("Clear Finished") { queue.clearFinished() }.buttonStyle(.link) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
