// Starting and stopping a bundle. The steps go one after another; the applications in a step (a sub-bundle)
// go together, and the next step begins only when every one of them is up (when starting) or down (when
// stopping). When something fails the run pauses and asks: Retry it, Skip it and go on, or — when starting —
// Stop what this run started. Nothing here touches the UI: it reports events and asks through `decide`.
import Foundation

public enum Phase: String, Sendable { case starting, stopping }

/// Where one application is in a run.
public enum AppProgress: Equatable, Sendable {
    case waiting
    case working(String)
    /// up (starting) or down (stopping) — `note` says how ("up in 4 s", "was already running")
    case done(String)
    case failed(String)
    case skipped
}

public struct FailedApp: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var reason: String
}

/// A step that did not finish: what failed and why.
public struct Failure: Equatable, Sendable {
    public var phase: Phase
    public var stepIndex: Int
    public var stepTitle: String
    public var apps: [FailedApp]
}

public enum Choice: Equatable, Sendable {
    case retry
    /// leave the failed apps as they are and go on with the next step
    case skip
    /// starting: stop everything this run started, then end. Stopping: end here.
    case giveUp
}

public enum RunEvent: Sendable {
    /// a step begins (index into the order the run goes in)
    case step(Int, of: Int, stepId: UUID)
    case app(UUID, AppProgress)
    /// the run waits for the answer to `decide`
    case paused(Failure)
    case resumed
}

public enum Outcome: Equatable, Sendable {
    case done
    /// finished, but these apps were skipped after failing
    case doneWithSkips([String])
    /// starting: stopped what it had started after a failure. Stopping: ended at the user's word.
    case gaveUp
    case cancelled

    public var text: String {
        switch self {
        case .done: return "done"
        case .doneWithSkips(let n): return "done, without \(n.joined(separator: ", "))"
        case .gaveUp: return "given up"
        case .cancelled: return "cancelled"
        }
    }
}

public final class Engine: @unchecked Sendable {
    public let logs: AppLogs
    public let runtime: Runtime
    /// how often a check is tried while waiting for an app to come up or go down
    public var pollEvery: Double = 1
    /// a kept-running app with no check counts as up once it has run this long
    public var settleSeconds: Double = 2
    /// how long a kept-running app gets to stop after being asked, before it is forced
    public var stopGrace: Double = 10

    public init(logs: AppLogs = AppLogs(), runtime: Runtime = Runtime()) { self.logs = logs; self.runtime = runtime }

    // MARK: is it up?

    /// Up right now, as far as App Starter can tell (see Health.swift).
    public func isUp(_ app: AppItem) async -> Bool {
        if app.mode == .keepRunning {
            guard runtime.processAlive(app.id) else { return false }
            return await Health.poll(app) ?? true
        }
        if let polled = await Health.poll(app) { return polled }
        return runtime[app.id].started
    }

    // MARK: a whole bundle

    public func start(_ bundle: AppBundle, events: @escaping @Sendable (RunEvent) -> Void, decide: @escaping @Sendable (Failure) async -> Choice) async -> Outcome {
        var started: [AppItem] = []   // what this run started, for "Stop what started"
        var skipped: [String] = []
        let steps = bundle.steps.filter { !$0.apps.isEmpty }
        for (i, step) in steps.enumerated() {
            if Task.isCancelled { return .cancelled }
            events(.step(i, of: steps.count, stepId: step.id))
            var todo = step.apps
            for a in todo { events(.app(a.id, .waiting)) }
            while true {
                let results = await parallel(todo) { [self] a in await startApp(a, events: events) }
                if Task.isCancelled { return .cancelled }
                started += results.filter { $0.ok && !$0.already }.map(\.app)
                let failed = results.filter { !$0.ok }
                if failed.isEmpty { break }
                let f = Failure(phase: .starting, stepIndex: i, stepTitle: step.title, apps: failed.map { FailedApp(id: $0.app.id, name: $0.app.name, reason: $0.note) })
                events(.paused(f))
                let choice = await decide(f)
                events(.resumed)
                switch choice {
                case .retry: todo = failed.map(\.app)
                case .skip:
                    for r in failed { events(.app(r.app.id, .skipped)) }
                    skipped += failed.map(\.app.name)
                case .giveUp:
                    // stop what this run started, the newest first
                    for a in started.reversed() { _ = await stopApp(a, events: events) }
                    return .gaveUp
                }
                if choice != .retry { break }
            }
        }
        return skipped.isEmpty ? .done : .doneWithSkips(skipped)
    }

