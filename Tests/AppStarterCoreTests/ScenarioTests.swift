import XCTest
@testable import AppStarterCore

/// Real-world shapes: scripts like Matt's TRACKER.sh / DESK.sh (start a server in the background, write a pid
/// file, exit), a server App Starter keeps running, cancelling, awkward paths and values. Real processes and
/// real web servers (python3's http.server), all inside a throwaway folder.
final class ScenarioTests: XCTestCase {
    /// A start/stop script in the style of TRACKER.sh: `start` puts a web server in the background and returns.
    private func trackerLike(_ s: Scratch, port: UInt16) -> AppItem {
        let script = """
        #!/bin/bash
        # a tiny TRACKER.sh: start | stop | status
        HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
        case "$1" in
          start)
            if [[ -f server.pid ]] && kill -0 "$(cat server.pid)" 2>/dev/null; then echo "Already running"; exit 0; fi
            nohup /usr/bin/python3 -m http.server \(port) --bind 127.0.0.1 >> server.log 2>&1 &
            echo $! > server.pid
            echo "started"
            ;;
          stop)
            [[ -f server.pid ]] && kill "$(cat server.pid)" 2>/dev/null; rm -f server.pid; echo "stopped" ;;
          status)
            if [[ -f server.pid ]] && kill -0 "$(cat server.pid)" 2>/dev/null; then echo "Running"; else echo "Not running"; fi ;;
        esac
        """
        let path = s.file("TRACKER.sh")
        try! script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return AppItem(name: "Tracker", workingFolder: s.path, start: "./TRACKER.sh start", stop: "./TRACKER.sh stop",
                       health: .url("http://127.0.0.1:\(port)/"), waitSeconds: 15)
    }

    func testAScriptThatBackgroundsAServerStartsAndStopsByURL() async throws {
        let s = Scratch()
        let port = freePort()
        let a = trackerLike(s, port: port)
        let e = s.engine()
        let up = await e.startApp(a)
        XCTAssertTrue(up.ok, up.note)
        let answering = await Health.urlAnswers("http://127.0.0.1:\(port)/")
        XCTAssertTrue(answering)
        // the start command's own process group must not have been killed when it returned
        try await Task.sleep(nanoseconds: 500_000_000)
        let still = await Health.urlAnswers("http://127.0.0.1:\(port)/")
        XCTAssertTrue(still, "the background server outlives the start script")
        // the server's output goes to its own log, the script's to the app's log
        XCTAssertTrue(e.logs.tail(a.id).contains("started"))

        let down = await e.stopApp(a)
        XCTAssertTrue(down.ok, down.note)
        let gone = await Health.urlAnswers("http://127.0.0.1:\(port)/")
        XCTAssertFalse(gone)
    }

    func testAnOutputCheckWithTheScriptsStatusWorksBothWays() async {
        let s = Scratch()
        let port = freePort()
        var a = trackerLike(s, port: port)
        // "Not running" contains "running" too, so the user's text must be the exact word ("Running", capitals counted)
        a.health = .output(command: "./TRACKER.sh status", contains: "Running", ignoreCase: false)
        let e = s.engine()
        let r = await e.startApp(a)
        XCTAssertTrue(r.ok, r.note)
        let up = await e.isUp(a)
        XCTAssertTrue(up)
        _ = await e.stopApp(a)
        let down = await e.isUp(a)
        XCTAssertFalse(down)
    }

    func testAKeptRunningWebServerIsUpByURLAndStoppedByAppStarter() async throws {
        let s = Scratch()
        let port = freePort()
        let a = AppItem(name: "Server", workingFolder: s.path, mode: .keepRunning,
                        start: "/usr/bin/python3 -m http.server \(port) --bind 127.0.0.1", stop: "",
                        health: .url("http://127.0.0.1:\(port)/"), waitSeconds: 15)
        let e = s.engine()
        let up = await e.startApp(a)
        XCTAssertTrue(up.ok, up.note)
        let pid = try XCTUnwrap(e.runtime[a.id].pid)
        // its output lands in the app's log (the request log of http.server goes to stderr)
        _ = await Health.urlAnswers("http://127.0.0.1:\(port)/")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(e.logs.tail(a.id).contains("GET /"))

        let down = await e.stopApp(a)
        XCTAssertTrue(down.ok, down.note)
        XCTAssertFalse(Shell.groupAlive(pid))
        let answering = await Health.urlAnswers("http://127.0.0.1:\(port)/")
        XCTAssertFalse(answering)
    }

    func testAKeptRunningAppWithAStopCommandIsWaitedForThenForced() async throws {
        let s = Scratch()
        // the stop command does nothing useful: App Starter must still bring it down (SIGTERM to the group)
        let a = AppItem(name: "Stubborn", workingFolder: s.path, mode: .keepRunning, start: "exec sleep 60", stop: "echo asked", waitSeconds: 2)
        let e = s.engine()
        _ = await e.startApp(a)
        let pid = try XCTUnwrap(e.runtime[a.id].pid)
        let began = Date()
        let r = await e.stopApp(a)
        XCTAssertTrue(r.ok, r.note)
        XCTAssertFalse(Shell.groupAlive(pid))
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }

