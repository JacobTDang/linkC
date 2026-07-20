import Foundation

/// Runs external commands via `Foundation.Process`.
///
/// stdout/stderr are drained concurrently on background queues *while* waiting for exit,
/// not after — a child that writes a lot (e.g. `kitten @ ls` with many tabs) can fill a
/// pipe's kernel buffer and block on write, and reading only after `waitUntilExit()`
/// would deadlock against that. Draining both pipes concurrently avoids that entirely.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(executable: String, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment {
                    process.environment = environment
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: LinkCError.process("failed to launch \(executable): \(error)"))
                    return
                }

                let stdoutBox = DataBox()
                let stderrBox = DataBox()
                let drainGroup = DispatchGroup()

                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }

                process.waitUntilExit()
                drainGroup.wait()

                continuation.resume(returning: CommandResult(
                    stdout: String(data: stdoutBox.data, encoding: .utf8) ?? "",
                    stderr: String(data: stderrBox.data, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus
                ))
            }
        }
    }
}

/// Mutable box so the two drain closures above can write into shared storage.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
