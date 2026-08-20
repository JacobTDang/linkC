import XCTest
@testable import LinkCKit

/// `supabase projects list --output json`, shapes captured from the live CLI.
final class SupabaseProjectsTests: XCTestCase {

    /// Real output: two projects, one paused. Note the CLI prints an unrelated
    /// "Cannot find project ref" line to STDERR — the runner discards stderr, so stdout
    /// is clean JSON, but the parser stays tolerant of a leading banner regardless.
    private let listJSON = """
    [
      {"id": "uaaodmiqcvmvesbemiha", "name": "Sprout", "region": "us-west-2",
       "status": "INACTIVE", "created_at": "2026-07-14T01:33:46.075775Z",
       "database": {"postgres_engine": "17", "version": "17.6.1.141"}},
      {"id": "ksqjgsezfqfevnfvonnm", "name": "june", "region": "ca-central-1",
       "status": "ACTIVE_HEALTHY", "created_at": "2026-07-19T19:28:38.429827Z",
       "database": {"postgres_engine": "17", "version": "17.6.1.147"}}
    ]
    """

    func testParsesProjectsWithStatus() throws {
        let projects = try XCTUnwrap(SupabaseProjects.parse(listJSON))
        XCTAssertEqual(projects.map(\.name), ["Sprout", "june"])
        XCTAssertEqual(projects[0].status, "INACTIVE")
        XCTAssertFalse(projects[0].isHealthy, "a paused project is not healthy")
        XCTAssertTrue(projects[1].isHealthy)
        XCTAssertEqual(projects[1].region, "ca-central-1")
        XCTAssertEqual(projects[1].postgresVersion, "17")
    }

    /// A paused project is the signal worth surfacing — Supabase pauses free projects
    /// after inactivity and they stop serving requests until restored.
    func testPausedIsDistinctFromEveryOtherState() {
        XCTAssertTrue(SupabaseProject.isPaused("INACTIVE"))
        XCTAssertFalse(SupabaseProject.isPaused("ACTIVE_HEALTHY"))
        XCTAssertFalse(SupabaseProject.isPaused("COMING_UP"))
    }

    func testTolerantOfLeadingBannerAndGarbage() {
        // Defensive: some CLI versions print notices before the payload.
        XCTAssertEqual(SupabaseProjects.parse("Cannot find project ref.\n" + listJSON)?.count, 2)
        XCTAssertNil(SupabaseProjects.parse("not json"), "unparseable output is nil, never an empty list")
        XCTAssertEqual(SupabaseProjects.parse("[]")?.count, 0, "a real empty account is a real zero")
    }
}

/// The service over a fake runner: CLI contract, quiet without the binary, stale rows on
/// failure — the same discipline as OracleService.
@MainActor
final class SupabaseServiceTests: XCTestCase {

    private let listJSON = """
    [{"id": "abc", "name": "june", "region": "ca-central-1", "status": "ACTIVE_HEALTHY",
      "database": {"postgres_engine": "17"}}]
    """

    func testRefreshParsesAndCarriesContract() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = SupabaseService(cliPath: "/fake/supabase", runner: runner)

        await service.refresh()

        XCTAssertEqual(service.projects.map(\.name), ["june"])
        XCTAssertEqual(runner.calls.first?.args, ["projects", "list", "--output", "json"])
        XCTAssertNil(service.lastError)
    }

    func testMissingBinaryNeverRuns() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = SupabaseService(cliPath: nil, runner: runner)
        await service.refresh()
        XCTAssertTrue(runner.calls.isEmpty, "no binary, no subprocess")
        XCTAssertTrue(service.projects.isEmpty)
    }

    /// Not logged in is the expected first-run state, not an error to shout about — but it
    /// must be distinguishable from "no projects".
    func testUnauthenticatedIsRecognized() async {
        let runner = FakeRunner(result: .failure(
            LinkCError.process("Access token not provided. Supply an access token by running supabase login")
        ))
        let service = SupabaseService(cliPath: "/fake/supabase", runner: runner)

        await service.refresh()

        XCTAssertTrue(service.needsLogin, "the login prompt is a state, not a failure")
        XCTAssertNil(service.lastError, "and it isn't reported as an error")
    }

    func testFailureKeepsStaleRowsAndIsLoud() async {
        let runner = FakeRunner(result: .success(listJSON))
        let service = SupabaseService(cliPath: "/fake/supabase", runner: runner)
        await service.refresh()
        XCTAssertEqual(service.projects.count, 1)

        runner.result = .failure(LinkCError.process("network unreachable"))
        await service.refresh()
        XCTAssertEqual(service.projects.count, 1, "a blip must not blank the section")
        XCTAssertNotNil(service.lastError)
        XCTAssertFalse(service.needsLogin, "a network error is not a login problem")
    }
}
