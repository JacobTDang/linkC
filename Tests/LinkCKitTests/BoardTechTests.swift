import AppKit
import XCTest
@testable import LinkCKit

final class BoardTechTests: XCTestCase {
    func testAliasesResolveToCanonicalIDs() {
        XCTAssertEqual(BoardTech.canonical("Postgres"), "postgresql")
        XCTAssertEqual(BoardTech.canonical("k8s"), "kubernetes")
        XCTAssertEqual(BoardTech.canonical("node"), "nodedotjs")
        XCTAssertEqual(BoardTech.canonical("redis"), "redis")
        XCTAssertNil(BoardTech.canonical("aws"))
    }

    func testEveryKnownLogoLoadsAsA24PointSVG() throws {
        XCTAssertEqual(BoardTech.knownIDs.count, 47)
        for id in BoardTech.knownIDs {
            let info = try XCTUnwrap(BoardTech.info(id), id)
            let image = try XCTUnwrap(NSImage(data: Data(info.svg.utf8)), "\(id) does not load")
            XCTAssertTrue(image.isValid, id)
            XCTAssertTrue(image.representations.contains { String(describing: type(of: $0)).contains("SVG") }, id)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), id)
            XCTAssertFalse(info.displayName.isEmpty, id)
        }
    }

    func testDarkBrandsAreFlagged() {
        XCTAssertEqual(BoardTech.info("github")?.isDark, true)
        XCTAssertEqual(BoardTech.info("redis")?.isDark, false)
    }

    func testResolveUsesTechThenAnExactName() {
        XCTAssertEqual(BoardTech.resolve(BoardComponent(name: "db", kind: .database, tech: "pg"))?.id, "postgresql")
        XCTAssertEqual(BoardTech.resolve(BoardComponent(name: "Redis", kind: .cache))?.id, "redis")
        XCTAssertNil(BoardTech.resolve(BoardComponent(name: "redis-worker", kind: .service)), "exact names only")
        XCTAssertNil(BoardTech.resolve(BoardComponent(name: "db", kind: .database, tech: "oracle")), "unknown tech draws the kind")
    }

    func testAgentNamesUseTheAgentLogos() {
        XCTAssertEqual(BoardTech.agent(for: BoardComponent(name: "claude", kind: .service)), .claude)
        XCTAssertEqual(BoardTech.agent(for: BoardComponent(name: "x", kind: .service, tech: "agy")), .agy)
        XCTAssertNil(BoardTech.resolve(BoardComponent(name: "codex", kind: .service)))
    }
}
