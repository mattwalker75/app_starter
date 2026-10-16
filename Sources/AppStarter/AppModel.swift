// The one object the windows and the menu bar item watch: the bundles, the live status of every app, the runs
// going on, and the settings. It owns bundles.json (through BundleStore), starts and stops bundles through the
// Engine, checks the apps every so often for the lights, starts the start-at-login bundles once per login and
// stops the stop-at-logout ones when you log out.
import SwiftUI
import AppStarterCore
import ServiceManagement
import Combine

/// Where a new or edited application goes in its bundle.
enum Placement: Hashable {
    /// a step of its own, at the end
    case newStep
    /// keep it where it is (editing)
    case stay
    /// into this sub-bundle
    case group(UUID)
    /// into a new sub-bundle with this name, at the end
    case newGroup(String)
}

enum MainSheet: Identifiable {
    case newBundle
    case editBundle(AppBundle)
    case newApp(bundleId: UUID, group: UUID?)
    case editApp(bundleId: UUID, AppItem)
    case newGroup(bundleId: UUID)
    case renameGroup(bundleId: UUID, Step)
    case log(AppItem)
    var id: String {
        switch self {
        case .newBundle: return "newBundle"
        case .editBundle(let b): return "editBundle-\(b.id)"
        case .newApp(let b, let g): return "newApp-\(b)-\(g?.uuidString ?? "")"
        case .editApp(_, let a): return "editApp-\(a.id)"
        case .newGroup(let b): return "newGroup-\(b)"
        case .renameGroup(_, let s): return "renameGroup-\(s.id)"
        case .log(let a): return "log-\(a.id)"
        }
    }
}

