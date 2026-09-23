import XCTest
@testable import LinkCKit

final class SystemMapReportTests: XCTestCase {
    private let map = SystemMap(components: [
        SystemComponent(name: "postgres", kind: .database, reachedBy: "DATABASE_URL",
                        runs: "docker compose (db)", usedBy: ["api", "worker"]),
        SystemComponent(name: "redis", kind: .cache, reachedBy: "REDIS_URL", intended: true),
        SystemComponent(name: "june-audio", kind: .host, reachedBy: "https://audio.example/mp3"),
    ])

    func testEveryComponentIsListedWithHowItIsReached() {
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        XCTAssertTrue(text.contains("## System"), text)
        XCTAssertTrue(text.contains("postgres"))
        XCTAssertTrue(text.contains("database"))
        XCTAssertTrue(text.contains("DATABASE_URL"))
        XCTAssertTrue(text.contains("docker compose (db)"))
        XCTAssertTrue(text.contains("api, worker"))
        XCTAssertTrue(text.contains("https://audio.example/mp3"))
    }

    /// An agent must not treat something planned as something it can use.
    func testAnIntendedComponentSaysItDoesNotExistYet() throws {
        let line = try XCTUnwrap(
            SystemMapReport.markdown(for: map, statuses: [:])
                .split(separator: "\n").first { $0.contains("redis") })
        XCTAssertTrue(line.lowercased().contains("intended"), String(line))
    }

    func testAStatusIsReportedOnlyWhenLinkCKnowsOne() throws {
        let text = SystemMapReport.markdown(
            for: map, statuses: ["postgres": .present, "june-audio": .unchecked])
        let lines = text.split(separator: "\n")
        let postgres = try XCTUnwrap(lines.first { $0.contains("postgres") })
        let audio = try XCTUnwrap(lines.first { $0.contains("june-audio") })
        XCTAssertTrue(postgres.lowercased().contains("running"), String(postgres))
        XCTAssertFalse(audio.lowercased().contains("running"), String(audio))
        XCTAssertFalse(audio.lowercased().contains("missing"), String(audio))
    }

    func testAMissingComponentSaysSo() throws {
        let line = try XCTUnwrap(
            SystemMapReport.markdown(for: map, statuses: ["postgres": .missing])
                .split(separator: "\n").first { $0.contains("postgres") })
        XCTAssertTrue(line.lowercased().contains("not running"), String(line))
    }

    func testAnEmptyMapReportsNothing() {
        XCTAssertTrue(SystemMapReport.markdown(for: .empty, statuses: [:]).isEmpty)
    }
}
