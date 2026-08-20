import XCTest
@testable import LinkCKit

/// The `~/.oci/config` parse is section-aware: only the DEFAULT profile counts — the
/// CLI authenticates as DEFAULT when no --profile is passed, so another profile's values
/// must never leak in, whatever the section order.
final class OCIConfigTests: XCTestCase {

    func testDefaultProfileValueParsed() {
        let config = """
        [DEFAULT]
        user=ocid1.user.oc1..aaa
        region=us-chicago-1
        """
        XCTAssertEqual(OCIConfig.defaultProfileValue("region", from: config), "us-chicago-1")
    }

    func testEarlierForeignProfileNeverWins() {
        let config = """
        [WORK]
        region=eu-frankfurt-1
        [DEFAULT]
        region = us-chicago-1
        """
        XCTAssertEqual(
            OCIConfig.defaultProfileValue("region", from: config), "us-chicago-1",
            "a non-DEFAULT profile listed first must not supply the value"
        )
    }

    func testCommentsAndMissingKeyAreNil() {
        let config = """
        [DEFAULT]
        # region=us-commented-1
        user=ocid1.user.oc1..aaa
        """
        XCTAssertNil(OCIConfig.defaultProfileValue("region", from: config))
        XCTAssertNil(OCIConfig.defaultProfileValue("region", from: "[WORK]\nregion=eu-frankfurt-1"))
    }
}

/// The structured-search parse: nil for non-JSON (stale rows must survive stdout noise),
/// [] only for a genuinely empty listing, TERMINATED dropped as console noise.
final class OracleInstancesTests: XCTestCase {

    func testParsesRunningAndStoppedDropsTerminated() throws {
        let json = """
        [
          {"name": "audio-1", "state": "RUNNING", "id": "ocid1.instance.oc1..aaa"},
          {"name": "old-box", "state": "STOPPED", "id": "ocid1.instance.oc1..bbb"},
          {"name": "ghost", "state": "TERMINATED", "id": "ocid1.instance.oc1..ccc"}
        ]
        """
        let instances = try XCTUnwrap(OracleInstances.parse(json))
        XCTAssertEqual(instances.map(\.name), ["audio-1", "old-box"])
        XCTAssertTrue(instances[0].isRunning)
        XCTAssertFalse(instances[1].isRunning)
    }

    func testGarbageIsNilButValidEmptyIsEmpty() {
        XCTAssertNil(OracleInstances.parse("Warning: your API key…\n[]"),
                     "banner-polluted output is not the listing — the caller keeps stale rows")
        XCTAssertNil(OracleInstances.parse("not json"))
        XCTAssertEqual(OracleInstances.parse("[]"), [])
    }
}

/// The service over a fake runner: the exact CLI contract (tenancy-wide search, --all),
/// quiet no-ops without a binary or config, stale rows + loud lastError on failure.
@MainActor
final class OracleServiceTests: XCTestCase {

    private let listJSON = """
    [{"name": "audio-1", "state": "RUNNING", "id": "ocid1.instance.oc1..aaa"}]
    """

    private func makeService(_ runner: FakeRunner) -> OracleService {
        OracleService(ociPath: "/fake/oci", hasConfig: true, region: "us-chicago-1", runner: runner)
    }

    func testRefreshParsesAndCarriesContract() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = makeService(runner)

        await service.refresh()

        XCTAssertEqual(service.instances.map(\.name), ["audio-1"])
        XCTAssertNil(service.lastError)
        XCTAssertEqual(
            runner.calls.first?.args,
            ["search", "resource", "structured-search",
             "--query-text", OracleInstances.searchText,
             "--query", OracleInstances.cliQuery,
             "--output", "json"],
            // structured-search spans every compartment by nature and has NO --all option
            // (the CLI exits 2 on it) — verified against the live oci CLI.
            "tenancy-wide search, child compartments included"
        )
    }

    func testMissingBinaryOrConfigNeverRuns() async {
        let runner = FakeRunner(result: .success(listJSON))
        let none = OracleService(ociPath: nil, hasConfig: true, region: nil, runner: runner)
        await none.refresh()
        let noConfig = OracleService(ociPath: "/fake/oci", hasConfig: false, region: nil, runner: runner)
        await noConfig.refresh()
        XCTAssertTrue(runner.calls.isEmpty, "no binary or no config → no subprocess, no rows")
        XCTAssertTrue(none.instances.isEmpty)
    }

    func testFailureKeepsStaleRowsAndIsLoud() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = makeService(runner)
        await service.refresh()
        XCTAssertEqual(service.instances.count, 1)

        runner.result = .failure(LinkCError.process("rate limited"))
        await service.refresh()
        XCTAssertEqual(service.instances.count, 1, "a network blip must not blank the section")
        XCTAssertTrue(service.lastError?.contains("rate limited") == true, "and it must not be silent")

        runner.result = .success(listJSON)
        await service.refresh()
        XCTAssertNil(service.lastError, "the next success clears the failure")
    }

    func testExitZeroGarbageKeepsStaleRows() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = makeService(runner)
        await service.refresh()

        runner.result = .success("Warning: some banner\nnot json")
        await service.refresh()
        XCTAssertEqual(service.instances.count, 1,
                       "exit-0 stdout noise must not blank the section either")
        XCTAssertNotNil(service.lastError)
    }
}
