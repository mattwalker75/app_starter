// Export and import: the bundles as one JSON file, to copy a setup to another Mac or keep a copy. Secret values
// are left out unless asked for (then the file holds them in plain text — say so where it is offered).
import Foundation

public struct ExportFile: Codable, Equatable, Sendable {
    public var app = "App Starter"
    public var version = 1
    public var exportedAt = Date()
    public var secretsIncluded: Bool
    public var bundles: [AppBundle]
}

public enum Transfer {
    public static func export(_ bundles: [AppBundle], includeSecrets: Bool) throws -> Data {
        var b = bundles
        if !includeSecrets {
            for i in b.indices { for s in b[i].steps.indices { for a in b[i].steps[s].apps.indices {
                for v in b[i].steps[s].apps[a].env.indices where b[i].steps[s].apps[a].env[v].secret { b[i].steps[s].apps[a].env[v].value = "" }
            } } }
        }
        return try JSON.encoder.encode(ExportFile(secretsIncluded: includeSecrets, bundles: b))
    }

    public static func read(_ data: Data) throws -> ExportFile {
        guard let f = try? JSON.decoder.decode(ExportFile.self, from: data), f.app == "App Starter" else {
            throw ASError("That file isn't an App Starter export.")
        }
        guard f.version <= 1 else { throw ASError("That file was made by a newer App Starter. Update this one first.") }
        return f
    }

    /// The bundles after an import: ones with the same id as an existing bundle replace it (`replace` true) or
    /// come in as copies with new ids; the rest are added.
    public static func merge(_ incoming: [AppBundle], into existing: [AppBundle], replace: Bool) -> [AppBundle] {
        var out = existing
        for b in incoming {
            if let i = out.firstIndex(where: { $0.id == b.id }) {
                if replace { out[i] = b } else { out.append(freshCopy(b, name: b.name + " (imported)")) }
            } else { out.append(b) }
        }
        return out
    }

    /// The same bundle with new ids everywhere (steps, apps, variables), so it shares nothing with the original.
    public static func freshCopy(_ b: AppBundle, name: String) -> AppBundle {
        var c = b
        c.id = UUID(); c.name = name
        var map: [UUID: UUID] = [:]
        for s in c.steps.indices {
            let new = UUID(); map[c.steps[s].id] = new; c.steps[s].id = new
            for a in c.steps[s].apps.indices {
                c.steps[s].apps[a].id = UUID()
                for v in c.steps[s].apps[a].env.indices { c.steps[s].apps[a].env[v].id = UUID() }
            }
        }
        c.stopOrder = c.stopOrder?.compactMap { map[$0] }
        return c
    }
}