struct Notice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var bundles: [AppBundle] = []
    @Published var selectedId: UUID?
    /// app id → up, from the last check
    @Published var up: [UUID: Bool] = [:]
    /// when the lights were last brought up to date
    @Published var checkedAt: Date?
    /// bundle id → its run going on now, or the last one until it is dismissed
    @Published var sessions: [UUID: RunSession] = [:]
    /// the run whose progress sheet is showing
    @Published var shownSession: RunSession?
    @Published var sheet: MainSheet?
    @Published var notice: Notice?
    /// a bundle waiting for "Stop it?" to be answered
    @Published var askToStop: AppBundle?
    @Published var settings = AppSettings.load() { didSet { guard settings != oldValue else { return }; settings.save(); Theme.apply(settings); engine.logs.maxBytes = settings.logLimitMB * 1_000_000; if oldValue.checkEvery != settings.checkEvery { restartMonitor() } } }
    @Published var settingsTab = "general"
    @Published var previewLook: Appearance?
    var lookInForce: Appearance { previewLook ?? settings.effectiveAppearance }

    let store = BundleStore()
    let engine = Engine()
    private var monitor: Task<Void, Never>?
    /// a run's changes are passed on, so the sidebar, the rows and the menu bar follow it too
    private var followers: [UUID: AnyCancellable] = [:]

    init() {
        do { bundles = try store.load() } catch let e as ASError { notice = Notice(title: "The bundles could not be read", message: e.message) } catch {}
        selectedId = bundles.first?.id
        engine.logs.maxBytes = settings.logLimitMB * 1_000_000
        Theme.apply(settings)
        restartMonitor()
        Task { await autostartIfNewLogin() }
    }

    // MARK: bundles

    var selected: AppBundle? { bundles.first { $0.id == selectedId } }
    func bundle(_ id: UUID) -> AppBundle? { bundles.first { $0.id == id } }

    func save() {
        do { try store.save(bundles) } catch { notice = Notice(title: "The bundles could not be saved", message: (error as? ASError)?.message ?? error.localizedDescription) }
        let ids = Set(bundles.flatMap(\.apps).map(\.id))
        engine.logs.prune(keeping: ids)
        engine.runtime.forget(keeping: ids)
    }

    func addBundle(_ name: String) {
        let b = AppBundle(name: name.trimmingCharacters(in: .whitespaces))
        bundles.append(b); selectedId = b.id; save()
    }

    func updateBundle(_ b: AppBundle) {
        guard let i = bundles.firstIndex(where: { $0.id == b.id }) else { return }
        bundles[i] = b; save()
    }

    func deleteBundle(_ b: AppBundle) {
        guard !isRunning(b.id) else { notice = Notice(title: "“\(b.name)” is busy", message: "Wait for it to finish starting or stopping, or cancel it, before deleting it."); return }
        bundles.removeAll { $0.id == b.id }
        sessions.removeValue(forKey: b.id)
        if selectedId == b.id { selectedId = bundles.first?.id }
        save()
    }

    func duplicateBundle(_ b: AppBundle) {
        let c = Transfer.freshCopy(b, name: b.name + " copy")
        bundles.append(c); selectedId = c.id; save()
    }

    func moveBundles(from: IndexSet, to: Int) { bundles.move(fromOffsets: from, toOffset: to); save() }

    // MARK: applications and sub-bundles

    /// Saves a new or changed app and puts it where `placement` says.
    func saveApp(_ app: AppItem, in bundleId: UUID, placement: Placement) {
        guard var b = bundle(bundleId) else { return }
        let existed = b.stepIndex(of: app.id)
        if placement == .stay, let si = existed, let ai = b.steps[si].apps.firstIndex(where: { $0.id == app.id }) {
            b.steps[si].apps[ai] = app
        } else {
            if let si = existed { b.steps[si].apps.removeAll { $0.id == app.id }; if !b.steps[si].isGroup && b.steps[si].apps.isEmpty { b.steps.remove(at: si) } }
            switch placement {
            case .newStep, .stay: b.steps.append(Step(app: app))
            case .group(let gid):
                if let gi = b.steps.firstIndex(where: { $0.id == gid }) { b.steps[gi].apps.append(app) } else { b.steps.append(Step(app: app)) }
            case .newGroup(let name): b.steps.append(Step(group: name, apps: [app]))
            }
        }
        updateBundle(b)
    }

    func deleteApp(_ appId: UUID, in bundleId: UUID) {
        guard var b = bundle(bundleId), let si = b.stepIndex(of: appId) else { return }
        b.steps[si].apps.removeAll { $0.id == appId }
        if !b.steps[si].isGroup && b.steps[si].apps.isEmpty { b.steps.remove(at: si) }
        updateBundle(b)
    }

    func addGroup(_ name: String, to bundleId: UUID) {
        guard var b = bundle(bundleId) else { return }
        b.steps.append(Step(group: name.trimmingCharacters(in: .whitespaces)))
        updateBundle(b)
    }

    func renameGroup(_ stepId: UUID, _ name: String, in bundleId: UUID) {
        guard var b = bundle(bundleId), let i = b.steps.firstIndex(where: { $0.id == stepId }) else { return }
        b.steps[i].name = name.trimmingCharacters(in: .whitespaces)
        updateBundle(b)
    }

    /// Removes a step; a sub-bundle's apps go with it.
    func deleteStep(_ stepId: UUID, in bundleId: UUID) {
        guard var b = bundle(bundleId) else { return }
        b.steps.removeAll { $0.id == stepId }
        b.stopOrder?.removeAll { $0 == stepId }
        updateBundle(b)
    }

    func moveStep(_ stepId: UUID, by delta: Int, in bundleId: UUID) {
        guard var b = bundle(bundleId), let i = b.steps.firstIndex(where: { $0.id == stepId }) else { return }
        let j = i + delta
        guard j >= 0 && j < b.steps.count else { return }
        b.steps.swapAt(i, j)
        updateBundle(b)
    }

    // MARK: status

    func isUp(_ appId: UUID) -> Bool { up[appId] ?? false }

    func status(_ b: AppBundle) -> BundleStatus {
        // while it runs, the run's own view is the truth
        BundleStatus.of(b.apps.map { isUp($0.id) })
    }

    func upCount(_ b: AppBundle) -> Int { b.apps.filter { isUp($0.id) }.count }

    var allApps: [AppItem] { bundles.flatMap(\.apps) }

    /// Checks every app (not those in a run going on now — that run reports them).
    func refreshStatus() async {
        let busy = Set(sessions.values.filter(\.isRunning).flatMap { $0.bundle.apps.map(\.id) })
        let apps = allApps.filter { !busy.contains($0.id) }
        let engine = self.engine
        let results = await withTaskGroup(of: (UUID, Bool).self) { g in
            for a in apps { g.addTask { (a.id, await engine.isUp(a)) } }
            var r: [UUID: Bool] = [:]
            for await (id, ok) in g { r[id] = ok }
            return r
        }
        for (id, ok) in results { up[id] = ok }
        checkedAt = Date()
    }

    private func restartMonitor() {
        monitor?.cancel()
        let every = max(5, settings.checkEvery)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(nanoseconds: UInt64(every) * 1_000_000_000)
            }
        }
    }

    // MARK: starting and stopping

    func isRunning(_ bundleId: UUID) -> Bool { sessions[bundleId]?.isRunning ?? false }
    var anyRunning: Bool { sessions.values.contains { $0.isRunning } }

    /// Starts (or stops) a bundle; `show` opens the progress sheet.
    func run(_ b: AppBundle, _ phase: Phase, show: Bool = true) {
        guard !isRunning(b.id) else { if show { shownSession = sessions[b.id] }; return }
        guard !b.apps.isEmpty else { notice = Notice(title: "“\(b.name)” has no applications yet", message: "Add an application to it first."); return }
        launch(RunSession(bundle: b, phase: phase), show: show) { engine, s in
            phase == .starting
                ? await engine.start(b, events: { e in Task { @MainActor in s.handle(e) } }, decide: { f in await s.ask(f) })
                : await engine.stop(b, events: { e in Task { @MainActor in s.handle(e) } }, decide: { f in await s.ask(f) })
        }
    }

    /// Starts or stops one application of a bundle on its own (from its row).
    func runApp(_ app: AppItem, in b: AppBundle, _ phase: Phase) {
        guard !isRunning(b.id) else { shownSession = sessions[b.id]; return }
        let one = AppBundle(id: b.id, name: b.name, steps: [Step(app: app)])
        launch(RunSession(bundle: one, phase: phase, singleApp: app.name), show: true) { engine, s in
            phase == .starting
                ? await engine.start(one, events: { e in Task { @MainActor in s.handle(e) } }, decide: { f in await s.ask(f) })
                : await engine.stop(one, events: { e in Task { @MainActor in s.handle(e) } }, decide: { f in await s.ask(f) })
        }
    }

    private func launch(_ s: RunSession, show: Bool, _ work: @escaping @Sendable (Engine, RunSession) async -> Outcome) {
        sessions[s.bundle.id] = s
        followers[s.id] = s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if show { shownSession = s }
        let engine = self.engine
        s.task = Task { [weak self] in
            let outcome = await work(engine, s)
            s.finish(outcome)
            // the lights follow what the run did, then a fresh check
            for (id, p) in s.progress { if case .done = p { self?.up[id] = s.phase == .starting } }
            await self?.refreshStatus()
        }
    }

    func dismiss(_ s: RunSession) {
        if shownSession === s { shownSession = nil }
        if !s.isRunning, sessions[s.bundle.id] === s { sessions.removeValue(forKey: s.bundle.id); followers.removeValue(forKey: s.id) }
    }

    // MARK: login and logout

    /// Starts the start-at-login bundles, once per login session (whether App Starter opened at login or later).
    func autostartIfNewLogin() async {
        let session = LoginSession.current
        guard engine.runtime.lastAutostartSession != session else { return }
        engine.runtime.lastAutostartSession = session
        // one after another, in the order they are listed; a failure is skipped (nobody is there to answer)
        for b in bundles where b.startAtLogin && !b.apps.isEmpty {
            run(b, .starting, show: false)
            await sessions[b.id]?.task?.value
        }
    }

    /// Stops the stop-at-logout bundles (the newest-listed first) before the Mac logs out, restarts or shuts down.
    /// Failures are skipped — nobody is there to answer. Calls `done` when finished or after `limit` seconds.
    func stopForLogout(limit: Double = 90, done: @escaping () -> Void) {
        let todo = bundles.reversed().filter { $0.stopAtLogout && !$0.apps.isEmpty }
        guard !todo.isEmpty else { done(); return }
        var finished = false
        let finishOnce = { if !finished { finished = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { finishOnce() }
        Task {
            for b in todo {
                sessions[b.id]?.cancel()
                let s = RunSession(bundle: b, phase: .stopping)
                sessions[b.id] = s
                followers[s.id] = s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                let o = await engine.stop(b, events: { e in Task { @MainActor in s.handle(e) } }, decide: { _ in .skip })
                s.finish(o)
            }
            finishOnce()
        }
    }

    var stopsAtLogout: Bool { bundles.contains { $0.stopAtLogout && !$0.apps.isEmpty } }

    // MARK: export and import

    func exportData(includeSecrets: Bool) throws -> Data { try Transfer.export(bundles, includeSecrets: includeSecrets) }

    func importFile(_ f: ExportFile, replace: Bool) {
        bundles = Transfer.merge(f.bundles, into: bundles, replace: replace)
        if selectedId == nil { selectedId = bundles.first?.id }
        save()
    }

    // MARK: development hooks (harmless when unset)

    /// APPSTARTER_SAMPLE=1 with an empty APPSTARTER_HOME fills in example bundles (for screenshots)
    func addSampleIfAsked() {
        guard ProcessInfo.processInfo.environment["APPSTARTER_SAMPLE"] == "1", bundles.isEmpty else { return }
        bundles = Sample.bundles()
        selectedId = bundles.first?.id
        save()
    }
}

/// Which login session this is: a new value after every log in (and every restart).
enum LoginSession {
    static var current: String {
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &boot, &size, nil, 0)
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        let sid = (dict?["kCGSSessionIDKey"] as? Int).map(String.init) ?? "?"
        return "\(boot.tv_sec)-\(sid)"
    }
}

