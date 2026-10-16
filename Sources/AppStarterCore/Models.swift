// What the user sets up: application bundles. A bundle is a list of steps that start one after another
// (and stop in the reverse order, unless the bundle says otherwise); a step is one application, or a
// sub-bundle whose applications start (and stop) together. Each application has its own start and stop
// commands (several lines allowed), its environment variables, and an optional health check.
import Foundation

public struct AppBundle: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var steps: [Step] = []
    /// nil = stop in the reverse of the start order; otherwise the step ids in the order they stop
    public var stopOrder: [UUID]?
    /// start this bundle when App Starter first opens after you log in
    public var startAtLogin = false
    /// stop this bundle when you log out, restart or shut down
    public var stopAtLogout = false

    public init(id: UUID = UUID(), name: String, steps: [Step] = []) { self.id = id; self.name = name; self.steps = steps }

    /// every application in the bundle, in start order
    public var apps: [AppItem] { steps.flatMap(\.apps) }

    /// The steps in the order they stop: the custom order (any step it leaves out goes last), or the reverse of the start order.
    public var stepsInStopOrder: [Step] {
        guard let order = stopOrder else { return steps.reversed() }
        var out = order.compactMap { id in steps.first { $0.id == id } }
        for s in steps.reversed() where !out.contains(where: { $0.id == s.id }) { out.append(s) }
        return out
    }

    /// The step that holds the app, and its position.
    public func stepIndex(of appId: UUID) -> Int? { steps.firstIndex { $0.apps.contains { $0.id == appId } } }

    public func app(_ id: UUID) -> AppItem? { apps.first { $0.id == id } }
}

/// One step of a bundle: a single application, or a named sub-bundle of applications that start together.
public struct Step: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// a sub-bundle has a name and may hold any number of apps (even none, while it is being filled)
    public var isGroup: Bool
    public var name: String
    public var apps: [AppItem]

    public init(id: UUID = UUID(), app: AppItem) { self.id = id; isGroup = false; name = ""; apps = [app] }
    public init(id: UUID = UUID(), group name: String, apps: [AppItem] = []) { self.id = id; isGroup = true; self.name = name; self.apps = apps }

    /// "Local AI", or the app's own name for a one-app step
    public var title: String { isGroup ? name : (apps.first?.name ?? "") }
}

/// How an application's start command behaves.
public enum RunMode: String, Codable, CaseIterable, Sendable {
    /// the command sets the app going and finishes (./TRACKER.sh --start, open -a Docker, docker start …)
    case startsItself
    /// the command IS the app and keeps running (npm start, ollama serve): App Starter keeps it going and stops it
    case keepRunning
}

/// How App Starter tells whether an application is up.
public enum HealthCheck: Codable, Equatable, Sendable {
    /// no check: started = the start command finished (or, kept running, the process is alive)
    case none
    /// the start (or stop) command must finish with exit code 0
    case returnCode
    /// run a command; up when its output contains the text
    case output(command: String, contains: String, ignoreCase: Bool)
    /// up when the address answers at all (any status, any certificate)
    case url(String)

    public var kind: Kind {
        switch self { case .none: return .none; case .returnCode: return .returnCode; case .output: return .output; case .url: return .url }
    }
    public enum Kind: String, CaseIterable, Sendable { case none, returnCode, output, url }

    /// a check App Starter can run again at any time (for the status lights)
    public var canPoll: Bool { kind == .output || kind == .url }
}

/// An environment variable for an application's commands (start, stop and the health check). A secret one's
/// value is kept encrypted on disk (`SecretBox`), never in bundles.json, and is hidden in logs.
public struct EnvVar: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var value: String
    public var secret: Bool
    public init(id: UUID = UUID(), name: String, value: String, secret: Bool = false) { self.id = id; self.name = name; self.value = value; self.secret = secret }

    /// names a shell accepts: a letter or _, then letters, digits and _
    public static func validName(_ n: String) -> Bool {
        guard let f = n.unicodeScalars.first, f == "_" || CharacterSet.letters.contains(f), f.isASCII else { return false }
        return n.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }
}

