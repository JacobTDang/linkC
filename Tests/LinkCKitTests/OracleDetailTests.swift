import XCTest
@testable import LinkCKit

/// The drill-in parsers: a VNIC listing yields the public IP, and one monitoring call
/// yields the latest CPU mean per instance (keyed by the resourceId dimension, so a single
/// tenancy-wide call covers every row).
final class OracleDetailTests: XCTestCase {

    func testPublicIPParsed() {
        let json = #"[{"public-ip": "203.0.113.10", "private-ip": "10.0.0.5"}]"#
        XCTAssertEqual(OracleVnics.publicIP(json), "203.0.113.10")
    }

    func testMissingOrPrivateOnlyVnicIsNil() {
        XCTAssertNil(OracleVnics.publicIP(#"[{"private-ip": "10.0.0.5"}]"#),
                     "a private-only instance has no public IP to show")
        XCTAssertNil(OracleVnics.publicIP("[]"))
        XCTAssertNil(OracleVnics.publicIP("not json"))
    }

    func testEmptyAndGarbageMetricsAreEmpty() {
        XCTAssertTrue(OracleMetrics.healthByInstance("[]").isEmpty)
        XCTAssertTrue(OracleMetrics.healthByInstance("not json").isEmpty)
        // A series with no datapoints contributes nothing rather than a bogus zero.
        XCTAssertTrue(OracleMetrics.healthByInstance(
            #"[{"name": "CpuUtilization", "dimensions": {"resourceId": "x"}, "aggregated-datapoints": []}]"#
        ).isEmpty)
    }
}

/// Health metrics: one call carries several metric names, keyed by name AND resourceId.
final class OracleHealthTests: XCTestCase {

    /// The real shape: `name` distinguishes the metric, `dimensions.resourceId` the box.
    private let multiMetricJSON = """
    [
      {"name": "CpuUtilization", "dimensions": {"resourceId": "aaa"},
       "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 2.4}]},
      {"name": "MemoryUtilization", "dimensions": {"resourceId": "aaa"},
       "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 10.9}]},
      {"name": "LoadAverage", "dimensions": {"resourceId": "aaa"},
       "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 0.31}]},
      {"name": "MemoryUtilization", "dimensions": {"resourceId": "bbb"},
       "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 71.2}]}
    ]
    """

    func testMetricsSplitByNameAndInstance() {
        let health = OracleMetrics.healthByInstance(multiMetricJSON)
        XCTAssertEqual(health["aaa"]?.cpuPercent ?? -1, 2.4, accuracy: 0.01)
        XCTAssertEqual(health["aaa"]?.memoryPercent ?? -1, 10.9, accuracy: 0.01)
        XCTAssertEqual(health["aaa"]?.loadAverage ?? -1, 0.31, accuracy: 0.01)
        XCTAssertEqual(health["bbb"]?.memoryPercent ?? -1, 71.2, accuracy: 0.01)
        XCTAssertNil(health["bbb"]?.cpuPercent, "a metric absent for a box stays nil, not zero")
    }

    /// Audit output is MULTIPLE concatenated JSON documents (one per page), not one array —
    /// verified against the live CLI, and a plain JSONDecoder chokes on it.
    func testAuditSummaryAcrossConcatenatedDocuments() {
        let json = """
        {"data": [
          {"data": {"identity": {"principal-name": "Jacob Dang", "ip-address": "47.1.2.3"}}},
          {"data": {"identity": {"principal-name": null, "ip-address": "10.0.2.7"}}}
        ]}
        {"data": [
          {"data": {"identity": {"principal-name": "Jacob Dang", "ip-address": "47.1.2.3"}}}
        ]}
        """
        let summary = OracleAudit.summarize(json)
        XCTAssertEqual(summary?.eventCount, 3, "events across every page count")
        XCTAssertEqual(summary?.humanPrincipals, ["Jacob Dang"], "system events aren't people")
        XCTAssertFalse(summary?.hasUnknownPrincipal ?? true)
    }

    func testUnfamiliarPrincipalIsFlagged() {
        let json = """
        {"data": [
          {"data": {"identity": {"principal-name": "Jacob Dang", "ip-address": "47.1.2.3"}}},
          {"data": {"identity": {"principal-name": "someone-else", "ip-address": "203.0.113.9"}}}
        ]}
        """
        let summary = OracleAudit.summarize(json, knownPrincipals: ["Jacob Dang"])
        XCTAssertTrue(summary?.hasUnknownPrincipal ?? false, "an unfamiliar principal is the whole point")
        XCTAssertEqual(summary?.humanPrincipals.count, 2)
    }

    /// A `||`-joined query returns ONE series named `join-#<id>` — the per-metric name is
    /// gone, so every figure would read "—". Pinned so nobody "optimizes" three calls into
    /// one; verified against the live API.
    func testJoinedSeriesNameIsNotAMetric() {
        let joined = """
        [{"name": "join-#123764268", "dimensions": {"resourceId": "aaa"},
          "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 1.0}]}]
        """
        let health = OracleMetrics.healthByInstance(joined)
        XCTAssertNil(health["aaa"]?.cpuPercent)
        XCTAssertNil(health["aaa"]?.memoryPercent)
        XCTAssertEqual(OracleMetrics.healthMetrics.count, 3, "one call per metric")
    }

