import SwiftUI
import ModelAPI

struct JobsPage: View {
    @Bindable var store: AppStore
    var body: some View {
        PageHeading(title: "Jobs", detail: "Temporary local execution queue. Connected apps own durable history and retries.")
        if store.jobRecords.isEmpty {
            ContentUnavailableView("No jobs yet", systemImage: "list.bullet.rectangle", description: Text("Audio, model loads and inference requests appear here."))
        }
        ForEach(Array(store.jobRecords.suffix(200))) { job in
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.model).font(.headline)
                            Text(job.operation.capitalized).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(label(job.state)).font(.callout)
                        if !job.state.terminal { Button("Cancel") { Task { try? await store.jobs.cancel(job.id); await store.refreshJobs() } } }
                    }
                    if let position = job.position { Text("Queue position \(position)").font(.caption).foregroundStyle(.secondary) }
                    if let progress = job.progress { ProgressView(value: progress) }
                    if let message = job.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if let resources = job.resources, resources.reason != nil {
                        Text("RAM: \(bytes(resources.availableMemoryBytes)) available / \(bytes(resources.requiredMemoryBytes)) required · Disk: \(bytes(resources.availableDiskBytes)) available")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(job.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Text("Completed results expire after 30 minutes. Quitting discards this queue and its private temporary files; jobs are never replayed after restart.").font(.caption).foregroundStyle(.secondary)
            .task { while !Task.isCancelled { await store.refreshJobs(); do { try await Task.sleep(for: .seconds(1)) } catch { break } } }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .memory) }
    private func label(_ state: JobState) -> String {
        switch state { case .waitingForResources: "Waiting for resources"; default: state.rawValue.capitalized }
    }
}
