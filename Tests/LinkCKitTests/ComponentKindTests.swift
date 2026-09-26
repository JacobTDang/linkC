import XCTest
@testable import LinkCKit

final class ComponentKindTests: XCTestCase {
    func testTheGroupsCoverEveryKnownKindOnce() {
        let grouped = ComponentKind.groups.flatMap(\.kinds)
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(ComponentKind.known))
        XCTAssertEqual(ComponentKind.groups.map(\.title), ["System", "AI agents", "Hardware"])
        XCTAssertEqual(ComponentKind.groups.map(\.kinds.count), [8, 12, 10])
    }

    func testNewKindsAreKnownAndKeepTheirIDs() {
        XCTAssertTrue(ComponentKind("vector-store").isKnown)
        XCTAssertEqual(ComponentKind.vectorStore.raw, "vector-store")
        XCTAssertTrue(ComponentKind("alu").isKnown)
        XCTAssertFalse(ComponentKind("flux-capacitor").isKnown)
    }

    func testGroupedKindListNamesEachGroupWithItsKinds() {
        let text = ComponentKind.groupedKindList
        XCTAssertTrue(text.hasPrefix("System: database, table, cache, queue, storage, service, host, external; "), text)
        XCTAssertTrue(text.contains("AI agents: agent, model, tool, mcp, router, start, end, vector-store, memory, prompt, state, human"), text)
        XCTAssertTrue(text.contains("Hardware: alu, mux, demux, register, ram, control, adder, decoder, clock, bus"), text)
        for kind in ComponentKind.known {
            XCTAssertTrue(text.contains(kind.raw), kind.raw)
        }
    }

    func testTableIsInTheSystemGroupRightAfterDatabase() {
        XCTAssertEqual(ComponentKind.table.raw, "table")
        XCTAssertEqual(ComponentKind.groups[0].kinds, [.database, .table, .cache, .queue, .storage, .service, .host, .external])
        XCTAssertTrue(ComponentKind.known.contains(.table))
        XCTAssertTrue(ComponentKind.table.isKnown)
    }
}
