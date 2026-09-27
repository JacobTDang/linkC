import Foundation
import Darwin

/// What a finished subprocess did: its exit status and both captured streams.
public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// The signal that ended the process, or nil when it exited normally. A login shell can run
    /// its last command in place of itself, so a signal death can reach `status` directly as the
    /// raw signal number instead of the shell's usual 128 + N — `signal` disambiguates the two.
    public let signal: Int32?

    public init(status: Int32, stdout: String, stderr: String, signal: Int32? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.signal = signal
    }
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut(seconds: Int)
}

/// The seam every subprocess call goes through (MCP health, plugin list, plugin toggles, task
/// verification) — faked in tests, timeout-enforced in the live implementation. Fail loud: a
/// stalled CLI must never hang the panel.
public protocol ProcessRunner: Sendable {
    /// Runs to completion and returns the exit status as data. Throws only when the process
    /// cannot start, or `ProcessRunnerError.timedOut`.
    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult
    /// Same as above, with `env` merged into the child's inherited environment (D26b) — e.g. to
    /// suppress a CLI's own advisory banner at the source instead of filtering it out of
    /// captured stderr afterward. A protocol requirement can't carry a default argument value,
    /// so this is a second requirement with a default IMPLEMENTATION below (not a default
    /// PARAMETER): a conformer that only implements the plain overload gets that default, which
    /// ignores `env` and forwards to it — no existing conformer needs to change.
    func runCapturing(_ executable: String, args: [String], cwd: URL?, env: [String: String], timeout: TimeInterval) async throws -> ProcessResult
}

extension ProcessRunner {
    public func runCapturing(_ executable: String, args: [String], cwd: URL?, env: [String: String], timeout: TimeInterval) async throws -> ProcessResult {
        try await runCapturing(executable, args: args, cwd: cwd, timeout: timeout)
    }

    /// stdout of a command that must succeed. A non-zero status throws `LinkCError.process`
    /// carrying the CLI's own stderr reason; a timeout throws `LinkCError.process` too.
    public func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String {
        try await run(executable, args: args, cwd: cwd, env: [:], timeout: timeout)
    }

    /// Same as above, with `env` merged into the child's inherited environment (D26b).
    public func run(_ executable: String, args: [String], cwd: URL?, env: [String: String], timeout: TimeInterval) async throws -> String {
        let command = "\(executable) \(args.joined(separator: " "))"
        let result: ProcessResult
        do {
            result = try await runCapturing(executable, args: args, cwd: cwd, env: env, timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            throw LinkCError.process("\(command) timed out after \(seconds)s")
        }
        guard result.status == 0 else {
            // The CLI's own words first — they carry the actionable part.
            let detail = LiveProcessRunner.meaningfulStderr(Data(result.stderr.utf8))
            throw LinkCError.process(
                detail.isEmpty
                    ? "\(command) exited with status \(result.status)"
                    : "\(detail) (\(command) exited with status \(result.status))"
            )
        }
        return result.stdout
    }
}

/// Holds what the two drain tasks read. Locked because the reads run concurrently.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()

    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }

    func setOut(_ data: Data) { lock.withLock { _out = data } }
    func setErr(_ data: Data) { lock.withLock { _err = data } }
}

/// The child's wait status, recorded by the thread that reaps it.
private final class ExitCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: Int32 = 0
    private var _waitError: Int32 = 0

    func record(status: Int32, waitError: Int32) {
        lock.withLock {
            _status = status
            _waitError = waitError
        }
    }

    /// What Foundation's `terminationStatus` reported (the exit code, or the number of the
    /// signal that ended the child — unchanged by the `signal` field below) together with that
    /// signal number, or nil when the child exited normally.
    func termination(of executable: String, pid: pid_t) throws -> (status: Int32, signal: Int32?) {
        let (status, waitError) = lock.withLock { (_status, _waitError) }
        guard waitError == 0 else {
            throw LinkCError.process("waitpid for \(executable) (pid \(pid)) failed: \(String(cString: strerror(waitError)))")
        }
        let signal = status & 0o177
        guard signal != 0 else { return ((status >> 8) & 0xff, nil) }
        return (signal, signal)
    }
}

