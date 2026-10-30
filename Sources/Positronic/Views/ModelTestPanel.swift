import SwiftUI
import UniformTypeIdentifiers
import ModelAPI
import ModelService

struct ModelTestPanel: View {
    @Bindable var store: AppStore
    @Bindable var sample: ModelTestStore
    let model: ManagedModel
    @State private var importing = false
    private var available: Bool {
        guard store.queueReady, !store.managingModels else { return false }
        if model.location != .downloaded { return model.info?.available == true }
        guard store.installedModels.contains(where: { $0.id == model.id }) else { return false }
        if model.capability == .speech || model.capability == .transcription { return AudioCatalog.runtimeReady }
        return store.loadedStatusKnown
    }
    var body: some View {
        GroupBox("Try this model") {
            VStack(alignment:.leading,spacing:12) {
                if let capability=model.capability {
                    if model.location == .appleCloud {
                        Label("This test uses Apple’s servers and your PCC quota.",systemImage:"cloud").font(.caption).foregroundStyle(.secondary)
                        Picker("Reasoning",selection:$sample.reasoning) { ForEach(ReasoningLevel.allCases,id:\.self) { Text($0.rawValue.capitalized).tag($0) } }.disabled(sample.busy)
                    }
                    if capability == .speech || capability == .transcription {
                        Picker("Language",selection:Binding(get:{sample.language},set:{sample.changeLanguage($0)})) { Text("English").tag("en");Text("Dutch").tag("nl") }.disabled(sample.busy || sample.capture.recording)
                    }
                    if capability == .transcription {
                        Text("Import or record a sample. Transcription starts after recording ends.").font(.caption).foregroundStyle(.secondary)
                        if sample.capture.recording {
                            Label("Recording…",systemImage:"record.circle").foregroundStyle(.red)
                            HStack { Button("Transcribe") { sample.capture.stop() };Button("Discard") { sample.capture.cancel() } }
                        } else {
                            HStack { Button("Import audio…") { importing=true };Button("Record") { Task { await sample.capture.start() } } }
                                .disabled(!available || sample.busy)
                        }
                        if !sample.capture.message.isEmpty { Text(sample.capture.message).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text(inputLabel(capability)).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text:$sample.input).font(.body).frame(height:90).disabled(sample.busy)
                            .overlay { RoundedRectangle(cornerRadius:6).stroke(.quaternary,lineWidth:1) }
                        if capability == .decision {
                            TextField("Question",text:$sample.question).disabled(sample.busy)
                            Text("Choices, one per line").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text:$sample.choices).frame(height:65).disabled(sample.busy)
                        }
                        if capability == .speech { Text("Default voice · \(sample.input.count) / 5000 characters").font(.caption).foregroundStyle(.secondary) }
                        Button(actionLabel(capability)) { sample.run() }.buttonStyle(.borderedProminent)
                            .disabled(!available || sample.busy || sample.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (capability == .speech && sample.input.count > 5000))
                    }
                    if !available {
                        Text(model.location == .downloaded ? "This test needs the installed model’s local runtime to be ready." : model.info?.detail ?? "Check this model’s system availability before testing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.location == .downloaded { Text("Local tests do not change API access. The model loads on demand.").font(.caption).foregroundStyle(.secondary) }
                } else { Text("Assign this model a supported type in Settings to test it.").foregroundStyle(.secondary) }
                if sample.busy || sample.job != nil {
                    HStack(alignment:.top) {
                        if sample.busy { ProgressView().controlSize(.small) }
                        VStack(alignment:.leading,spacing:4) {
                            Text(sample.job?.message ?? "Preparing sample…").font(.caption)
                            if let position=sample.job?.position { Text("Queue position \(position)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if sample.busy { Button("Cancel") { sample.cancel() } }
                    }
                    if let progress=sample.job?.progress,sample.busy { ProgressView(value:progress) }
                }
                if let result=sample.result { Divider();ModelTestResultView(store:store,result:result) }
                if !sample.error.isEmpty { Text(sample.error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(10)
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.audio]) { result in
            switch result { case .success(let file):sample.run(file:file,imported:true);case .failure(let error):sample.error=error.localizedDescription }
        }
        .onChange(of:sample.capture.completed) {
            if let file=sample.capture.completed { sample.capture.completed=nil;sample.run(file:file) }
        }
        .onDisappear { sample.capture.cancel() }
        .task { while !Task.isCancelled { await sample.refresh();do { try await Task.sleep(for:.seconds(1)) } catch { return } } }
    }
    private func inputLabel(_ kind:ModelCapability) -> String {
        switch kind { case .generation:"Prompt";case .decision:"Sample to classify";case .embedding:"Texts to compare, one per line";default:"Text to speak" }
    }
    private func actionLabel(_ kind:ModelCapability) -> String {
        switch kind { case .generation:"Generate sample";case .decision:"Test decision";case .embedding:"Compare embeddings";default:"Generate audio snippet" }
    }
}
