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

    func testGroupedKindListNamesEachGroupWithItsKinds() {
        let text = ComponentKind.groupedKindList
        XCTAssertTrue(text.hasPrefix("System: database, cache, queue, storage, service, host, external; "), text)
        XCTAssertTrue(text.contains("AI agents: agent, model, tool, mcp, router, start, end, vector-store, memory, prompt, state, human"), text)
        XCTAssertTrue(text.contains("Hardware: alu, mux, demux, register, ram, control, adder, decoder, clock, bus"), text)
        for kind in ComponentKind.known {
            XCTAssertTrue(text.contains(kind.raw), kind.raw)
        }
    }
}
