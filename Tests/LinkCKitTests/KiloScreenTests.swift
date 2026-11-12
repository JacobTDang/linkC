import XCTest
@testable import LinkCKit

/// Kilo's screens, captured from the real TUI. Its chrome matches OpenCode's, so the OpenCode
/// reader is reused; these tests pin the fixtures and the free-tier limit wording Kilo shows.
final class KiloScreenTests: XCTestCase {
    private func screen(_ name: String) throws -> [String] { try CodexScreenFixture.rows("kilo-\(name)") }

    func testAnIdleScreenReadsIdle() throws {
        XCTAssertNil(TerminalPreview.liveActivity(from: try screen("idle"), agent: .kilo))
        XCTAssertEqual(OpenCodeScreen.turn(in: try screen("idle")), .idle)
    }

    func testAWorkingScreenReadsWorking() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("working"), agent: .kilo), "Working")
        XCTAssertEqual(OpenCodeScreen.turn(in: try screen("working")), .working(phrase: "Working"))
    }

    func testThePermissionFixtureNamesPermissionRequired() throws {
        let rows = try screen("permission")
        XCTAssertTrue(rows.contains { $0.contains("Permission required") }, rows.joined(separator: "\n"))
        XCTAssertTrue(rows.contains { $0.contains("Allow once") }, "permission choices")
        XCTAssertTrue(rows.contains { $0.contains("Reject") }, "permission choices")
    }

    func testTheConnectFixtureNamesConnectAProvider() throws {
        let rows = try screen("connect")
        XCTAssertTrue(rows.contains { $0.contains("Connect a provider") }, rows.joined(separator: "\n"))
    }

    /// Live free-tier exhaustion was not forced; the fixture is idle chrome plus Kilo's own
    /// "Rate limit exceeded" banner wording from the binary.
    func testTheRateLimitFixtureIsALimitForKilo() throws {
        let frame = try String(contentsOf:
            try XCTUnwrap(Bundle.module.url(forResource: "kilo-rate-limit", withExtension: "txt")
                ?? Bundle.module.url(forResource: "kilo-rate-limit", withExtension: "txt", subdirectory: "Fixtures")),
            encoding: .utf8)
        let match = LimitDetector.detectLimit(inOutput: frame, agent: .kilo)
        XCTAssertNotNil(match, "expected a limit from 'Rate limit' + ' exceeded'")
        XCTAssertEqual(match?.agent, .kilo)
        XCTAssertEqual(match?.cooldown, LimitDetector.defaultCooldown)
        XCTAssertNil(LimitDetector.detectLimit(inOutput: frame, agent: .opencode),
                     "the phrase is Kilo's alone")
    }
}
