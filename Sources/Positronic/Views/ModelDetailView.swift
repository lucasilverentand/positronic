import SwiftUI
import ModelService

struct ModelDetailView: View {
    @Bindable var store: AppStore
    let model: ManagedModel
    var tryModel: (String) -> Void
    @State private var confirmingRemoval = false
    private var installed: InstalledModel? { model.installed }
    private var readyForPlayground: Bool {
        store.models.contains { $0.id == model.id && $0.capability == "generation" && $0.available }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: model.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tint)
                    .frame(width: 64, height: 64).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                Text(model.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Label(model.locationTitle, systemImage: model.location == .appleCloud ? "cloud" : "laptopcomputer")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL ID").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(model.id).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let installed {
                localControls(installed)
            } else if model.location == .appleCloud {
                AppleCloudControls(store: store, info: model.info)
            } else {
                Text(model.info?.detail ?? "Checking Apple Intelligence…").font(.callout).foregroundStyle(.secondary)
                Text("Apple manages this model’s files and memory through macOS.").font(.callout).foregroundStyle(.secondary)
            }
            if model.capability == .generation {
                Button { tryModel(model.id) } label: { Label("Open in Playground", systemImage: "text.bubble") }
                    .frame(maxWidth: .infinity).disabled(!readyForPlayground || store.managingModels)
                if !readyForPlayground && model.location == .downloaded {
                    Text("Enable API access to try this model in Playground.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let installed {
                Divider()
                Button("Remove from Mac…", role: .destructive) { confirmingRemoval = true }
                    .disabled(!store.canManageModels)
                Text("Removes this download and disables its API access. Files shared with other installed models are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.modelOperation == installed.id { ProgressView("Updating model…").controlSize(.small) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Remove \(model.id)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            if let installed { Button("Remove from Mac", role: .destructive) { Task { await store.manage(.remove, model: installed) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This unloads the model, disables API access and removes its downloaded files. You can download it again later. Shared files needed by other installed models stay on this Mac.") }
    }
    @ViewBuilder private func localControls(_ installed: InstalledModel) -> some View {
        let loaded = store.loadedModel(installed)
        VStack(alignment: .leading, spacing: 12) {
            if let capability = installed.capability { LabeledContent("Type", value: capability.title) }
            if let size = installed.sizeBytes { LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
            LabeledContent("Memory", value: !store.loadedStatusKnown ? "Unavailable" : loaded == nil ? "Not loaded" : "Loaded")
            if let bytes = loaded?.memoryBytes { LabeledContent("In use", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)) }
            if !installed.detail.isEmpty { Text(installed.detail).font(.caption).foregroundStyle(.secondary) }
        }.font(.callout)
        Button {
            let action: AppStore.ModelAction = loaded == nil ? .load : .unload
            Task { await store.manage(action, model: installed) }
        } label: {
            Label(loaded == nil ? "Load into memory" : "Unload model", systemImage: loaded == nil ? "play.fill" : "stop.fill")
                .frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent)
            .disabled(!store.canManageModels || !store.loadedStatusKnown || (loaded == nil && installed.capability == nil))
        Text(!store.loadedStatusKnown ? "Start or reconnect the local runtime in Settings, then refresh." : loaded == nil ? "Loading prepares the model for requests. Enabled models can also load on demand." : "Unloading frees memory and keeps the downloaded files. An API request can load the model again.")
            .font(.caption).foregroundStyle(.secondary)
        Divider()
        if let capability = installed.capability {
            Toggle("API access", isOn: Binding(
                get: { store.isEnabled(installed.id, capability: capability) },
                set: { enabled in Task { await store.setEnabled(installed.id, capability: capability, enabled: enabled) } }
            )).toggleStyle(.switch).disabled(store.managingModels)
            Text("Allow your connected apps to request this model.").font(.caption).foregroundStyle(.secondary)
        } else { Text("Set this model’s role under Advanced model tags in Settings before enabling it.").font(.callout).foregroundStyle(.secondary) }
    }
}
