import SwiftUI
import AppKit

private enum AppPage: String, CaseIterable, Identifiable {
    case models, playground, api, settings
    var id: Self { self }
    var title: String { switch self { case .models: "Models"; case .playground: "Playground"; case .api: "API & Keys"; case .settings: "Settings" } }
    var symbol: String { switch self { case .models: "square.stack.3d.up"; case .playground: "text.bubble"; case .api: "network"; case .settings: "gearshape" } }
}

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var selection: AppPage? = .models
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: "AppIcon") { Image(nsImage: icon).resizable().frame(width: 42, height: 42) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Purple Matter").font(.headline)
                        Text("Models on your Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(18)
                List(AppPage.allCases, selection: $selection) { page in Label(page.title, systemImage: page.symbol).tag(page) }
                    .listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label(store.running ? "API running" : store.apiStarting ? "API starting…" : "API stopped", systemImage: store.running ? "circle.fill" : "circle")
                        .foregroundStyle(store.running ? Color.green : .secondary)
                    Text("Inference stays on this Mac.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.navigationSplitViewColumnWidth(min: 205, ideal: 235, max: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch selection ?? .models {
                    case .models: ModelsPage(store: store)
                    case .playground: PlaygroundView(store: store)
                    case .api: APIPage(store: store)
                    case .settings: SettingsPage(store: store)
                    }
                    if !store.message.isEmpty {
                        Label(store.message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle((selection ?? .models).title)
            .toolbar { ToolbarItem { Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(store.busy) } }
        }
    }
}

struct PageHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.bold())
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