public struct AppItem: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// commands run here ("~" allowed); empty = your home folder
    public var workingFolder: String = ""
    public var mode: RunMode = .startsItself
    /// the start command or script — several lines allowed; run by your login shell
    public var start: String = ""
    /// the stop command or script; empty = App Starter stops what it started (kept-running apps only)
    public var stop: String = ""
    public var env: [EnvVar] = []
    public var health: HealthCheck = .none
    /// how long to wait for it to come up (or go down), in seconds
    public var waitSeconds: Int = 60

    public init(id: UUID = UUID(), name: String, workingFolder: String = "", mode: RunMode = .startsItself, start: String = "", stop: String = "", env: [EnvVar] = [], health: HealthCheck = .none, waitSeconds: Int = 60) {
        self.id = id; self.name = name; self.workingFolder = workingFolder; self.mode = mode; self.start = start; self.stop = stop
        self.env = env; self.health = health; self.waitSeconds = waitSeconds
    }

    /// The working folder as a full path ("~" expanded); nil when none is set.
    public var resolvedFolder: String? {
        let f = workingFolder.trimmingCharacters(in: .whitespaces)
        if f.isEmpty { return nil }
        return (f as NSString).expandingTildeInPath
    }

    /// What is wrong with it, in plain words (nil = fine to save).
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the application a name." }
        if start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type the command that starts it." }
        if mode == .startsItself && stop.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type the command that stops it. (Only an app App Starter keeps running can be stopped without one.)"
        }
        for v in env {
            if !EnvVar.validName(v.name) { return "“\(v.name)” can't be an environment variable's name: use letters, digits and _, starting with a letter or _." }
        }
        let names = env.map(\.name)
        if Set(names).count != names.count { return "Two environment variables have the same name." }
        switch health {
        case .output(let c, let t, _):
            if c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type the command the health check runs." }
            if t.isEmpty { return "Type the text the health check looks for." }
        case .url(let u):
            guard let url = URL(string: u.trimmingCharacters(in: .whitespaces)), let s = url.scheme?.lowercased(), s == "http" || s == "https", url.host != nil else {
                return "The health check's address must start with http:// or https://, like http://localhost:8420."
            }
        default: break
        }
        if mode == .keepRunning && health.kind == .returnCode {
            return "A return-code check needs a start command that finishes; this one keeps running. Pick None, Output text or URL."
        }
        if waitSeconds < 1 || waitSeconds > 3600 { return "Wait between 1 second and an hour." }
        return nil
    }
}

/// The only error type: a sentence for the user.
public struct ASError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// Reading bundles.json: a key that is missing (a file from an older App Starter) takes its default, so adding a field
// never makes old files unreadable.
extension AppBundle {
    enum CodingKeys: String, CodingKey { case id, name, steps, stopOrder, startAtLogin, stopAtLogout }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Bundle"
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        stopOrder = try c.decodeIfPresent([UUID].self, forKey: .stopOrder)
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        stopAtLogout = try c.decodeIfPresent(Bool.self, forKey: .stopAtLogout) ?? false
    }
}

extension Step {
    enum CodingKeys: String, CodingKey { case id, isGroup, name, apps }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        apps = try c.decodeIfPresent([AppItem].self, forKey: .apps) ?? []
    }
}

extension EnvVar {
    enum CodingKeys: String, CodingKey { case id, name, value, secret }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
    }
}

extension AppItem {
    enum CodingKeys: String, CodingKey { case id, name, workingFolder, mode, start, stop, env, health, waitSeconds }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Application"
        workingFolder = try c.decodeIfPresent(String.self, forKey: .workingFolder) ?? ""
        mode = try c.decodeIfPresent(RunMode.self, forKey: .mode) ?? .startsItself
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        stop = try c.decodeIfPresent(String.self, forKey: .stop) ?? ""
        env = try c.decodeIfPresent([EnvVar].self, forKey: .env) ?? []
        health = try c.decodeIfPresent(HealthCheck.self, forKey: .health) ?? .none
        waitSeconds = try c.decodeIfPresent(Int.self, forKey: .waitSeconds) ?? 60
    }
}