public struct LiveProcessRunner: ProcessRunner {
    /// Enough for a CLI's error message; a runaway stderr must not balloon an error string.
    private static let stderrCap = 4096
    /// On timeout the command's process group gets SIGTERM, then SIGKILL after this long.
    static let terminationGrace: TimeInterval = 2

    /// The actionable part of stderr. CLIs prepend advisory banners (the `oci` key-
    /// permissions warning fires on every call — though D26b now asks `oci` to suppress that
    /// one at the source) and put the real reason LAST, so the cap keeps the tail — capping the
    /// head would drop exactly the line worth reading.
    static func meaningfulStderr(_ data: Data) -> String {
        // Decode the tail; a multi-byte character split by the cut is dropped by the
        // lossy conversion rather than failing the whole decode.
        let tail = data.suffix(stderrCap)
        let text = String(data: tail, encoding: .utf8)
            ?? String(decoding: tail, as: UTF8.self)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Advisory banners are dropped ONLY when something else survives to explain the
        // failure (D26b) — a blanket "Warning:" match must never leave a caller with nothing
        // when that banner was the CLI's only word on the matter.
        let withoutBanners = lines.filter { !$0.hasPrefix("Warning:") }
        let kept = withoutBanners.isEmpty ? lines : withoutBanners
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init() {}

    /// `runCapturingSync` blocks its calling thread for the whole subprocess (its drain queue
    /// does the actual waiting, but this frame sits on a semaphore the entire time) — `Task
    /// .detached` used to run that on a Swift-concurrency cooperative-pool thread, tying it up
    /// for as long as the child runs (D19a). A plain `DispatchQueue` thread, bridged back with a
    /// checked continuation, keeps the blocking work off that pool entirely.
    public func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        try await runCapturing(executable, args: args, cwd: cwd, env: [:], timeout: timeout)
    }

