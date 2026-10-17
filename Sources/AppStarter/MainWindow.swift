// The main window — Matt's pick, layout A "Sidebar + step list": the bundles down the left with their lights,
// the selected bundle on the right with its numbered steps top to bottom (a sub-bundle is one card holding the
// apps that start together), Edit / Start / Stop at the top, Add application / Add sub-bundle at the bottom.
import SwiftUI
import AppStarterCore

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let b = model.selected { BundleDetail(bundle: b) }
            else { EmptyState() }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newBundle: NewBundleSheet()
            case .editBundle(let b): BundleEditor(bundle: b)
            case .newApp(let bid, let g): AppEditor(bundleId: bid, app: nil, group: g)
            case .editApp(let bid, let a): AppEditor(bundleId: bid, app: a, group: nil)
            case .newGroup(let bid): GroupNameSheet(bundleId: bid, step: nil)
            case .renameGroup(let bid, let s): GroupNameSheet(bundleId: bid, step: s)
            case .logs(let b, let a): BundleLogs(bundleId: b, initial: a)
            }
        }
        .sheet(item: $model.shownSession) { RunSheet(session: $0) }
        .confirmationDialog(stopTitle, isPresented: Binding(get: { model.askToStop != nil }, set: { if !$0 { model.askToStop = nil } }), titleVisibility: .visible) {
            Button("Stop it") { if let b = model.askToStop { model.run(b, .stopping) }; model.askToStop = nil }
            Button("Cancel", role: .cancel) { model.askToStop = nil }.keyboardShortcut(.defaultAction)
        } message: { Text(stopMessage) }
        .alert(item: $model.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK"))) }
        .onAppear(perform: developmentHooks)
    }

    /// Development only, harmless when unset (for trying screens on a scratch APPSTARTER_HOME):
    /// APPSTARTER_AUTOSTART="<bundle name>" starts it; APPSTARTER_AUTOSHEET=newApp|editApp|editBundle|log|menubar|settings[:tab]
    private func developmentHooks() {
        let env = ProcessInfo.processInfo.environment
        if let name = env["APPSTARTER_AUTOSTART"], let b = model.bundles.first(where: { $0.name == name }) {
            model.selectedId = b.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.run(b, .starting) }
        }
        guard let sheet = env["APPSTARTER_AUTOSHEET"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let b = model.selected ?? model.bundles.first else { return }
            let apps = b.apps
            switch sheet {
            case "newApp": model.sheet = .newApp(bundleId: b.id, group: nil)
            case "editApp": if let a = apps.first(where: { !$0.env.isEmpty }) ?? apps.first { model.sheet = .editApp(bundleId: b.id, a) }
            case "editBundle": model.sheet = .editBundle(b)
            case "log": model.sheet = .logs(bundleId: b.id, app: apps.first?.id)
            case "menubar":
                let w = NSWindow(contentRect: NSRect(x: 700, y: 400, width: 340, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Menu bar panel"; w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: MenuBarPanel().environmentObject(model).preferredColorScheme(model.lookInForce.colorScheme).tint(Theme.accent))
                w.makeKeyAndOrderFront(nil)
            default:
                if sheet.hasPrefix("settings") {
                    model.settingsTab = sheet.split(separator: ":").dropFirst().first.map(String.init) ?? "general"
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
    }

    private var stopTitle: String { "Stop “\(model.askToStop?.name ?? "")”?" }
    private var stopMessage: String {
        guard let b = model.askToStop else { return "" }
        let names = b.apps.map(\.name)
        let list = names.count <= 8 ? names.joined(separator: ", ") : names.prefix(7).joined(separator: ", ") + " and \(names.count - 7) more"
        return "This stops \(list) — in the bundle's stop order\(b.stopOrder == nil ? " (the reverse of the start order)" : "")."
    }
}

// MARK: - the sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedId) {
                Section("Bundles") {
                    ForEach(model.bundles) { b in
                        SidebarRow(bundle: b).tag(b.id)
                            .contextMenu {
                                Button("Start") { model.run(b, .starting) }
                                Button("Stop…") { model.askToStop = b }
                                Divider()
                                Button("Edit…") { model.sheet = .editBundle(b) }
                                Button("Duplicate") { model.duplicateBundle(b) }
                            }
                    }
                    .onMove { model.moveBundles(from: $0, to: $1) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(Theme.sidebarTint == nil ? .automatic : .hidden)
            .background(Theme.sidebarTint?.opacity(0.18) ?? .clear)
            Divider()
            HStack(spacing: 8) {
                Button { model.sheet = .newBundle } label: { Label("New bundle", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let bundle: AppBundle
    var body: some View {
        HStack(spacing: 10) {
            if model.isRunning(bundle.id) { ProgressView().controlSize(.small).frame(width: 10) }
            else { Dot(color: Theme.light(model.status(bundle)), size: 10) }
            VStack(alignment: .leading, spacing: 1) {
                Text(bundle.name).fontWeight(.semibold).lineLimit(1)
                Text(subtitle).font(DS.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
    private var subtitle: String {
        if let s = model.sessions[bundle.id], s.isRunning {
            return (s.phase == .starting ? "Starting" : "Stopping") + (s.failure != nil ? " · needs you" : " · step \(s.stepIndex + 1) of \(s.steps.count)")
        }
        let n = bundle.apps.count
        if n == 0 { return "No applications yet" }
        return "\(model.status(bundle).label) · \(n) app\(n == 1 ? "" : "s")"
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power").font(.system(size: 40, weight: .medium)).foregroundStyle(Theme.accent)
            Text("No bundles yet").font(DS.heading)
            Text("A bundle is a group of your apps that start and stop together, in the order you choose.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("New bundle…") { model.sheet = .newBundle }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - a bundle's page

struct BundleDetail: View {
    @EnvironmentObject var model: AppModel
    let bundle: AppBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            if bundle.steps.isEmpty {
                VStack(spacing: 10) {
                    Text("This bundle is empty").font(DS.heading)
                    Text("Add the applications it starts. Each one is a step; put apps in a sub-bundle to start them together.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    HStack { addButtons }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Start order", detail: (bundle.stopOrder == nil ? "· top to bottom; stopping goes bottom to top" : "· top to bottom; stopping has its own order (Edit)") + " · drag a card to move it")
                        // drop spots between the steps; a card dropped on one moves there (an app from a sub-bundle
                        // becomes a step of its own); dropped on a sub-bundle, an app goes into it
                        VStack(spacing: 0) {
                            ForEach(Array(bundle.steps.enumerated()), id: \.element.id) { i, step in
                                DropGap(bundleId: bundle.id, index: i, first: i == 0)
                                StepRow(bundle: bundle, step: step, number: i + 1, last: i == bundle.steps.count - 1)
                            }
                            DropGap(bundleId: bundle.id, index: bundle.steps.count, first: false)
                        }
                        HStack(spacing: 8) {
                            addButtons
                            Spacer()
                            if let t = model.checkedAt { Text("Checked \(t.formatted(date: .omitted, time: .shortened))").font(DS.secondary).foregroundStyle(.secondary) }
                            Button("Check now") { Task { await model.refreshStatus() } }.buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.secondary)
                        }
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 28).padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var addButtons: some View {
        Button { model.sheet = .newApp(bundleId: bundle.id, group: nil) } label: { Label("Add application", systemImage: "plus") }
        Button { model.sheet = .newGroup(bundleId: bundle.id) } label: { Label("Add sub-bundle", systemImage: "square.stack.3d.up") }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.name).font(DS.title).lineLimit(2)
                Text(subtitle).font(DS.secondary).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = model.sessions[bundle.id] {
                Button(s.isRunning ? (s.failure != nil ? "Needs you…" : "Show progress") : "Last run") { model.shownSession = s }
            }
            Button { model.sheet = .logs(bundleId: bundle.id, app: nil) } label: { Label("Logs", systemImage: "doc.text") }
                .disabled(bundle.apps.isEmpty).help("The logs of this bundle's applications")
            Button("Edit") { model.sheet = .editBundle(bundle) }
            let st = model.status(bundle)
            if st != .allUp && st != .empty {
                Button { model.run(bundle, .starting) } label: { Label(st == .mixed ? "Start the rest" : "Start bundle", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(model.isRunning(bundle.id))
            }
            if st == .allUp || st == .mixed {
                Button { model.askToStop = bundle } label: { Label("Stop bundle", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.problem).disabled(model.isRunning(bundle.id))
            }
        }
        .controlSize(.large)
    }

    private var subtitle: String {
        let steps = bundle.steps.count, apps = bundle.apps.count
        var parts = ["\(steps) step\(steps == 1 ? "" : "s")", "\(apps) app\(apps == 1 ? "" : "s")"]
        if apps > 0 { parts.append("\(model.upCount(bundle)) up") }
        if bundle.startAtLogin { parts.append("starts at login") }
        if bundle.stopAtLogout { parts.append("stops at logout") }
        return parts.joined(separator: " · ")
    }
}

/// One numbered step: a single app, or a sub-bundle card with its apps side by side.
struct StepRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let bundle: AppBundle
    let step: Step
    let number: Int
    let last: Bool
    @State private var confirmDelete = false
    @State private var targeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26).background(Theme.accent.opacity(0.14), in: Circle())
                if !last { Rectangle().fill(DS.edge(scheme)).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: 28)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    if step.isGroup {
                        // the header is the handle for the whole sub-bundle; its apps can each be dragged on their own
                        HStack(spacing: 8) {
                            DragHandle()
                            Text(step.name.isEmpty ? "Sub-bundle" : step.name).font(DS.section)
                            Badge(text: "Sub-bundle · together", fill: Theme.accent.opacity(0.14), color: Theme.accent)
                            Spacer()
                            stepMenu
                        }
                        .contentShape(Rectangle())
                        .draggable(DragItem.step(step.id).token) { DragPreview(title: step.name.isEmpty ? "Sub-bundle" : step.name, icon: "square.stack.3d.up") }
                        if step.apps.isEmpty {
                            Text(targeted ? "Drop it here" : "Empty — add the apps that start together, or drag apps here.").font(DS.secondary).foregroundStyle(targeted ? Theme.accent : .secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8)], spacing: 8) {
                                ForEach(step.apps) { AppRow(bundle: bundle, app: $0, compact: true, groupId: step.id) }
                            }
                        }
                        Button { model.sheet = .newApp(bundleId: bundle.id, group: step.id) } label: { Label("Add to this sub-bundle", systemImage: "plus") }
                            .buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.secondary)
                    } else if let a = step.apps.first {
                        HStack(spacing: 8) { DragHandle(); AppRow(bundle: bundle, app: a, compact: false); stepMenu }
                            .contentShape(Rectangle())
                            .draggable(DragItem.step(step.id).token) { DragPreview(title: a.name, icon: "app") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(RoundedRectangle(cornerRadius: DS.radius).strokeBorder(Theme.accent, lineWidth: targeted ? 2 : 0))
            // a sub-bundle takes apps dropped on it; a one-app step takes a drop as "put it here, before me"
            .dropDestination(for: String.self) { items, _ in
                guard let token = items.first else { return false }
                return model.drop(token, at: step.isGroup ? .intoGroup(step.id, before: nil) : .gap(number - 1), in: bundle.id)
            } isTargeted: { targeted = $0 }
        }
        .confirmationDialog("Delete \(step.isGroup ? "the sub-bundle “\(step.name)”" : "“\(step.title)”")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete") { model.deleteStep(step.id, in: bundle.id) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(step.isGroup && !step.apps.isEmpty ? "Its \(step.apps.count) app\(step.apps.count == 1 ? "" : "s") go with it. Nothing is stopped." : "Only App Starter forgets it. Nothing is stopped.")
        }
    }

    private var stepMenu: some View {
        Menu {
            // edit what the card is: the app, or the sub-bundle's name
            if step.isGroup {
                Button("Edit…") { model.sheet = .renameGroup(bundleId: bundle.id, step) }
            } else if let a = step.apps.first {
                Button("Edit…") { model.sheet = .editApp(bundleId: bundle.id, a) }
            }
            Divider()
            Button("Move up") { model.moveStep(step.id, by: -1, in: bundle.id) }.disabled(number == 1)
            Button("Move down") { model.moveStep(step.id, by: 1, in: bundle.id) }.disabled(last)
            if step.isGroup {
                Divider()
                Button("Start this sub-bundle") { model.run(AppBundle(id: bundle.id, name: step.name, steps: [step]), .starting) }.disabled(step.apps.isEmpty)
                Button("Stop this sub-bundle") { model.run(AppBundle(id: bundle.id, name: step.name, steps: [step]), .stopping) }.disabled(step.apps.isEmpty)
            }
            Divider()
            Button(step.isGroup ? "Delete sub-bundle…" : "Delete…", role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Edit, move or delete this step").accessibilityLabel("Step \(number) options")
    }
}

/// An application: its light, its name, how it is checked; click to edit it.
struct AppRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let bundle: AppBundle
    let app: AppItem
    let compact: Bool
    /// the sub-bundle it is in (its rows can be dragged on their own, and take drops "before me")
    var groupId: UUID? = nil
    @State private var confirmDelete = false
    @State private var targeted = false

    var body: some View {
        // a card that opens the editor on a click (a tap, not a Button: a button would take the mouse and a drag
        // could never start from it)
        HStack(spacing: 10) {
            progressMark
            Text(app.name).fontWeight(compact ? .medium : .semibold).lineLimit(1)
            Spacer(minLength: 6)
            Text(detail).font(DS.secondary).foregroundStyle(failed ? Theme.problem : .secondary).lineLimit(1)
        }
        .padding(.horizontal, compact ? 10 : 0).padding(.vertical, compact ? 8 : 0)
        .background(compact ? DS.panel(scheme) : .clear, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
        .contentShape(Rectangle())
        .onTapGesture { model.sheet = .editApp(bundleId: bundle.id, app) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.sheet = .editApp(bundleId: bundle.id, app) }
        .overlay(alignment: .leading) {
            if targeted { RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3).offset(x: -6) }
        }
        .modifier(GroupAppDrag(bundleId: bundle.id, app: app, groupId: groupId, targeted: $targeted))
        .help("Click to edit “\(app.name)” · drag to move it")
        .contextMenu {
            Button("Start this one") { model.runApp(app, in: bundle, .starting) }
            Button("Stop this one") { model.runApp(app, in: bundle, .stopping) }
            Divider()
            Button("Show log") { model.sheet = .logs(bundleId: bundle.id, app: app.id) }
            Button("Edit…") { model.sheet = .editApp(bundleId: bundle.id, app) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(app.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete") { model.deleteApp(app.id, in: bundle.id) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { Text("Only App Starter forgets it (and its log). Nothing is stopped.") }
    }

    private var running: AppProgress? {
        guard let s = model.sessions[bundle.id], s.isRunning else { return nil }
        return s.progress[app.id]
    }
    private var failed: Bool { if case .failed = running { return true }; return false }

    @ViewBuilder private var progressMark: some View {
        if case .working = running { ProgressView().controlSize(.mini).frame(width: 8, height: 8) }
        else { Dot(color: failed ? Theme.problem : (model.isUp(app.id) ? Theme.good : Theme.problem)) }
    }

    private var detail: String {
        switch running {
        case .working(let w): return w
        case .failed(let f): return f
        default: break
        }
        let how: String
        switch app.health {
        case .none: how = app.mode == .keepRunning ? "kept running" : "no check"
        case .returnCode: how = "return code"
        case .output: how = "output text"
        case .url: how = "URL"
        }
        return "\(how) · \(model.isUp(app.id) ? "up" : "down")"
    }
}

// MARK: - drag and drop

/// The thin space between two steps: a drop there puts the card at that place in the order.
struct DropGap: View {
    @EnvironmentObject var model: AppModel
    let bundleId: UUID
    let index: Int
    let first: Bool
    @State private var targeted = false
    var body: some View {
        ZStack {
            Color.clear
            if targeted { Capsule().fill(Theme.accent).frame(height: 3).padding(.leading, 40) }
        }
        .frame(height: targeted ? 22 : (first ? 4 : 10))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let token = items.first else { return false }
            return model.drop(token, at: .gap(index), in: bundleId)
        } isTargeted: { t in withAnimation(.easeOut(duration: 0.12)) { targeted = t } }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

/// An app inside a sub-bundle: dragged on its own; another app dropped on it goes in just before it.
struct GroupAppDrag: ViewModifier {
    @EnvironmentObject var model: AppModel
    let bundleId: UUID
    let app: AppItem
    let groupId: UUID?
    @Binding var targeted: Bool
    func body(content: Content) -> some View {
        if let gid = groupId {
            content
                .draggable(DragItem.app(app.id).token) { DragPreview(title: app.name, icon: "app") }
                .dropDestination(for: String.self) { items, _ in
                    guard let token = items.first else { return false }
                    return model.drop(token, at: .intoGroup(gid, before: app.id), in: bundleId)
                } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

/// The six dots that say "you can drag this".
struct DragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            .frame(width: 14).accessibilityHidden(true)
    }
}

/// What follows the pointer while a card is dragged.
struct DragPreview: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon).font(DS.body).fontWeight(.semibold)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
