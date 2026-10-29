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
                        Text("Apple Intelligence · On device").font(.headline)
                        Text(apple.detail + " · Managed by macOS").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(apple.available ? "Ready" : "Unavailable", systemImage: apple.available ? "checkmark.circle.fill" : "circle").foregroundStyle(apple.available ? Color.green : .secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let cloud = store.models.first(where: { $0.id == "apple-pcc" }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Apple Private Cloud Compute", systemImage: "cloud").font(.headline)
                        Spacer()
                        Text(cloud.available ? "Ready" : store.configuration.allowApplePCC ? "Unavailable" : "Off")
                            .foregroundStyle(cloud.available ? Color.green : .secondary)
                    }
                    Text("Runs on Apple’s servers. Use light, moderate or deep reasoning for more complex requests.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Allow Private Cloud Compute for Playground and API clients", isOn: Binding(
                        get: { store.configuration.allowApplePCC },
                        set: { enabled in Task { await store.setApplePCC(enabled) } }
                    )).disabled(store.managingModels)
                    Text(cloud.detail).font(.callout).foregroundStyle(.secondary)
                    Text("Clients must select apple-pcc explicitly. Requests to local models stay on this Mac. Apple applies a daily quota; Positronic never upgrades your plan automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Apple access requirements", destination: URL(string: "https://developer.apple.com/private-cloud-compute/")!)
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
            .task {
                while !Task.isCancelled {
                    await store.refreshLoaded()
                    do { try await Task.sleep(for: .seconds(3)) } catch { break }
                }
            }
    }
}
