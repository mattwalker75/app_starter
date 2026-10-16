// Running an application's commands: as you, through your login shell (`zsh -l -c "<the script>"`, so your
// PATH, Homebrew and profile work as in Terminal), in the working folder, with the app's environment variables
// added. Every command gets a process group of its own, so stopping it stops whatever it started too, and its
// output goes straight into the app's log file — not through a pipe, so a kept-running app goes on working
// after App Starter quits.
import Foundation
import Darwin

public struct Command: Sendable {
    public var script: String
    public var folder: String?
    public var env: [String: String]
    public init(script: String, folder: String? = nil, env: [String: String] = [:]) { self.script = script; self.folder = folder; self.env = env }

    /// An app's command with its folder and variables.
    public init(_ script: String, for app: AppItem) {
        self.init(script: script, folder: app.resolvedFolder, env: Dictionary(app.env.map { ($0.name, $0.value) }, uniquingKeysWith: { _, b in b }))
    }
}

/// How a command ended.
public enum Ending: Equatable, Sendable {
    case exited(Int32)
    case signalled(Int32)
    public var succeeded: Bool { self == .exited(0) }
    public var text: String {
        switch self {
        case .exited(let c): return "exit code \(c)"
        case .signalled(let s): return "stopped by signal \(s)\(s == SIGTERM ? " (asked to stop)" : s == SIGKILL ? " (forced)" : "")"
        }
    }
}

/// A command that was started. Its pid is also its process group's id.
public final class Spawned: @unchecked Sendable {
    public let pid: pid_t
    private let lock = NSLock()
    private var ending: Ending?
    private var waiters: [CheckedContinuation<Ending, Never>] = []

    init(pid: pid_t) {
        self.pid = pid
        // reap it on a plain thread (waitpid blocks); every waiter hears how it ended
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let e: Ending = (status & 0x7f) == 0 ? .exited((status >> 8) & 0xff) : .signalled(status & 0x7f)
            lock.lock(); ending = e; let w = waiters; waiters = []; lock.unlock()
            for c in w { c.resume(returning: e) }
        }
    }

    public var finished: Ending? { lock.lock(); defer { lock.unlock() }; return ending }

    public func wait() async -> Ending {
        await withCheckedContinuation { c in
            lock.lock()
            if let e = ending { lock.unlock(); c.resume(returning: e) } else { waiters.append(c); lock.unlock() }
        }
    }

    /// Waits up to `seconds` (less if the task is cancelled); nil = still running.
    public func wait(upTo seconds: Double) async -> Ending? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !Task.isCancelled {
            if let e = finished { return e }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return finished
    }

    /// Signals the whole process group (the command and everything it started).
    public func signal(_ sig: Int32) { Shell.signalGroup(pid, sig) }
}

public enum Shell {
    /// Your login shell (from your account), or zsh.
    public static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    /// A login shell reads ~/.zprofile (bash: ~/.bash_profile) but not ~/.zshrc — and many people (Matt included) put
    /// PATH lines there (conda, LM Studio, ~/.local/bin). So, as in Terminal, the shell's rc file is read too, quietly.
    static func rcPrefix(_ shell: String) -> String {
        switch (shell as NSString).lastPathComponent {
        case "zsh": return "[ -r \"${ZDOTDIR:-$HOME}/.zshrc\" ] && source \"${ZDOTDIR:-$HOME}/.zshrc\" >/dev/null 2>&1 </dev/null\n"
        case "bash": return "[ -r \"$HOME/.bashrc\" ] && source \"$HOME/.bashrc\" >/dev/null 2>&1 </dev/null\n"
        default: return ""
        }
    }