    public func stop(_ bundle: AppBundle, events: @escaping @Sendable (RunEvent) -> Void, decide: @escaping @Sendable (Failure) async -> Choice) async -> Outcome {
        var skipped: [String] = []
        let steps = bundle.stepsInStopOrder.filter { !$0.apps.isEmpty }
        for (i, step) in steps.enumerated() {
            if Task.isCancelled { return .cancelled }
            events(.step(i, of: steps.count, stepId: step.id))
            var todo = step.apps
            for a in todo { events(.app(a.id, .waiting)) }
            while true {
                let results = await parallel(todo) { [self] a in await stopApp(a, events: events) }
                if Task.isCancelled { return .cancelled }
                let failed = results.filter { !$0.ok }
                if failed.isEmpty { break }
                let f = Failure(phase: .stopping, stepIndex: i, stepTitle: step.title, apps: failed.map { FailedApp(id: $0.app.id, name: $0.app.name, reason: $0.note) })
                events(.paused(f))
                let choice = await decide(f)
                events(.resumed)
                switch choice {
                case .retry: todo = failed.map(\.app)
                case .skip:
                    for r in failed { events(.app(r.app.id, .skipped)) }
                    skipped += failed.map(\.app.name)
                case .giveUp: return .gaveUp
                }
                if choice != .retry { break }
            }
        }
        return skipped.isEmpty ? .done : .doneWithSkips(skipped)
    }

    // MARK: one application

    public struct AppResult: Sendable {
        public var app: AppItem
        public var ok: Bool
        /// it was already up (starting) or down (stopping): nothing was run
        public var already = false
        public var note: String
    }

    public func startApp(_ app: AppItem, events: @escaping @Sendable (RunEvent) -> Void = { _ in }) async -> AppResult {
        let began = Date()
        let deadline = began.addingTimeInterval(Double(app.waitSeconds))
        func took() -> String { Self.duration(Date().timeIntervalSince(began)) }
        func fail(_ why: String) -> AppResult {
            logs.note(app, "Did not start: \(why)")
            events(.app(app.id, .failed(why)))
            return AppResult(app: app, ok: false, note: why)
        }

        // already up? (only when that can really be told: a check that can be run, or our own live process)
        let alreadyUp: Bool
        if app.mode == .keepRunning { alreadyUp = runtime.processAlive(app.id) ? (await Health.poll(app) ?? true) : false }
        else { alreadyUp = await Health.poll(app) == true }
        if alreadyUp {
            events(.app(app.id, .done("was already running")))
            return AppResult(app: app, ok: true, already: true, note: "was already running")
        }

        events(.app(app.id, .working("starting…")))
        logs.note(app, "── Starting \(app.name)\(app.resolvedFolder.map { " (in \($0))" } ?? "") ──\n\(app.start)")
        let cmd = Command(app.start, for: app)

        switch app.mode {
        case .keepRunning:
            let p: Spawned
            do { p = try Shell.spawn(cmd, output: logs.url(app.id)) } catch { return fail((error as? ASError)?.message ?? error.localizedDescription) }
            runtime.keep(app.id, p)
            if app.health.canPoll {
                while Date() < deadline {
                    if Task.isCancelled { return fail("cancelled") }
                    if let e = p.finished { runtime.forgetProcess(app.id); return fail("it stopped by itself (\(e.text))") }
                    events(.app(app.id, .working("waiting for the check · \(took())")))
                    if await Health.poll(app) == true { break }
                    try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1e9))
                }
                if Date() >= deadline, await Health.poll(app) != true { return fail("the health check did not pass within \(app.waitSeconds) s (it keeps running; stop it or retry)") }
            } else {
                // no check that can be run: it counts as up when it is still running after a moment
                if let e = await p.wait(upTo: settleSeconds) {
                    runtime.forgetProcess(app.id)
                    return fail("it finished at once (\(e.text)) — a kept-running app should keep running")
                }
            }

