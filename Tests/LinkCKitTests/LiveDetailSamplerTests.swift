import XCTest
@testable import LinkCKit

final class LiveDetailSamplerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-sampler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private struct Fixed: SessionLiveReader {
        let detail: SessionLiveDetail
        func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail { detail }
    }

    private struct Failing: SessionLiveReader {
        struct Broken: Error, CustomStringConvertible { var description: String { "the record is torn" } }
        func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail { throw Broken() }
    }

    /// Records what the reader was handed.
    private final class Recording: SessionLiveReader, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [LiveSessionTarget] = []
        var targets: [LiveSessionTarget] { lock.lock(); defer { lock.unlock() }; return stored }
        func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
            lock.lock(); stored.append(target); lock.unlock()
            return SessionLiveDetail()
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func session(_ id: String, _ agent: AgentKind, agentSessionId: String? = nil) -> LiveDetailSampler.Session {
        LiveDetailSampler.Session(id: id, agent: agent, cwd: "/p", agentSessionId: agentSessionId, pid: nil)
    }

    func testEachSessionGetsWhatItsAgentsReaderReads() async {
        let sampler = LiveDetailSampler(readers: [.codex: Fixed(detail: SessionLiveDetail(contextPercent: 40, step: "$ ls"))])

        await sampler.refresh([session("S1", .codex), session("S2", .agy)])?.value

        XCTAssertEqual(sampler.detail(for: "S1"), SessionLiveDetail(contextPercent: 40, step: "$ ls"))
        XCTAssertNil(sampler.detail(for: "S2"), "an agent with no reader is not read")
    }

    /// The reader learns the agent's own conversation id linkC holds.
    func testTheReaderIsHandedTheAgentsOwnSessionId() async {
        let recording = Recording()
        let sampler = LiveDetailSampler(readers: [.opencode: recording])

        await sampler.refresh([session("S1", .opencode, agentSessionId: "ses_made_up")])?.value

        XCTAssertEqual(recording.targets.map(\.agentSessionId), ["ses_made_up"])
        XCTAssertEqual(recording.targets.map(\.sessionId), ["S1"])
    }

    /// A record that cannot be read leaves no stale figure and is said once, not on every read.
    func testAFailedReadDropsTheDetailAndIsSaidOnce() async {
        let logged = Lines()
        let sampler = LiveDetailSampler(readers: [.codex: Failing()], log: { logged.append($0) })

        await sampler.refresh([session("S1", .codex)])?.value
        await sampler.refresh([session("S1", .codex)])?.value

        XCTAssertNil(sampler.detail(for: "S1"))
        XCTAssertEqual(logged.all.count, 1)
        XCTAssertEqual(logged.all.first?.contains("the record is torn"), true)
    }

    /// Reads, then fails: a figure from before the failure is not kept as if it were current.
    private final class ThenFailing: SessionLiveReader, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
            lock.lock(); reads += 1; let first = reads == 1; lock.unlock()
            if first { return SessionLiveDetail(contextPercent: 55) }
            throw Failing.Broken()
        }
    }

    func testAFailureAfterAGoodReadDropsTheGoodFigure() async {
        let sampler = LiveDetailSampler(readers: [.codex: ThenFailing()], log: { _ in })
        await sampler.refresh([session("S1", .codex)])?.value
        XCTAssertEqual(sampler.detail(for: "S1")?.contextPercent, 55)

        await sampler.refresh([session("S1", .codex)])?.value

        XCTAssertNil(sampler.detail(for: "S1"))
    }

    /// Records where each read ran.
    private final class WhereItRan: SessionLiveReader, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        var onReadQueue: [Bool] { lock.lock(); defer { lock.unlock() }; return stored }
        func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
            let here = LiveDetailSampler.isOnReadQueue
            lock.lock(); stored.append(here); lock.unlock()
            return SessionLiveDetail()
        }
    }

    /// A read blocks on sqlite3 and on files: it runs on the sampler's own serial queue, never on a
    /// thread of the Swift concurrency pool, which it would tie up.
    func testReadsRunOnTheSamplersOwnQueue() async {
        let reader = WhereItRan()
        let sampler = LiveDetailSampler(readers: [.codex: reader])

        await sampler.refresh([session("S1", .codex), session("S2", .codex)])?.value

        XCTAssertEqual(reader.onReadQueue, [true, true])
        XCTAssertFalse(LiveDetailSampler.isOnReadQueue)
    }

    /// A clock the test moves.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return stored }
        func advance(minutes: Double) { advance(seconds: minutes * 60) }
        func advance(seconds: Double) { lock.lock(); stored += seconds; lock.unlock() }
    }

    /// Fails with the reason it is given, or reads when it has none.
    private final class Flapping: SessionLiveReader, @unchecked Sendable {
        struct Broken: Error, CustomStringConvertible { let description: String }
        private let lock = NSLock()
        private var reason: String?
        func fail(_ reason: String?) { lock.lock(); self.reason = reason; lock.unlock() }
        func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
            lock.lock(); let reason = reason; lock.unlock()
            if let reason { throw Broken(description: reason) }
            return SessionLiveDetail(contextPercent: 10)
        }
    }

    /// A failure that comes and goes is said again only when it changes, or once ten minutes have
    /// passed since it was said; a read that works in between does not make it new.
    func testAFailureThatComesAndGoesIsSaidAgainOnlyWhenItChangesOrTenMinutesPass() async {
        let logged = Lines()
        let clock = Clock()
        let reader = Flapping()
        let sampler = LiveDetailSampler(readers: [.codex: reader], log: { logged.append($0) }, now: { clock.now })
        func pass(_ reason: String?) async {
            reader.fail(reason)
            await sampler.refresh([session("S1", .codex)])?.value
        }

        await pass("torn")
        await pass(nil)
        await pass("torn")
        clock.advance(minutes: 9)
        await pass(nil)
        await pass("torn")
        XCTAssertEqual(logged.all.count, 1, logged.all.joined(separator: "\n"))

        await pass("gone")
        await pass("torn")
        XCTAssertEqual(logged.all.count, 3, "a different failure is said")

        clock.advance(minutes: 10)
        await pass("torn")
        XCTAssertEqual(logged.all.count, 4, "ten minutes on, the same failure is said again")
    }

    /// Counts the process trees looked into, and says each holds one made-up file.
    private final class Trees: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [pid_t] = []
        var looked: [pid_t] { lock.lock(); defer { lock.unlock() }; return stored }
        func openFiles(_ pid: pid_t) -> [String] {
            lock.lock(); stored.append(pid); lock.unlock()
            return ["/made/up/open-\(pid)"]
        }
    }

    private func session(_ id: String, _ agent: AgentKind, pid: pid_t) -> LiveDetailSampler.Session {
        LiveDetailSampler.Session(id: id, agent: agent, cwd: "/p", agentSessionId: nil, pid: pid)
    }

    /// The reader is handed the files its session's process tree holds open.
    func testTheReaderIsHandedTheFilesItsSessionsProcessTreeHoldsOpen() async {
        let trees = Trees()
        let recording = Recording()
        let sampler = LiveDetailSampler(readers: [.codex: recording], openFiles: { trees.openFiles($0) })

        await sampler.refresh([session("S1", .codex, pid: 41)])?.value

        XCTAssertEqual(recording.targets.map(\.openFiles), [["/made/up/open-41"]])
    }

    /// Listing a process tree's open files asks the kernel about every file of every process in it:
    /// it is done at most every ten seconds for a session, and at once for a new process.
    func testASessionsProcessTreeIsLookedIntoAtMostEveryTenSeconds() async {
        let trees = Trees()
        let clock = Clock()
        let recording = Recording()
        let sampler = LiveDetailSampler(readers: [.codex: recording], now: { clock.now }, openFiles: { trees.openFiles($0) })

        await sampler.refresh([session("S1", .codex, pid: 41)])?.value
        clock.advance(seconds: 9)
        await sampler.refresh([session("S1", .codex, pid: 41)])?.value
        XCTAssertEqual(trees.looked, [41])
        XCTAssertEqual(recording.targets.map(\.openFiles), [["/made/up/open-41"], ["/made/up/open-41"]])

        clock.advance(seconds: 1)
        await sampler.refresh([session("S1", .codex, pid: 41)])?.value
        XCTAssertEqual(trees.looked, [41, 41])

        await sampler.refresh([session("S1", .codex, pid: 42)])?.value
        XCTAssertEqual(trees.looked, [41, 41, 42])
    }

    /// OpenCode is found by the conversation id linkC passes it, never by an open file: its
    /// session's process tree is not looked into.
    func testAReaderThatUsesNoOpenFileHasNoProcessTreeLookedInto() async {
        let trees = Trees()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-none-\(UUID().uuidString)")
        let reader = OpenCodeLiveReader(database: missing.appendingPathComponent("opencode.db"), modelsFile: missing.appendingPathComponent("models.json"))
        let sampler = LiveDetailSampler(readers: [.opencode: reader], openFiles: { trees.openFiles($0) })

        await sampler.refresh([session("S1", .opencode, pid: 41)])?.value

        XCTAssertEqual(trees.looked, [])
    }

    // MARK: - Reading only what changed

    /// Names one file as what it reads, and counts its reads; the figure is the count.
    private final class Counting: SessionLiveReader, @unchecked Sendable {
        struct Broken: Error {}
        private let file: String
        private let lock = NSLock()
        private var count = 0
        private var failing = false
        init(file: String) { self.file = file }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
        func failNext() { lock.lock(); failing = true; lock.unlock() }
        func sources(of target: LiveSessionTarget) throws -> [String] { [file] }
        func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if failing { failing = false; throw Broken() }
            return SessionLiveDetail(contextPercent: count)
        }
    }

    private func record(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("made-up-record")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// The sweep asks every second: a record whose size, modification time and inode are as they
    /// were is not read again, and its last figure stands.
    func testARecordThatHasNotChangedIsNotReadAgain() async throws {
        let url = try record("one")
        let reader = Counting(file: url.path)
        let sampler = LiveDetailSampler(readers: [.codex: reader], log: { _ in })

        await sampler.refresh([session("S1", .codex)])?.value
        await sampler.refresh([session("S1", .codex)])?.value
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(sampler.detail(for: "S1")?.contextPercent, 1)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" two".utf8))
        try handle.close()
        await sampler.refresh([session("S1", .codex)])?.value
        XCTAssertEqual(reader.reads, 2)
        XCTAssertEqual(sampler.detail(for: "S1")?.contextPercent, 2)

        try FileManager.default.removeItem(at: url)
        await sampler.refresh([session("S1", .codex)])?.value
        XCTAssertEqual(reader.reads, 3, "a record that went is a change")
    }

    func testASessionWhoseTargetChangedIsReadAgain() async throws {
        let reader = Counting(file: try record("one").path)
        let sampler = LiveDetailSampler(readers: [.opencode: reader])

        await sampler.refresh([session("S1", .opencode, agentSessionId: "ses_one")])?.value
        await sampler.refresh([session("S1", .opencode, agentSessionId: "ses_two")])?.value

        XCTAssertEqual(reader.reads, 2)
    }

    /// A read that failed is tried again on the next pass, though its record has not changed.
    func testAReadThatFailedIsDoneAgain() async throws {
        let reader = Counting(file: try record("one").path)
        reader.failNext()
        let sampler = LiveDetailSampler(readers: [.codex: reader], log: { _ in })

        await sampler.refresh([session("S1", .codex)])?.value
        await sampler.refresh([session("S1", .codex)])?.value

        XCTAssertEqual(reader.reads, 2)
        XCTAssertEqual(sampler.detail(for: "S1")?.contextPercent, 2)
    }

    /// A reader that names no file, as one that found no record does, is read every pass.
    func testAReaderThatNamesNoFileIsReadEveryPass() async {
        let recording = Recording()
        let sampler = LiveDetailSampler(readers: [.codex: recording])

        await sampler.refresh([session("S1", .codex)])?.value
        await sampler.refresh([session("S1", .codex)])?.value

        XCTAssertEqual(recording.targets.count, 2)
    }

    /// An ended session's detail goes with it.
    func testASessionNoLongerLiveIsForgotten() async {
        let sampler = LiveDetailSampler(readers: [.codex: Fixed(detail: SessionLiveDetail(contextPercent: 1))])
        await sampler.refresh([session("S1", .codex)])?.value

        await sampler.refresh([])?.value

        XCTAssertNil(sampler.detail(for: "S1"))
    }
}
