import SwiftUI
import AppKit
import Darwin

@main
struct PurpleMatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup("Purple Matter", id: "main") {
            ContentView(store: store).frame(minWidth: 690, minHeight: 590)
                .task { await store.prepare() }
        }
        .defaultSize(width: 850, height: 740)
        MenuBarExtra("Purple Matter", systemImage: "cpu") {
            Text(store.running ? "API running" : "API stopped")
            OpenWindowButton()
            Button(store.running ? "Stop API" : "Start API") { Task { await store.toggleAPI() } }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
private struct OpenWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Open Purple Matter") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
        source.resume(); terminationSignal = source
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await AppStore.current?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
