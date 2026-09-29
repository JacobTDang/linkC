import XCTest
@testable import LinkCKit

/// When the process tree is walked to find which agent runs in a terminal. Each walk is a
/// `proc_listpids` and a `proc_pidpath` per process, and it used to run for every session, every second.
final class ForegroundAgentSamplerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Answers every probe with `agent` and counts how many were made.
    private final class Probe {
        var agent: AgentKind?
        var calls = 0
        init(_ agent: AgentKind?) { self.agent = agent }
        func run() -> AgentKind? { calls += 1; return agent }
    }

    func testTheFirstSampleProbes() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(.codex)

        XCTAssertEqual(sampler.sample(foreground: 100, now: start, probe: probe.run), .codex)
        XCTAssertEqual(probe.calls, 1)
    }

    func testAnUnchangedForegroundKeepsTheAnswerWithoutProbing() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(.codex)
        _ = sampler.sample(foreground: 100, now: start, probe: probe.run)

        for second in 1...9 {
            XCTAssertEqual(sampler.sample(foreground: 100, now: start.addingTimeInterval(TimeInterval(second)), probe: probe.run), .codex)
        }

        XCTAssertEqual(probe.calls, 1)
    }

    func testAnAnswerOfNoAgentIsKeptToo() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(nil)

        for second in 0..<5 {
            XCTAssertNil(sampler.sample(foreground: 100, now: start.addingTimeInterval(TimeInterval(second)), probe: probe.run))
        }

        XCTAssertEqual(probe.calls, 1, "a busy shell with no agent is the case the walk was costing most")
    }

    func testAForegroundThatMovedProbesAtOnce() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(nil)
        _ = sampler.sample(foreground: 100, now: start, probe: probe.run)

        probe.agent = .agy
        XCTAssertEqual(sampler.sample(foreground: 200, now: start.addingTimeInterval(1), probe: probe.run), .agy)

        XCTAssertEqual(probe.calls, 2, "a new command, or an agent starting, is seen on the next sample")
    }

    func testTheAnswerExpiresAfterTheReprobeInterval() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(.codex)
        _ = sampler.sample(foreground: 100, now: start, probe: probe.run)

        _ = sampler.sample(foreground: 100, now: start.addingTimeInterval(ForegroundAgentSampler.reprobeInterval - 0.1), probe: probe.run)
        XCTAssertEqual(probe.calls, 1)

        probe.agent = .cursor
        XCTAssertEqual(
            sampler.sample(foreground: 100, now: start.addingTimeInterval(ForegroundAgentSampler.reprobeInterval), probe: probe.run),
            .cursor,
            "a wrapper that execs another agent keeps its process group, so only the timer can find it"
        )
        XCTAssertEqual(probe.calls, 2)
    }

    func testAnUnreadableForegroundLeavesOnlyTheTimer() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(.codex)

        for second in 0..<10 {
            _ = sampler.sample(foreground: nil, now: start.addingTimeInterval(TimeInterval(second)), probe: probe.run)
        }
        XCTAssertEqual(probe.calls, 1)

        _ = sampler.sample(foreground: nil, now: start.addingTimeInterval(10), probe: probe.run)
        XCTAssertEqual(probe.calls, 2)
    }

    func testForgettingTheAnswerProbesOnTheNextSample() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(.codex)
        _ = sampler.sample(foreground: 100, now: start, probe: probe.run)

        sampler.forget()
        _ = sampler.sample(foreground: 100, now: start.addingTimeInterval(1), probe: probe.run)

        XCTAssertEqual(probe.calls, 2)
    }

    func testAClockThatWentBackwardsProbesAgain() {
        var sampler = ForegroundAgentSampler()
        let probe = Probe(.codex)
        _ = sampler.sample(foreground: 100, now: start, probe: probe.run)

        _ = sampler.sample(foreground: 100, now: start.addingTimeInterval(-60), probe: probe.run)

        XCTAssertEqual(probe.calls, 2, "an answer of unknowable age is not kept")
    }
}
