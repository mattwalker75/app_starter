// One log per application (logs/<app id>.log): App Starter's own lines (when, which command, how it ended)
// with the commands' output in between. Secret values are hidden in App Starter's lines; what an app prints
// itself goes in as it is. A log is trimmed to its newest part once it passes the size limit.
import Foundation

public final class AppLogs: @unchecked Sendable {
    public let folder: URL
    /// a log is cut back to half of this once it grows past it
    public var maxBytes: Int
    private let lock = NSLock()

    public init(folder: URL = Home.folder().appendingPathComponent("logs", isDirectory: true), maxBytes: Int = 2_000_000) {
        self.folder = folder; self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func url(_ appId: UUID) -> URL { folder.appendingPathComponent("\(appId.uuidString).log") }

    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    /// Adds App Starter's own line(s), each stamped with the time; secret values replaced by •••.
    public func note(_ app: AppItem, _ text: String) {
        var t = text
        for v in app.env where v.secret && v.value.count >= 3 { t = t.replacingOccurrences(of: v.value, with: "•••") }
        let now = AppLogs.stamp.string(from: Date())
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map { "[\(now)] \($0)" }.joined(separator: "\n") + "\n"
        lock.lock(); defer { lock.unlock() }
        let u = url(app.id)
        trimIfNeeded(u)
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile(); h.write(Data(lines.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: u.path, contents: Data(lines.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    /// The newest part of an app's log (up to `bytes`).
    public func tail(_ appId: UUID, bytes: Int = 200_000) -> String {
        guard let h = try? FileHandle(forReadingFrom: url(appId)) else { return "" }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        h.seek(toFileOffset: from)
        var s = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        if from > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s
    }

    public func clear(_ appId: UUID) { lock.lock(); defer { lock.unlock() }; try? Data().write(to: url(appId)) }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "log" { try? Data().write(to: f) }
    }

    /// Removes the logs of apps that no longer exist.
    public func prune(keeping ids: Set<UUID>) {
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "log" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !ids.contains(id) { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Keeps the newest half once a log is over the limit (called before App Starter writes to it).
    private func trimIfNeeded(_ u: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int, size > maxBytes,
              let h = try? FileHandle(forReadingFrom: u) else { return }
        h.seek(toFileOffset: UInt64(size - maxBytes / 2))
        var keep = h.readDataToEndOfFile(); try? h.close()
        if let nl = keep.firstIndex(of: 0x0A) { keep = keep.subdata(in: keep.index(after: nl)..<keep.endIndex) }
        // written in place (not replaced): a kept-running app still has this file open for its output
        if let w = try? FileHandle(forWritingTo: u) { w.truncateFile(atOffset: 0); w.write(Data("[… older lines removed …]\n".utf8) + keep); try? w.close() }
    }
}
