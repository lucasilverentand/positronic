import SwiftUI
import ModelService

struct SettingsPage: View {
    @Bindable var store: AppStore
    @State private var choosingAssets = false
    var body: some View {
        PageHeading(title: "Settings", detail: "Control startup, local runtimes and who can reach your Mac.")
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Start at login", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) }))
                Toggle("Start API when the app opens", isOn: $store.configuration.startAPIOnLaunch).onChange(of: store.configuration.startAPIOnLaunch) { store.persist() }
                Toggle("Start my local runtime when the app opens", isOn: $store.configuration.startRuntimeOnLaunch).onChange(of: store.configuration.startRuntimeOnLaunch) { store.persist() }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).disabled(store.managingModels)
        }
        GroupBox("Local runtime") {
            VStack(alignment: .leading, spacing: 12) {
                Label(store.runtimeRunning ? "Owned runtime running" : "Owned runtime stopped", systemImage: "cpu")
                TextField("Ollama URL", text: $store.configuration.ollamaURL).disabled(store.running)
                Text(store.configuration.assetsPath.isEmpty ? "No prepared model folder selected" : store.configuration.assetsPath).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Prepare runtime") { Task { await store.prepareRuntime() } }
                    Button("Choose folder…") { choosingAssets = true }
                    Button(store.runtimeRunning ? "Stop runtime" : "Start runtime") { Task { await store.toggleRuntime() } }
                    Button("Use installed Ollama") { Task { await store.connectToOllama() } }
                }.disabled(store.busy || store.downloading != nil || store.running)
                Text("Runtime connection changes require stopping the API. Model downloads and enable switches remain available while the API runs.").font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).disabled(store.managingModels)
        }
        GroupBox("Network access") {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("API port"); TextField("Port", value: $store.configuration.port, format: .number.grouping(.never)).frame(width: 100) }
                Toggle("Allow connections from other devices", isOn: $store.configuration.allowNetwork)
                Text("Every request needs an API key. For remote access, use a trusted encrypted private network or an HTTPS proxy you control.").font(.callout).foregroundStyle(.secondary)
                Button("Save connection settings") { store.persist() }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).disabled(store.managingModels).disabled(store.running || store.apiStarting)
        }
        DisclosureGroup("Advanced model tags") {
            VStack(spacing: 12) {
                ModelNamesField(title: "Generation models", values: $store.configuration.generationModels)
                ModelNamesField(title: "Decision models", values: $store.configuration.decisionModels)
                ModelNamesField(title: "Embedding models", values: $store.configuration.embeddingModels)
                Button("Save model tags") { Task { await store.applyModelSettings() } }
            }.padding(.top, 10)
        }
        .disabled(store.managingModels)
        .fileImporter(isPresented: $choosingAssets, allowedContentTypes: [.folder]) { result in
            switch result { case .success(let url): store.configuration.assetsPath = url.path; store.persist(); case .failure(let error): store.message = error.localizedDescription }
        }
    }
}
private struct ModelNamesField: View {
    let title: String
    @Binding var values: [String]
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(title, text: $text).focused($focused)
            .onAppear { text = values.joined(separator: ", ") }
            .onChange(of: values) { if !focused { text = values.joined(separator: ", ") } }
            .onChange(of: text) { values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    }
}
