import SwiftUI
import ModelService

struct InstalledModelRow: View {
    @Bindable var store: AppStore
    let model: InstalledModel
    @State private var confirmingRemoval = false
    private var loaded: LoadedModel? { store.loadedModel(model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.id).font(.headline).textSelection(.enabled)
                    HStack {
                        if !model.detail.isEmpty { Text(model.detail) }
                        if let bytes = model.sizeBytes { Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on disk") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if !store.loadedStatusKnown {
                        Label("Memory status unavailable", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                    } else if let loaded {
                        Label("Loaded in memory", systemImage: "memorychip").foregroundStyle(.green)
                        if let bytes = loaded.memoryBytes { Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)) in use").foregroundStyle(.secondary) }
                    } else {
                        Label("On disk · Loads on demand", systemImage: "internaldrive").foregroundStyle(.secondary)
                    }
                }.font(.caption)
                Spacer()
                if store.modelOperation == model.id { ProgressView().controlSize(.small) }
                Button(loaded == nil ? "Load" : "Unload") {
                    let action: AppStore.ModelAction = loaded == nil ? .load : .unload
                    Task { await store.manage(action, model: model) }
                }.disabled(!store.canManageModels || !store.loadedStatusKnown || (loaded == nil && model.capability == nil))
                Menu {
                    Button("Remove from Mac…", role: .destructive) { confirmingRemoval = true }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().disabled(!store.canManageModels)
                .accessibilityLabel("More actions for \(model.id)")
            }
            if let capability = model.capability {
                Toggle("Available to API clients", isOn: Binding(
                    get: { store.isEnabled(model.id, capability: capability) },
                    set: { enabled in Task { await store.setEnabled(model.id, capability: capability, enabled: enabled) } }
                )).toggleStyle(.switch).disabled(store.managingModels)
            } else { Text("Set its role in Advanced model tags to use this model.").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 9)
        .confirmationDialog("Remove \(model.id)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove from Mac", role: .destructive) { Task { await store.manage(.remove, model: model) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unloads the model, disables its API access and removes its downloaded files. You can download it again later. Files shared with another installed model are kept.")
        }
    }
}