    func testATimedOutStartStopsEverythingItStarted() async throws {
        let s = Scratch()
        // a script that starts a child and then hangs: both must be gone after the time limit
        let a = AppItem(name: "Hang", workingFolder: s.path, start: "sleep 120 &\necho $! > child.pid\nsleep 120", stop: "true", waitSeconds: 1)
        let r = await s.engine().startApp(a)
        XCTAssertFalse(r.ok)
        try await Task.sleep(nanoseconds: 500_000_000)
        let child = Int32(s.read("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0)
        XCTAssertNotEqual(kill(child, 0), 0, "the background child of a timed-out start is stopped too")
    }

    func testCancellingARunStopsWaitingButLeavesTheCommandRunning() async throws {
        let s = Scratch()
        let slow = AppItem(name: "Slow", workingFolder: s.path, start: "echo $$ > slow.pid; sleep 60", stop: "true", waitSeconds: 120)
        let after = AppItem(name: "After", workingFolder: s.path, start: "touch after", stop: "true")
        let e = s.engine()
        let task = Task { await e.start(AppBundle(name: "B", steps: [Step(app: slow), Step(app: after)]), events: { _ in }, decide: { _ in .skip }) }
        try await Task.sleep(nanoseconds: 800_000_000)
        task.cancel()
        let out = await task.value
        XCTAssertEqual(out, .cancelled)
        XCTAssertFalse(s.exists("after"))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let pid = Int32(s.read("slow.pid").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(pid, 0)
        XCTAssertEqual(kill(pid, 0), 0, "Cancel only stops waiting: the start command goes on (Matt's wording: whatever started stays)")
        Shell.signalGroup(pid, SIGKILL)
    }

    func testFoldersWithSpacesAndAwkwardValuesArePassedAsTheyAre() async throws {
        let s = Scratch()
        let dir = s.url.appendingPathComponent("My Apps (test)/junk tracker", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var a = AppItem(name: "A", workingFolder: dir.path, start: "printf '%s|' \"$QUOTED\" \"$MULTI\" \"$EMPTY\" > values.txt; pwd > where.txt", stop: "true")
        a.env = [EnvVar(name: "QUOTED", value: "it's \"quoted\" & $NOT_EXPANDED"), EnvVar(name: "MULTI", value: "line1\nline2"), EnvVar(name: "EMPTY", value: "")]
        let r = await s.engine().startApp(a)
        XCTAssertTrue(r.ok, r.note)
        let values = (try? String(contentsOf: dir.appendingPathComponent("values.txt"), encoding: .utf8)) ?? ""
        XCTAssertEqual(values, "it's \"quoted\" & $NOT_EXPANDED|line1\nline2||")
        let whereText = (try? String(contentsOf: dir.appendingPathComponent("where.txt"), encoding: .utf8)) ?? ""
        XCTAssertTrue(whereText.contains("My Apps (test)/junk tracker"))
    }

    func testATildeFolderIsYourHome() {
        let a = AppItem(name: "A", workingFolder: "~/Desktop/REPOs")
        XCTAssertEqual(a.resolvedFolder, NSHomeDirectory() + "/Desktop/REPOs")
        XCTAssertNil(AppItem(name: "A", workingFolder: "  ").resolvedFolder)
    }

    func testSecretValuesNeverReachTheLogEvenFromTheCommandLine() async {
        let s = Scratch()
        var a = AppItem(name: "A", workingFolder: s.path, start: "echo starting with sk-abc123secret", stop: "true")
        a.env = [EnvVar(name: "KEY", value: "sk-abc123secret", secret: true)]
        let e = s.engine()
        _ = await e.startApp(a)
        let log = e.logs.tail(a.id)
        // App Starter's own lines (the command it ran) hide it; what the command printed itself is the app's business
        XCTAssertFalse(log.contains("] echo starting with sk-abc123secret"))
        XCTAssertTrue(log.contains("echo starting with •••"))
    }

    func testStoppingWithGiveUpEndsHereAndLeavesTheRest() async {
        let s = Scratch()
        let order = s.file("stop.txt")
        let first = AppItem(name: "First", workingFolder: s.path, start: "true", stop: "echo first >> \(order)")
        let bad = AppItem(name: "Bad", workingFolder: s.path, start: "true", stop: "exit 4", health: .returnCode)
        let e = s.engine()
        let b = AppBundle(name: "B", steps: [Step(app: first), Step(app: bad)])
        _ = await e.start(b, events: { _ in }, decide: { _ in .skip })
        let ev = Events()
        let out = await e.stop(b, events: { ev.add($0) }, decide: { _ in .giveUp })
        XCTAssertEqual(out, .gaveUp)
        XCTAssertEqual(ev.failures.first?.phase, .stopping)
        XCTAssertFalse(s.exists("stop.txt"), "the step after the failed one was not stopped")
    }

    func testAnEmptySubBundleIsPassedOver() async {
        let s = Scratch()
        let a = AppItem(name: "A", workingFolder: s.path, start: "touch a", stop: "true")
        let out = await s.engine().start(AppBundle(name: "B", steps: [Step(group: "Nothing yet"), Step(app: a)]), events: { _ in }, decide: { _ in .skip })
        XCTAssertEqual(out, .done)
        XCTAssertTrue(s.exists("a"))
    }

    func testTheLoginShellLoadsAProfileButAppStarterVariablesAreNotPassedOn() async {
        let s = Scratch()
        setenv("APPSTARTER_HOME", "/should/not/leak", 1)
        defer { unsetenv("APPSTARTER_HOME") }
        let a = AppItem(name: "A", workingFolder: s.path, start: "echo \"home=[$APPSTARTER_HOME] path=$PATH\" > env.txt", stop: "true")
        _ = await s.engine().startApp(a)
        let out = s.read("env.txt")
        XCTAssertTrue(out.contains("home=[]"), out)
        XCTAssertTrue(out.contains("/usr/bin"), "a login shell has a PATH")
    }
}
