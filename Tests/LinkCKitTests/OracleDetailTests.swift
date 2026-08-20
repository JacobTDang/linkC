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

    func testExpandFetchesIPAndCpu() async {
        let runner = FakeRunner(result: .success(#"[{"public-ip": "203.0.113.10"}]"#))
        let service = OracleService(ociPath: "/fake/oci", hasConfig: true, region: "us-chicago-1", runner: runner)

        await service.loadDetail(for: "ocid1.instance.oc1..aaa")

        let args = runner.calls.map(\.args)
        XCTAssertTrue(args.contains { $0.contains("list-vnics") }, "public IP comes from the VNIC listing")
        XCTAssertTrue(args.contains { $0.contains("summarize-metrics-data") }, "CPU comes from monitoring")
        XCTAssertEqual(service.detail(for: "ocid1.instance.oc1..aaa")?.publicIP, "203.0.113.10")
    }

    func testDetailFailureIsQuietNotFatal() async {
        let runner = FakeRunner(result: .failure(LinkCError.process("rate limited")))
        let service = OracleService(ociPath: "/fake/oci", hasConfig: true, region: "us-chicago-1", runner: runner)

        await service.loadDetail(for: "ocid1.instance.oc1..aaa")

        // A failed drill-in renders "—" per field; it must not blank the row or throw.
        XCTAssertNotNil(service.detail(for: "ocid1.instance.oc1..aaa"), "an attempted detail exists, fields empty")
        XCTAssertNil(service.detail(for: "ocid1.instance.oc1..aaa")?.publicIP)
    }
}
