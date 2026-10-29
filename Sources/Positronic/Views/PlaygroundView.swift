import SwiftUI
import ModelAPI
import ModelService

struct PlaygroundView: View {
    @Bindable var store: AppStore
    @State private var model = "apple"
    @State private var prompt = ""
    @State private var answer = ""
    @State private var error = ""
    @State private var generating = false
    @State private var work: Task<Void, Never>?
    var body: some View {
        PageHeading(title: "Try a model", detail: "A quick local check before connecting another app. Prompts are not saved.")
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Model", selection: $model) {
                    ForEach(store.models.filter { $0.capability == "generation" && $0.available }) { Text($0.id).tag($0.id) }
                }.disabled(generating)
                TextEditor(text: $prompt).font(.body).frame(minHeight: 130).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) { if prompt.isEmpty { Text("Ask something…").foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) } }
                HStack {
                    if generating { ProgressView().controlSize(.small); Text("Generating on this Mac…").foregroundStyle(.secondary) }
                    Spacer()
                    if generating { Button("Cancel") { work?.cancel() } }
                    Button("Generate") { generate() }.buttonStyle(.borderedProminent).disabled(store.managingModels || generating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(12)
        }
        if !answer.isEmpty { GroupBox("Response") { Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) } }
        if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
    }
    private func generate() {
        generating = true; error = ""; answer = ""
        let config = store.configuration, request = GenerationRequest(model: model, prompt: prompt, maxTokens: 600)
        work = Task {
            defer { generating = false; work = nil }
            do { answer = try await store.makeEngine(configuration: config).generate(request).text }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
