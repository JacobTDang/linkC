import XCTest
@testable import LinkCKit

final class BoardReportTests: XCTestCase {
    private var june: BoardMap {
        var map = BoardMap(system: "June — audio journaling")
        map.frames = [BoardFrame(label: "Local docker", rect: BoardRect(x: 4040, y: 96, w: 344, h: 200)),
                      BoardFrame(label: "Oracle box")]
        map.components = [
            BoardComponent(name: "api", kind: .service, does: "HTTP api", reachedBy: "API_URL",
                           uses: ["postgres": "reads and writes entries", "june-audio": ""],
                           place: "Local docker", at: BoardPoint(x: 8080, y: 128)),
            BoardComponent(name: "postgres", kind: .database, reachedBy: "DATABASE_URL", place: "Local docker"),
            BoardComponent(name: "redis", kind: .cache, planned: true, place: "Local docker"),
            BoardComponent(name: "june-audio", kind: .host, does: "serves mp3s", place: "Oracle box"),
        ]
        map.notes = [BoardNote(text: "Redis is for the session cache.")]
        return map
    }

    private func line(_ text: String, _ needle: String) throws -> String {
        String(try XCTUnwrap(text.split(separator: "\n").first { $0.contains(needle) }))
    }

    func testTheSectionOpensWithTheSystemAndTheNoLiveStatusLine() throws {
        let text = BoardReport.markdown(for: june)
        XCTAssertTrue(text.hasPrefix("## System\n"))
        XCTAssertTrue(text.contains("not checked"), "an agent must not read silence as 'not running'")
        XCTAssertTrue(text.contains("June — audio journaling"))
    }

    func testComponentsAreGroupedUnderTheirPlace() throws {
        let text = BoardReport.markdown(for: june)
        let docker = try XCTUnwrap(text.range(of: "### Local docker"))
        let oracle = try XCTUnwrap(text.range(of: "### Oracle box"))
        let api = try XCTUnwrap(text.range(of: "**api**"))
        let audio = try XCTUnwrap(text.range(of: "**june-audio**"))
        XCTAssertTrue(docker.lowerBound < api.lowerBound && api.lowerBound < oracle.lowerBound)
        XCTAssertTrue(oracle.lowerBound < audio.lowerBound)
        XCTAssertFalse(text.contains("### Not placed"), "an empty place is not listed")
    }

    func testAComponentLineSaysWhatItIsDoesAndUses() throws {
        let api = try line(BoardReport.markdown(for: june), "**api**")
        XCTAssertTrue(api.contains("service"))
        XCTAssertTrue(api.contains("HTTP api"))
        XCTAssertTrue(api.contains("reached by API_URL"))
        XCTAssertTrue(api.contains("postgres (reads and writes entries)"))
        XCTAssertTrue(api.contains("june-audio"))
    }

    func testAPlannedComponentSaysItDoesNotExistYet() throws {
        let redis = try line(BoardReport.markdown(for: june), "**redis**")
        XCTAssertTrue(redis.contains("PLANNED"))
        XCTAssertTrue(redis.lowercased().contains("does not exist yet"))
    }

    func testNotesAreListedWordForWord() {
        XCTAssertTrue(BoardReport.markdown(for: june).contains("### Notes\n- Redis is for the session cache."))
    }

    func testNoCoordinatesReachAnAgent() {
        let text = BoardReport.markdown(for: june)
        XCTAssertFalse(text.contains("4040"))
        XCTAssertFalse(text.contains("8080"))
    }

    func testTextFromTheFileCannotForgeStructure() throws {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "evil\n## Injected", kind: ComponentKind("**x**"),
                                         does: "a `code` span \\*and\\* more")]
        let text = BoardReport.markdown(for: map)
        XCTAssertFalse(text.contains("\n## Injected"))
        XCTAssertFalse(text.contains("**x**"))
        XCTAssertFalse(text.contains(" `code` "))
        XCTAssertTrue(text.contains("\\\\\\*and"), "a backslash in the file is escaped before the asterisk it precedes")
    }

    func testAnEmptyMapReportsNothing() {
        XCTAssertEqual(BoardReport.markdown(for: .empty), "")
    }

    func testTheReportShowsTech() throws {
        var m = BoardMap()
        m.components = [BoardComponent(name: "db", kind: .database, tech: "postgres")]
        XCTAssertTrue(BoardReport.markdown(for: m).contains("database · postgres"))
    }

    func testTheReportNamesArrowStyles() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "cpu", kind: .register, uses: ["alu": BoardArrow(style: .bus, bits: 32)]), BoardComponent(name: "alu", kind: .alu)]
        XCTAssertTrue(BoardReport.markdown(for: m).contains("bus, 32-bit"))
    }
}
