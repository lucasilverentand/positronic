import SwiftUI
import ModelService
import ModelAPI

struct ModelsPage: View {
    @Bindable var store: AppStore
    var discover: () -> Void
    @State private var search = ""
    @State private var selectedID: String?
    private var models: [ManagedModel] { ManagedModel.all(in: store) }
    private var filtered: [ManagedModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { query.isEmpty || $0.matchesSearch.localizedCaseInsensitiveContains(query) }
    }
    private var selected: ManagedModel? { models.first { $0.id == selectedID } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your models").font(.largeTitle.bold())
                        Text("\(store.installedModels.count) downloaded · \(store.loadedModels.count) loaded")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { discover() } label: { Label("Discover", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }.padding(.horizontal, 24).padding(.top, 24)
                TextField("Search models, types or model IDs", text: $search)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 24)
                List(selection: $selectedID) {
                    let apple = filtered.filter { $0.location != .downloaded }
                    if !apple.isEmpty {
                        Section("Apple Intelligence") {
                            ForEach(apple) { model in ModelBrowserRow(store: store, model: model).tag(model.id) }
                        }
                    }
                    let downloaded = filtered.filter { $0.location == .downloaded }
                    if !downloaded.isEmpty {
                        Section("Downloaded on this Mac") {
                            ForEach(downloaded) { model in ModelBrowserRow(store: store, model: model).tag(model.id) }
                        }
                    }
                }.listStyle(.inset).overlay {
                    if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                }
                if store.installedModels.isEmpty && search.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Make room for your first local model").font(.headline)
                        Text("Discover generation, decision and embedding models to run on this Mac.").foregroundStyle(.secondary)
                        Button("Browse model library", action: discover)
                    }.padding(24)
                }
            }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            ScrollView {
                if let selected { ModelDetailView(store: store, model: selected).id(selected.id).padding(24) }
                else {
                    ContentUnavailableView("Select a model", systemImage: "cpu", description: Text("Inspect its memory, API access and model details here."))
                        .padding(.top, 80)
                }
            }.frame(minWidth: 340, idealWidth: 420, maxWidth: 480)
        }
        .onChange(of: filtered.map(\.id), initial: true) {
            if store.launchConversationPending, filtered.contains(where: { $0.id == RealtimeConfiguration.modelID }) {
                selectedID = RealtimeConfiguration.modelID; return
            }
            guard !filtered.contains(where: { $0.id == selectedID }) else { return }
            selectedID = filtered.first { $0.installed?.capability == .generation }?.id ?? filtered.first?.id
        }
        .task {
            while !Task.isCancelled {
                await store.refreshLoaded()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }
}
