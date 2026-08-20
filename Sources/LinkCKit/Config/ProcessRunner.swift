import Foundation

/// The seam every subprocess call goes through (MCP health, plugin list, plugin toggles) —
/// faked in tests, timeout-enforced in the live implementation. Fail loud: a stalled CLI must
/// never hang the panel.
public protocol ProcessRunner: Sendable {
    func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String
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

    public func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String {
        let cwdPath = cwd?.path
        return try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(executable: executable, args: args, cwdPath: cwdPath, timeout: timeout)
        }.value
    }

    /// Synchronous core — the Process/Pipe pair never crosses a concurrency boundary.
    /// BOTH streams are drained on background queues WHILE the child runs: a pipe holds
    /// ~64KB, so a chatty CLI (docker progress, anything with --debug) that fills it while
    /// nobody reads would block forever and burn the timeout. Reading only after exit was
    /// a latent landmine for stdout and a live bug once stderr was captured too.
    /// stderr is captured because CLIs say WHY they failed there — "Access token not
    /// provided", "Cannot connect to the Docker daemon" — and discarding it left callers
    /// unable to tell an auth prompt from a crash.
    private static func runBlocking(
        executable: String, args: [String], cwdPath: String?, timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwdPath { process.currentDirectoryURL = URL(fileURLWithPath: cwdPath) }
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
            throw LinkCError.process("\(executable) \(args.joined(separator: " ")) timed out after \(Int(timeout))s")
        }

        // Both reads finish once the child exits and its pipe ends close.
        _ = outDone.wait(timeout: .now() + 5)
        _ = errDone.wait(timeout: .now() + 5)
        let data = collected.out
        let errorData = collected.err
        guard process.terminationStatus == 0 else {
            // The CLI's own words first — they carry the actionable part.
            let detail = Self.meaningfulStderr(errorData)
            let command = "\(executable) \(args.joined(separator: " "))"
            throw LinkCError.process(
                detail.isEmpty
                    ? "\(command) exited with status \(process.terminationStatus)"
                    : "\(detail) (\(command) exited with status \(process.terminationStatus))"
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
