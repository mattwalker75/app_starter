// Where App Starter keeps things: ~/Library/Application Support/App Starter/
//   bundles.json   every bundle, step and application (secret values left out)
//   secrets.enc    the secret environment variables' values, encrypted (SecretBox)
//   secret.key     the key that file is encrypted with (readable by you only)
//   state.json     what App Starter remembers between launches (which apps it started, the processes it keeps)
//   settings.json  the app's own settings (the UI target)
//   logs/          one log per application
// APPSTARTER_HOME in the environment points all of it somewhere else (tests, trying things out).
import Foundation

public enum Home {
    public static func folder() -> URL {
        let dir: URL
        if let h = ProcessInfo.processInfo.environment["APPSTARTER_HOME"], !h.isEmpty {
            dir = URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = base.appendingPathComponent("App Starter", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum JSON {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension BundleStore {
    /// Renames a file to "<name>.unreadable-<date>" beside it; returns the new name.
    @discardableResult
    static func moveAside(_ u: URL) -> String? {
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(u.lastPathComponent).unreadable-\(f.string(from: Date()))"
        do { try FileManager.default.moveItem(at: u, to: u.deletingLastPathComponent().appendingPathComponent(name)); return name } catch { return nil }
    }
}

public struct BundlesFile: Codable, Equatable, Sendable {
    public var version = 1
    public var bundles: [AppBundle]
    public init(bundles: [AppBundle]) { self.bundles = bundles }
}

/// bundles.json and the secrets that go with it.
public final class BundleStore: @unchecked Sendable {
    public let folder: URL
    public var url: URL { folder.appendingPathComponent("bundles.json") }
    public let secrets: SecretBox
    /// a warning from the last load that did not stop it (the secret values could not be read)
    public private(set) var problem: String?

    public init(folder: URL = Home.folder()) {
        self.folder = folder
        secrets = SecretBox(folder: folder)
    }

    /// Loads the bundles. A damaged bundles.json is moved aside (never overwritten by the next save) and reported;
    /// unreadable secret values are moved aside too and the bundles load without them (`problem` says so).
    public func load() throws -> [AppBundle] {
        problem = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var bundles: [AppBundle]
        do { bundles = try JSON.decoder.decode(BundlesFile.self, from: Data(contentsOf: url)).bundles }
        catch {
            let aside = Self.moveAside(url)
            throw ASError("The bundles file could not be read (\(error.localizedDescription)). It was kept as \(aside ?? url.lastPathComponent) in \(folder.path), so nothing is lost; App Starter starts with no bundles. Put it back once it is fixed, or Import a backup.")
        }
        var values: [String: String] = [:]
        do { values = try secrets.load() }
        catch {
            let a = Self.moveAside(secrets.dataURL), k = Self.moveAside(secrets.keyURL)
            problem = "\((error as? ASError)?.message ?? error.localizedDescription) The old files were kept as \([a, k].compactMap { $0 }.joined(separator: " and ")). Your bundles loaded without their secret values: type them again in each app's editor."
        }
        for b in bundles.indices { for s in bundles[b].steps.indices { for a in bundles[b].steps[s].apps.indices {
            for v in bundles[b].steps[s].apps[a].env.indices where bundles[b].steps[s].apps[a].env[v].secret {
                bundles[b].steps[s].apps[a].env[v].value = values[bundles[b].steps[s].apps[a].env[v].id.uuidString] ?? ""
            }
        } } }
        return bundles
    }

    /// Saves the bundles; secret values go to the encrypted file, never into bundles.json.
    public func save(_ bundles: [AppBundle]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var plain = bundles
        var values: [String: String] = [:]
        for b in plain.indices { for s in plain[b].steps.indices { for a in plain[b].steps[s].apps.indices {
            for v in plain[b].steps[s].apps[a].env.indices where plain[b].steps[s].apps[a].env[v].secret {
                values[plain[b].steps[s].apps[a].env[v].id.uuidString] = plain[b].steps[s].apps[a].env[v].value
                plain[b].steps[s].apps[a].env[v].value = ""
            }
        } } }
        // the secrets first: a crash between the two writes must never leave bundles.json pointing at secrets that are gone
        try secrets.save(values)
        try JSON.encoder.encode(BundlesFile(bundles: plain)).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
