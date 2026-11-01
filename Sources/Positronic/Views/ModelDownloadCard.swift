import SwiftUI
import ModelService
import ModelAPI

struct ModelDownloadCard: View {
    @Bindable var store: AppStore
    let preset: ModelPreset
    private var installed: Bool { store.installedModels.contains { $0.id == preset.id } }
    private var restriction: String? {
        if preset.id == RealtimeConfiguration.modelID, !AudioCatalog.realtimeReady { return "Prepare the audio update in Settings first." }
        return (try? ModelLibrary(configuration: store.configuration))?.downloadRestriction(preset)
    }
    private var downloading: Bool { store.downloading?.id == preset.id }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: "cpu").font(.title2).foregroundStyle(.tint)
                    Spacer()
                    if installed { Label("Downloaded", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary) }
                    else if downloading { ProgressView().controlSize(.small) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(preset.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(preset.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                if !installed, let restriction { Text(restriction).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Divider()
                HStack {
                    Link("Model details", destination: preset.source)
                    Spacer()
                    if installed { Text("On this Mac").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Button(downloading ? "Downloading…" : "Download") { store.download(preset) }
                            .disabled(!store.canManageModels || (!store.modelLibraryMessage.isEmpty && !AudioCatalog.ids.contains(preset.id)) || restriction != nil)
                    }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
}
