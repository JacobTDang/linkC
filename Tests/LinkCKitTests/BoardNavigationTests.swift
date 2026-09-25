import XCTest
@testable import LinkCKit

final class BoardNavigationTests: XCTestCase {
    private let path = "/p/june"
    private func at(_ slug: String?) -> BoardAddress { BoardAddress(projectPath: path, slug: slug) }
    private let catalog = BoardCatalog(entries: [
        .init(slug: nil, path: ["June"], linked: true),
        .init(slug: "audio-engine", path: ["June", "Audio engine"], linked: true),
        .init(slug: "audio-engine.mixer", path: ["June", "Audio engine", "Mixer"], linked: true),
        .init(slug: "api", path: ["June", "API"], linked: true),
        .init(slug: "old-cache", path: ["June", "old-cache"], linked: false),
    ])

    func testTheOverviewKeepsItsOldViewportKey() {
        XCTAssertEqual(at(nil).viewportKey, "/p/june")
        XCTAssertEqual(at("audio-engine.mixer").viewportKey, "/p/june#audio-engine.mixer")
    }

    func testUpGoesOneLevel() {
        XCTAssertEqual(at("audio-engine.mixer").up, at("audio-engine"))
        XCTAssertEqual(at("audio-engine").up, at(nil))
        XCTAssertNil(at(nil).up)
    }

    func testCrumbsFollowTheCatalogPath() {
        XCTAssertEqual(BoardNavigation.crumbs(for: at("audio-engine.mixer"), in: catalog), [
            .init(title: "June", address: at(nil)),
            .init(title: "Audio engine", address: at("audio-engine")),
            .init(title: "Mixer", address: at("audio-engine.mixer")),
        ])
        XCTAssertEqual(BoardNavigation.crumbs(for: at(nil), in: catalog), [.init(title: "June", address: at(nil))])
    }

    func testAnUnlinkedOrUnknownBoardsCrumbs() {
        XCTAssertEqual(BoardNavigation.crumbs(for: at("old-cache"), in: catalog), [
            .init(title: "June", address: at(nil)),
            .init(title: "old-cache", address: at("old-cache")),
        ])
        XCTAssertEqual(BoardNavigation.crumbs(for: at("gone"), in: catalog), [.init(title: "June", address: at(nil))])
    }

    func testTheMenuIsATreeThenUnlinked() {
        XCTAssertEqual(BoardNavigation.menuRows(for: catalog, projectPath: path), [
            .init(title: "June", indent: 0, address: at(nil)),
            .init(title: "Audio engine", indent: 1, address: at("audio-engine")),
            .init(title: "Mixer", indent: 2, address: at("audio-engine.mixer")),
            .init(title: "API", indent: 1, address: at("api")),
            .init(title: "Unlinked", indent: 0, address: nil),
            .init(title: "old-cache", indent: 1, address: at("old-cache")),
        ])
    }

    func testNoUnlinkedHeaderWhenNothingIsUnlinked() {
        let linkedOnly = BoardCatalog(entries: [.init(slug: nil, path: ["June"], linked: true)])
        XCTAssertEqual(BoardNavigation.menuRows(for: linkedOnly, projectPath: path), [.init(title: "June", indent: 0, address: at(nil))])
    }
}
