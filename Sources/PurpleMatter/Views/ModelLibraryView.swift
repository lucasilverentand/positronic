import SwiftUI
import ModelService

struct ModelLibraryView: View {
    @Bindable var store: AppStore
    @State private var category: ModelCapability = .generation
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Model type", selection: $category) {
                ForEach(ModelCapability.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if let downloading = store.downloading {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading \(downloading.name)").font(.headline)
                        if let progress = store.downloadProgress?.fraction { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                        Text(store.downloadProgress?.status ?? "Connecting to the local runtime…").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { store.cancelDownload() }
                }
            }
            if !store.installedModels.isEmpty {
                Text("Installed on this Mac").font(.headline)
                ForEach(store.installedModels.filter { $0.capability == category }) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.id).font(.headline)
                            HStack {
                                if !model.detail.isEmpty { Text(model.detail) }
                                if let bytes = model.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Available to API clients", isOn: Binding(get: { store.isEnabled(model.id, capability: category) }, set: { store.setEnabled(model.id, capability: category, enabled: $0) }))
                            .toggleStyle(.switch).fixedSize()
                    }.padding(.vertical, 3)
                }
                ForEach(store.installedModels.filter { $0.capability == nil }) { model in
                    HStack { Text(model.id); Spacer(); Text("Set its role in Advanced model tags").font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
            }
            Text("More models").font(.headline)
            Text("Downloads stay on this Mac. Model size, license and hardware needs are listed on each model’s page. After downloading, enable it for API clients above.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(ModelLibrary.presets.filter { $0.capability == category }) { preset in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.name).font(.headline)
                        Text(preset.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Details", destination: preset.source)
                    if store.installedModels.contains(where: { $0.id == preset.id }) {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else {
                        Button("Download") { store.download(preset) }.disabled(store.downloading != nil || !store.modelLibraryMessage.isEmpty)
                    }
                }.padding(.vertical, 4)
            }
            if !store.modelLibraryMessage.isEmpty { Text(store.modelLibraryMessage).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
