import XCTest
@testable import AppStarterCore

final class StoreTests: XCTestCase {
    func testBundlesSaveAndLoadWithSecretsKeptOutOfTheFile() throws {
        let s = Scratch()
        let store = BundleStore(folder: s.url)
        var a = AppItem(name: "Trading Desk", start: "./DESK.sh --start", stop: "./DESK.sh --stop")
        a.env = [EnvVar(name: "MODE", value: "sandbox"), EnvVar(name: "API_KEY", value: "sk-very-secret-value", secret: true)]
        let b = AppBundle(name: "Trading", steps: [Step(app: a)])
        try store.save([b])

        let plain = s.read("bundles.json")
        XCTAssertTrue(plain.contains("sandbox"))
        XCTAssertFalse(plain.contains("sk-very-secret-value"), "a secret value must never be written to bundles.json")
        let sealed = try Data(contentsOf: s.url.appendingPathComponent("secrets.enc"))
        XCTAssertNil(String(data: sealed, encoding: .utf8).flatMap { $0.contains("sk-very") ? $0 : nil }, "secrets.enc is encrypted")
        let perms = try FileManager.default.attributesOfItem(atPath: s.file("secret.key"))[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let loaded = try BundleStore(folder: s.url).load()
        XCTAssertEqual(loaded, [b])
    }

    func testAMissingKeyIsAPlainProblemAndTheBundlesStillLoad() throws {
        let s = Scratch()
        let store = BundleStore(folder: s.url)
        try store.save([AppBundle(name: "B", steps: [Step(app: AppItem(name: "A", start: "x", stop: "y", env: [EnvVar(name: "K", value: "v", secret: true)]))])])
        try FileManager.default.removeItem(atPath: s.file("secret.key"))
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertTrue(store.problem?.contains("key") == true)
    }

    func testStopOrderIsTheReverseUnlessSet() {
        let s1 = Step(app: AppItem(name: "1")), s2 = Step(group: "Two"), s3 = Step(app: AppItem(name: "3"))
        var b = AppBundle(name: "B", steps: [s1, s2, s3])
        XCTAssertEqual(b.stepsInStopOrder.map(\.id), [s3.id, s2.id, s1.id])
        b.stopOrder = [s2.id, s1.id]   // s3 left out: it goes last
        XCTAssertEqual(b.stepsInStopOrder.map(\.id), [s2.id, s1.id, s3.id])
    }

    func testAnAppNeedsANameAStartAndAStopUnlessItIsKeptRunning() {
        XCTAssertNotNil(AppItem(name: "", start: "x", stop: "y").problem)
        XCTAssertNotNil(AppItem(name: "A", start: " ", stop: "y").problem)
        XCTAssertNotNil(AppItem(name: "A", start: "x", stop: "").problem)
        XCTAssertNil(AppItem(name: "A", mode: .keepRunning, start: "ollama serve").problem)
        XCTAssertNotNil(AppItem(name: "A", start: "x", stop: "y", env: [EnvVar(name: "1BAD", value: "")]).problem)
        XCTAssertNotNil(AppItem(name: "A", start: "x", stop: "y", health: .url("localhost:80")).problem)
        XCTAssertNil(AppItem(name: "A", start: "x", stop: "y", health: .url("https://mini.ts.net:8443/")).problem)
        XCTAssertNotNil(AppItem(name: "A", start: "x", stop: "y", health: .output(command: "", contains: "x", ignoreCase: false)).problem)
    }

    func testTheLightIsGreenRedOrYellow() {
        XCTAssertEqual(BundleStatus.of([true, true]), .allUp)
        XCTAssertEqual(BundleStatus.of([false, false]), .allDown)
        XCTAssertEqual(BundleStatus.of([true, false]), .mixed)
        XCTAssertEqual(BundleStatus.of([]), .empty)
    }

    func testExportLeavesSecretsOutUnlessAskedAndImportCanAddCopies() throws {
        let a = AppItem(name: "A", start: "x", stop: "y", env: [EnvVar(name: "K", value: "hush", secret: true)])
        let s1 = Step(app: a), s2 = Step(app: AppItem(name: "B", start: "x", stop: "y"))
        var b = AppBundle(name: "B", steps: [s1, s2]); b.stopOrder = [s1.id, s2.id]
        let without = String(decoding: try Transfer.export([b], includeSecrets: false), as: UTF8.self)
        XCTAssertFalse(without.contains("hush"))
        let with = try Transfer.read(Transfer.export([b], includeSecrets: true))
        XCTAssertTrue(with.secretsIncluded)
        XCTAssertEqual(with.bundles.first?.apps.first?.env.first?.value, "hush")
        XCTAssertThrowsError(try Transfer.read(Data("{}".utf8)))

        let merged = Transfer.merge(with.bundles, into: [b], replace: false)
        XCTAssertEqual(merged.count, 2)
        XCTAssertNotEqual(merged[1].id, b.id)
        XCTAssertNotEqual(merged[1].apps.first?.id, a.id, "a copy shares no ids with the original")
        XCTAssertEqual(merged[1].stopOrder, merged[1].steps.map(\.id), "the custom stop order follows the new step ids")
        XCTAssertEqual(Transfer.merge(with.bundles, into: [b], replace: true).count, 1)
    }

    func testLogsHideSecretsAndStayUnderTheLimit() {
        let s = Scratch()
        let logs = AppLogs(folder: s.url, maxBytes: 4000)
        let a = AppItem(name: "A", env: [EnvVar(name: "K", value: "hunter22", secret: true)])
        logs.note(a, "export K=hunter22")
        XCTAssertFalse(logs.tail(a.id).contains("hunter22"))
        XCTAssertTrue(logs.tail(a.id).contains("export K=•••"))
        for i in 0..<400 { logs.note(a, "line \(i) with some text in it") }
        let size = (try? FileManager.default.attributesOfItem(atPath: logs.url(a.id).path))?[.size] as? Int ?? 0
        XCTAssertLessThan(size, 4200)
        XCTAssertTrue(logs.tail(a.id).contains("line 399"))
    }
}
