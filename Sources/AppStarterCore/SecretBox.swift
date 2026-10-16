// Secret environment variables, encrypted on disk (Matt's decision: not the Keychain). The values are sealed
// with AES-GCM (256-bit) into secrets.enc; the key is a random file, secret.key, readable by you only. That keeps
// the values out of bundles.json, out of exports (unless you ask), out of backups of that file and out of the
// logs — but anyone who can read your files as you can read the key too: it protects against a file being
// copied or shown, not against someone using your account.
import Foundation
import CryptoKit

public final class SecretBox: @unchecked Sendable {
    public let folder: URL
    var dataURL: URL { folder.appendingPathComponent("secrets.enc") }
    var keyURL: URL { folder.appendingPathComponent("secret.key") }

    public init(folder: URL) { self.folder = folder }

    /// The key, made the first time it is needed.
    func key(create: Bool) throws -> SymmetricKey? {
        if let d = try? Data(contentsOf: keyURL), d.count == 32 { return SymmetricKey(data: d) }
        if FileManager.default.fileExists(atPath: keyURL.path) {
            throw ASError("The secrets key \(keyURL.path) is damaged, so the secret values can't be read. Move it and secrets.enc aside and type the secret values again.")
        }
        guard create else { return nil }
        let k = SymmetricKey(size: .bits256)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let d = k.withUnsafeBytes { Data($0) }
        guard FileManager.default.createFile(atPath: keyURL.path, contents: d, attributes: [.posixPermissions: 0o600]) else {
            throw ASError("The secrets key could not be written in \(folder.path).")
        }
        return k
    }

    /// variable id → value
    public func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return [:] }
        guard let k = try key(create: false) else {
            throw ASError("The secret values (\(dataURL.path)) can't be read: their key, secret.key, is missing. Move secrets.enc aside and type the secret values again.")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: dataURL))
            return try JSONDecoder().decode([String: String].self, from: AES.GCM.open(box, using: k))
        } catch {
            throw ASError("The secret values (\(dataURL.path)) can't be read with this key. Move secrets.enc and secret.key aside and type the secret values again.")
        }
    }

    public func save(_ values: [String: String]) throws {
        if values.isEmpty, !FileManager.default.fileExists(atPath: dataURL.path) { return }
        guard let k = try key(create: true) else { return }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(values), using: k)
        guard let combined = sealed.combined else { throw ASError("The secret values could not be encrypted.") }
        try combined.write(to: dataURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataURL.path)
    }
}
