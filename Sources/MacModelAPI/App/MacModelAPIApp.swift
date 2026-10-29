import SwiftUI
import AppKit

@main
struct MacModelAPIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup("Mac Model API", id: "main") {
            ContentView(store: store).frame(minWidth: 690, minHeight: 590)
                .task { await store.prepare() }
        }
        .defaultSize(width: 850, height: 740)
        MenuBarExtra("Mac Model API", systemImage: "cpu") {
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
    var body: some View { Button("Open Mac Model API") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await AppStore.current?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
