// The sheets that make and change things: a new bundle, a sub-bundle's name, a bundle's settings (name, login
// and logout, the stop order, delete), and an application (AppEditor).
import SwiftUI
import AppStarterCore

struct NewBundleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New bundle").font(DS.heading)
            Text("A bundle starts and stops its applications in the order you set. It starts empty: add the applications next.")
                .font(DS.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form { Field("Name", $name, "Mac mini — everything") }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create bundle") { model.addBundle(name); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}

/// A new sub-bundle, or a new name for one.
struct GroupNameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bundleId: UUID
    let step: Step?
    @State private var name: String
    init(bundleId: UUID, step: Step?) { self.bundleId = bundleId; self.step = step; _name = State(initialValue: step?.name ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(step == nil ? "New sub-bundle" : "Rename sub-bundle").font(DS.heading)
            Text("The applications in a sub-bundle start together, and all of them must be up before the next step begins.")
                .font(DS.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form { Field("Name", $name, "Everyday apps") }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(step == nil ? "Add sub-bundle" : "Rename") {
                    if let s = step { model.renameGroup(s.id, name, in: bundleId) } else { model.addGroup(name, to: bundleId) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}

/// A bundle's own settings.
struct BundleEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var bundle: AppBundle
    @State private var customStop = false
    @State private var order: [Step] = []
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit “\(bundle.name)”").font(DS.heading)
            Form {
                Field("Name", $bundle.name, "Mac mini — everything")
                Section("Login and logout") {
                    Toggle("Start this bundle when I log in", isOn: $bundle.startAtLogin)
                    Toggle("Stop this bundle when I log out, restart or shut down", isOn: $bundle.stopAtLogout)
                    Text("Starting at login needs App Starter to open at login (Settings → General).").font(DS.secondary).foregroundStyle(.secondary)
                }
                Section("Stop order") {
                    Toggle("Stop in the reverse of the start order", isOn: Binding(get: { !customStop }, set: { customStop = !$0 }))
                    if customStop {
                        ForEach(Array(order.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                                Text(s.title.isEmpty ? "Sub-bundle" : s.title)
                                if s.isGroup { Text("sub-bundle").font(DS.secondary).foregroundStyle(.secondary) }
                                Spacer()
                                Button { order.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0).accessibilityLabel("Move \(s.title) earlier")
                                Button { order.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == order.count - 1).accessibilityLabel("Move \(s.title) later")
                            }
                        }
                        Text("Top stops first. Each step must be fully down before the next one stops.").font(DS.secondary).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Delete bundle…") { confirmDelete = true }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    // only what this sheet edits goes onto the bundle as it is NOW (steps, login switches in
                    // Settings or an import may have changed it while the sheet was open)
                    guard var now = model.bundle(bundle.id) else { dismiss(); return }
                    now.name = bundle.name.trimmingCharacters(in: .whitespaces)
                    now.startAtLogin = bundle.startAtLogin; now.stopAtLogout = bundle.stopAtLogout
                    now.stopOrder = customStop ? order.map(\.id).filter { id in now.steps.contains { $0.id == id } } : nil
                    model.updateBundle(now); dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(bundle.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 560, height: customStop ? 600 : 470)
        .onAppear { customStop = bundle.stopOrder != nil; order = bundle.stepsInStopOrder }
        .confirmationDialog("Delete the bundle “\(bundle.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete bundle") { model.deleteBundle(bundle); dismiss() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { Text("App Starter forgets it and its \(bundle.apps.count) application\(bundle.apps.count == 1 ? "" : "s"). Nothing is stopped — stop it first if you want it down.") }
    }
}

// MARK: - an application

struct AppEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bundleId: UUID
    let isNew: Bool
    @State private var app: AppItem
    @State private var placement: Placement
    @State private var newGroupName = ""
    @State private var healthKind: HealthCheck.Kind
    @State private var checkCommand = ""
    @State private var checkText = ""
    @State private var checkIgnoreCase = false
    @State private var checkURL = ""
    @State private var waitText: String
    @State private var testing = false
    @State private var testResult: String?

    init(bundleId: UUID, app: AppItem?, group: UUID?) {
        self.bundleId = bundleId
        isNew = app == nil
        let a = app ?? AppItem(name: "")
        _app = State(initialValue: a)
        _placement = State(initialValue: app != nil ? .stay : (group.map { .group($0) } ?? .newStep))
        _healthKind = State(initialValue: a.health.kind)
        _waitText = State(initialValue: String(a.waitSeconds))
        switch a.health {
        case .output(let c, let t, let i): _checkCommand = State(initialValue: c); _checkText = State(initialValue: t); _checkIgnoreCase = State(initialValue: i)
        case .url(let u): _checkURL = State(initialValue: u)
        default: break
        }
    }

    private var bundle: AppBundle? { model.bundle(bundleId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New application" : "Edit “\(app.name)”").font(DS.heading)
                Text("In bundle “\(bundle?.name ?? "")”").font(DS.secondary).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
            Form {
                Section {
                    Field("Name", $app.name, "Junk Tracker")
                    Picker("Where it goes", selection: $placement) { placementChoices }
                    if case .newGroup = placement { Field("New sub-bundle's name", $newGroupName, "Everyday apps") }
                    LabeledContent("Working folder") {
                        HStack {
                            PlainTextField("optional — your home folder", text: $app.workingFolder, monospaced: true, label: "Working folder")
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                    Text("Its commands run here, as you, in your login shell (\(Shell.loginShell)) — like typing them in Terminal.").font(DS.secondary).foregroundStyle(.secondary)
                }
                Section("Environment variables · for start, stop and the check") {
                    ForEach($app.env) { $v in
                        HStack(spacing: 8) {
                            PlainTextField("NAME", text: $v.name, monospaced: true, label: "Variable name").frame(width: 190)
                            if v.secret {
                                SecureField("value", text: $v.value).labelsHidden().textFieldStyle(.roundedBorder).accessibilityLabel("Secret value of \(v.name)")
                            } else {
                                PlainTextField("value", text: $v.value, monospaced: true, label: "Value of \(v.name)")
                            }
                            Toggle("Secret", isOn: $v.secret).toggleStyle(.checkbox)
                            Button { app.env.removeAll { $0.id == v.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(v.name)")
                        }
                    }
                    HStack {
                        Button { app.env.append(EnvVar(name: "", value: "")) } label: { Label("Add variable", systemImage: "plus") }
                        Spacer()
                        Text("Secret values are kept encrypted on disk and hidden in the log.").font(DS.secondary).foregroundStyle(.secondary)
                    }
                }
                Section("Start") {
                    Picker("How it runs", selection: $app.mode) {
                        Text("Starts itself in the background").tag(RunMode.startsItself)
                        Text("App Starter keeps it running").tag(RunMode.keepRunning)
                    }
                    .pickerStyle(.segmented)
                    Text(app.mode == .startsItself
                         ? "The command sets the app going and finishes — like ./TRACKER.sh --start, open -a Docker or docker start …"
                         : "The command is the app itself and keeps running — like npm start or ollama serve. App Starter keeps it going, sends its output to the log, and stops it.")
                        .font(DS.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ScriptEditor(text: $app.start, placeholder: "./TRACKER.sh --start", label: "Start command")
                    Text("Several lines are fine: they run one after another.").font(DS.secondary).foregroundStyle(.secondary)
                }
                Section("Stop") {
                    ScriptEditor(text: $app.stop, placeholder: app.mode == .keepRunning ? "optional — empty: App Starter stops what it started" : "./TRACKER.sh --stop", label: "Stop command")
                    if app.mode == .keepRunning {
                        Text("Empty: App Starter asks the app to quit, and forces it after 10 seconds.").font(DS.secondary).foregroundStyle(.secondary)
                    }
                }
                Section("Health check · optional") {
                    Picker("Check", selection: $healthKind) {
                        Text("None").tag(HealthCheck.Kind.none)
                        Text("Return code").tag(HealthCheck.Kind.returnCode)
                        Text("Output text").tag(HealthCheck.Kind.output)
                        Text("URL").tag(HealthCheck.Kind.url)
                    }
                    .pickerStyle(.segmented)
                    switch healthKind {
                    case .none:
                        Text(app.mode == .keepRunning ? "Up = the process is running." : "Up = the start command finished. App Starter can't tell later if it went down by itself.").font(DS.secondary).foregroundStyle(.secondary)
                    case .returnCode:
                        Text("Up = the start command finished with exit code 0; down = the stop command did. App Starter can't tell later if it went down by itself.").font(DS.secondary).foregroundStyle(.secondary)
                    case .output:
                        LabeledContent("Command to run") { PlainTextField("./TRACKER.sh --status", text: $checkCommand, monospaced: true, label: "Check command") }
                        Field("Up when the output contains", $checkText, "Running")
                        Toggle("Ignore capitals", isOn: $checkIgnoreCase)
                    case .url:
                        LabeledContent("Address") { PlainTextField("http://localhost:8420", text: $checkURL, monospaced: true, label: "Check address") }
                        Text("Up = anything answers at that address (any page, any certificate).").font(DS.secondary).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Wait up to")
                        PlainTextField("60", text: $waitText, label: "Seconds to wait").frame(width: 60)
                        Text("seconds for it to come up or go down")
                        Spacer()
                        if healthKind == .output || healthKind == .url {
                            if testing { ProgressView().controlSize(.small) }
                            if let r = testResult { Text(r).font(DS.secondary).foregroundStyle(r.hasPrefix("Up") ? Theme.good : Theme.problem) }
                            Button("Test check") { test() }.disabled(testing)
                        }
                    }
                    Text("The lights check it again every \(model.settings.checkEvery) seconds (Settings → General).").font(DS.secondary).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let p = built.problem { Text(p).font(DS.secondary).foregroundStyle(Theme.problem).lineLimit(2) }
                else if case .newGroup = placement, newGroupName.trimmingCharacters(in: .whitespaces).isEmpty { Text("Name the new sub-bundle.").font(DS.secondary).foregroundStyle(Theme.problem) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add application" : "Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 760, height: 860)
    }

    @ViewBuilder private var placementChoices: some View {
        if !isNew, let b = bundle, let si = b.stepIndex(of: app.id) {
            Text("Where it is now — step \(si + 1)\(b.steps[si].isGroup ? " (in “\(b.steps[si].name)”)" : "")").tag(Placement.stay)
        }
        Text("A step of its own, at the end").tag(Placement.newStep)
        if let b = bundle {
            ForEach(Array(b.steps.enumerated()), id: \.element.id) { i, s in
                if s.isGroup && (isNew || b.stepIndex(of: app.id) != i) { Text("Step \(i + 1) — in sub-bundle “\(s.name)”").tag(Placement.group(s.id)) }
            }
        }
        Text("A new sub-bundle…").tag(Placement.newGroup(""))
    }

    private var built: AppItem {
        var a = app
        a.name = a.name.trimmingCharacters(in: .whitespaces)
        a.workingFolder = a.workingFolder.trimmingCharacters(in: .whitespaces)
        a.env = a.env.map { var v = $0; v.name = v.name.trimmingCharacters(in: .whitespaces); return v }
        a.waitSeconds = Int(waitText.trimmingCharacters(in: .whitespaces)) ?? 0
        switch healthKind {
        case .none: a.health = .none
        case .returnCode: a.health = .returnCode
        case .output: a.health = .output(command: checkCommand, contains: checkText, ignoreCase: checkIgnoreCase)
        case .url: a.health = .url(checkURL.trimmingCharacters(in: .whitespaces))
        }
        return a
    }

    private var canSave: Bool {
        if built.problem != nil { return false }
        if case .newGroup = placement, newGroupName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func save() {
        var p = placement
        if case .newGroup = p { p = .newGroup(newGroupName.trimmingCharacters(in: .whitespaces)) }
        model.saveApp(built, in: bundleId, placement: p)
        dismiss()
    }

    private func test() {
        testing = true; testResult = nil
        let a = built
        Task {
            let up = await Health.poll(a) ?? false
            testing = false
            testResult = up ? "Up — the check passes" : "Down — the check does not pass"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let f = app.resolvedFolder { panel.directoryURL = URL(fileURLWithPath: f) }
        if panel.runModal() == .OK, let u = panel.url {
            let home = NSHomeDirectory()
            app.workingFolder = u.path.hasPrefix(home + "/") ? "~" + u.path.dropFirst(home.count) : u.path
        }
    }
}