    func testGarbageAuditIsNil() {
        XCTAssertNil(OracleAudit.summarize("not json"))
        XCTAssertEqual(OracleAudit.summarize(#"{"data": []}"#)?.eventCount, 0,
                       "a real empty page is a real zero")
    }

    /// A document with no `data` array (an error payload, a banner) must NOT decode as a
    /// confident "0 events" — that reads exactly like a verified-quiet account.
    func testNonEventDocumentIsNilNotZero() {
        XCTAssertNil(OracleAudit.summarize(#"{"error": {"code": "NotAuthenticated"}}"#))
        XCTAssertNil(OracleAudit.summarize(#"{"data": [{"data": {}}]} {"opc-next-page": "abc"}"#),
                     "a malformed or non-event page invalidates the summary rather than under-reporting")
    }
}

/// Detail fetching is on-demand only: expanding a row fetches, refresh() never does.
/// Answers per command rather than one canned payload for every call — a single-answer
/// fake is how a wrong argument list slips through unnoticed.
final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let args: [String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var answers: [String: Result<String, Error>]

    var calls: [Call] { lock.withLock { recorded } }

    /// Keyed by a distinctive subcommand token ("list-vnics", "summarize-metrics-data").
    init(answers: [String: Result<String, Error>]) { self.answers = answers }

    /// Change one command's answer mid-test (an instance losing its public IP, say).
    func setAnswer(_ token: String, _ answer: Result<String, Error>) {
        lock.withLock { answers[token] = answer }
    }

    func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String {
        lock.withLock { recorded.append(Call(executable: executable, args: args)) }
        let snapshot = lock.withLock { answers }
        for (token, answer) in snapshot where args.contains(token) {
            return try answer.get()
        }
        throw LinkCError.process("unscripted command: \(args.joined(separator: " "))")
    }
}

@MainActor
final class OracleDetailServiceTests: XCTestCase {

    private let listJSON = """
    [{"name": "audio-1", "state": "RUNNING", "id": "ocid1.instance.oc1..aaa"}]
    """

    func testRefreshNeverFetchesDetail() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = OracleService(ociPath: "/fake/oci", hasConfig: true, region: "us-chicago-1", runner: runner)

        await service.refresh()

        XCTAssertFalse(
            runner.calls.contains { $0.args.contains("list-vnics") || $0.args.contains("metric-data") },
            "the polling path must stay cheap — detail is fetched only when a row expands"
        )
    }

    func testExpandFetchesIPAndCpuWithRequiredArgs() async {
        let metricsJSON = """
        [{"name": "CpuUtilization", "dimensions": {"resourceId": "ocid1.instance.oc1..aaa"},
          "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 3.5}]}]
        """
        let runner = ScriptedRunner(answers: [
            "list-vnics": .success(#"[{"public-ip": "203.0.113.10"}]"#),
            "summarize-metrics-data": .success(metricsJSON),
            "event": .success(#"{"data": []}"#),
        ])
        let service = OracleService(
            ociPath: "/fake/oci", hasConfig: true, region: "us-chicago-1",
            tenancy: "ocid1.tenancy.oc1..zzz", runner: runner
        )

        await service.loadDetail(for: "ocid1.instance.oc1..aaa")

        let detail = service.detail(for: "ocid1.instance.oc1..aaa")
        XCTAssertEqual(detail?.publicIP, "203.0.113.10")
        XCTAssertEqual(detail?.cpuPercent ?? -1, 3.5, accuracy: 0.01, "the metrics half must parse too")
        XCTAssertNil(service.lastError)

        // The monitoring API requires a compartment — without it the CLI exits nonzero and
        // CPU silently reads "—" forever. Pin the whole contract, not just the subcommand.
        // Three metric calls run concurrently and record in arbitrary order — select the
        // CPU one explicitly rather than "the first metrics call" (which was flaky).
        let metricsArgs = runner.calls.map(\.args).first {
            $0.contains("summarize-metrics-data")
                && $0.contains(OracleMetrics.healthQueryText("CpuUtilization"))
        }
        XCTAssertEqual(
            metricsArgs,
            ["monitoring", "metric-data", "summarize-metrics-data",
             "--compartment-id", "ocid1.tenancy.oc1..zzz",
             "--compartment-id-in-subtree", "true",
             "--namespace", "oci_computeagent",
             "--query-text", OracleMetrics.healthQueryText("CpuUtilization"),
             "--query", OracleMetrics.healthQuery, "--output", "json"]
        )
    }

    /// One tenancy-wide metrics call serves every row, and a cached detail is reused —
    /// expanding twice must not spawn four processes against a rate-limited API.
    func testCachesAndFansOutMetricsToOtherRows() async {
        let metricsJSON = """
        [{"name": "CpuUtilization", "dimensions": {"resourceId": "ocid1.instance.oc1..aaa"},
          "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 3.5}]},
         {"name": "CpuUtilization", "dimensions": {"resourceId": "ocid1.instance.oc1..bbb"},
          "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 42.0}]}]
        """
        let runner = ScriptedRunner(answers: [
            "list-vnics": .success(#"[{"public-ip": "1.2.3.4"}]"#),
            "summarize-metrics-data": .success(metricsJSON),
            "event": .success(#"{"data": []}"#),
        ])
        let service = OracleService(
            ociPath: "/fake/oci", hasConfig: true, region: "r", tenancy: "t", runner: runner
        )

        await service.loadDetail(for: "ocid1.instance.oc1..aaa")
        XCTAssertEqual(service.detail(for: "ocid1.instance.oc1..bbb")?.cpuPercent ?? -1, 42.0, accuracy: 0.01,
                       "the tenancy-wide map serves the other rows too")

        // …but a fanned-out CPU seed must NOT count as a loaded row: expanding B still has
        // to fetch B's own IP, or every row except the first shows "—" forever.
        await service.loadDetail(for: "ocid1.instance.oc1..bbb")
        XCTAssertEqual(service.detail(for: "ocid1.instance.oc1..bbb")?.publicIP, "1.2.3.4",
                       "a metrics-seeded row still fetches its own IP")

        let callsAfterFirst = runner.calls.count
        await service.loadDetail(for: "ocid1.instance.oc1..aaa")
        XCTAssertEqual(runner.calls.count, callsAfterFirst, "a cached detail is reused")

        await service.loadDetail(for: "ocid1.instance.oc1..aaa", force: true)
        XCTAssertGreaterThan(runner.calls.count, callsAfterFirst, "refresh forces a re-fetch")
    }

    func testDetailFailureIsLoudNotFatal() async {
        let runner = FakeRunner(result: .failure(LinkCError.process("rate limited")))
        let service = OracleService(
            ociPath: "/fake/oci", hasConfig: true, region: "us-chicago-1", tenancy: "t", runner: runner
        )

        await service.loadDetail(for: "ocid1.instance.oc1..aaa")

        // A failed drill-in renders "—" per field; it must not blank the row or throw —
        // but it must not be silent either (a swallowed failure looks like "no public IP").
        XCTAssertNotNil(service.detail(for: "ocid1.instance.oc1..aaa"), "an attempted detail exists, fields empty")
        XCTAssertNil(service.detail(for: "ocid1.instance.oc1..aaa")?.publicIP)
        XCTAssertNotNil(service.detailError, "fail loud")
    }

    /// An IP that is genuinely unassigned must clear, not linger: coalescing exists for
    /// failed calls, not for successful ones that report nothing.
    func testUnassignedIPClearsButFailureKeepsLastKnown() async {
        let runner = ScriptedRunner(answers: [
            "list-vnics": .success(#"[{"public-ip": "1.2.3.4"}]"#),
            "summarize-metrics-data": .success("[]"),
            "event": .success(#"{"data": []}"#),
        ])
        let service = OracleService(
            ociPath: "/fake/oci", hasConfig: true, region: "r", tenancy: "t", runner: runner
        )
        await service.loadDetail(for: "aaa")
        XCTAssertEqual(service.detail(for: "aaa")?.publicIP, "1.2.3.4")

        // The instance loses its public IP — the call succeeds, private-only.
        runner.setAnswer("list-vnics", .success(#"[{"private-ip": "10.0.0.5"}]"#))
        await service.loadDetail(for: "aaa", force: true)
        XCTAssertNil(service.detail(for: "aaa")?.publicIP, "a real unassignment must clear")

        // But a FAILED call keeps whatever was last known.
        runner.setAnswer("list-vnics", .success(#"[{"public-ip": "5.6.7.8"}]"#))
        await service.loadDetail(for: "aaa", force: true)
        runner.setAnswer("list-vnics", .failure(LinkCError.process("rate limited")))
        await service.loadDetail(for: "aaa", force: true)
        XCTAssertEqual(service.detail(for: "aaa")?.publicIP, "5.6.7.8", "a failure keeps the last known IP")
    }

    /// The drill-in and the listing keep separate error fields: a successful expand must
    /// not erase an expired-auth listing failure the user still needs to see.
    func testDrillInSuccessDoesNotEraseListingError() async {
        let runner = ScriptedRunner(answers: [
            "structured-search": .failure(LinkCError.process("NotAuthenticated")),
            "list-vnics": .success(#"[{"public-ip": "1.2.3.4"}]"#),
            "summarize-metrics-data": .success("[]"),
            "event": .success(#"{"data": []}"#),
        ])
        let service = OracleService(
            ociPath: "/fake/oci", hasConfig: true, region: "r", tenancy: "t", runner: runner
        )

        await service.refresh()
        XCTAssertNotNil(service.lastError, "the listing failure is recorded")

        await service.loadDetail(for: "ocid1.instance.oc1..aaa")
        XCTAssertNotNil(service.lastError, "a successful drill-in must not wipe it")
        XCTAssertNil(service.detailError)
    }
}
