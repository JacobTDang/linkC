import XCTest
@testable import LinkCKit

@MainActor
final class TerminalSessionManagerSelectionTests: XCTestCase {
    func testEverySelectionChangeIsAnnouncedBeforeItHappens() {
        let manager = TerminalSessionManager()
        var announcedFrom: [String?] = []
        manager.onSelectionWillChange = { [unowned manager] in announcedFrom.append(manager.selectedId) }

        manager.makeSession(id: "a", cwd: "/tmp", title: "a")                 // nil → a
        manager.makeSession(id: "b", cwd: "/tmp", title: "b", select: false)  // unchanged
        manager.select("b")                                                    // a → b
        manager.select("b")                                                    // unchanged
        manager.select("missing")                                              // ignored
        manager.deselect()                                                     // b → nil
        manager.deselect()                                                     // unchanged
        manager.select("a")                                                    // nil → a
        manager.remove("a")                                                    // a → b (falls back to the last)
        manager.remove("zzz")                                                  // unchanged

        XCTAssertEqual(announcedFrom, [nil, "a", "b", nil, "a"])
        XCTAssertEqual(manager.selectedId, "b")
    }
}
