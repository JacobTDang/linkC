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

    func testCpuKeyedByResourceIdTakesLatestDatapoint() {
        // Shape copied from a real `oci monitoring metric-data summarize-metrics-data` run.
        let json = """
        [
          {"dimensions": {"resourceId": "ocid1.instance.oc1..aaa"},
           "aggregated-datapoints": [
             {"timestamp": "2026-08-20T00:30:00+00:00", "value": 1.5933216150719312},
             {"timestamp": "2026-08-20T01:30:00+00:00", "value": 3.4821}
           ]},
          {"dimensions": {"resourceId": "ocid1.instance.oc1..bbb"},
           "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 42.5}]}
        ]
        """
        let cpu = OracleMetrics.latestCpuByInstance(json)
        XCTAssertEqual(cpu["ocid1.instance.oc1..aaa"] ?? -1, 3.48, accuracy: 0.01,
                       "the newest datapoint wins, not the first")
        XCTAssertEqual(cpu["ocid1.instance.oc1..bbb"] ?? -1, 42.5, accuracy: 0.01)
    }

    func testEmptyAndGarbageMetricsAreEmpty() {
        XCTAssertTrue(OracleMetrics.latestCpuByInstance("[]").isEmpty)
        XCTAssertTrue(OracleMetrics.latestCpuByInstance("not json").isEmpty)
        // A series with no datapoints contributes nothing rather than a bogus zero.
        XCTAssertTrue(OracleMetrics.latestCpuByInstance(
            #"[{"dimensions": {"resourceId": "x"}, "aggregated-datapoints": []}]"#
        ).isEmpty)
    }
}

/// Detail fetching is on-demand only: expanding a row fetches, refresh() never does.
/// Answers per command rather than one canned payload for every call — a single-answer
/// fake is how a wrong argument list slips through unnoticed.
final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let args: [String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private let answers: [String: Result<String, Error>]

    var calls: [Call] { lock.withLock { recorded } }

    /// Keyed by a distinctive subcommand token ("list-vnics", "summarize-metrics-data").
    init(answers: [String: Result<String, Error>]) { self.answers = answers }

    func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String {
        lock.withLock { recorded.append(Call(executable: executable, args: args)) }
        for (token, answer) in answers where args.contains(token) {
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
        [{"dimensions": {"resourceId": "ocid1.instance.oc1..aaa"},
          "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 3.5}]}]
        """
        let runner = ScriptedRunner(answers: [
            "list-vnics": .success(#"[{"public-ip": "203.0.113.10"}]"#),
            "summarize-metrics-data": .success(metricsJSON),
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
        let metricsArgs = runner.calls.map(\.args).first { $0.contains("summarize-metrics-data") }
        XCTAssertEqual(
            metricsArgs,
            ["monitoring", "metric-data", "summarize-metrics-data",
             "--compartment-id", "ocid1.tenancy.oc1..zzz",
             "--compartment-id-in-subtree", "true",
             "--namespace", "oci_computeagent",
             "--query-text", OracleMetrics.queryText,
             "--query", OracleMetrics.cliQuery, "--output", "json"]
        )
    }

    /// One tenancy-wide metrics call serves every row, and a cached detail is reused —
    /// expanding twice must not spawn four processes against a rate-limited API.
    func testCachesAndFansOutMetricsToOtherRows() async {
        let metricsJSON = """
        [{"dimensions": {"resourceId": "ocid1.instance.oc1..aaa"},
          "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 3.5}]},
         {"dimensions": {"resourceId": "ocid1.instance.oc1..bbb"},
          "aggregated-datapoints": [{"timestamp": "2026-08-20T01:30:00+00:00", "value": 42.0}]}]
        """
        let runner = ScriptedRunner(answers: [
            "list-vnics": .success(#"[{"public-ip": "1.2.3.4"}]"#),
            "summarize-metrics-data": .success(metricsJSON),
        ])
        let service = OracleService(
            ociPath: "/fake/oci", hasConfig: true, region: "r", tenancy: "t", runner: runner
        )

        await service.loadDetail(for: "ocid1.instance.oc1..aaa")
        XCTAssertEqual(service.detail(for: "ocid1.instance.oc1..bbb")?.cpuPercent ?? -1, 42.0, accuracy: 0.01,
                       "the tenancy-wide map serves the other rows too")

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
        XCTAssertNotNil(service.lastError, "fail loud")
    }
}
