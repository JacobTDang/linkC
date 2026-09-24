import XCTest
@testable import LinkCKit

final class ComponentKindTests: XCTestCase {
    func testTheGroupsCoverEveryKnownKindOnce() {
        let grouped = ComponentKind.groups.flatMap(\.kinds)
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(ComponentKind.known))
        XCTAssertEqual(ComponentKind.groups.map(\.title), ["System", "AI agents", "Hardware"])
        XCTAssertEqual(ComponentKind.groups.map(\.kinds.count), [7, 12, 10])
    }

    func testNewKindsAreKnownAndKeepTheirIDs() {
        XCTAssertTrue(ComponentKind("vector-store").isKnown)
        XCTAssertEqual(ComponentKind.vectorStore.raw, "vector-store")
        XCTAssertTrue(ComponentKind("alu").isKnown)
        XCTAssertFalse(ComponentKind("flux-capacitor").isKnown)
    }
}
