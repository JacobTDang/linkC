import XCTest
@testable import LinkCKit

final class LiveDetailSamplerTests: XCTestCase {
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
        func advance(minutes: Double) { lock.lock(); stored += minutes * 60; lock.unlock() }
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

    /// An ended session's detail goes with it.
    func testASessionNoLongerLiveIsForgotten() async {
        let sampler = LiveDetailSampler(readers: [.codex: Fixed(detail: SessionLiveDetail(contextPercent: 1))])
        await sampler.refresh([session("S1", .codex)])?.value

        await sampler.refresh([])?.value

        XCTAssertNil(sampler.detail(for: "S1"))
    }
}
