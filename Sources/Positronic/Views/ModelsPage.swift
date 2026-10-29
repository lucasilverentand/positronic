import SwiftUI
import ModelService

struct ModelsPage: View {
    @Bindable var store: AppStore
    var body: some View {
        PageHeading(title: "Your models", detail: "Discover, download and enable models without stopping your API.")
        if let apple = store.models.first(where: { $0.id == "apple" }) {
            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: "apple.logo").font(.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Intelligence").font(.headline)
                        Text(apple.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(apple.available ? "Ready" : "Unavailable", systemImage: apple.available ? "checkmark.circle.fill" : "circle").foregroundStyle(apple.available ? Color.green : .secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if !store.modelLibraryMessage.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect a local runtime").font(.headline)
                    Text("Prepare a private runtime for Positronic, or connect to an Ollama service already running on this Mac.").foregroundStyle(.secondary)
                    HStack {
                        Button("Prepare local runtime") { Task { await store.prepareRuntime() } }.buttonStyle(.borderedProminent)
                        Button("Use installed Ollama") { Task { await store.connectToOllama() } }
                    }.disabled(store.busy || store.downloading != nil)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        GroupBox { ModelLibraryView(store: store).padding(14) }
    }
}
