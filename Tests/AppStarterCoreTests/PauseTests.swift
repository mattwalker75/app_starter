import XCTest
@testable import AppStarterCore

/// Pause (Matt, Oct 17 2026): a paused app is left out when its bundle starts or stops, and left exactly as it is;
/// started or stopped on its own, it still runs.
final class PauseTests: XCTestCase {
    func testABundleStartAndStopLeaveAPausedAppAlone() async {
        let s = Scratch()
        let a = app("A", in: s, start: "touch a.up", stop: "rm -f a.up")
        var p = app("P", in: s, start: "touch p.started", stop: "touch p.stopped")
        p.paused = true
        let solo = app("Solo", in: s, start: "touch solo.started", stop: "touch solo.stopped")
        var soloPaused = solo; soloPaused.paused = true
        let b = AppBundle(name: "B", steps: [Step(group: "G", apps: [a, p]), Step(app: soloPaused)])
        let ev = Events()
        let e = s.engine()
        let up = await e.start(b, events: { ev.add($0) }, decide: { _ in .skip })
        XCTAssertEqual(up, .done)
        XCTAssertTrue(s.exists("a.up"))
        XCTAssertFalse(s.exists("p.started"))
        XCTAssertFalse(s.exists("solo.started"), "a step whose only app is paused is passed over")
        XCTAssertTrue(ev.all.contains { if case .app(let id, .paused) = $0 { return id == p.id }; return false })
        let down = await e.stop(b, events: { _ in }, decide: { _ in .skip })
        XCTAssertEqual(down, .done)
        XCTAssertFalse(s.exists("a.up"))
        XCTAssertFalse(s.exists("p.stopped"))
    }

    func testOnItsOwnAPausedAppStillStartsAndStops() async {
        let s = Scratch()
        var p = app("P", in: s, start: "touch p.started", stop: "touch p.stopped")
        p.paused = true
        let one = AppBundle(name: "B", steps: [Step(app: p)])
        let e = s.engine()
        _ = await e.start(one, respectPause: false, events: { _ in }, decide: { _ in .skip })
        _ = await e.stop(one, respectPause: false, events: { _ in }, decide: { _ in .skip })
        XCTAssertTrue(s.exists("p.started"))
        XCTAssertTrue(s.exists("p.stopped"))
    }

    func testRunStepsLeaveOutPausedAppsAndAllPausedSteps() {
        var p1 = AppItem(name: "p1"); p1.paused = true
        var p2 = AppItem(name: "p2"); p2.paused = true
        let a = AppItem(name: "a")
        let b = AppBundle(name: "B", steps: [Step(group: "G", apps: [a, p1]), Step(app: p2), Step(group: "Empty")])
        XCTAssertEqual(b.runSteps(false).map { $0.apps.map(\.name) }, [["a"]])
        XCTAssertEqual(b.runSteps(true, respectPause: false).map { $0.apps.map(\.name) }, [["p2"], ["a", "p1"]])
        XCTAssertEqual(b.activeApps.map(\.name), ["a"])
    }

    func testPausedIsSavedAndOlderFilesLoadUnpaused() throws {
        let s = Scratch()
        var p = AppItem(name: "P", start: "x", stop: "y"); p.paused = true
        try BundleStore(folder: s.url).save([AppBundle(name: "B", steps: [Step(app: p)])])
        XCTAssertEqual(try BundleStore(folder: s.url).load().first?.apps.first?.paused, true)
        let old = try JSONDecoder().decode(AppItem.self, from: Data(#"{"name":"Old","start":"x","stop":"y"}"#.utf8))
        XCTAssertFalse(old.paused)
    }
}
