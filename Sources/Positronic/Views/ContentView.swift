import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var selection: AppPage? = .models
    init(store: AppStore, initialPage: AppPage = .models) {
        self.store = store; _selection = State(initialValue: initialPage)
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: "AppIcon") { Image(nsImage: icon).resizable().frame(width: 42, height: 42) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Positronic").font(.headline)
                        Text("Your model API").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(18)
                List(selection: $selection) {
                    Section("Models") {
                        ForEach([AppPage.models, .discover]) { page in Label(page.title, systemImage: page.symbol).tag(page) }
                    }
                    Section("Workspace") {
                        ForEach([AppPage.jobs, .api, .settings]) { page in Label(page.title, systemImage: page.symbol).tag(page) }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label(store.running ? "API running" : store.apiStarting ? "API starting…" : "API stopped", systemImage: store.running ? "circle.fill" : "circle")
                        .foregroundStyle(store.running ? Color.green : .secondary)
                    Text(store.configuration.allowApplePCC ? "Local models + optional Apple cloud" : "Local inference · Apple cloud off").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        } detail: {
            VStack(spacing: 0) {
                switch selection ?? .models {
                case .models:
                    ModelsPage(store: store, discover: { selection = .discover })
                case .discover:
                    DiscoverModelsPage(store: store)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            switch selection ?? .models {
                            case .jobs: JobsPage(store: store)
                            case .api: APIPage(store: store)
                            case .settings: SettingsPage(store: store)
                            default: EmptyView()
                            }
                        }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                if store.downloading != nil { Divider(); DownloadStatusView(store: store) }
                if !store.message.isEmpty { ModelStatusBanner(store: store) }
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
