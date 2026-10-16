// What App Starter remembers about each application between launches (state.json): whether its last start
// worked and it has not been stopped since (the only way to know for an app whose health can't be checked),
// and — for an app App Starter keeps running — that process's number and start time, so it can be found (and
// stopped) after App Starter itself was closed and opened again.
import Foundation

public struct AppRuntime: Codable, Equatable, Sendable {
    /// the last start worked and no stop since
    public var started = false
    /// the kept-running process (its process group has the same number)
    public var pid: Int32?
    /// when that process started, so a different process that later got the same number is never mistaken for it
    public var pidStart: Double?
    public var changedAt = Date()
    public init() {}
}

public final class Runtime: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var apps: [UUID: AppRuntime] = [:]
    /// the processes started in this session, kept to be waited on
    private var live: [UUID: Spawned] = [:]
    /// the login session the start-at-login bundles last ran in
    private var autostartSession: String?

    struct File: Codable { var apps: [UUID: AppRuntime]; var autostartSession: String? }

    public init(url: URL = Home.folder().appendingPathComponent("state.json")) {
        self.url = url
        if let d = try? Data(contentsOf: url), let f = try? JSON.decoder.decode(File.self, from: d) { apps = f.apps; autostartSession = f.autostartSession }
    }

    public subscript(_ id: UUID) -> AppRuntime {
        lock.lock(); defer { lock.unlock() }
        return apps[id] ?? AppRuntime()
    }

    public func update(_ id: UUID, _ change: (inout AppRuntime) -> Void) {
        lock.lock()
        var r = apps[id] ?? AppRuntime()
        change(&r); r.changedAt = Date(); apps[id] = r
        lock.unlock()
        save()
    }

    func keep(_ id: UUID, _ p: Spawned) {
        lock.lock(); live[id] = p; lock.unlock()
        update(id) { $0.pid = p.pid; $0.pidStart = Shell.startTime(of: p.pid) }
    }

    func liveProcess(_ id: UUID) -> Spawned? { lock.lock(); defer { lock.unlock() }; return live[id] }

    func forgetProcess(_ id: UUID) {
        lock.lock(); live.removeValue(forKey: id); lock.unlock()
        update(id) { $0.pid = nil; $0.pidStart = nil }
    }

    /// Is the kept-running process (or anything it started) still going?
    public func processAlive(_ id: UUID) -> Bool {
        if let p = liveProcess(id) {
            if p.finished == nil { return true }
            return Shell.groupAlive(p.pid)   // the leader ended but its children carry on
        }
        let r = self[id]
        guard let pid = r.pid else { return false }
        if let want = r.pidStart, let now = Shell.startTime(of: pid), abs(want - now) < 1 { return true }
        // the leader is gone (or is someone else now): only its own group still counts
        return Shell.startTime(of: pid) == nil && Shell.groupAlive(pid)
    }

    public func forget(keeping ids: Set<UUID>) {
        lock.lock(); apps = apps.filter { ids.contains($0.key) }; lock.unlock()
        save()
    }

    public var lastAutostartSession: String? {
        get { lock.lock(); defer { lock.unlock() }; return autostartSession }
        set { lock.lock(); autostartSession = newValue; lock.unlock(); save() }
    }

    /// Written while holding the lock: two apps of a sub-bundle start at once, and an older copy written last would
    /// lose the other's process number (found in review; reproduced with 16 parallel updates).
    private func save() {
        lock.lock(); defer { lock.unlock() }
        try? JSON.encoder.encode(File(apps: apps, autostartSession: autostartSession)).write(to: url, options: .atomic)
    }
}
