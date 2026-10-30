import SwiftUI
import ModelService

struct DiscoverModelsPage: View {
    @Bindable var store: AppStore
    @State private var search = ""
    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 440), spacing: 16, alignment: .top)]
    private var presets: [ModelPreset] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelLibrary.presets.filter { query.isEmpty || "\($0.name) \($0.id) \($0.detail) \($0.capability.title)".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "Discover models", detail: "Find your next local model. Every download stays on this Mac.")
                TextField("Search the model library", text: $search).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460, alignment: .leading)
                if !store.modelLibraryMessage.isEmpty { RuntimeSetupCard(store: store) }
                if presets.isEmpty { ContentUnavailableView.search(text: search).frame(maxWidth: .infinity).padding(.top, 50) }
                if !AudioCatalog.realtimeReady {
                    GroupBox {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Local audio runtime").font(.headline)
                                Text("Prepare or update the audio runtime before downloading live conversation models. Existing batch audio remains available.").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Prepare audio") { Task { await store.prepareAudioRuntime() } }.disabled(store.busy || store.managingModels)
                        }.padding(12)
                    }
                }
                ForEach(ModelCapability.allCases, id: \.self) { capability in
                    let matches = presets.filter { $0.capability == capability }
                    if !matches.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(capability.title).font(.title2.bold())
                                Text("\(matches.count) models").font(.callout).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                ForEach(matches) { preset in ModelDownloadCard(store: store, preset: preset) }
                            }
                        }
                    }
                }
                Text("Model pages list their license, size and hardware requirements. Downloading never enables API access automatically; choose Your models after installation to enable access or load a model.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct RuntimeSetupCard: View {
    @Bindable var store: AppStore
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connect a local runtime", systemImage: "cpu").font(.headline)
                Text("Prepare Positronic’s private runtime, or connect to an Ollama service already running on this Mac.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Prepare runtime") { Task { await store.prepareRuntime() } }.buttonStyle(.borderedProminent)
                    Button("Use installed Ollama") { Task { await store.connectToOllama() } }
                }.disabled(!store.canManageModels)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
