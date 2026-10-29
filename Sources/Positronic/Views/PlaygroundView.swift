import SwiftUI
import ModelAPI
import ModelService

struct PlaygroundView: View {
    @Bindable var store: AppStore
    @Binding var model: String
    @State private var prompt = ""
    @State private var reasoning: ReasoningLevel = .moderate
    private var cloudSelected: Bool { model == "apple-pcc" }
    private var modelAvailable: Bool { store.models.contains { $0.id == model && $0.available } }
    @State private var answer = ""
    @State private var error = ""
    @State private var generating = false
    @State private var work: Task<Void, Never>?
    var body: some View {
        PageHeading(title: "Try a model", detail: "Try a model before connecting another app. Prompts are not saved.")
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Model", selection: $model) {
                    ForEach(store.models.filter { $0.capability == "generation" && ($0.available || $0.id == model) }) { info in
                        Text(modelTitle(info)).tag(info.id).disabled(!info.available)
                    }
                    if !store.models.contains(where: { $0.id == model && $0.capability == "generation" }) {
                        Text("\(model) · Unavailable").tag(model).disabled(true)
                    }
                }.disabled(generating)
                if !modelAvailable {
                    Text("This model is unavailable. Select a ready model or check its access in Your models.").font(.callout).foregroundStyle(.secondary)
                }
                if cloudSelected {
                    Picker("Reasoning", selection: $reasoning) {
                        ForEach(ReasoningLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.segmented).disabled(generating)
                    Label("This request goes to Apple’s servers and uses your PCC quota. Deeper reasoning may take longer.", systemImage: "cloud")
                        .font(.callout).foregroundStyle(.secondary)
                }
                TextEditor(text: $prompt).font(.body).frame(minHeight: 130).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) { if prompt.isEmpty { Text("Ask something…").foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) } }
                HStack {
                    if generating { ProgressView().controlSize(.small); Text(cloudSelected ? "Generating with Apple Private Cloud Compute…" : "Generating on this Mac…").foregroundStyle(.secondary) }
                    Spacer()
                    if generating { Button("Cancel") { work?.cancel() } }
                    Button("Generate") { generate() }.buttonStyle(.borderedProminent).disabled(!modelAvailable || store.managingModels || generating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(12)
        }
        if !answer.isEmpty { GroupBox("Response") { Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) } }
        if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
    }
    private func modelTitle(_ info: ModelInfo) -> String {
        let name = info.id == "apple" ? "Apple · On device" : info.id == "apple-pcc" ? "Apple · Private Cloud Compute" : info.id
        return name + (info.available ? "" : " · Unavailable")
    }
    private func generate() {
        generating = true; error = ""; answer = ""
        let config = store.configuration, request = GenerationRequest(model: model, prompt: prompt, maxTokens: 600, reasoningLevel: cloudSelected ? reasoning : nil)
        work = Task {
            defer { generating = false; work = nil }
            do { answer = try await store.makeEngine(configuration: config).generate(request).text }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
            if request.model == "apple-pcc" { await store.refresh() }
        }
    }
}
