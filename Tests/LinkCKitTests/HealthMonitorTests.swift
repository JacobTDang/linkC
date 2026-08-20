import XCTest
@testable import LinkCKit

/// A down status with a chosen label, for tests about transitions rather than about how a
/// failure is classified.
private func down(_ label: String) -> HealthStatus {
    .down(DownReason(label: label, detail: "\(label) (test)"))
}

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
        XCTAssertEqual(down("timeout").shortLabel, "timeout",
                       "the row names the failure instead of just calling it down")
        XCTAssertEqual(HealthStatus.unknown.shortLabel, "—")
        XCTAssertTrue(HealthStatus.ok(200, 0.142).isUp)
        XCTAssertFalse(down("dns").isUp)
    }
}

/// Notifications fire on CHANGE, never on repetition — a service that has been down for
/// an hour must not re-alert every 30 seconds, and the first check (unknown → anything)
/// establishes a baseline rather than announcing it.
final class HealthTransitionTests: XCTestCase {

    private let endpoint = WatchedEndpoint(id: "e1", label: "audio-1", url: URL(string: "https://x.test")!)

    func testFirstCheckIsSilent() {
        let changes = HealthTransitions.changes(
            from: [:], to: ["e1": down("refused")], endpoints: [endpoint]
        )
        XCTAssertTrue(changes.isEmpty, "the first observation is a baseline, not news")
    }

    func testGoingDownAndComingBackBothNotify() {
        let lost = HealthTransitions.changes(
            from: ["e1": .ok(200, 0.1)], to: ["e1": down("refused")], endpoints: [endpoint]
        )
        XCTAssertEqual(lost.count, 1)
        XCTAssertTrue(lost[0].body.contains("not responding"))
        XCTAssertEqual(lost[0].endpointId, "e1")

        let up = HealthTransitions.changes(
            from: ["e1": down("refused")], to: ["e1": .ok(200, 0.1)], endpoints: [endpoint]
        )
        XCTAssertEqual(up.count, 1)
        XCTAssertTrue(up[0].body.contains("back"))
    }

    func testStayingDownIsSilent() {
        let changes = HealthTransitions.changes(
            from: ["e1": down("refused")], to: ["e1": down("timeout")], endpoints: [endpoint]
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

    /// Only a serving project is probed. Every other state — paused, mid-pause, restoring,
    /// removed — either doesn't resolve or refuses, so probing it would fire a false
    /// "not responding" alert for a state the row already names. Allowlist, not blocklist.
    func testOnlyHealthyProjectsAreProbed() {
        for status in ["INACTIVE", "PAUSING", "GOING_DOWN", "RESTORING", "REMOVED",
                       "INIT_FAILED", "RESTORE_FAILED", "COMING_UP", "UNKNOWN"] {
            let project = SupabaseProject(
                id: "abc", name: "p", region: "us-west-2", status: status
            )
            XCTAssertNil(project.healthURL, "\(status) must not be probed")
        }
        let healthy = SupabaseProject(
            id: "abc", name: "p", region: "us-west-2", status: "ACTIVE_HEALTHY"
        )
        XCTAssertNotNil(healthy.healthURL)
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
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))

        let changes = await monitor.check(endpoints())

        XCTAssertEqual(monitor.status(of: "a"), .ok(200, 0.12))
        XCTAssertEqual(monitor.status(of: "b"), .ok(401, 0.22))
        XCTAssertTrue(changes.isEmpty, "first pass is a baseline")
    }

    /// Emptying the watch list must clear what was learned — a stale "down" that outlives
    /// the endpoint it described would sit in the UI for the life of the process.
    func testPruneForgetsRemovedEndpoints() async {
        let probe = FakeProbe(answers: [
            "https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.12)),
            "https://b.test": .success(ProbeResult(statusCode: 200, latency: 0.12)),
        ])
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
        _ = await monitor.check(endpoints())
        XCTAssertNotNil(monitor.status(of: "a"))

        monitor.prune(to: [])
        XCTAssertNil(monitor.status(of: "a"))
        XCTAssertNil(monitor.status(of: "b"))
    }