    /// The environment a command gets: App Starter's own (a login shell fills in PATH and the rest) plus the app's variables.
    static func environment(_ extra: [String: String]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // never hand our development hooks to the user's apps
        for k in env.keys where k.hasPrefix("APPSTARTER_") { env.removeValue(forKey: k) }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        for (k, v) in extra { env[k] = v }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Starts `command` with its output appended to `output` (made if missing). Throws a plain sentence when it can't.
    public static func spawn(_ command: Command, output: URL) throws -> Spawned {
        if let f = command.folder {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: f, isDirectory: &dir), dir.boolValue else {
                throw ASError("The working folder \(f) doesn't exist.")
            }
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        // its own process group; every other descriptor closed; signals back to their defaults
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(); sigfillset(&all); posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t(); sigemptyset(&none); posix_spawnattr_setsigmask(&attr, &none)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, output.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        if let f = command.folder { posix_spawn_file_actions_addchdir_np(&fa, f) }
        else { posix_spawn_file_actions_addchdir_np(&fa, NSHomeDirectory()) }

        let shell = loginShell
        let args = [shell, "-l", "-c", rcPrefix(shell) + command.script]
        let envs = environment(command.env)
        var pid: pid_t = 0
        let rc = withCStrings(args) { argv in withCStrings(envs) { envp in posix_spawn(&pid, shell, &fa, &attr, argv, envp) } }
        guard rc == 0 else { throw ASError("The command could not be started (\(String(cString: strerror(rc)))).") }
        return Spawned(pid: pid)
    }

    /// The result of a command run to the end.
    public struct Result: Sendable {
        public var ending: Ending?
        public var timedOut: Bool
        public var output: String
    }

    /// Runs a command and waits for it, up to `timeout` seconds (then it is stopped). The output goes to `log`, or
    /// is captured and returned when `log` is nil.
    /// `leaveOnCancel`: when the task is cancelled, stop waiting but leave the command running (Cancel means "stop
    /// waiting", never "kill what is starting"); otherwise it is stopped like a command that ran out of time.
    public static func run(_ command: Command, log: URL?, timeout: Double, leaveOnCancel: Bool = false) async -> Result {
        let capture = log == nil ? FileManager.default.temporaryDirectory.appendingPathComponent("appstarter-\(UUID().uuidString).out") : nil
        defer { if let c = capture { try? FileManager.default.removeItem(at: c) } }
        let p: Spawned
        do { p = try spawn(command, output: log ?? capture!) }
        catch { return Result(ending: nil, timedOut: false, output: (error as? ASError)?.message ?? error.localizedDescription) }
        var ending = await p.wait(upTo: timeout)
        if ending == nil && leaveOnCancel && Task.isCancelled { return Result(ending: nil, timedOut: false, output: "cancelled") }
        var timedOut = false
        if ending == nil {
            timedOut = true
            ending = await stop(p, grace: 3)
        }
        var out = ""
        if let c = capture, let h = try? FileHandle(forReadingFrom: c) {
            out = String(decoding: h.readData(ofLength: 1 << 20), as: UTF8.self); try? h.close()
        }
        return Result(ending: ending, timedOut: timedOut, output: out)
    }

    /// Asks a process group to stop (SIGTERM), and forces it (SIGKILL) after `grace` seconds. It waits for the whole
    /// group, not just the first process: a script's shell may end at once while what it started takes its time (or
    /// ignores the request) — that must still be forced.
    @discardableResult
    public static func stop(_ p: Spawned, grace: Double) async -> Ending? {
        await stopGroup(p.pid, grace: grace)
        return await p.wait(upTo: 1)
    }

    public static func stopGroup(_ pgid: pid_t, grace: Double) async {
        signalGroup(pgid, SIGTERM)
        let until = Date().addingTimeInterval(grace)
        // a cancelled task still finishes this (never leave a half-stopped group), but without spinning: plain sleeps
        while groupAlive(pgid) && Date() < until { usleep(100_000); await Task.yield() }
        if groupAlive(pgid) {
            signalGroup(pgid, SIGKILL)
            let hard = Date().addingTimeInterval(2)
            while groupAlive(pgid) && Date() < hard { usleep(50_000); await Task.yield() }
        }
    }

    public static func signalGroup(_ pgid: pid_t, _ sig: Int32) {
        guard pgid > 1 else { return }   // never 0 (our own group) or 1 (launchd)
        if kill(-pgid, sig) != 0 { kill(pgid, sig) }
    }

    /// Is anything in this process group (or the process itself) still running?
    public static func groupAlive(_ pgid: pid_t) -> Bool {
        guard pgid > 1 else { return false }
        if kill(-pgid, 0) == 0 || errno == EPERM { return true }
        return kill(pgid, 0) == 0
    }

    /// When a process started (seconds since 1970), to tell a process we started from another that later got its number.
    public static func startTime(of pid: pid_t) -> Double? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
}

/// Calls `body` with a NULL-terminated C array of the strings.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
    defer { for p in ptrs { free(p) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}
