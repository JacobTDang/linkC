import Foundation

/// The seam every subprocess call goes through (MCP health, plugin list, plugin toggles) —
/// faked in tests, timeout-enforced in the live implementation. Fail loud: a stalled CLI must
/// never hang the panel.
public protocol ProcessRunner: Sendable {
    func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String
}

public struct LiveProcessRunner: ProcessRunner {
    /// Enough for a CLI's error message; a runaway stderr must not balloon an error string.
    private static let stderrCap = 4096

    /// The actionable part of stderr. CLIs prepend advisory banners (the `oci` key-
    /// permissions warning fires on every call) that would otherwise bury the real reason
    /// a command failed.
    static func meaningfulStderr(_ data: Data) -> String {
        let text = String(data: data.prefix(stderrCap), encoding: .utf8) ?? ""
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
    /// stdout is read only after exit, which is safe for the small outputs our CLI calls
    /// produce (well under the 64KB pipe buffer); this is not a general-purpose runner.
    /// stderr is captured (bounded) and folded into the thrown error: CLIs say WHY they
    /// failed there — "Access token not provided", "Cannot connect to the Docker daemon" —
    /// and discarding it left callers unable to tell an auth prompt from a crash.
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

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw LinkCError.process("\(executable) \(args.joined(separator: " ")) timed out after \(Int(timeout))s")
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
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
