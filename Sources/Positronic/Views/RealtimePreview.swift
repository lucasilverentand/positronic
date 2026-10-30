import SwiftUI
import ModelService

struct RealtimePreview: View {
    @State private var preview: RealtimePreviewStore
    let available: Bool
    init(store: AppStore, available: Bool) {
        _preview = State(initialValue: RealtimePreviewStore(jobs: store.jobs, runtime: store.audioRuntime)); self.available = available
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
                if !available { Text("Prepare the updated audio runtime in Settings, then explicitly download this model. The shared queue checks its 16 GiB memory budget before loading.").font(.caption).foregroundStyle(.secondary) }
                if !preview.userText.isEmpty { Text("You").font(.caption.bold()); Text(preview.userText).textSelection(.enabled) }
                if !preview.assistantText.isEmpty { Text("Model").font(.caption.bold()); Text(preview.assistantText).textSelection(.enabled) }
                Text("Local preview does not enable API access. Microphone capture starts only after admission. Headphones help avoid echo.").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }.onDisappear { preview.stop() }
    }
}
