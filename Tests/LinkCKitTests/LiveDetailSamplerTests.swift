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

    /// An ended session's detail goes with it.
    func testASessionNoLongerLiveIsForgotten() async {
        let sampler = LiveDetailSampler(readers: [.codex: Fixed(detail: SessionLiveDetail(contextPercent: 1))])
        await sampler.refresh([session("S1", .codex)])?.value

        await sampler.refresh([])?.value

        XCTAssertNil(sampler.detail(for: "S1"))
    }
}