    func testFailureBecomesDownAndReportsOnce() async {
        let probe = FakeProbe(answers: [
            "https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.12)),
            "https://b.test": .success(ProbeResult(statusCode: 200, latency: 0.12)),
        ])
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
        _ = await monitor.check(endpoints())

        probe.setAnswer("https://a.test", .failure(URLError(.cannotConnectToHost)))
        _ = await monitor.check(endpoints())   // one miss is not yet an outage
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

/// Network failures on THIS machine are not outages. Wi-Fi dropping must not announce
/// that every watched service died — and must not destroy the baseline either, or a real
/// outage arriving right after the blip would be silent.
@MainActor
final class HealthLocalFailureTests: XCTestCase {

    private let endpoint = WatchedEndpoint(
        id: "a", label: "mp3", url: URL(string: "https://a.test")!
    )

    func testLocalFailureIsNotAnOutage() async {
        let probe = FakeProbe(answers: ["https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.1))])
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
        _ = await monitor.check([endpoint])

        probe.setAnswer("https://a.test", .failure(URLError(.notConnectedToInternet)))
        let changes = await monitor.check([endpoint])

        XCTAssertTrue(changes.isEmpty, "losing Wi-Fi is not a service outage")
        XCTAssertEqual(monitor.status(of: "a"), .ok(200, 0.1),
                       "the last real reading stands — we simply couldn't ask")
    }

    /// The sequence that matters: blip, then the service genuinely dies. The outage must
    /// still be announced, measured against the last reading we actually trust.
    func testOutageAfterABlipIsStillAnnounced() async {
        let probe = FakeProbe(answers: ["https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.1))])
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
        _ = await monitor.check([endpoint])

        probe.setAnswer("https://a.test", .failure(URLError(.networkConnectionLost)))
        _ = await monitor.check([endpoint])

        probe.setAnswer("https://a.test", .failure(URLError(.cannotConnectToHost)))
        _ = await monitor.check([endpoint])
        let changes = await monitor.check([endpoint])

        XCTAssertEqual(changes.count, 1, "a real outage after a blip must not be swallowed")
        XCTAssertTrue(changes[0].body.contains("not responding"))
    }

    /// DNS failure, refused connections and TLS errors are things the SERVICE did — the
    /// paused-Supabase and mp3-by-IP cases both land here and must stay real outages.
    func testServiceSideFailuresRemainOutages() {
        XCTAssertFalse(HealthStatus.isLocalNetworkFailure(URLError(.cannotFindHost)))
        XCTAssertFalse(HealthStatus.isLocalNetworkFailure(URLError(.secureConnectionFailed)))
        XCTAssertFalse(HealthStatus.isLocalNetworkFailure(URLError(.timedOut)))
        XCTAssertTrue(HealthStatus.isLocalNetworkFailure(URLError(.notConnectedToInternet)))
    }
}

/// "Is the service down, or am I?" is answered by asking the OS for a network path —
/// never by inferring it from "everything failed at once", which cannot tell a dead Wi-Fi
/// from the single host that runs every watched service.
@MainActor
final class HealthReachabilityTests: XCTestCase {

    private func endpoints() -> [WatchedEndpoint] {
        [
            WatchedEndpoint(id: "a", label: "mp3", url: URL(string: "https://a.test")!),
            WatchedEndpoint(id: "b", label: "june", url: URL(string: "https://b.test")!),
        ]
    }

    private func healthy() -> FakeProbe {
        FakeProbe(answers: [
            "https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.1)),
            "https://b.test": .success(ProbeResult(statusCode: 200, latency: 0.1)),
        ])
    }

    func testOfflineMachineReportsNoOutages() async {
        let probe = healthy()
        let network = FakeReachability(online: true)
        let monitor = HealthMonitor(probe: probe, reachability: network)
        _ = await monitor.check(endpoints())

        network.online = false
        probe.setAnswer("https://a.test", .failure(URLError(.cannotFindHost)))
        probe.setAnswer("https://b.test", .failure(URLError(.timedOut)))
        let changes = await monitor.check(endpoints())

        XCTAssertTrue(changes.isEmpty, "no network path means no verdict about the services")
        XCTAssertEqual(monitor.status(of: "a"), .ok(200, 0.1), "the last real reading stands")
    }

    /// The case the old unanimity heuristic got catastrophically wrong: every watched
    /// service lives on one host, the host dies, the machine is fine. That MUST alert.
    func testOnlineMachineReportsEveryServiceOnADeadHost() async {
        let probe = healthy()
        let network = FakeReachability(online: true)
        let monitor = HealthMonitor(probe: probe, reachability: network)
        _ = await monitor.check(endpoints())

        probe.setAnswer("https://a.test", .failure(URLError(.cannotConnectToHost)))
        probe.setAnswer("https://b.test", .failure(URLError(.cannotConnectToHost)))
        _ = await monitor.check(endpoints())
        let changes = await monitor.check(endpoints())

        XCTAssertEqual(changes.count, 2, "the network is up, so both really are down")
    }

    /// Pruning belongs to the round that actually probed — a re-entrant call dropped by
    /// the guard must not prune against its own list.
    func testCheckPrunesWhatItProbed() async {
        let probe = healthy()
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
        _ = await monitor.check(endpoints())
        XCTAssertNotNil(monitor.status(of: "b"))

        _ = await monitor.check([endpoints()[0]])
        XCTAssertNil(monitor.status(of: "b"), "an unwatched endpoint's reading is dropped")
        XCTAssertNotNil(monitor.status(of: "a"))
    }
}

final class FakeReachability: NetworkReachability, @unchecked Sendable {
    private let lock = NSLock()
    private var _online: Bool
    init(online: Bool) { _online = online }
    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
    var isOnline: Bool { online }
}

/// A service that answers slowly enough to sit on the timeout boundary alternates
/// pass/fail every beat. Alerting on each flip is noisier than any sustained outage —
/// roughly two notifications a minute — so a change of kind has to be seen twice in a row
/// before it counts.
@MainActor
final class HealthFlapDampingTests: XCTestCase {

    private let endpoint = WatchedEndpoint(
        id: "a", label: "mp3", url: URL(string: "https://a.test")!
    )

    private func monitor(_ probe: FakeProbe) -> HealthMonitor {
        HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
    }

    private func healthy() -> FakeProbe {
        FakeProbe(answers: ["https://a.test": .success(ProbeResult(statusCode: 200, latency: 0.1))])
    }

    func testOneFailedProbeIsNotYetAnOutage() async {
        let probe = healthy()
        let monitor = monitor(probe)
        _ = await monitor.check([endpoint])

        probe.setAnswer("https://a.test", .failure(URLError(.timedOut)))
        let changes = await monitor.check([endpoint])

        XCTAssertTrue(changes.isEmpty, "one miss is not yet news")
        XCTAssertEqual(monitor.status(of: "a"), .ok(200, 0.1),
                       "and the row still shows the last confirmed reading")
    }

    func testASecondConsecutiveFailureConfirmsTheOutage() async {
        let probe = healthy()
        let monitor = monitor(probe)
        _ = await monitor.check([endpoint])

        probe.setAnswer("https://a.test", .failure(URLError(.timedOut)))
        _ = await monitor.check([endpoint])
        let changes = await monitor.check([endpoint])

        XCTAssertEqual(changes.count, 1, "a sustained outage is still announced")
        XCTAssertTrue(changes[0].body.contains("not responding"))
        XCTAssertFalse(monitor.status(of: "a")?.isUp ?? true)
    }

    /// The finding this damping exists for: without it, six beats produce six notifications.
    func testAFlappingServiceNeverNotifies() async {
        let probe = healthy()
        let monitor = monitor(probe)
        _ = await monitor.check([endpoint])

        var total = 0
        for round in 0..<6 {
            probe.setAnswer(
                "https://a.test",
                round.isMultiple(of: 2)
                    ? .failure(URLError(.timedOut))
                    : .success(ProbeResult(statusCode: 200, latency: 0.1))
            )
            total += await monitor.check([endpoint]).count
        }

        XCTAssertEqual(total, 0, "a service flapping on the timeout boundary is not six outages")
    }

    /// Recovery is confirmed the same way — otherwise damping just moves the flapping
    /// noise to the "back up" side.
    func testRecoveryIsConfirmedBeforeItIsAnnounced() async {
        let probe = healthy()
        let monitor = monitor(probe)
        _ = await monitor.check([endpoint])
        probe.setAnswer("https://a.test", .failure(URLError(.timedOut)))
        _ = await monitor.check([endpoint])
        _ = await monitor.check([endpoint])   // outage confirmed

        probe.setAnswer("https://a.test", .success(ProbeResult(statusCode: 200, latency: 0.1)))
        let first = await monitor.check([endpoint])
        XCTAssertTrue(first.isEmpty, "one good answer during an outage is not recovery")

        let second = await monitor.check([endpoint])
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].body.contains("back up"))
    }

    /// A blip (no reading at all) is not evidence of recovery, so it must not reset the
    /// count — otherwise a flaky link could postpone a real outage alert indefinitely.
    func testABlipDoesNotResetTheFailureCount() async {
        let probe = healthy()
        let monitor = monitor(probe)
        _ = await monitor.check([endpoint])

        probe.setAnswer("https://a.test", .failure(URLError(.timedOut)))
        _ = await monitor.check([endpoint])
        probe.setAnswer("https://a.test", .failure(URLError(.notConnectedToInternet)))
        _ = await monitor.check([endpoint])
        probe.setAnswer("https://a.test", .failure(URLError(.timedOut)))
        let changes = await monitor.check([endpoint])

        XCTAssertEqual(changes.count, 1, "two real failures either side of a blip still confirm")
    }

    /// Latency drift within a kind is not a change and must never wait for confirmation.
    func testSameKindReadingsUpdateImmediately() async {
        let probe = healthy()
        let monitor = monitor(probe)
        _ = await monitor.check([endpoint])

        probe.setAnswer("https://a.test", .success(ProbeResult(statusCode: 200, latency: 0.9)))
        let changes = await monitor.check([endpoint])

        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(monitor.status(of: "a"), .ok(200, 0.9), "the row tracks latency live")
    }
}

/// The Supabase half of the watch list is only as trustworthy as the project listing it
/// came from: a cached ACTIVE_HEALTHY for a project that has since auto-paused produces
/// exactly the false "not responding" the status allowlist exists to prevent.
final class ListingFreshnessTests: XCTestCase {

    private let policy = ListingFreshness.standard
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNeverListedAsksForARefresh() {
        XCTAssertTrue(policy.shouldRefresh(lastListedAt: nil, now: now))
    }

    func testAFreshListingIsLeftAlone() {
        let listed = now.addingTimeInterval(-60)
        XCTAssertFalse(policy.shouldRefresh(lastListedAt: listed, now: now),
                       "the beat must not spawn a CLI every minute")
    }

    func testAStaleListingIsRefreshed() {
        let listed = now.addingTimeInterval(-policy.refreshInterval - 1)
        XCTAssertTrue(policy.shouldRefresh(lastListedAt: listed, now: now))
    }

    /// If refreshing has been failing, the listing keeps its stale rows by design — but at
    /// some point "ACTIVE_HEALTHY as of an hour ago" stops being grounds for an alert.
    func testAnAncientListingIsNoLongerTrustedToDriveAlerts() {
        XCTAssertTrue(policy.isTrustworthy(lastListedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(policy.isTrustworthy(lastListedAt: nil, now: now))
        XCTAssertFalse(
            policy.isTrustworthy(lastListedAt: now.addingTimeInterval(-policy.trustWindow - 1), now: now),
            "an unrefreshable listing must not keep generating outage alerts"
        )
    }

    func testTrustOutlastsTheRefreshInterval() {
        let listed = now.addingTimeInterval(-policy.refreshInterval - 1)
        XCTAssertTrue(policy.isTrustworthy(lastListedAt: listed, now: now),
                      "one missed refresh is not grounds to stop watching")
    }
}

/// `deinit` cancels the path monitor — which only ever runs if the update handler doesn't
/// hold the object that owns it.
final class LiveNetworkReachabilityTests: XCTestCase {

    func testItIsReleasedWhenTheOwnerLetsGo() {
        weak var weakRef: LiveNetworkReachability?
        autoreleasepool {
            let reachability = LiveNetworkReachability()
            weakRef = reachability
            XCTAssertTrue(reachability.isOnline, "optimistic until the monitor says otherwise")
        }
        XCTAssertNil(weakRef, "the path handler must not retain the object that owns the monitor")
    }
}

/// "down" alone is not an answer. The failures a watched service actually hits are
/// different problems with different fixes, and the row has room for the distinction.
final class DownReasonTests: XCTestCase {

    func testTheFailuresAreToldApart() {
        XCTAssertEqual(DownReason.classify(URLError(.cannotFindHost)).label, "dns")
        XCTAssertEqual(DownReason.classify(URLError(.dnsLookupFailed)).label, "dns")
        XCTAssertEqual(DownReason.classify(URLError(.cannotConnectToHost)).label, "refused")
        XCTAssertEqual(DownReason.classify(URLError(.timedOut)).label, "timeout")
    }

    /// The mp3-server-by-IP case: Caddy aborts the handshake when SNI names no site it
    /// serves. Reading "down" sends you looking for a dead service; reading "tls" sends
    /// you to the hostname, which is the actual problem.
    func testATLSFailureSaysSoInsteadOfClaimingTheServiceIsDead() {
        XCTAssertEqual(DownReason.classify(URLError(.secureConnectionFailed)).label, "tls")
        XCTAssertEqual(DownReason.classify(URLError(.serverCertificateUntrusted)).label, "tls")
        XCTAssertEqual(DownReason.classify(URLError(.serverCertificateHasBadDate)).label, "tls")
    }

    func testTheFullReasonSurvivesForTheTooltip() {
        let reason = DownReason.classify(URLError(.timedOut))
        XCTAssertFalse(reason.detail.isEmpty)
        XCTAssertNotEqual(reason.detail, reason.label, "the label is a summary, not the whole story")
    }

    func testAnUnrecognisedFailureStillReadsAsDown() {
        XCTAssertEqual(DownReason.classify(LinkCError.process("boom")).label, "down")
    }

    func testTheRowShowsTheReasonNotTheWordDown() {
        XCTAssertEqual(HealthStatus.down(DownReason.classify(URLError(.timedOut))).shortLabel, "timeout")
    }
}

/// A liveness probe answers "did the thing I named answer me" — so it must not chase a
/// redirect to somewhere else and report on that instead.
final class RedirectPolicyTests: XCTestCase {

    func testARedirectIsNotFollowed() {
        let blocker = RedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://example.test")!)
        let response = HTTPURLResponse(
            url: URL(string: "http://example.test")!, statusCode: 308,
            httpVersion: nil, headerFields: ["Location": "https://elsewhere.test/"]
        )!
        let expectation = expectation(description: "redirect decision")
        var followed: URLRequest?

        blocker.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.test/")!)
        ) { request in
            followed = request
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertNil(followed, "the 308 IS the answer — following it would watch a host nobody asked for")
        task.cancel()
        session.invalidateAndCancel()
    }

    /// A 308 from a front door that only serves HTTPS is a live server, not an outage —
    /// this is what makes the mp3 server monitorable before its domain exists.
    func testARedirectCountsAsAlive() {
        XCTAssertTrue(HealthStatus.classify(code: 308, latency: 0.034).isUp)
        XCTAssertTrue(HealthStatus.classify(code: 301, latency: 0.01).isUp)
    }
}

/// What gets probed each beat. Extracted from the app target so the rule that matters —
/// a stale Supabase listing must not take the user's OWN endpoints down with it — is
/// covered by a test rather than by reading the code.
final class WatchListTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func project(_ id: String, _ status: String) -> SupabaseProject {
        SupabaseProject(id: id, name: id, region: "ca-central-1", status: status)
    }

    private let mp3 = WatchedEndpoint(
        id: "https://mp3.test", label: "mp3", url: URL(string: "https://mp3.test")!
    )

    func testServingProjectsAndConfiguredEndpointsAreBothWatched() {
        let list = WatchList.endpoints(
            supabaseProjects: [project("abc", "ACTIVE_HEALTHY")],
            lastListedAt: now, configured: [mp3], now: now
        )
        XCTAssertEqual(list.map(\.id), ["supabase:abc", "https://mp3.test"])
    }

    func testPausedProjectsAreNotProbed() {
        let list = WatchList.endpoints(
            supabaseProjects: [project("abc", "INACTIVE")],
            lastListedAt: now, configured: [], now: now
        )
        XCTAssertTrue(list.isEmpty, "a paused project doesn't resolve; probing it invents an outage")
    }

    /// The finding: the allowlist is only as fresh as the listing it filters.
    func testAnUntrustworthyListingStopsDrivingProbes() {
        let ancient = now.addingTimeInterval(-ListingFreshness.standard.trustWindow - 1)
        let list = WatchList.endpoints(
            supabaseProjects: [project("abc", "ACTIVE_HEALTHY")],
            lastListedAt: ancient, configured: [], now: now
        )
        XCTAssertTrue(list.isEmpty, "ACTIVE_HEALTHY from an hour ago is not grounds to alert")
    }

    /// And the rule that must survive it: Supabase going stale is not a reason to stop
    /// watching the services the user named themselves.
    func testConfiguredEndpointsSurviveAStaleListing() {
        let ancient = now.addingTimeInterval(-ListingFreshness.standard.trustWindow - 1)
        let list = WatchList.endpoints(
            supabaseProjects: [project("abc", "ACTIVE_HEALTHY")],
            lastListedAt: ancient, configured: [mp3], now: now
        )
        XCTAssertEqual(list.map(\.id), ["https://mp3.test"])
    }

    func testNeverListedMeansNoSupabaseEndpoints() {
        let list = WatchList.endpoints(
            supabaseProjects: [project("abc", "ACTIVE_HEALTHY")],
            lastListedAt: nil, configured: [mp3], now: now
        )
        XCTAssertEqual(list.map(\.id), ["https://mp3.test"])
    }

    func testTheIdMatchesWhatTheRowLooksUp() {
        XCTAssertEqual(WatchList.supabaseEndpointId(project("abc", "ACTIVE_HEALTHY")), "supabase:abc")
    }
}

/// The whole chain for a service the user configured by hand: the file they edit, the
/// watch list built from it, the probe, and what the row ends up showing. Every piece is
/// unit-tested on its own; this is the one that fails if they stop fitting together.
@MainActor
final class ConfiguredServiceEndToEndTests: XCTestCase {

    private func storeDirectory(containing json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("endpoints.json"))
        return dir
    }

    /// The real endpoints.json content, and the answer the real server really gives.
    private let config = #"[{ "label": "audio-1", "url": "http://203.0.113.10/" }]"#

    func testTheConfiguredServiceIsWatchedAndReadsHealthy() async throws {
        let dir = try storeDirectory(containing: config)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configured = WatchedEndpointsStore(directory: dir).load()
        // No Supabase listing at all — the case that must not take the user's own
        // endpoints down with it.
        let endpoints = WatchList.endpoints(
            supabaseProjects: [], lastListedAt: nil, configured: configured
        )
        XCTAssertEqual(endpoints.map(\.label), ["audio-1"])

        let probe = FakeProbe(answers: [
            "http://203.0.113.10/": .success(ProbeResult(statusCode: 308, latency: 0.042)),
        ])
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
        let changes = await monitor.check(endpoints)

        XCTAssertEqual(monitor.status(of: endpoints[0].id)?.shortLabel, "42ms",
                       "a 308 from a redirect-only front door is a live server")
        XCTAssertTrue(monitor.status(of: endpoints[0].id)?.isUp ?? false)
        XCTAssertTrue(changes.isEmpty, "the first reading is a baseline, not an alert")
    }

    /// Pointed at HTTPS instead, the same box refuses the handshake. The row has to say
    /// which problem that is — "down" would send you hunting a service that never died.
    func testAHandshakeRefusalReadsAsTLSNotAsADeadService() async throws {
        let dir = try storeDirectory(
            containing: #"[{ "label": "audio-1", "url": "https://203.0.113.10/" }]"#
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let endpoints = WatchedEndpointsStore(directory: dir).load()
        let probe = FakeProbe(answers: [
            "https://203.0.113.10/": .success(ProbeResult(statusCode: 200, latency: 0.04)),
        ])
        let monitor = HealthMonitor(probe: probe, reachability: FakeReachability(online: true))
        _ = await monitor.check(endpoints)

        probe.setAnswer("https://203.0.113.10/", .failure(URLError(.secureConnectionFailed)))
        _ = await monitor.check(endpoints)
        let changes = await monitor.check(endpoints)

        XCTAssertEqual(monitor.status(of: endpoints[0].id)?.shortLabel, "tls")
        XCTAssertEqual(changes.count, 1, "confirmed, then announced once")
    }
}
