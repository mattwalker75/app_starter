// The app: the main window (bundles down the left, the selected one on the right), the menu bar item by the
// clock, and Settings. Closing the window keeps App Starter in the menu bar; Close App Starter (in the menu bar
// panel) quits it — your apps keep running.
import SwiftUI
import AppStarterCore

@main
struct AppStarterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("App Starter", id: "main") {
            MainWindow()
                .environmentObject(model)
                .preferredColorScheme(model.lookInForce.colorScheme)
                .tint(Theme.accent)
                .font(DS.body)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { delegate.model = model; model.addSampleIfAsked() }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bundle…") { model.sheet = .newBundle }.keyboardShortcut("n")
            }
            CommandMenu("Bundle") {
                Button("Start") { if let b = model.selected { model.run(b, .starting) } }.keyboardShortcut("r").disabled(model.selected == nil)
                Button("Stop…") { if let b = model.selected { model.askToStop = b } }.keyboardShortcut(".").disabled(model.selected == nil)
                Divider()
                Button("Add Application…") { if let b = model.selected { model.sheet = .newApp(bundleId: b.id, group: nil) } }.disabled(model.selected == nil)
                Button("Add Sub-bundle…") { if let b = model.selected { model.sheet = .newGroup(bundleId: b.id) } }.disabled(model.selected == nil)
                Button("Edit Bundle…") { if let b = model.selected { model.sheet = .editBundle(b) } }.keyboardShortcut("e").disabled(model.selected == nil)
                Divider()
                Button("Check Now") { Task { await model.refreshStatus() } }.keyboardShortcut("k")
            }
        }

        // a binding that writes only real changes: SwiftUI sets it while it builds the scene, and writing the same
        // value back would publish a change, rebuild the scene and set it again — round and round (it crashed)
        MenuBarExtra(isInserted: Binding(get: { model.settings.showInMenuBar },
                                         set: { v in if model.settings.showInMenuBar != v { model.settings.showInMenuBar = v } })) {
            MenuBarPanel()
                .environmentObject(model)
                .preferredColorScheme(model.lookInForce.colorScheme)
                .tint(Theme.accent)
        } label: {
            Image(systemName: model.anyRunning ? "arrow.triangle.2.circlepath" : "power")
                .accessibilityLabel(model.anyRunning ? "App Starter, busy" : "App Starter")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.lookInForce.colorScheme)
                .tint(Theme.accent)
                .font(DS.body)
        }
    }
}

/// Stops the stop-at-logout bundles before the Mac logs out, restarts or shuts down.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var loggingOut = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.loggingOut = true
        }
    }

    // closing the window leaves App Starter in the menu bar
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard loggingOut, let model, model.stopsAtLogout else { return .terminateNow }
        // macOS waits while we stop them (it gives up on its own after a while)
        MainActor.assumeIsolated { model.stopForLogout { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}