    public func runCapturing(_ executable: String, args: [String], cwd: URL?, env: [String: String], timeout: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runCapturingSync(executable: executable, args: args, cwd: cwd, env: env, timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous core, public for callers outside an async context (`GitClient`, the MCP
    /// stdio server). BOTH streams are drained on background queues WHILE the child runs: a
    /// pipe holds ~64KB, so a chatty child that fills it while nobody reads would block forever
    /// and burn the timeout. stderr is captured because CLIs say WHY they failed there. The
    /// child leads its own process group, so a timeout stops everything the command started.
    /// `env` is merged into the child's inherited environment (D26b); empty means "inherit only".
    public static func runCapturingSync(
        executable: String, args: [String], cwd: URL?, env: [String: String] = [:], timeout: TimeInterval
    ) throws -> ProcessResult {
        let stdout = Pipe()
        let stderr = Pipe()
        let pid = try spawnGroupLeader(
            executable: executable, args: args, cwd: cwd, environment: env.isEmpty ? nil : env,
            stdout: stdout.fileHandleForWriting.fileDescriptor,
            stderr: stderr.fileHandleForWriting.fileDescriptor
        )

        let drainQueue = DispatchQueue(label: "linkc.process.drain", attributes: .concurrent)
        let reaped = ExitCollector()
        let exited = DispatchSemaphore(value: 0)
        drainQueue.async {
            let result = reap(pid)
            reaped.record(status: result.status, waitError: result.waitError)
            exited.signal()
        }

        // The child holds its own copies of the write ends. The drains see EOF only once the
        // parent's copies are closed as well.
        do {
            try stdout.fileHandleForWriting.close()
            try stderr.fileHandleForWriting.close()
        } catch {
            kill(-pid, SIGKILL)
            throw error
        }

        // Drain both pipes concurrently so neither can fill and stall the child.
        let collected = StreamCollector()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        drainQueue.async {
            collected.setOut(stdout.fileHandleForReading.readDataToEndOfFile())
            outDone.signal()
        }
        drainQueue.async {
            collected.setErr(stderr.fileHandleForReading.readDataToEndOfFile())
            errDone.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            terminateGroup(pid, running: executable, in: cwd)
            _ = exited.wait(timeout: .now() + 2)
            // The drains end when every process in the group has closed its pipe ends.
            _ = outDone.wait(timeout: .now() + 2)
            _ = errDone.wait(timeout: .now() + 2)
            throw ProcessRunnerError.timedOut(seconds: Int(timeout))
        }

        // Both reads finish once the child exits and its pipe ends close.
        _ = outDone.wait(timeout: .now() + 5)
        _ = errDone.wait(timeout: .now() + 5)
        let termination = try reaped.termination(of: executable, pid: pid)
        return ProcessResult(
            status: termination.status,
            stdout: String(decoding: collected.out, as: UTF8.self),
            stderr: String(decoding: collected.err, as: UTF8.self),
            signal: termination.signal
        )
    }

    /// Starts `executable` as the leader of a new process group (pgid = its pid). Like
    /// `Process`, the child inherits stdin and the environment (plus `environment`, when given),
    /// starts with default signal handling and an empty signal mask, and receives no other open
    /// descriptors.
    static func spawnGroupLeader(
        executable: String, args: [String], cwd: URL?, environment: [String: String]? = nil, stdout: Int32, stderr: Int32
    ) throws -> pid_t {
        func require(_ result: Int32, _ call: String) throws {
            guard result == 0 else {
                throw LinkCError.process("\(call) failed for \(executable): \(String(cString: strerror(result)))")
            }
        }
        var actions: posix_spawn_file_actions_t?
        try require(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try require(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        try require(posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO), "posix_spawn_file_actions_addinherit_np")
        try require(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO), "posix_spawn_file_actions_adddup2")
        try require(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO), "posix_spawn_file_actions_adddup2")
        if let cwd {
            try require(posix_spawn_file_actions_addchdir_np(&actions, cwd.path), "posix_spawn_file_actions_addchdir_np")
        }

        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        try require(posix_spawnattr_setsigmask(&attributes, &noSignals), "posix_spawnattr_setsigmask")
        try require(posix_spawnattr_setsigdefault(&attributes, &allSignals), "posix_spawnattr_setsigdefault")
        try require(posix_spawnattr_setpgroup(&attributes, 0), "posix_spawnattr_setpgroup")
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        try require(posix_spawnattr_setflags(&attributes, Int16(flags)), "posix_spawnattr_setflags")

        let argv = ([executable] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let started: Int32
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            merged.merge(environment) { _, added in added }
            let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { envp.forEach { free($0) } }
            started = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        } else {
            started = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        guard started == 0 else {
            let place = cwd.map { " in \($0.path)" } ?? ""
            throw LinkCError.process("could not start \(executable)\(place): \(String(cString: strerror(started)))")
        }
        return pid
    }

    /// Blocks until `pid` exits. Returns its raw wait status, or the errno of a failed wait.
    private static func reap(_ pid: pid_t) -> (status: Int32, waitError: Int32) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            let error = errno
            if error != EINTR { return (0, error) }
        }
        return (status, 0)
    }

    /// SIGTERM to every process in the group, then SIGKILL to whatever is left after the grace
    /// period. The group id cannot be reused while any member of the group is still running.
    private static func terminateGroup(_ group: pid_t, running executable: String, in cwd: URL?) {
        signalGroup(group, SIGTERM, running: executable, in: cwd)
        let deadline = Date().addingTimeInterval(terminationGrace)
        while Date() < deadline {
            if kill(-group, 0) == -1 && errno == ESRCH { return } // every member has exited
            usleep(50_000)
        }
        signalGroup(group, SIGKILL, running: executable, in: cwd)
    }

    static func signalGroup(_ group: pid_t, _ signal: Int32, running executable: String, in cwd: URL?) {
        guard kill(-group, signal) == -1 else { return }
        let error = errno
        guard error != ESRCH else { return } // the group has already exited
        NSLog("[linkC process] signal %d to the process group of %@ in %@ (pgid %d) failed — %@",
              signal, executable, cwd?.path ?? "the current directory", group, String(cString: strerror(error)))
    }
}
