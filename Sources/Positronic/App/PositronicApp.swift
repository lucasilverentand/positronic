import SwiftUI
import AppKit
import Darwin

@main
struct PositronicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup("Positronic", id: "main") {
            ContentView(store: store).frame(minWidth: 940, minHeight: 650)
                .task { await store.prepare() }
        }
        .defaultSize(width: 1060, height: 780)
        MenuBarExtra("Positronic", systemImage: "cpu") {
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
    var body: some View { Button("Open Positronic") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        // Use CFBundleIconName and the compiled Icon Composer asset so macOS
        // can render Liquid Glass and appearance variants without a bitmap override.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                await AppStore.current?.shutdown()
                // A development restart must finish even if AppKit has deferred
                // termination for an unrelated open window or event.
                Darwin.exit(EXIT_SUCCESS)
            }
        }
        source.resume(); terminationSignal = source
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await AppStore.current?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
