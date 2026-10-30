import SwiftUI
import ModelAPI
import ModelService

struct JobsPage: View {
    @Bindable var store: AppStore
    @State private var snapshot: ResourceSnapshot?
    var body: some View {
        PageHeading(title: "Jobs", detail: "Temporary local execution queue. Connected apps own durable history and retries.")
        GroupBox("Mac memory") {
            if let snapshot, let memory = snapshot.memory {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(bytes(snapshot.available)) estimated available").font(.headline)
                    Text("\(bytes(memory.freeBytes)) immediately reusable + \(bytes(memory.fileCacheBytes)) file cache + \(bytes(memory.purgeableBytes)) purgeable")
                    let headroom = ResourceMonitor.headroom(physical: snapshot.physical)
                    Text("\(bytes(headroom)) stays available for macOS and other apps · \(bytes(max(0, snapshot.available - headroom))) for additional model memory")
                    Text("Pressure: \(snapshot.pressure == 1 ? "Normal" : "Elevated") · Recent swap activity: \(bytes(snapshot.swapActivityBytes)) / 30 seconds")
                    Text("Cached memory is already included. Wired memory and compressed app data are excluded; Positronic never forces a cache purge.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else { Text("Waiting for memory telemetry…").foregroundStyle(.secondary).padding(12) }
        }
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
                    if let resources = job.resources {
                        Text("RAM: \(bytes(resources.availableMemoryBytes)) available / \(bytes(resources.requiredMemoryBytes)) required · Disk: \(bytes(resources.availableDiskBytes)) available")
                            .font(.caption).foregroundStyle(.secondary)
                        if let memory = resources.memory {
                            Text("Includes \(bytes(memory.reclaimableBytes)) estimated reclaimable cache · System headroom: \(bytes(resources.systemHeadroomBytes ?? 0))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(job.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Text("Completed results expire after 30 minutes. Quitting discards this queue and its private temporary files; jobs are never replayed after restart.").font(.caption).foregroundStyle(.secondary)
            .task { while !Task.isCancelled { await store.refreshJobs(); snapshot = try? ResourceMonitor.snapshot(); do { try await Task.sleep(for: .seconds(1)) } catch { break } } }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .memory) }
    private func label(_ state: JobState) -> String {
        switch state { case .waitingForResources: "Waiting for resources"; default: state.rawValue.capitalized }
    }
}
