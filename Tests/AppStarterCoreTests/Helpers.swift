import Foundation
import Network
import XCTest
@testable import AppStarterCore

/// A throwaway folder per test, removed afterwards. Nothing ever touches the real Application Support folder.
final class Scratch {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("appstarter-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var path: String { url.path }
    func file(_ name: String) -> String { url.appendingPathComponent(name).path }
    func read(_ name: String) -> String { (try? String(contentsOfFile: file(name), encoding: .utf8)) ?? "" }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name)) }
    /// a fast engine with its logs and state in here
    func engine() -> Engine {
        let e = Engine(logs: AppLogs(folder: url.appendingPathComponent("logs")), runtime: Runtime(url: url.appendingPathComponent("state.json")))
        e.pollEvery = 0.1; e.settleSeconds = 0.5; e.stopGrace = 2
        return e
    }
}

/// Collects a run's events (from any thread).
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [RunEvent] = []
    func add(_ e: RunEvent) { lock.lock(); list.append(e); lock.unlock() }
    var all: [RunEvent] { lock.lock(); defer { lock.unlock() }; return list }
    var failures: [Failure] { all.compactMap { if case .paused(let f) = $0 { return f }; return nil } }
}

/// Answers the run's questions from a list, in order (then `.skip`).
final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Choice]
    init(_ q: [Choice]) { queue = q }
    func next(_ f: Failure) async -> Choice { lock.lock(); defer { lock.unlock() }; return queue.isEmpty ? .skip : queue.removeFirst() }
}

/// A tiny web server on a free port that answers every request with `status`.
final class TinyServer: @unchecked Sendable {
    let listener: NWListener
    private(set) var port: UInt16 = 0
    init(status: Int = 404) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let body = "HTTP/1.1 \(status) X\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                c.send(content: Data(body.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }
    var address: String { "http://127.0.0.1:\(port)/" }
    func stop() { listener.cancel() }
}

/// A port nothing listens on.
func freePort() -> UInt16 {
    let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = 0; a.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
    return UInt16(bigEndian: a.sin_port)
}

/// An app whose commands run in the scratch folder.
func app(_ name: String, in s: Scratch, start: String, stop: String = "true", mode: RunMode = .startsItself, health: HealthCheck = .none, wait: Int = 10) -> AppItem {
    AppItem(name: name, workingFolder: s.path, mode: mode, start: start, stop: stop, health: health, waitSeconds: wait)
}
