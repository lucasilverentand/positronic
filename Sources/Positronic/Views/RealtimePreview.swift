import SwiftUI
import ModelService
import ModelAPI

@MainActor
struct RealtimePreview: View {
    @State private var preview: RealtimePreviewStore
    let available: Bool
    let store: AppStore
    init(store: AppStore, available: Bool) {
        _preview = State(initialValue: RealtimePreviewStore(jobs: store.jobs, runtime: store.audioRuntime)); self.available = available; self.store = store
    }
    var body: some View {
        GroupBox("Try a live conversation") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nemotron listens and speaks on one continuous timeline using its built-in LLM. English only.").font(.caption).foregroundStyle(.secondary)
                TextField("Instructions", text: $preview.instructions).disabled(preview.busy)
                HStack {
                    if preview.busy { Button("Stop conversation", role: .destructive) { preview.stop() } }
                    else { Button("Start conversation") { preview.start() }.buttonStyle(.borderedProminent).disabled(!available || preview.instructions.utf8.count > 1024) }
                    if preview.busy { ProgressView().controlSize(.small) }
                }
                Text(preview.status).font(.caption).foregroundStyle(.secondary)
                Text(preview.processingStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Echo cancellation", isOn: $preview.echoCancellationEnabled)
                    Toggle("Voice focus", isOn: $preview.voiceFocusEnabled)
                }.disabled(preview.busy)
                Text("Reduce speaker echo and background noise locally while keeping speech clear.")
                    .font(.caption).foregroundStyle(.secondary)
                if !available { Text("Prepare the updated audio runtime in Settings, then explicitly download this model. The shared queue checks resources as the model loads and learns from measured runs.").font(.caption).foregroundStyle(.secondary) }
                if !preview.userText.isEmpty { Text("You").font(.caption.bold()); Text(preview.userText).textSelection(.enabled) }
                if !preview.assistantText.isEmpty { Text("Model").font(.caption.bold()); Text(preview.assistantText).textSelection(.enabled) }
                Text("Local preview does not enable API access. Microphone capture starts only after admission. Headphones help avoid echo.").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        .task {
            guard CommandLine.arguments.contains("--check-realtime-preview") || CommandLine.arguments.contains("--check-continuous-preview") else { return }
            while !Task.isCancelled && (!store.queueReady || !store.installedModels.contains(where: { $0.id == RealtimeConfiguration.modelID })) {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await preview.checkRepeatedStartupIfRequested()
        }
        .task(id: available) {
            guard available, store.launchConversationPending else { return }
            store.launchConversationPending = false
            preview.start()
        }
        .onDisappear { preview.stop(reason: "Preview closed") }
    }
}
