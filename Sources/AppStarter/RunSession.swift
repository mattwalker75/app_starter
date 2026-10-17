// One start or stop of a bundle (or of a single app), as the windows see it: which step it is on, where each
// app is, the question it is waiting on (Retry / Skip / Stop what started), and how it ended.
import SwiftUI
import AppStarterCore

@MainActor
final class RunSession: ObservableObject, Identifiable {
    let id = UUID()
    let bundle: AppBundle
    let phase: Phase
    /// "Junk Tracker" when only one app is being started or stopped
    let singleApp: String?
    /// the steps in the order this run goes through them
    let steps: [Step]
    let startedAt = Date()
    @Published var stepIndex = 0
    @Published var progress: [UUID: AppProgress] = [:]
    /// why each app last failed in this run (kept after a skip replaces its progress)
    @Published var failures: [UUID: String] = [:]
    @Published var failure: Failure?
    @Published var outcome: Outcome?
    @Published var finishedAt: Date?
    private var answer: CheckedContinuation<Choice, Never>?
    var task: Task<Void, Never>?

    /// `respectPause` false: a run of one app on its own, which goes ahead even when the app is paused.
    init(bundle: AppBundle, phase: Phase, singleApp: String? = nil, respectPause: Bool = true) {
        self.bundle = bundle; self.phase = phase; self.singleApp = singleApp
        // the same steps the engine goes through (paused apps left out, all-paused steps passed over)
        steps = bundle.runSteps(phase == .stopping, respectPause: respectPause)
        for a in bundle.apps { progress[a.id] = respectPause && a.paused ? .paused : .waiting }
    }

    var isRunning: Bool { outcome == nil }
    var title: String {
        let what = singleApp.map { "“\($0)”" } ?? "“\(bundle.name)”"
        if let o = outcome {
            switch o {
            case .done: return phase == .starting ? "\(what) is up" : "\(what) is down"
            case .doneWithSkips: return phase == .starting ? "\(what) started, with some skipped" : "\(what) stopped, with some skipped"
            case .gaveUp: return phase == .starting ? "Starting \(what) was given up" : "Stopping \(what) was ended"
            case .cancelled: return phase == .starting ? "Starting \(what) was cancelled" : "Stopping \(what) was cancelled"
            }
        }
        return phase == .starting ? "Starting \(what)" : "Stopping \(what)"
    }

    /// what the engine reports
    func handle(_ e: RunEvent) {
        switch e {
        case .step(let i, _, _): stepIndex = i
        case .app(let id, let p):
            progress[id] = p
            if case .failed(let why) = p { failures[id] = why }
        case .paused, .resumed: break   // the question itself arrives through ask()
        }
    }

    /// The engine waits here for the user's answer.
    func ask(_ f: Failure) async -> Choice {
        await withCheckedContinuation { c in
            answer = c
            failure = f
        }
    }

    func choose(_ c: Choice) {
        failure = nil
        answer?.resume(returning: c); answer = nil
    }

    func finish(_ o: Outcome) { outcome = o; finishedAt = Date(); failure = nil }

    func cancel() {
        // a question being asked must not be left hanging
        if answer != nil { choose(.giveUp) }
        task?.cancel()
    }

    /// 0…1, for the bar at the top
    var fraction: Double {
        guard !steps.isEmpty else { return 1 }
        if outcome != nil { return 1 }
        let apps = steps[min(stepIndex, steps.count - 1)].apps
        let done = apps.filter { if case .done = progress[$0.id] { return true }; if case .skipped = progress[$0.id] { return true }; return false }.count
        return (Double(stepIndex) + Double(done) / Double(max(apps.count, 1))) / Double(steps.count)
    }
}