/// "Open App Starter at login".
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func set(_ on: Bool) throws { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
}

enum Appearance: String, Codable, CaseIterable {
    case system, light, dark
    var label: String { switch self { case .system: return "Follow the system"; case .light: return "Light"; case .dark: return "Dark" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

/// The app's own settings, saved as settings.json beside bundles.json.
struct AppSettings: Codable, Equatable {
    var appearance: Appearance = .system
    var accent: ThemeColor = .blue
    var themes: [CustomTheme] = []
    var activeThemeId: UUID?
    var showInMenuBar = true
    /// seconds between checks for the lights
    var checkEvery = 30
    /// a log is trimmed back once it passes this size
    var logLimitMB = 2

    var activeTheme: CustomTheme? { activeThemeId.flatMap { id in themes.first { $0.id == id } } }
    var effectiveAppearance: Appearance { activeTheme?.look ?? appearance }

    init() {}
    // every field optional on disk, so a settings file from an older version still loads
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        accent = try c.decodeIfPresent(ThemeColor.self, forKey: .accent) ?? .blue
        themes = try c.decodeIfPresent([CustomTheme].self, forKey: .themes) ?? []
        activeThemeId = try c.decodeIfPresent(UUID.self, forKey: .activeThemeId)
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        checkEvery = try c.decodeIfPresent(Int.self, forKey: .checkEvery) ?? 30
        logLimitMB = try c.decodeIfPresent(Int.self, forKey: .logLimitMB) ?? 2
    }

    static var url: URL { Home.folder().appendingPathComponent("settings.json") }
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
    func save() { if let data = try? JSONEncoder().encode(self) { try? data.write(to: AppSettings.url, options: .atomic) } }
}
