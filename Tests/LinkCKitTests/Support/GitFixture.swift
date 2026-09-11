import XCTest
@testable import LinkCKit

/// Runs git in `directory` with a fixed identity, so commits work on a machine with no git
/// config. Fails the calling test on a non-zero exit and returns trimmed stdout.
@discardableResult
func runGit(_ args: [String], in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let result = try LiveProcessRunner.runCapturingSync(
        executable: try XCTUnwrap(GitClient.resolveGit(), "git not found", file: file, line: line),
        args: ["-c", "user.email=t@t", "-c", "user.name=t"] + args, cwd: directory, timeout: 10
    )
    XCTAssertEqual(result.status, 0, "git \(args.joined(separator: " ")): \(result.stderr)", file: file, line: line)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}
