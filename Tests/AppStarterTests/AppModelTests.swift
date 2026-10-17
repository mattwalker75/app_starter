import XCTest
@testable import AppStarter
@testable import AppStarterCore

/// The app's own logic, each test on its own scratch APPSTARTER_HOME (never the real Application Support).
@MainActor
final class AppModelTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("appstarter-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("APPSTARTER_HOME", home.path, 1)
    }

    override func tearDown() async throws {
        unsetenv("APPSTARTER_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    private func marker(_ name: String) -> String { home.appendingPathComponent(name).path }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: marker(name)) }
    private func app(_ name: String, start: String = "true", stop: String = "true") -> AppItem {
        AppItem(name: name, workingFolder: home.path, start: start, stop: stop, waitSeconds: 10)
    }
    private func waitFor(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async {
        let until = Date().addingTimeInterval(timeout)
        while !cond() && Date() < until { try? await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testAppsGoWhereTheEditorSays() throws {
        let m = AppModel()
        m.addBundle("  Mac mini  ")
        let b = try XCTUnwrap(m.selected)
        XCTAssertEqual(b.name, "Mac mini")

        let a = app("A"), b1 = app("B1"), b2 = app("B2")
        m.saveApp(a, in: b.id, placement: .newStep)
        m.saveApp(b1, in: b.id, placement: .newGroup("Together"))
        let group = try XCTUnwrap(m.bundle(b.id)?.steps.last)
        m.saveApp(b2, in: b.id, placement: .group(group.id))
        XCTAssertEqual(m.bundle(b.id)?.steps.map(\.apps.count), [1, 2])

        // moving the one-app step into the sub-bundle removes the empty step
        m.saveApp(a, in: b.id, placement: .group(group.id))
        XCTAssertEqual(m.bundle(b.id)?.steps.count, 1)
        XCTAssertEqual(m.bundle(b.id)?.steps.first?.apps.map(\.name), ["B1", "B2", "A"])

        // editing in place keeps the position
        var renamed = a; renamed.name = "A renamed"
        m.saveApp(renamed, in: b.id, placement: .stay)
        XCTAssertEqual(m.bundle(b.id)?.steps.first?.apps.last?.name, "A renamed")

        // deleting the last app of a sub-bundle keeps the (now empty) sub-bundle
        for x in [b1, b2, a] { m.deleteApp(x.id, in: b.id) }
        XCTAssertEqual(m.bundle(b.id)?.steps.count, 1)
        XCTAssertEqual(m.bundle(b.id)?.steps.first?.isGroup, true)

        // everything was saved
        let again = AppModel()
        XCTAssertEqual(again.bundles.first?.steps.first?.name, "Together")
    }

    func testDeletingAStepTakesItOutOfACustomStopOrder() throws {
        let m = AppModel()
        m.addBundle("B")
        let id = try XCTUnwrap(m.selectedId)
        m.saveApp(app("1"), in: id, placement: .newStep)
        m.saveApp(app("2"), in: id, placement: .newStep)
        var b = try XCTUnwrap(m.bundle(id))
        b.stopOrder = b.steps.map(\.id)
        m.updateBundle(b)
        m.deleteStep(b.steps[0].id, in: id)
        XCTAssertEqual(m.bundle(id)?.stopOrder, [b.steps[1].id])
        m.moveStep(b.steps[1].id, by: -1, in: id)   // already first: nothing happens
        XCTAssertEqual(m.bundle(id)?.steps.count, 1)
    }

    func testStartAndStopABundleAndTheLightsFollow() async throws {
        let m = AppModel()
        m.addBundle("B")
        let id = try XCTUnwrap(m.selectedId)
        var a = app("A", start: "touch a.up", stop: "rm -f a.up")
        a.health = .output(command: "test -f a.up && echo UP", contains: "UP", ignoreCase: false)
        m.saveApp(a, in: id, placement: .newStep)
        let b = try XCTUnwrap(m.bundle(id))

        m.run(b, .starting)
        XCTAssertNotNil(m.shownSession)
        await waitFor("the start") { !(m.sessions[id]?.isRunning ?? true) }
        XCTAssertEqual(m.sessions[id]?.outcome, .done)
        await waitFor("the light") { m.status(b) == .allUp }

        m.run(b, .stopping, show: false)
        await waitFor("the stop") { !(m.sessions[id]?.isRunning ?? true) && m.sessions[id]?.phase == .stopping }
        await waitFor("the light") { m.status(b) == .allDown }
        XCTAssertFalse(exists("a.up"))

        if let s = m.sessions[id] { m.dismiss(s) }
        XCTAssertNil(m.sessions[id])
    }

    func testAFailedStepWaitsForTheAnswerAndCancelEndsIt() async throws {
        let m = AppModel()
        m.addBundle("B")
        let id = try XCTUnwrap(m.selectedId)
        var bad = app("Bad", start: "exit 2"); bad.health = .returnCode
        m.saveApp(bad, in: id, placement: .newStep)
        m.run(try XCTUnwrap(m.bundle(id)), .starting)
        await waitFor("the question") { m.sessions[id]?.failure != nil }
        XCTAssertTrue(m.isRunning(id))
        m.sessions[id]?.cancel()
        await waitFor("the end") { !(m.sessions[id]?.isRunning ?? true) }
        XCTAssertNotEqual(m.sessions[id]?.outcome, .done)
    }

    func testStartAtLoginRunsOncePerLoginSession() async throws {
        do {
            let m = AppModel()
            // this login session's check counts as done (as it would be once the app has been open a moment)
            m.engine.runtime.lastAutostartSession = LoginSession.current
            m.addBundle("Login")
            let id = try XCTUnwrap(m.selectedId)
            m.saveApp(app("A", start: "echo run >> login.txt"), in: id, placement: .newStep)
            var b = try XCTUnwrap(m.bundle(id)); b.startAtLogin = true; m.updateBundle(b)
        }
        // a new launch in the same login session: the check already happened → nothing runs
        let second = AppModel()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(exists("login.txt"))
        // a new login session: it runs, once
        second.engine.runtime.lastAutostartSession = "an older login"
        await second.autostartIfNewLogin()
        await second.autostartIfNewLogin()
        await waitFor("the autostart") { (try? String(contentsOfFile: self.marker("login.txt"), encoding: .utf8)) == "run\n" }
    }

    func testStopAtLogoutStopsThoseBundlesAndSaysWhenDone() async throws {
        let m = AppModel()
        m.addBundle("Night")
        let id = try XCTUnwrap(m.selectedId)
        m.saveApp(app("A", stop: "touch stopped.txt"), in: id, placement: .newStep)
        XCTAssertFalse(m.stopsAtLogout)
        var b = try XCTUnwrap(m.bundle(id)); b.stopAtLogout = true; m.updateBundle(b)
        XCTAssertTrue(m.stopsAtLogout)
        // it counts as up only if App Starter started it (no check): start it first
        m.run(b, .starting, show: false)
        await waitFor("the start") { !(m.sessions[id]?.isRunning ?? true) }
        var finished = false
        m.stopForLogout(limit: 20) { finished = true }
        await waitFor("logout stop") { finished }
        XCTAssertTrue(exists("stopped.txt"))
    }

    func testImportReplacesOrCopies() throws {
        let m = AppModel()
        m.addBundle("Mine")
        let id = try XCTUnwrap(m.selectedId)
        m.saveApp(app("A"), in: id, placement: .newStep)
        let f = try Transfer.read(m.exportData(includeSecrets: false))
        m.importFile(f, replace: false)
        XCTAssertEqual(m.bundles.map(\.name), ["Mine", "Mine (imported)"])
        m.importFile(f, replace: true)
        XCTAssertEqual(m.bundles.count, 2)
    }

    func testOldOrPartialSettingsStillLoad() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appearance":"dark"}"#.utf8))
        XCTAssertEqual(s.appearance, .dark)
        XCTAssertEqual(s.checkEvery, 30)
        XCTAssertTrue(s.showInMenuBar)
    }
}

@MainActor
final class AppModelReviewTests: XCTestCase {
    private var home: URL!
    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("appstarter-model2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("APPSTARTER_HOME", home.path, 1)
    }
    override func tearDown() async throws { unsetenv("APPSTARTER_HOME"); try? FileManager.default.removeItem(at: home) }

    func testStartAtLoginSkipsAFailureAndStartsTheNextBundle() async throws {
        let m = AppModel()
        m.engine.runtime.lastAutostartSession = LoginSession.current
        m.addBundle("First")
        var bad = AppItem(name: "Bad", workingFolder: home.path, start: "exit 1", stop: "true", health: .returnCode)
        bad.waitSeconds = 5
        m.saveApp(bad, in: m.selectedId!, placement: .newStep)
        var b1 = m.bundle(m.selectedId!)!; b1.startAtLogin = true; m.updateBundle(b1)
        m.addBundle("Second")
        m.saveApp(AppItem(name: "Good", workingFolder: home.path, start: "touch good", stop: "true"), in: m.selectedId!, placement: .newStep)
        var b2 = m.bundle(m.selectedId!)!; b2.startAtLogin = true; m.updateBundle(b2)
        m.engine.runtime.lastAutostartSession = "an older login"
        await m.autostartIfNewLogin()
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("good").path), "the failure was skipped, the next bundle started")
    }

    func testTheLoginSessionHasARealId() {
        XCTAssertFalse(LoginSession.current.hasSuffix("-?"), "a session id was found")
    }

    func testAfterALoadProblemNothingIsTidiedAway() throws {
        try Data("{ broken".utf8).write(to: home.appendingPathComponent("bundles.json"))
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let someLog = logs.appendingPathComponent("\(UUID().uuidString).log")
        try Data("old app's log".utf8).write(to: someLog)
        let m = AppModel()
        XCTAssertNotNil(m.notice)
        m.addBundle("New")   // saves
        XCTAssertTrue(FileManager.default.fileExists(atPath: someLog.path), "the logs of apps that only seem gone are kept")
    }
}

@MainActor
final class AppModelDragTests: XCTestCase {
    private var home: URL!
    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("appstarter-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("APPSTARTER_HOME", home.path, 1)
    }
    override func tearDown() async throws { unsetenv("APPSTARTER_HOME"); try? FileManager.default.removeItem(at: home) }

    func testADropRearrangesAndSavesButNotWhileTheBundleIsBusy() async throws {
        let m = AppModel()
        m.addBundle("B")
        let id = try XCTUnwrap(m.selectedId)
        let a = AppItem(name: "A", workingFolder: home.path, start: "true", stop: "true")
        let slow = AppItem(name: "Slow", workingFolder: home.path, start: "sleep 3", stop: "true")
        m.saveApp(a, in: id, placement: .newStep)
        m.saveApp(slow, in: id, placement: .newGroup("G"))
        let gid = try XCTUnwrap(m.bundle(id)?.steps.last?.id)

        XCTAssertTrue(m.drop(DragItem.app(a.id).token, at: .intoGroup(gid, before: slow.id), in: id))
        XCTAssertEqual(m.bundle(id)?.steps.map(\.apps.count), [2])
        XCTAssertEqual(AppModel().bundles.first?.steps.first?.apps.map(\.name), ["A", "Slow"], "saved")
        XCTAssertFalse(m.drop("not a drag", at: .gap(0), in: id))

        m.run(try XCTUnwrap(m.bundle(id)), .starting, show: false)
        XCTAssertFalse(m.drop(DragItem.app(a.id).token, at: .gap(0), in: id), "no rearranging while it starts")
        XCTAssertNotNil(m.notice)
        m.sessions[id]?.cancel()
    }
}
