import SwiftUI
import AppKit
import ModelAPI

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var choosingAssets = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(systemName: "cpu").font(.largeTitle).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("Mac Model API").font(.largeTitle.bold())
                        Text("A simple API for the models on your Mac.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.running ? "Stop API" : "Start API") { Task { await store.toggleAPI() } }.buttonStyle(.borderedProminent).disabled(store.busy)
                }
                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(store.running ? "Listening at \(store.endpoint)" : "API stopped", systemImage: store.running ? "circle.fill" : "circle")
                            .foregroundStyle(store.running ? Color.green : Color.secondary).textSelection(.enabled)
                        HStack { Text("Port"); TextField("Port", value: $store.configuration.port, format: .number.grouping(.never)).frame(width: 90) }
                        Toggle("Allow connections from other devices", isOn: $store.configuration.allowNetwork)
                        Text(store.configuration.allowNetwork ? "Listens on all IPv4 interfaces. Use your Mac’s address through a trusted private network or an HTTPS proxy you control. Every request needs an API key." : "Only apps and scripts on this Mac can connect. Every request needs an API key.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Start API when the app opens", isOn: $store.configuration.startAPIOnLaunch)
                            .onChange(of: store.configuration.startAPIOnLaunch) { store.persist() }
                        Toggle("Start at login", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) }))
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(store.running || store.busy)
                GroupBox("Models") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.models) { model in
                            HStack {
                                Image(systemName: model.available ? "checkmark.circle.fill" : "circle").foregroundStyle(model.available ? .green : .secondary)
                                VStack(alignment: .leading) { Text(model.id).font(.headline); Text(model.detail).font(.callout).foregroundStyle(.secondary) }
                                Spacer(); Text(model.capability).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        TextField("Ollama URL", text: $store.configuration.ollamaURL)
                        ModelNamesField(title: "Generation models (comma separated)", values: $store.configuration.generationModels)
                        ModelNamesField(title: "Decision models (comma separated)", values: $store.configuration.decisionModels)
                        HStack {
                            Text(store.configuration.assetsPath.isEmpty ? "Optional: choose a prepared model folder" : store.configuration.assetsPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer(); Button("Choose folder…") { choosingAssets = true }
                        }
                        HStack {
                            Button(store.runtimeRunning ? "Stop local runtime" : "Start local runtime") { Task { await store.toggleRuntime() } }.disabled(store.busy)
                            Button("Save & refresh") { store.persist(); Task { await store.refresh() } }
                        }
                        Text("Use an existing Ollama service, or choose a folder containing runtime/ollama and models/. The app starts only that runtime, with cloud inference disabled. Models are never downloaded automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(10)
                }.disabled(store.running)
                APIKeysView(store: store)
                if !store.message.isEmpty { Text(store.message).foregroundStyle(.red).textSelection(.enabled) }
                Text("GET /v1/models   ·   POST /v1/generate   ·   POST /v1/decisions").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(28)
        }
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
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = values.joined(separator: ", ") }
            .onChange(of: values) { if !focused { text = values.joined(separator: ", ") } }
            .onChange(of: text) { values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    }
}
