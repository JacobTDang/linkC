import XCTest
@testable import LinkCKit

/// Classifying a probe: a service that ANSWERS is alive, even when it answers 401 —
/// verified against the live Supabase API, where an unauthenticated health call returns
/// 401 in ~0.2s and a paused project doesn't resolve at all.
final class HealthStatusTests: XCTestCase {

    func testAnyAnswerMeansAlive() {
        XCTAssertEqual(HealthStatus.classify(code: 200, latency: 0.14), .ok(200, 0.14))
        XCTAssertEqual(HealthStatus.classify(code: 401, latency: 0.22), .ok(401, 0.22),
                       "401 proves the API is reachable — credentials aren't the question")
        XCTAssertEqual(HealthStatus.classify(code: 308, latency: 0.03), .ok(308, 0.03))
    }

    func testServerErrorsAreDegradedNotDead() {
        XCTAssertEqual(HealthStatus.classify(code: 502, latency: 1.2), .degraded(502, 1.2))
        XCTAssertEqual(HealthStatus.classify(code: 500, latency: 0.9), .degraded(500, 0.9))
    }

    func testShortLabels() {
        XCTAssertEqual(HealthStatus.ok(200, 0.142).shortLabel, "142ms")
        XCTAssertEqual(HealthStatus.degraded(502, 1.2).shortLabel, "502")
        XCTAssertEqual(HealthStatus.down("timed out").shortLabel, "down")
        XCTAssertEqual(HealthStatus.unknown.shortLabel, "—")
        XCTAssertTrue(HealthStatus.ok(200, 0.142).isUp)
        XCTAssertFalse(HealthStatus.down("x").isUp)
    }
}

/// Notifications fire on CHANGE, never on repetition — a service that has been down for
/// an hour must not re-alert every 30 seconds, and the first check (unknown → anything)
/// establishes a baseline rather than announcing it.
final class HealthTransitionTests: XCTestCase {

    private let endpoint = WatchedEndpoint(id: "e1", label: "audio-1", url: URL(string: "https://x.test")!)

    func testFirstCheckIsSilent() {
        let changes = HealthTransitions.changes(
            from: [:], to: ["e1": .down("refused")], endpoints: [endpoint]
        )
        XCTAssertTrue(changes.isEmpty, "the first observation is a baseline, not news")
    }

    func testGoingDownAndComingBackBothNotify() {
        let down = HealthTransitions.changes(
            from: ["e1": .ok(200, 0.1)], to: ["e1": .down("refused")], endpoints: [endpoint]
        )
        XCTAssertEqual(down.count, 1)
        XCTAssertTrue(down[0].body.contains("not responding"))
        XCTAssertEqual(down[0].endpointId, "e1")

        let up = HealthTransitions.changes(
            from: ["e1": .down("refused")], to: ["e1": .ok(200, 0.1)], endpoints: [endpoint]
        )
        XCTAssertEqual(up.count, 1)
        XCTAssertTrue(up[0].body.contains("back"))
    }

    func testStayingDownIsSilent() {
        let changes = HealthTransitions.changes(
            from: ["e1": .down("refused")], to: ["e1": .down("timed out")], endpoints: [endpoint]
        )
        XCTAssertTrue(changes.isEmpty, "an ongoing outage must not re-alert every tick")
    }

    func testLatencyDriftIsSilent() {
        let changes = HealthTransitions.changes(
            from: ["e1": .ok(200, 0.10)], to: ["e1": .ok(200, 0.95)], endpoints: [endpoint]
        )
        XCTAssertTrue(changes.isEmpty, "slower is not an event")
    }

    func testDegradedIsWorthKnowing() {
        let changes = HealthTransitions.changes(
            from: ["e1": .ok(200, 0.1)], to: ["e1": .degraded(502, 0.4)], endpoints: [endpoint]
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].body.contains("502"))
    }
}

/// Supabase endpoints need no configuration: the health URL derives from the project ref.
final class SupabaseHealthURLTests: XCTestCase {

    func testHealthURLDerivedFromRef() {
        let project = SupabaseProject(
            id: "ksqjgsezfqfevnfvonnm", name: "june", region: "ca-central-1",
            status: "ACTIVE_HEALTHY"
        )
        XCTAssertEqual(
            project.healthURL?.absoluteString,
            "https://ksqjgsezfqfevnfvonnm.supabase.co/auth/v1/health"
        )
    }

    /// A paused project's hostname doesn't even resolve — checking it would report a
    /// scary "down" for a state the row already explains as "paused".
    func testPausedProjectIsNotProbed() {
        let paused = SupabaseProject(
            id: "abc", name: "Sprout", region: "us-west-2", status: "INACTIVE"
        )
        XCTAssertNil(paused.healthURL, "paused is a known state, not an outage")
    }
}

/// The monitor over a fake probe: concurrent checks, statuses recorded, transitions
/// reported once.
@MainActor
final class HealthMonitorTests: XCTestCase {

    private func endpoints() -> [WatchedEndpoint] {
        [
            WatchedEndpoint(id: "a", label: "mp3", url: URL(string: "https://a.test")!),
            WatchedEndpoint(id: "b", label: "june", url: URL(string: "https://b.test")!),
        ]
    }

    func testChecksEveryEndpointAndRecordsStatus() async {
        let probe = FakeProbe(answers: [
            "https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.12)),
            "https://b.test": .success(ProbeResult(statusCode: 401, latency: 0.22)),
        ])
        let monitor = HealthMonitor(probe: probe)

        let changes = await monitor.check(endpoints())

        XCTAssertEqual(monitor.status(of: "a"), .ok(200, 0.12))
        XCTAssertEqual(monitor.status(of: "b"), .ok(401, 0.22))
        XCTAssertTrue(changes.isEmpty, "first pass is a baseline")
    }

    func testFailureBecomesDownAndReportsOnce() async {
        let probe = FakeProbe(answers: [
            "https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.12)),
            "https://b.test": .success(ProbeResult(statusCode: 200, latency: 0.12)),
        ])
        let monitor = HealthMonitor(probe: probe)
        _ = await monitor.check(endpoints())

        probe.setAnswer("https://a.test", .failure(URLError(.cannotConnectToHost)))
        let first = await monitor.check(endpoints())
        XCTAssertEqual(first.count, 1, "the outage is announced once")
        XCTAssertFalse(monitor.status(of: "a")?.isUp ?? true)

        let second = await monitor.check(endpoints())
        XCTAssertTrue(second.isEmpty, "and not again on the next tick")
    }
}

/// Answers per URL so a test can flip one endpoint without disturbing the other.
final class FakeProbe: EndpointProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<ProbeResult, Error>]

    init(answers: [String: Result<ProbeResult, Error>]) { self.answers = answers }

    func setAnswer(_ url: String, _ answer: Result<ProbeResult, Error>) {
        lock.withLock { answers[url] = answer }
    }

    func probe(_ url: URL, timeout: TimeInterval) async throws -> ProbeResult {
        let answer = lock.withLock { answers[url.absoluteString] }
        guard let answer else { throw URLError(.badURL) }
        return try answer.get()
    }
}
