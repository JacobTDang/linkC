import XCTest
@testable import LinkCKit

final class ProcessSnooperTests: XCTestCase {
    func testDetectAgentInPath() {
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/bin/claude"), .claude)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/usr/local/bin/claude"), .claude)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "claude"), .claude)

        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/Users/user/.local/bin/agy"), .agy)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/bin/agy"), .agy)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "agy"), .agy)

        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"), .cursor)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/usr/local/bin/cursor"), .cursor)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "cursor"), .cursor)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/Users/user/.local/bin/cursor-agent"), .cursor)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/Users/user/.local/share/cursor-agent/versions/2026.09.08/node"), .cursor)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "cursor-agent"), .cursor)

        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/bin/codex"), .codex)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "codex"), .codex)

        XCTAssertNil(ProcessSnooper.detectAgent(inPath: "/bin/zsh"))
        XCTAssertNil(ProcessSnooper.detectAgent(inPath: "/usr/bin/git"))
        XCTAssertNil(ProcessSnooper.detectAgent(inPath: "/usr/bin/vim"))
        XCTAssertNil(ProcessSnooper.detectAgent(inPath: ""))
    }

    func testProcessTreeInspectionReturnsNilForEmptyChildren() {
        // PID 0 (kernel task) or invalid negative PID has no child agent
        XCTAssertNil(ProcessSnooper.detectAgent(inProcessTreeOf: -1))
    }

    func testParentPidOfSelfMatchesGetppid() {
        XCTAssertEqual(ProcessSnooper.parentPid(of: getpid()), getppid())
        XCTAssertNil(ProcessSnooper.parentPid(of: -1))
    }

    func testDetectAgentInAncestorsRespectsDepthAndInvalidPid() {
        XCTAssertNil(ProcessSnooper.detectAgent(inAncestorsOf: -1))
        XCTAssertNil(ProcessSnooper.detectAgent(inAncestorsOf: getpid(), maxDepth: 0))
        // With a real depth this either finds a CLI (when run inside one) or returns nil; it must not crash.
        _ = ProcessSnooper.detectAgent(inAncestorsOf: getpid())
    }

    // MARK: - KERN_PROCARGS2 parsing (synthetic buffers, no live process reads)

    /// Builds a buffer shaped like the kernel's own `KERN_PROCARGS2` reply: argc, the exec path,
    /// padding, argv, then the environment — the exact layout `parseProcArgs2` must walk.
    private func procArgs2Buffer(argv: [String], execPath: String, env: [String], paddingBytes: Int = 0) -> [UInt8] {
        var bytes: [UInt8] = []
        var argc = Int32(argv.count)
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(execPath.utf8))
        bytes.append(0)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: paddingBytes))
        for arg in argv {
            bytes.append(contentsOf: Array(arg.utf8))
            bytes.append(0)
        }
        for entry in env {
            bytes.append(contentsOf: Array(entry.utf8))
            bytes.append(0)
        }
        return bytes
    }

    func testParseProcArgs2ExtractsEnvironmentPastArgvAndPadding() {
        let buffer = procArgs2Buffer(
            argv: ["env", "sh"],
            execPath: "/usr/bin/env",
            env: ["PATH=/usr/bin", "LINKC_SESSION=probe-123"],
            paddingBytes: 3
        )
        let env = ProcessSnooper.parseProcArgs2(buffer)
        XCTAssertEqual(env["LINKC_SESSION"], "probe-123")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    /// A value may itself contain '=' — only the first one separates the name from the value.
    func testParseProcArgs2SplitsOnlyOnTheFirstEqualsSign() {
        let buffer = procArgs2Buffer(argv: ["x"], execPath: "/bin/x", env: ["FOO=bar=baz"])
        XCTAssertEqual(ProcessSnooper.parseProcArgs2(buffer)["FOO"], "bar=baz")
    }

    /// An empty string in the environment region marks the end; anything after it is not argv or
    /// environment data and must not be read as such.
    func testParseProcArgs2StopsAtTheFirstEmptyEnvironmentEntry() {
        var buffer = procArgs2Buffer(argv: ["x"], execPath: "/bin/x", env: ["A=1"])
        buffer.append(0) // an empty string right after A=1's terminator
        buffer.append(contentsOf: Array("B=2\0".utf8)) // must never be reached
        XCTAssertEqual(ProcessSnooper.parseProcArgs2(buffer), ["A": "1"])
    }

    func testParseProcArgs2OnATooShortBufferReturnsEmpty() {
        XCTAssertEqual(ProcessSnooper.parseProcArgs2([]), [:])
        XCTAssertEqual(ProcessSnooper.parseProcArgs2([1, 2]), [:])
    }
}
