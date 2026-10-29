import SwiftUI
import AppKit

struct APIKeysView: View {
    @Bindable var store: AppStore
    @State private var name = ""
    var body: some View {
        GroupBox("API keys") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Name this client, for example Seven", text: $name)
                    Button("Create key") { Task { await store.createKey(name: name); name = "" } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !store.createdKey.isEmpty {
                    Text("Save this key now. It will not be shown again.").font(.callout)
                    HStack {
                        Text(store.createdKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.createdKey, forType: .string) }
                        Button("Done") { store.createdKey = "" }
                    }
                }
                ForEach(store.keys) { key in
                    HStack { Text(key.name); Spacer(); Text(key.createdAt, style: .date).foregroundStyle(.secondary); Button("Revoke", role: .destructive) { Task { await store.revoke(key.id) } } }
                }
                if store.keys.isEmpty { Text("Create one key for each system that connects to this Mac.").foregroundStyle(.secondary) }
            }.padding(10)
        }
    }
}
