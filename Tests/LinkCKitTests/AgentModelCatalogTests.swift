import XCTest
@testable import LinkCKit

final class AgentModelCatalogTests: XCTestCase {
    func testInteractiveSwitchCommandFormatting() {
        XCTAssertEqual(AgentModelCatalog.interactiveSwitchCommand(model: "haiku", for: .claude), "/model haiku")
        XCTAssertEqual(AgentModelCatalog.interactiveSwitchCommand(model: "o3-mini", for: .codex), "/model o3-mini")
        XCTAssertEqual(AgentModelCatalog.interactiveSwitchCommand(model: "flash", for: .agy), "/model flash")
        XCTAssertEqual(AgentModelCatalog.interactiveSwitchCommand(model: "default", for: .cursor), "/model default")
    }

    func testLaunchArgumentsFormatting() {
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "haiku", for: .claude), ["--model", "haiku"])
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "o3-mini", for: .codex), ["--model", "o3-mini"])
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "flash", for: .agy), ["--model", "flash"])
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "default", for: .cursor), ["--model", "default"])
    }

    /// OpenCode 2.2.5's TUI has no `--model` flag; its model goes in its inline config instead.
    func testOpenCodeTakesNoModelArgument() {
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "opencode/big-pickle", for: .opencode), [])
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "gpt-5.6-sol", for: .codex), ["--model", "gpt-5.6-sol"])
    }

    /// Kilo's TUI has no `--model` flag; its model goes in `KILO_CONFIG_CONTENT` instead.
    func testKiloTakesNoModelArgument() {
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "kilo/kilo-auto/free", for: .kilo), [])
    }

    /// Crush's TUI has no model flag either; its model is pinned through a per-session config.
    func testCrushTakesNoModelArgument() {
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "openrouter/nvidia/nemotron-3.5-super-vl:free", for: .crush), [])
    }
}
