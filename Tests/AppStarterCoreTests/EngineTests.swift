import XCTest
@testable import AppStarterCore

final class EngineTests: XCTestCase {
    func testCommandsRunInTheLoginShellInTheFolderWithTheirVariablesAndSeveralLines() async throws {
        let s = Scratch()
        var a = app("A", in: s, start: "echo \"one $GREETING\" > out.txt\necho two >> out.txt\npwd >> out.txt")
        a.env = [EnvVar(name: "GREETING", value: "hello")]
        let r = await s.engine().startApp(a)
        XCTAssertTrue(r.ok, r.note)
        let out = s.read("out.txt")
        XCTAssertTrue(out.contains("one hello\ntwo\n"))
        XCTAssertTrue(out.contains(s.url.resolvingSymlinksInPath().path) || out.contains(s.path))
    }

    func testAReturnCodeCheckNeedsExitZero() async {
        let s = Scratch()
        let bad = await s.engine().startApp(app("A", in: s, start: "exit 3", health: .returnCode))
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.note.contains("exit code 3"))
        let noCheck = await s.engine().startApp(app("B", in: s, start: "exit 3"))
        XCTAssertTrue(noCheck.ok, "with no check, the command finishing is enough")
    }

    func testAStartThatHangsIsStoppedAtTheTimeLimit() async {
        let s = Scratch()
        let began = Date()
        let r = await s.engine().startApp(app("A", in: s, start: "sleep 30", wait: 1))
        XCTAssertFalse(r.ok)
        XCTAssertLessThan(Date().timeIntervalSince(began), 8)
    }

    func testStepsGoInOrderAndASubBundleStartsTogether() async {
        let s = Scratch()
        let order = s.file("order.txt")
        let first = app("First", in: s, start: "sleep 0.3; echo first >> \(order)")
        let g1 = app("G1", in: s, start: "sleep 1; echo g >> \(order)")
        let g2 = app("G2", in: s, start: "sleep 1; echo g >> \(order)")
        let last = app("Last", in: s, start: "echo last >> \(order)")
        let b = AppBundle(name: "B", steps: [Step(app: first), Step(group: "Together", apps: [g1, g2]), Step(app: last)])
        let began = Date()
        let out = await s.engine().start(b, events: { _ in }, decide: { _ in .skip })
        let took = Date().timeIntervalSince(began)
        XCTAssertEqual(out, .done)
        XCTAssertEqual(s.read("order.txt"), "first\ng\ng\nlast\n")
        XCTAssertLessThan(took, 3.5, "the two apps of the sub-bundle ran at the same time (one second, not two)")
    }

    func testTheNextStepWaitsForTheHealthCheck() async {
        let s = Scratch()
        // the start command returns at once; the app is "ready" a second later
        let slow = app("Slow", in: s, start: "(sleep 1.2; touch ready) >/dev/null 2>&1 &",
                       health: .output(command: "test -f ready && echo READY", contains: "ready", ignoreCase: true))
        let next = app("Next", in: s, start: "test -f ready && echo ok > next.txt || echo early > next.txt")
        let out = await s.engine().start(AppBundle(name: "B", steps: [Step(app: slow), Step(app: next)]), events: { _ in }, decide: { _ in .skip })
        XCTAssertEqual(out, .done)
        XCTAssertEqual(s.read("next.txt"), "ok\n")
    }

    func testAFailurePausesAndRetryRunsItAgain() async {
        let s = Scratch()
        // fails the first time, works the second
        let flaky = app("Flaky", in: s, start: "if [ -f tried ]; then exit 0; else touch tried; exit 1; fi", health: .returnCode)
        let ev = Events()
        let answers = Answers([.retry])
        let out = await s.engine().start(AppBundle(name: "B", steps: [Step(app: flaky)]), events: { ev.add($0) }, decide: { await answers.next($0) })
        XCTAssertEqual(out, .done)
        XCTAssertEqual(ev.failures.count, 1)
        XCTAssertEqual(ev.failures.first?.apps.first?.name, "Flaky")
    }

    func testSkipGoesOnAndSaysWhatWasSkipped() async {
        let s = Scratch()
        let bad = app("Bad", in: s, start: "exit 1", health: .returnCode)
        let after = app("After", in: s, start: "touch after")
        let out = await s.engine().start(AppBundle(name: "B", steps: [Step(app: bad), Step(app: after)]), events: { _ in }, decide: { _ in .skip })
        XCTAssertEqual(out, .doneWithSkips(["Bad"]))
        XCTAssertTrue(s.exists("after"))
    }

    func testStopWhatStartedStopsOnlyWhatThisRunStarted() async {
        let s = Scratch()
        let a = app("A", in: s, start: "touch a-up", stop: "touch a-stopped")
        let bad = app("Bad", in: s, start: "exit 1", stop: "touch bad-stopped", health: .returnCode)
        let never = app("Never", in: s, start: "touch never-up", stop: "touch never-stopped")
        let out = await s.engine().start(AppBundle(name: "B", steps: [Step(app: a), Step(app: bad), Step(app: never)]), events: { _ in }, decide: { _ in .giveUp })
        XCTAssertEqual(out, .gaveUp)
        XCTAssertTrue(s.exists("a-stopped"))
        XCTAssertFalse(s.exists("bad-stopped"), "the app that failed to start is not 'stopped'")
        XCTAssertFalse(s.exists("never-up"))
        XCTAssertFalse(s.exists("never-stopped"))
    }

    func testStoppingGoesInTheReverseOrder() async {
        let s = Scratch()
        let order = s.file("stop.txt")
        let a = app("A", in: s, start: "true", stop: "echo a >> \(order)")
        let b = app("B", in: s, start: "true", stop: "echo b >> \(order)")
        let c = app("C", in: s, start: "true", stop: "echo c >> \(order)")
        var bundle = AppBundle(name: "X", steps: [Step(app: a), Step(app: b), Step(app: c)])
        let e = s.engine()
        _ = await e.start(bundle, events: { _ in }, decide: { _ in .skip })
        _ = await e.stop(bundle, events: { _ in }, decide: { _ in .skip })
        XCTAssertEqual(s.read("stop.txt"), "c\nb\na\n")
        bundle.stopOrder = [bundle.steps[1].id, bundle.steps[0].id, bundle.steps[2].id]
        try? FileManager.default.removeItem(atPath: order)
        _ = await e.stop(bundle, events: { _ in }, decide: { _ in .skip })
        XCTAssertEqual(s.read("stop.txt"), "b\na\nc\n")
    }

    func testAKeptRunningAppIsStoppedByAppStarterWhenItHasNoStopCommand() async throws {
        let s = Scratch()
        let e = s.engine()
        let server = app("Server", in: s, start: "echo $$ > pid.txt; exec sleep 60", stop: "", mode: .keepRunning)
        let up = await e.startApp(server)
        XCTAssertTrue(up.ok, up.note)
        let isUp = await e.isUp(server)
        XCTAssertTrue(isUp)
        let pid = Int32(s.read("pid.txt").trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(kill(pid, 0), 0)

        // App Starter closed and opened again: a new engine on the same state still finds it, and stops it
        let again = s.engine()
        let stillUp = await again.isUp(server)
        XCTAssertTrue(stillUp)
        let down = await again.stopApp(server)
        XCTAssertTrue(down.ok, down.note)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "the process is gone")
        let isDown = await again.isUp(server)
        XCTAssertFalse(isDown)
    }

    func testAKeptRunningAppThatEndsAtOnceIsAFailure() async {
        let s = Scratch()
        let r = await s.engine().startApp(app("Quick", in: s, start: "echo bye", stop: "", mode: .keepRunning))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.note.contains("finished at once"))
    }

    func testAURLCheckIsUpWhenAnythingAnswers() async throws {
        let server = try TinyServer(status: 503)   // even an error page is an answer
        defer { server.stop() }
        let up = await Health.urlAnswers(server.address)
        XCTAssertTrue(up)
        let down = await Health.urlAnswers("http://127.0.0.1:\(freePort())/")
        XCTAssertFalse(down)
    }

    func testStoppingWaitsUntilTheCheckSaysDown() async {
        let s = Scratch()
        let a = app("A", in: s, start: "touch running", stop: "(sleep 1; rm -f running) >/dev/null 2>&1 &",
                    health: .output(command: "test -f running && echo UP", contains: "UP", ignoreCase: false))
        let e = s.engine()
        _ = await e.startApp(a)
        let r = await e.stopApp(a)
        XCTAssertTrue(r.ok, r.note)
        XCTAssertFalse(s.exists("running"), "the stop finished only once the check said down")
    }

    func testAnAppAlreadyUpIsNotStartedAgain() async {
        let s = Scratch()
        let a = app("A", in: s, start: "echo again >> starts.txt", health: .output(command: "echo UP", contains: "UP", ignoreCase: false))
        let r = await s.engine().startApp(a)
        XCTAssertTrue(r.already)
        XCTAssertFalse(s.exists("starts.txt"))
    }

    func testAMissingWorkingFolderIsAPlainProblem() async {
        let s = Scratch()
        var a = app("A", in: s, start: "true")
        a.workingFolder = s.path + "/nope"
        let r = await s.engine().startApp(a)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.note.contains("doesn't exist"))
    }
}
