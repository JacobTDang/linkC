import XCTest
@testable import LinkCKit

final class SystemMapReportTests: XCTestCase {
    private let map = SystemMap(components: [
        SystemComponent(name: "postgres", kind: .database, reachedBy: "DATABASE_URL",
                        runs: "docker compose (db)", usedBy: ["api", "worker"]),
        SystemComponent(name: "redis", kind: .cache, reachedBy: "REDIS_URL", intended: true),
        SystemComponent(name: "june-audio", kind: .host, reachedBy: "https://audio.example/mp3"),
    ])

    func testEveryComponentIsListedWithHowItIsReached() throws {
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        XCTAssertTrue(text.contains("## System"), text)

        let postgres = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("postgres") })
        XCTAssertTrue(postgres.contains("database"), String(postgres))
        XCTAssertTrue(postgres.contains("DATABASE_URL"), String(postgres))
        XCTAssertTrue(postgres.contains("docker compose (db)"), String(postgres))
        XCTAssertTrue(postgres.contains("api, worker"), String(postgres))

        let audio = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("june-audio") })
        XCTAssertTrue(audio.contains("https://audio.example/mp3"), String(audio))
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

    /// This tool has no discovery of its own — a context-read runs no processes — so a reader
    /// must never mistake silence for "not running": the section must say, once, that it is not
    /// checking, and where checked status actually lives.
    func testTheSectionSaysStatusIsNotCheckedHere() throws {
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "## System", text)

        let notice = try XCTUnwrap(lines.dropFirst().first { !$0.isEmpty })
        XCTAssertTrue(notice.lowercased().contains("not checked"), String(notice))
        XCTAssertTrue(notice.lowercased().contains("board"), String(notice))

        // Exactly one notice — not one per component.
        let mentions = lines.filter { $0.lowercased().contains("not checked") }
        XCTAssertEqual(mentions.count, 1, text)
    }

    // MARK: - Text from the map cannot introduce structure

    /// `system-map.json` is a file in a repository, which may be a cloned one: a name is not
    /// trusted input. An embedded newline must never split a component onto extra lines — that
    /// is how a name could forge a heading or start of a new bullet another model reads as real.
    func testANewlineInAFieldIsCollapsedToASpace() throws {
        let map = SystemMap(components: [
            SystemComponent(name: "evil", kind: .service, reachedBy: "line one\n# forged heading\nline two"),
        ])
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains("evil") }
        XCTAssertEqual(lines.count, 1, "an embedded newline must not split one component across lines: \(text)")
        XCTAssertFalse(text.contains("\n# forged heading"), "a newline must never let a field start its own line: \(text)")
    }

    /// A control character (not just `\n`) is just as capable of corrupting the markdown a
    /// downstream model parses, so it is collapsed the same way.
    func testAControlCharacterInAFieldIsCollapsedToASpace() throws {
        let map = SystemMap(components: [
            SystemComponent(name: "evil", kind: .service, runs: "before\u{0007}after"),
        ])
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("evil") })
        XCTAssertFalse(line.contains("\u{0007}"), String(line))
        XCTAssertTrue(line.contains("before after"), String(line))
    }

    /// The template already wraps a name in `**…**`. A name carrying its own `**` must not be
    /// able to close that bold early and reopen it somewhere the caller never intended.
    func testAsteriskPairsInAFieldCannotForgeBoldAcrossTheLine() throws {
        let map = SystemMap(components: [SystemComponent(name: "evil**name", kind: .service)])
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("evil") })
        let pairs = line.components(separatedBy: "**").count - 1
        XCTAssertEqual(pairs, 2, "only the template's own **name** wrapper may use it: \(line)")
    }

    /// A backtick in a field must not be able to open a code span (or, worse, a fence) that
    /// swallows the rest of the report.
    func testABacktickInAFieldCannotOpenACodeSpan() throws {
        let map = SystemMap(components: [
            SystemComponent(name: "shady", kind: .service, reachedBy: "`rm -rf /`"),
        ])
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("shady") })
        XCTAssertFalse(line.contains("`rm -rf /`"), "a raw, unescaped backtick pair must not survive: \(line)")
    }

    /// A field's own backslash must be escaped too, and before `*`/backtick are — otherwise a
    /// backslash sitting right next to one of those combines with the escaping backslash this
    /// function inserts, cancelling it out: `\*x\*` must render as that literal text, not as a
    /// stray backslash plus live emphasis.
    func testABackslashInAFieldCannotCancelTheEscapeOfAnAsterisk() throws {
        let map = SystemMap(components: [
            SystemComponent(name: "evil", kind: .service, reachedBy: #"\*x\*"#),
        ])
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("evil") })
        // The field's own backslash must render as an escaped backslash (`\\`) in its own right,
        // leaving the asterisk right after it still escaped (`\*`) rather than freed to open
        // live emphasis — so each `\*` in the field becomes `\\\*` in the report.
        XCTAssertTrue(line.contains(#"\\\*x\\\*"#), String(line))
    }

    /// A field is capped so one component cannot balloon a tool result an agent has to read.
    func testAnOverlongFieldIsCapped() throws {
        let long = String(repeating: "a", count: 4000)
        let map = SystemMap(components: [SystemComponent(name: "big", kind: .service, runs: long)])
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("big") })
        XCTAssertLessThan(line.count, long.count, "an overlong field must be capped: \(line.count) characters")
    }
}
