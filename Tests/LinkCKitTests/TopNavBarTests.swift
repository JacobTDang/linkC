import XCTest
@testable import LinkCKit

final class TopNavBarTests: XCTestCase {
    func testPanelScreenCasesForTopNav() {
        let expectedScreens: [PanelScreen] = [.activity, .skills, .mcpServers, .settings]
        for screen in expectedScreens {
            XCTAssertTrue(PanelScreen.allCases.contains(screen))
        }
    }

    func testPanelScreenIdentifiers() {
        XCTAssertEqual(PanelScreen.activity.rawValue, "activity")
        XCTAssertEqual(PanelScreen.skills.rawValue, "skills")
        XCTAssertEqual(PanelScreen.mcpServers.rawValue, "mcpServers")
        XCTAssertEqual(PanelScreen.settings.rawValue, "settings")
        XCTAssertEqual(PanelScreen.terminals.rawValue, "terminals")
        XCTAssertEqual(PanelScreen.toolServers.rawValue, "toolServers")
    }
}