        case .startsItself:
            let r = await Shell.run(cmd, log: logs.url(app.id), timeout: max(1, deadline.timeIntervalSinceNow))
            if Task.isCancelled { return fail("cancelled") }
            if r.timedOut { return fail("the start command did not finish within \(app.waitSeconds) s, so it was stopped") }
            guard let ending = r.ending else { return fail(r.output) }
            logs.note(app, "The start command finished: \(ending.text)")
            if app.health.kind == .returnCode && !ending.succeeded { return fail("the start command finished with \(ending.text)") }
            if app.health.canPoll {
                while true {
                    if Task.isCancelled { return fail("cancelled") }
                    if await Health.poll(app) == true { break }
                    if Date() >= deadline { return fail("the health check did not pass within \(app.waitSeconds) s") }
                    events(.app(app.id, .working("waiting for the check · \(took())")))
                    try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1e9))
                }
            }
        }

        runtime.update(app.id) { $0.started = true }
        logs.note(app, "Up (\(took()))")
        events(.app(app.id, .done("up in \(took())")))
        return AppResult(app: app, ok: true, note: "up in \(took())")
    }

    public func stopApp(_ app: AppItem, events: @escaping @Sendable (RunEvent) -> Void = { _ in }) async -> AppResult {
        let began = Date()
        let deadline = began.addingTimeInterval(Double(app.waitSeconds))
        func took() -> String { Self.duration(Date().timeIntervalSince(began)) }
        func fail(_ why: String) -> AppResult {
            logs.note(app, "Did not stop: \(why)")
            events(.app(app.id, .failed(why)))
            return AppResult(app: app, ok: false, note: why)
        }
        let owned = app.mode == .keepRunning
        let hasStop = !app.stop.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // already down? (a check that says so, or — kept running — no process left)
        var alreadyDown = false
        if owned && !runtime.processAlive(app.id) { alreadyDown = !hasStop ? true : (await Health.poll(app) ?? false) == false }
        if alreadyDown {
            runtime.forgetProcess(app.id); runtime.update(app.id) { $0.started = false }
            events(.app(app.id, .done("was not running")))
            return AppResult(app: app, ok: true, already: true, note: "was not running")
        }
        let polledDown = owned ? false : (await Health.poll(app) == false)
        if polledDown {
            runtime.update(app.id) { $0.started = false }
            events(.app(app.id, .done("was not running")))
            return AppResult(app: app, ok: true, already: true, note: "was not running")
        }

        events(.app(app.id, .working("stopping…")))
        if hasStop {
            logs.note(app, "── Stopping \(app.name) ──\n\(app.stop)")
            let r = await Shell.run(Command(app.stop, for: app), log: logs.url(app.id), timeout: max(1, deadline.timeIntervalSinceNow))
            if Task.isCancelled { return fail("cancelled") }
            if r.timedOut { return fail("the stop command did not finish within \(app.waitSeconds) s, so it was stopped") }
            guard let ending = r.ending else { return fail(r.output) }
            logs.note(app, "The stop command finished: \(ending.text)")
            if app.health.kind == .returnCode && !ending.succeeded { return fail("the stop command finished with \(ending.text)") }
        } else if owned {
            logs.note(app, "── Stopping \(app.name): asking it to quit ──")
        } else {
            return fail("it has no stop command")
        }

        if owned {
            // the process must be gone: wait for it, then ask it to stop, then force it
            while runtime.processAlive(app.id) && Date() < deadline && hasStop {
                if Task.isCancelled { return fail("cancelled") }
                events(.app(app.id, .working("waiting for it to quit · \(took())")))
                try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1e9))
            }
            if runtime.processAlive(app.id), let pid = runtime[app.id].pid {
                if let p = runtime.liveProcess(app.id) { await Shell.stop(p, grace: stopGrace) }
                else {
                    Shell.signalGroup(pid, SIGTERM)
                    let until = Date().addingTimeInterval(stopGrace)
                    while Shell.groupAlive(pid) && Date() < until { try? await Task.sleep(nanoseconds: 200_000_000) }
                    if Shell.groupAlive(pid) { Shell.signalGroup(pid, SIGKILL) }
                }
            }
            if runtime.processAlive(app.id) { return fail("it is still running") }
            runtime.forgetProcess(app.id)
        }
        if app.health.canPoll {
            while true {
                if Task.isCancelled { return fail("cancelled") }
                if await Health.poll(app) == false { break }
                if Date() >= deadline { return fail("the health check still passes after \(app.waitSeconds) s, so it seems to be running") }
                events(.app(app.id, .working("waiting for it to go down · \(took())")))
                try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1e9))
            }
        }
        runtime.update(app.id) { $0.started = false }
        logs.note(app, "Down (\(took()))")
        events(.app(app.id, .done("down in \(took())")))
        return AppResult(app: app, ok: true, note: "down in \(took())")
    }

    // MARK: helpers

    /// Runs `work` for every app at once and returns the results in the apps' order.
    private func parallel(_ apps: [AppItem], _ work: @escaping @Sendable (AppItem) async -> AppResult) async -> [AppResult] {
        await withTaskGroup(of: (Int, AppResult).self) { g in
            for (i, a) in apps.enumerated() { g.addTask { (i, await work(a)) } }
            var out = [AppResult?](repeating: nil, count: apps.count)
            for await (i, r) in g { out[i] = r }
            return out.compactMap { $0 }
        }
    }

    public static func duration(_ s: Double) -> String {
        if s < 1 { return "under a second" }
        if s < 60 { return "\(Int(s.rounded())) s" }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }
}
