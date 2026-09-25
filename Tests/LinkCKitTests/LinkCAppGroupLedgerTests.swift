import XCTest
@testable import LinkCKit

/// The ledger of app process groups linkC started and hasn't seen stop — real child processes,
/// like `LinkCAppProcessTests`, so the record/stop-leftovers round trip is exercised for real.
final class LinkCAppGroupLedgerTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func groupIsGone(_ group: pid_t) -> Bool {
        kill(-group, 0) == -1 && errno == ESRCH
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition never became true") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // `FileHandle.nullDevice.fileDescriptor` is -1 (a discard sentinel, not a real fd) — open
    // `/dev/null` directly and hold it for the test's lifetime.
    nonisolated(unsafe) private var devNull: FileHandle!

    private func spawnGroup(_ executable: String, _ args: [String]) throws -> pid_t {
        if devNull == nil { devNull = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null")) }
        return try LiveProcessRunner.spawnGroupLeader(
            executable: executable, args: args, cwd: folder,
            stdout: devNull.fileDescriptor, stderr: devNull.fileDescriptor)
    }

    /// In production, a leftover's real parent (the crashed linkC) is gone, so the kernel
    /// reparents it to launchd, which reaps it automatically. Here the test itself is the direct
    /// parent, so it must reap it the same way — otherwise a killed child lingers as a zombie
    /// (which still answers `kill(pid, 0)`) and `groupIsGone` would never see it as gone.
    private func reapInBackground(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    /// A group recorded by one launch is stopped by the ledger a fresh launch builds on the same
    /// directory — the crash/force-quit recovery path.
    func testALeftoverGroupIsStoppedOnTheNextLaunch() async throws {
        let pid = try spawnGroup("/bin/sleep", ["300"])
        reapInBackground(pid)
        let ledger = LinkCAppGroupLedger(directory: folder)
        ledger.record(pid)

        let nextLaunch = LinkCAppGroupLedger(directory: folder)
        nextLaunch.stopLeftovers(grace: 0.5)

        try await waitUntil(2) { self.groupIsGone(pid) }
        kill(-pid, SIGKILL) // belt and suspenders: never leave `sleep 300` behind on a red run
        XCTAssertTrue(nextLaunch.load().isEmpty, "the file is cleared once leftovers are handled")
    }

    /// A pid the system reused since the entry was recorded must never be signalled — the ledger
    /// exists exactly to protect against that. This spawns its own throwaway process; it must
    /// NEVER pass the test runner's own pid here. Deliberately a plain `sleep` (no TERM trap): if
    /// the ledger wrongly signalled it, it would die right away instead of surviving to the
    /// SIGKILL fallback, which would otherwise mask a real bug here.
    func testAnEntryWithAWrongStartTimeIsNotSignalled() async throws {
        let pid = try spawnGroup("/bin/sleep", ["300"])
        reapInBackground(pid)
        let ledger = LinkCAppGroupLedger(directory: folder)
        ledger.recordForTesting(pgid: pid, startSeconds: 1, startMicros: 0) // deliberately wrong

        ledger.stopLeftovers(grace: 0.3)

        XCTAssertEqual(kill(pid, 0), 0, "a mismatched start time must never be signalled")
        kill(-pid, SIGKILL)
    }

    /// An entry whose pid is gone by the next launch is dropped with no signal sent at all.
    func testAnEntryWhosePidIsGoneIsDroppedQuietly() throws {
        let pid = try spawnGroup("/bin/sh", ["-c", "exit 0"])
        var status: Int32 = 0
        waitpid(pid, &status, 0) // let it exit and reap it — genuinely gone

        let ledger = LinkCAppGroupLedger(directory: folder)
        ledger.recordForTesting(pgid: pid, startSeconds: 1, startMicros: 0)
        ledger.stopLeftovers(grace: 0.3)

        XCTAssertTrue(ledger.load().isEmpty)
    }
}
