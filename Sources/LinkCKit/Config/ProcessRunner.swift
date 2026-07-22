import Foundation

/// The seam every subprocess call goes through (MCP health, plugin list, plugin toggles) —
/// faked in tests, timeout-enforced in the live implementation. Fail loud: a stalled CLI must
/// never hang the panel.
public protocol ProcessRunner: Sendable {
    func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String
}

public struct LiveProcessRunner: ProcessRunner {
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
    private static func runBlocking(
        executable: String, args: [String], cwdPath: String?, timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwdPath { process.currentDirectoryURL = URL(fileURLWithPath: cwdPath) }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw LinkCError.process("\(executable) \(args.joined(separator: " ")) timed out after \(Int(timeout))s")
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw LinkCError.process("\(executable) \(args.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
