import XCTest
@testable import AppStarterCore

/// One test per problem found in the Oct 16 2026 review (each was reproduced first).
final class ReviewFixTests: XCTestCase {
    func testParallelUpdatesAreAllSaved() async {
        let s = Scratch()
        let url = s.url.appendingPathComponent("state.json")
        let rt = Runtime(url: url)
        let ids = (0..<16).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { g in
            for (i, id) in ids.enumerated() { g.addTask { rt.update(id) { $0.pid = Int32(1000 + i) } } }
        }
        let again = Runtime(url: url)
        XCTAssertEqual(ids.compactMap { again[$0].pid }.count, 16, "no update lost to a save race")
    }

    func testAKeptRunningScriptWhoseChildIgnoresTheRequestIsForced() async throws {
        let s = Scratch()
        // a multi-line command: the shell is the leader and quits at once on SIGTERM; its child ignores SIGTERM
        let a = AppItem(name: "Stubborn", workingFolder: s.path, mode: .keepRunning,
                        start: "/usr/bin/python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(\"child.pid\",\"w\").write(str(__import__(\"os\").getpid())); time.sleep(120)'\necho never", stop: "", waitSeconds: 10)
        let e = s.engine()
        let up = await e.startApp(a)
        XCTAssertTrue(up.ok, up.note)
        try await Task.sleep(nanoseconds: 500_000_000)
        let child = Int32(s.read("child.pid")) ?? 0
        XCTAssertGreaterThan(child, 0)
        let down = await e.stopApp(a)
        XCTAssertTrue(down.ok, down.note)
        XCTAssertNotEqual(kill(child, 0), 0, "the child that ignored the request was forced")
    }

    func testRetryWaitsForTheSameProcessInsteadOfStartingASecondCopy() async throws {
        let s = Scratch()
        // the check only passes once the file exists; the first try gives up before that
        let a = AppItem(name: "Slow", workingFolder: s.path, mode: .keepRunning, start: "echo $$ >> pids.txt; exec sleep 60", stop: "",
                        health: .output(command: "test -f ready && echo UP", contains: "UP", ignoreCase: false), waitSeconds: 1)
        let e = s.engine()
        let first = await e.startApp(a)
        XCTAssertFalse(first.ok)
        FileManager.default.createFile(atPath: s.file("ready"), contents: nil)
        let retry = await e.startApp(a)
        XCTAssertTrue(retry.ok, retry.note)
        let pids = s.read("pids.txt").split(separator: "\n")
        XCTAssertEqual(pids.count, 1, "only one copy was ever started")
        _ = await e.stopApp(a)
    }

    func testStopWhatStartedAlsoStopsAKeptRunningAppWhoseCheckFailed() async throws {
        let s = Scratch()
        let a = AppItem(name: "NeverReady", workingFolder: s.path, mode: .keepRunning, start: "exec sleep 60", stop: "",
                        health: .output(command: "echo no", contains: "UP", ignoreCase: false), waitSeconds: 1)
        let e = s.engine()
        let out = await e.start(AppBundle(name: "B", steps: [Step(app: a)]), events: { _ in }, decide: { _ in .giveUp })
        XCTAssertEqual(out, .gaveUp)
        XCTAssertFalse(e.runtime.processAlive(a.id), "the process this run left going was stopped")
    }

