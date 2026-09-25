import XCTest
@testable import LinkCKit

final class BoardSlugTests: XCTestCase {
    func testANameBecomesLowercaseWords() {
        XCTAssertEqual(BoardSlug.part("Audio engine"), "audio-engine")
        XCTAssertEqual(BoardSlug.part("  ALU  Control_Unit "), "alu-control-unit")
        XCTAssertEqual(BoardSlug.part("R&D / Ops"), "rd-ops")
        XCTAssertEqual(BoardSlug.part("✨"), "part")
    }

    func testNestedSlugsAndTheSuffix() {
        XCTAssertEqual(BoardSlug.new(for: "Audio engine", under: nil, taken: []), "audio-engine")
        XCTAssertEqual(BoardSlug.new(for: "Mixer", under: "audio-engine", taken: []), "audio-engine.mixer")
        XCTAssertEqual(BoardSlug.new(for: "Audio engine", under: nil, taken: ["audio-engine", "audio-engine-2"]), "audio-engine-3")
    }

    func testOnlyWellFormedSlugsAreValid() {
        XCTAssertTrue(BoardSlug.isValid("audio-engine.mixer"))
        XCTAssertFalse(BoardSlug.isValid("../etc"))
        XCTAssertFalse(BoardSlug.isValid("a..b"))
        XCTAssertFalse(BoardSlug.isValid("Audio"))
        XCTAssertFalse(BoardSlug.isValid(""))
    }

    func testFileNames() {
        XCTAssertEqual(BoardSlug.fileName(for: nil), "system-map.json")
        XCTAssertEqual(BoardSlug.fileName(for: "audio-engine"), "system-map.audio-engine.json")
        XCTAssertEqual(BoardSlug.slug(fromFileName: "system-map.audio-engine.mixer.json"), "audio-engine.mixer")
        XCTAssertNil(BoardSlug.slug(fromFileName: "system-map.json"))
        XCTAssertNil(BoardSlug.slug(fromFileName: "notes.json"))
    }
}
