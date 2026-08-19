import XCTest
@testable import LinkCKit

/// The `~/.oci/config` tenancy parse: first `tenancy=` line of the ini wins; comments
/// and missing keys are quiet nils.
final class OCIConfigTests: XCTestCase {

    func testTenancyParsed() {
        let config = """
        [DEFAULT]
        user=ocid1.user.oc1..aaa
        fingerprint=aa:bb
        tenancy=ocid1.tenancy.oc1..zzz
        region=us-chicago-1
        """
        XCTAssertEqual(OCIConfig.tenancy(from: config), "ocid1.tenancy.oc1..zzz")
    }

    func testWhitespaceAndCommentsTolerated() {
        let config = """
        # tenancy=ocid1.tenancy.oc1..commented
        [DEFAULT]
        tenancy = ocid1.tenancy.oc1..spaced
        """
        XCTAssertEqual(OCIConfig.tenancy(from: config), "ocid1.tenancy.oc1..spaced")
    }

    func testMissingTenancyIsNil() {
        XCTAssertNil(OCIConfig.tenancy(from: "[DEFAULT]\nuser=ocid1.user.oc1..aaa"))
    }
}

/// `oci compute instance list --output json`: real CLI field names, terminated rows
/// dropped (console noise, not state).
final class OracleInstancesTests: XCTestCase {

    func testParsesRunningAndStoppedDropsTerminated() throws {
        // The CLI is invoked with a JMESPath --query that renames fields and drops the
        // rest (keeps output far under the runner's 64KB after-exit pipe read).
        let json = """
        [
          {"name": "june-audio", "state": "RUNNING",
           "shape": "VM.Standard.A1.Flex", "region": "us-chicago-1",
           "id": "ocid1.instance.oc1.us-chicago-1.aaa"},
          {"name": "old-box", "state": "STOPPED",
           "shape": "VM.Standard.E2.1.Micro", "region": "us-chicago-1",
           "id": "ocid1.instance.oc1.us-chicago-1.bbb"},
          {"name": "ghost", "state": "TERMINATED",
           "shape": "VM.Standard.A1.Flex", "region": "us-chicago-1",
           "id": "ocid1.instance.oc1.us-chicago-1.ccc"}
        ]
        """
        let instances = OracleInstances.parse(json)
        XCTAssertEqual(instances.map(\.name), ["june-audio", "old-box"])
        XCTAssertEqual(instances[0].state, "RUNNING")
        XCTAssertEqual(instances[0].shape, "VM.Standard.A1.Flex")
        XCTAssertEqual(instances[0].region, "us-chicago-1")
        XCTAssertTrue(instances[0].isRunning)
        XCTAssertFalse(instances[1].isRunning)
    }

    func testGarbageIsEmpty() {
        XCTAssertTrue(OracleInstances.parse("not json").isEmpty)
        XCTAssertTrue(OracleInstances.parse("[]").isEmpty)
    }
}

/// The service over a fake runner: the exact CLI contract, quiet no-ops without a
/// binary or tenancy, stale rows kept over a network blip.
@MainActor
final class OracleServiceTests: XCTestCase {

    private let listJSON = """
    [{"name": "june-audio", "state": "RUNNING",
     "shape": "VM.Standard.A1.Flex", "region": "us-chicago-1",
     "id": "ocid1.instance.oc1.us-chicago-1.aaa"}]
    """

    func testRefreshParsesAndCarriesContract() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = OracleService(ociPath: "/fake/oci", tenancy: "ocid1.tenancy.oc1..zzz", runner: runner)

        await service.refresh()

        XCTAssertEqual(service.instances.map(\.name), ["june-audio"])
        XCTAssertEqual(
            runner.calls.first?.args,
            ["compute", "instance", "list", "--compartment-id", "ocid1.tenancy.oc1..zzz",
             "--query", OracleInstances.cliQuery, "--output", "json"]
        )
    }

    func testMissingBinaryOrTenancyNeverRuns() async {
        let runner = FakeRunner(result: .success(listJSON))
        let none = OracleService(ociPath: nil, tenancy: "ocid1.tenancy.oc1..zzz", runner: runner)
        await none.refresh()
        let noTenancy = OracleService(ociPath: "/fake/oci", tenancy: nil, runner: runner)
        await noTenancy.refresh()
        XCTAssertTrue(runner.calls.isEmpty, "no binary or no tenancy → no subprocess, no rows")
        XCTAssertTrue(none.instances.isEmpty)
    }

    func testFailureKeepsStaleRows() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = OracleService(ociPath: "/fake/oci", tenancy: "t", runner: runner)
        await service.refresh()
        XCTAssertEqual(service.instances.count, 1)

        runner.result = .failure(LinkCError.process("rate limited"))
        await service.refresh()
        XCTAssertEqual(service.instances.count, 1, "a network blip must not blank the section")
    }
}