    func testAKeptRunningCommandThatHandsOverToAChildStillCounts() async throws {
        let s = Scratch()
        // the leader starts a child in the background and ends: the group lives on
        let a = AppItem(name: "Forks", workingFolder: s.path, mode: .keepRunning, start: "sleep 60 &\necho $! > child.pid", stop: "", waitSeconds: 5)
        let e = s.engine()
        let up = await e.startApp(a)
        XCTAssertTrue(up.ok, up.note)
        let child = Int32(s.read("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let isUp = await e.isUp(a)
        XCTAssertTrue(isUp)
        let down = await e.stopApp(a)
        XCTAssertTrue(down.ok, down.note)
        XCTAssertNotEqual(kill(child, 0), 0)
    }

    func testTheFirstLookDoesNotEatTheStartCommandsTime() async {
        let s = Scratch()
        // a slow check (~1.8 s with the shell), a slow start (~2.3 s), 5 s to wait: the first look (1.8) + start (2.3) +
        // check (1.8) is 5.9 s — over 5 when the first look counted, inside it now that the wait starts after it
        let a = AppItem(name: "A", workingFolder: s.path, start: "sleep 2; touch up", stop: "rm -f up",
                        health: .output(command: "sleep 1.5; test -f up && echo UP", contains: "UP", ignoreCase: false), waitSeconds: 5)
        let r = await s.engine().startApp(a)
        XCTAssertTrue(r.ok, r.note)
    }

    func testStartTheRestLeavesAnAppItAlreadyStarted() async {
        let s = Scratch()
        let a = AppItem(name: "A", workingFolder: s.path, start: "echo x >> starts.txt", stop: "true")
        let e = s.engine()
        _ = await e.startApp(a)
        let again = await e.startApp(a)
        XCTAssertTrue(again.already)
        XCTAssertEqual(s.read("starts.txt"), "x\n")
    }

    func testADamagedBundlesFileIsMovedAsideNotOverwritten() throws {
        let s = Scratch()
        try Data("{ not json".utf8).write(to: s.url.appendingPathComponent("bundles.json"))
        let store = BundleStore(folder: s.url)
        XCTAssertThrowsError(try store.load())
        let kept = try FileManager.default.contentsOfDirectory(atPath: s.path).filter { $0.hasPrefix("bundles.json.unreadable-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOfFile: s.file(kept[0]), encoding: .utf8), "{ not json")
    }

    func testUnreadableSecretsStillLoadTheBundles() throws {
        let s = Scratch()
        let store = BundleStore(folder: s.url)
        try store.save([AppBundle(name: "B", steps: [Step(app: AppItem(name: "A", start: "x", stop: "y", env: [EnvVar(name: "K", value: "v", secret: true)]))])])
        try FileManager.default.removeItem(atPath: s.file("secret.key"))
        let loaded = try store.load()
        XCTAssertEqual(loaded.first?.apps.first?.name, "A")
        XCTAssertEqual(loaded.first?.apps.first?.env.first?.value, "")
        XCTAssertNotNil(store.problem)
        // a save afterwards works (a new key) and the unreadable file was kept aside
        try store.save(loaded)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: s.path).contains { $0.hasPrefix("secrets.enc.unreadable-") })
    }

    func testImportReplaceWithoutSecretsKeepsTheSecretsAlreadyHere() throws {
        let a = AppItem(name: "A", start: "x", stop: "y", env: [EnvVar(name: "K", value: "topsecret", secret: true)])
        let b = AppBundle(name: "B", steps: [Step(app: a)])
        let f = try Transfer.read(Transfer.export([b], includeSecrets: false))
        let merged = Transfer.merge(f.bundles, into: [b], replace: true, secretsIncluded: f.secretsIncluded)
        XCTAssertEqual(merged.first?.apps.first?.env.first?.value, "topsecret")
    }

    func testAnOlderBundlesFileWithMissingFieldsStillLoads() throws {
        let s = Scratch()
        let json = #"{"version":1,"bundles":[{"id":"\#(UUID().uuidString)","name":"Old","steps":[{"id":"\#(UUID().uuidString)","isGroup":false,"name":"","apps":[{"id":"\#(UUID().uuidString)","name":"A","start":"x","stop":"y"}]}]}]}"#
        try Data(json.utf8).write(to: s.url.appendingPathComponent("bundles.json"))
        let b = try BundleStore(folder: s.url).load()
        XCTAssertEqual(b.first?.apps.first?.waitSeconds, 60)
        XCTAssertEqual(b.first?.apps.first?.health, HealthCheck.none)
        XCTAssertEqual(b.first?.startAtLogin, false)
    }

    func testAKeptRunningAppCannotUseAReturnCodeCheck() {
        XCTAssertNotNil(AppItem(name: "A", mode: .keepRunning, start: "npm start", health: .returnCode).problem)
    }

    func testLogsAreTrimmedEvenWhenOnlyTheAppWrites() throws {
        let s = Scratch()
        let logs = AppLogs(folder: s.url, maxBytes: 2000)
        let id = UUID()
        try Data(String(repeating: "app output line\n", count: 1000).utf8).write(to: logs.url(id))
        logs.trimAll()
        let size = try FileManager.default.attributesOfItem(atPath: logs.url(id).path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 1200)
    }

    func testTheShellsRcFileIsReadLikeInTerminal() async throws {
        let s = Scratch()
        try "export FROM_RC=yes\necho noise from rc\n".write(toFile: s.file(".zshrc"), atomically: true, encoding: .utf8)
        // ZDOTDIR points zsh at this folder's .zshrc (and its .zprofile, which does not exist)
        let a = AppItem(name: "A", workingFolder: s.path, start: "echo \"rc=$FROM_RC\" > rc.txt", stop: "true", env: [EnvVar(name: "ZDOTDIR", value: s.path)])
        guard (Shell.loginShell as NSString).lastPathComponent == "zsh" else { throw XCTSkip("the login shell is not zsh") }
        let r = await s.engine().startApp(a)
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(s.read("rc.txt"), "rc=yes\n")
        XCTAssertFalse(s.engine().logs.tail(a.id).contains("noise from rc"), "the rc file's own output is kept out of the log")
    }
}
