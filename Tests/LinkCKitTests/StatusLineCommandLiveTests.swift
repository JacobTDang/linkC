import XCTest
@testable import LinkCKit

/// Runs the exact command string linkC gives Claude as its status line, through the same
/// `/bin/sh -c` the CLI runs it with (observed with the real CLI: a status line is started as
/// `/bin/sh -c <command>` with the status JSON piped to stdin), and checks what it does.
final class StatusLineCommandLiveTests: XCTestCase {
    /// A status JSON like the real CLI's: one line with its line end, rate limits present.
    private let sample = #"{"session_id":"b9fa","cwd":"/Users/x/It's here","model":{"display_name":"Opus"},"cost":{"total_cost_usd":0.24},"rate_limits":{"five_hour":{"used_percentage":36,"resets_at":1790713200},"seven_day":{"used_percentage":13,"resets_at":1791226800}}}"#

    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("it's a session.line") }
    private var command: String { SettingsComposer.statusLineCommand(writingTo: file) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: file)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// The shells a `sh -c` can be on this system. `/bin/sh` is what the CLI uses; the rest prove the
    /// command is plain POSIX rather than something one shell happens to accept.
    private let shells = ["/bin/sh", "/bin/bash", "/bin/dash", "/bin/zsh"]

    /// Forbids any process to be forked and any program but a shell to be executed inside the shell it
    /// starts: a command that finishes here spawned nothing. (`/bin/sh` re-executes itself as
    /// `/bin/bash` on macOS, so the shells themselves must stay executable.)
    private let noSpawnProfile = """
        (version 1)(allow default)(deny process-fork)(deny process-exec*)\
        (allow process-exec (literal "/bin/sh") (literal "/bin/bash") (literal "/bin/dash") (literal "/bin/zsh"))
        """

    private func run(_ script: String, shell: String = "/bin/sh", stdin: Data, forbiddingSpawns: Bool = false) throws -> Run {
        let process = Process()
        if forbiddingSpawns {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", noSpawnProfile, shell, "-c", script]
        } else {
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", script]
        }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }

    private func written() throws -> String {
        String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    func testTheCommandWritesTheStatusLineIntoTheFileAndPrintsNothing() throws {
        let result = try run(command, stdin: Data((sample + "\n").utf8))

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "", "a status line that prints anything shows up as a status row")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(try written(), sample + "\n")
    }

    /// The file is what `StatusLineFile` reads, so the two halves must agree on the bytes.
    func testWhatTheCommandWritesIsAReportTheReaderAccepts() throws {
        _ = try run(command, stdin: Data((sample + "\n").utf8))

        guard case .report(let body, let reading) = StatusLineFile.read(at: file, receivedAt: Date()) else {
            return XCTFail("the reader must take what the command wrote")
        }
        XCTAssertEqual(body, Data(sample.utf8))
        XCTAssertEqual(reading?.windows.map(\.usedPercent), [36, 13])
    }

    /// The whole point: no `curl`, no other program, no fork. Under a profile that forbids both, the
    /// command still finishes and still writes.
    func testTheCommandSpawnsNothingBeyondTheShell() throws {
        for shell in shells {
            try Data().write(to: file)
            let result = try run(command, shell: shell, stdin: Data((sample + "\n").utf8), forbiddingSpawns: true)

            XCTAssertEqual(result.status, 0, "\(shell): \(result.stderr)")
            XCTAssertEqual(try written(), sample + "\n", "\(shell) must still deliver the report with every spawn forbidden")
        }
    }

    /// Proves the check above can fail: the command this replaces, and any command that starts another
    /// program, cannot finish under the same profile.
    func testTheSpawnCheckCatchesACommandThatStartsAProgram() throws {
        let old = "curl -s -m 2 -X POST -H 'X-LinkC-Token: t' -H 'X-LinkC-Event: status_line' --data-binary @- http://127.0.0.1:9/hook >/dev/null"
        let replaced = try run(old, stdin: Data((sample + "\n").utf8), forbiddingSpawns: true)
        XCTAssertNotEqual(replaced.status, 0, "curl must not get to run with spawns forbidden")

        let cat = try run("cat >'\(file.path)'", stdin: Data((sample + "\n").utf8), forbiddingSpawns: true)
        XCTAssertNotEqual(cat.status, 0, "any other program must be caught too")
        XCTAssertEqual(try written(), "", "and nothing may have been written")
    }

    func testEveryShellWritesTheSameBytes() throws {
        for shell in shells {
            try Data().write(to: file)
            let result = try run(command, shell: shell, stdin: Data((sample + "\n").utf8))

            XCTAssertEqual(result.status, 0, shell)
            XCTAssertEqual(result.stdout + result.stderr, "", shell)
            XCTAssertEqual(try written(), sample + "\n", shell)
        }
    }

    func testAReportWithNoLineEndIsStillWrittenWithOne() throws {
        let result = try run(command, stdin: Data(sample.utf8))

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try written(), sample + "\n", "the reader needs the line end to tell a whole line from a torn one")
    }

    /// Backslashes, quotes and shell metacharacters in the JSON are data, not shell.
    func testTheReportIsWrittenVerbatim() throws {
        let tricky = #"{"a":"x\\ny \"q\" é $HOME `id` $(id) *","rate_limits":{}}"#
        _ = try run(command, stdin: Data((tricky + "\n").utf8))

        XCTAssertEqual(try written(), tricky + "\n")
    }

    /// Empty input is not a report: it must not blank the last good one.
    func testNothingOnStdinLeavesTheLastReportAlone() throws {
        _ = try run(command, stdin: Data((sample + "\n").utf8))

        let result = try run(command, stdin: Data())

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try written(), sample + "\n")
    }

    /// The command must never fail a turn or print into the status area, whatever is wrong with the
    /// file: a status refresh that cannot be delivered is the feed's to report, not the CLI's.
    func testAnUnwritableFileIsSilent() throws {
        let gone = SettingsComposer.statusLineCommand(writingTo: folder.appendingPathComponent("no-such-folder/x.line"))

        let result = try run(gone, stdin: Data((sample + "\n").utf8))

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }

    /// A CLI that closed stdin without sending anything, or one that sends a report and keeps the
    /// pipe open, must not leave the command waiting for the other side.
    func testTheCommandReturnsAsSoonAsItHasTheLine() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data((sample + "\n").utf8))   // and the pipe stays open

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let finished = !process.isRunning
        if !finished { process.terminate() }
        try? input.fileHandleForWriting.close()

        XCTAssertTrue(finished, "the command must not wait for the CLI to close its end")
        XCTAssertEqual(try written(), sample + "\n")
    }
}
