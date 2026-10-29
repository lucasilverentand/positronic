import SwiftUI

struct APIPage: View {
    @Bindable var store: AppStore
    var body: some View {
        PageHeading(title: "Connect your apps", detail: "Use a separate API key for each local script or external system.")
        GroupBox("API service") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(store.running ? "Running" : store.apiStarting ? "Starting…" : "Stopped", systemImage: store.running ? "circle.fill" : "circle").foregroundStyle(store.running ? Color.green : .secondary)
                    Spacer()
                    Button(store.running ? "Stop API" : "Start API") { Task { await store.toggleAPI() } }.buttonStyle(.borderedProminent).disabled(store.busy || store.apiStarting)
                }
                Text(store.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text(store.configuration.allowNetwork ? "Network access enabled. Connect through a trusted private network or an HTTPS proxy you control." : "Only clients on this Mac can connect. Network access is available in Settings.").font(.callout).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        APIKeysView(store: store)
        GroupBox("Endpoints") {
            VStack(alignment: .leading, spacing: 10) {
                endpoint("GET", "/v1/models", "Enabled models and availability")
                endpoint("POST", "/v1/generate", "Text and structured generation")
                endpoint("POST", "/v1/decisions", "Typed decisions with probabilities")
                endpoint("POST", "/v1/embeddings", "Vectors for search and retrieval")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func endpoint(_ method: String, _ path: String, _ detail: String) -> some View {
        HStack {
            Text(method).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
            Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Spacer(); Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}
