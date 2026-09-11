import Foundation

/// What a finished subprocess did: its exit status and both captured streams.
public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
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
}

extension ProcessRunner {
    /// stdout of a command that must succeed. A non-zero status throws `LinkCError.process`
    /// carrying the CLI's own stderr reason; a timeout throws `LinkCError.process` too.
    public func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String {
        let command = "\(executable) \(args.joined(separator: " "))"
        let result: ProcessResult
        do {
            result = try await runCapturing(executable, args: args, cwd: cwd, timeout: timeout)
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

public struct LiveProcessRunner: ProcessRunner {
    /// Enough for a CLI's error message; a runaway stderr must not balloon an error string.
    private static let stderrCap = 4096

    /// The actionable part of stderr. CLIs prepend advisory banners (the `oci` key-
    /// permissions warning fires on every call) and put the real reason LAST, so the cap
    /// keeps the tail — capping the head would drop exactly the line worth reading.
    static func meaningfulStderr(_ data: Data) -> String {
        // Decode the tail; a multi-byte character split by the cut is dropped by the
        // lossy conversion rather than failing the whole decode.
        let tail = data.suffix(stderrCap)
        let text = String(data: tail, encoding: .utf8)
            ?? String(decoding: tail, as: UTF8.self)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning:") }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init() {}

    public func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runCapturingSync(executable: executable, args: args, cwd: cwd, timeout: timeout)
        }.value
    }

    /// Synchronous core, public for callers outside an async context (`GitClient`, the MCP
    /// stdio server). The Process/Pipe pair never crosses a concurrency boundary. BOTH
    /// streams are drained on background queues WHILE the child runs: a pipe holds ~64KB, so
    /// a chatty child that fills it while nobody reads would block forever and burn the
    /// timeout. stderr is captured because CLIs say WHY they failed there.
    public static func runCapturingSync(
        executable: String, args: [String], cwd: URL?, timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr

        // Drain both pipes concurrently so neither can fill and stall the child.
        let collected = StreamCollector()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let drainQueue = DispatchQueue(label: "linkc.process.drain", attributes: .concurrent)
        drainQueue.async {
            collected.setOut(stdout.fileHandleForReading.readDataToEndOfFile())
            outDone.signal()
        }
        drainQueue.async {
            collected.setErr(stderr.fileHandleForReading.readDataToEndOfFile())
            errDone.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            // The drains end when the child's pipe ends close.
            _ = outDone.wait(timeout: .now() + 2)
            _ = errDone.wait(timeout: .now() + 2)
            throw ProcessRunnerError.timedOut(seconds: Int(timeout))
        }

        // Both reads finish once the child exits and its pipe ends close.
        _ = outDone.wait(timeout: .now() + 5)
        _ = errDone.wait(timeout: .now() + 5)
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: collected.out, as: UTF8.self),
            stderr: String(decoding: collected.err, as: UTF8.self)
        )
    }
}
