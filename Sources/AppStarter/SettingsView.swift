// Settings (⌘, or the gear): General (open at login, the menu bar item, how often to check, where things are
// kept), Bundles at login and logout, Appearance, Logs, Backup (export / import).
import SwiftUI
import UniformTypeIdentifiers
import AppStarterCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var loginItem = LoginItem.isOn
    @State private var loginProblem: String?

    var body: some View {
        TabView(selection: $model.settingsTab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            loginBundles.tabItem { Label("Login", systemImage: "person.badge.clock") }.tag("login")
            AppearancePane().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
            logs.tabItem { Label("Logs", systemImage: "doc.text") }.tag("logs")
            BackupPane().tabItem { Label("Backup", systemImage: "externaldrive") }.tag("backup")
        }
        .frame(width: 640, height: 520)
        .onAppear { loginItem = LoginItem.isOn }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Open App Starter when I log in", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        guard on != LoginItem.isOn else { return }
                        do { try LoginItem.set(on); loginProblem = nil } catch { loginProblem = error.localizedDescription; loginItem = LoginItem.isOn }
                    }
                Text(loginProblem ?? (LoginItem.needsApproval
                     ? "macOS is waiting for your say-so: System Settings → General → Login Items & Extensions, then allow App Starter."
                     : "Needed for bundles that start at login (Settings → Login)."))
                    .font(DS.secondary).foregroundStyle(loginProblem == nil ? .secondary : Theme.problem)
                Toggle("Show App Starter in the menu bar", isOn: $model.settings.showInMenuBar)
                Text("The item by the clock lists every bundle with its light and a Start or Stop button. Turned off, open App Starter from Applications to get it back.")
                    .font(DS.secondary).foregroundStyle(.secondary)
                Picker("Check running apps every", selection: $model.settings.checkEvery) {
                    Text("10 seconds").tag(10); Text("30 seconds").tag(30); Text("1 minute").tag(60); Text("5 minutes").tag(300)
                }
            }
            Section {
                LabeledContent("App Starter") { Text(AppStarterCore.version) }
                LabeledContent("Bundles, settings and logs") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.store.folder.path).font(DS.mono).textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }.buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var loginBundles: some View {
        Form {
            Section {
                if model.bundles.isEmpty { Text("No bundles yet.").foregroundStyle(.secondary) }
                ForEach($model.bundles) { $b in
                    HStack {
                        Text(b.name).fontWeight(.medium)
                        Spacer()
                        Toggle("Start when I log in", isOn: $b.startAtLogin).toggleStyle(.checkbox)
                        Toggle("Stop when I log out", isOn: $b.stopAtLogout).toggleStyle(.checkbox)
                    }
                }
                .onChange(of: model.bundles) { _, _ in model.save() }
            } header: { Text("Bundles at login and logout · each one on its own") }
            Text("Bundles that start at login go one after another, in the order of the sidebar, when App Starter first opens after you log in (turn on “Open App Starter when I log in”). “Stop when I log out” also runs when you restart or shut down; macOS waits up to about a minute and a half. A failure is skipped, since nobody is there to answer.")
                .font(DS.secondary).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var logs: some View {
        Form {
            Picker("Trim each app's log once it passes", selection: $model.settings.logLimitMB) {
                Text("1 MB").tag(1); Text("2 MB").tag(2); Text("5 MB").tag(5); Text("20 MB").tag(20)
            }
            Text("Each app's log holds App Starter's own lines (when, which command, how it ended) and what the commands print. Open one from an app's row: right-click → Show log.")
                .font(DS.secondary).foregroundStyle(.secondary)
            HStack {
                Button("Show the logs folder") { NSWorkspace.shared.open(model.engine.logs.folder) }
                Button("Clear every log…") { model.engine.logs.clearAll() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Export the bundles to a file, or import them from one.
struct BackupPane: View {
    @EnvironmentObject var model: AppModel
    @State private var includeSecrets = false
    @State private var message: String?
    @State private var pending: ExportFile?

    var body: some View {
        Form {
            Section("Export") {
                Toggle("Include secret values", isOn: $includeSecrets)
                Text(includeSecrets ? "The file will hold your secret values in plain text. Keep it somewhere safe." : "Secret values are left out; type them again after importing.")
                    .font(DS.secondary).foregroundStyle(includeSecrets ? Theme.attention : .secondary)
                Button("Export bundles…") { export() }.disabled(model.bundles.isEmpty)
            }
            Section("Import") {
                Text("Adds the bundles from an export — for example from your other Mac. A bundle that is already here can be replaced or added as a copy.")
                    .font(DS.secondary).foregroundStyle(.secondary)
                Button("Import bundles…") { pick() }
            }
            if let message { Text(message).font(DS.secondary) }
        }
        .formStyle(.grouped)
        .confirmationDialog("Some of these bundles are already here", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Replace them") { finish(replace: true) }
            Button("Add them as copies") { finish(replace: false) }
            Button("Cancel", role: .cancel) { pending = nil }.keyboardShortcut(.defaultAction)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "App Starter bundles.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportData(includeSecrets: includeSecrets).write(to: url, options: .atomic)
            if includeSecrets { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            message = "Exported \(model.bundles.count) bundle\(model.bundles.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch { message = "Could not write the file: \(error.localizedDescription)" }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let f = try Transfer.read(Data(contentsOf: url))
            if f.bundles.contains(where: { b in model.bundles.contains { $0.id == b.id } }) { pending = f } else { model.importFile(f, replace: false); report(f) }
        } catch { message = (error as? ASError)?.message ?? error.localizedDescription }
    }

    private func finish(replace: Bool) {
        guard let f = pending else { return }
        model.importFile(f, replace: replace); report(f); pending = nil
    }

    private func report(_ f: ExportFile) {
        message = "Imported \(f.bundles.count) bundle\(f.bundles.count == 1 ? "" : "s")" + (f.secretsIncluded ? "." : " — type their secret values again.")
    }
}
