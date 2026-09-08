import XCTest
@testable import LinkCKit

final class AgentModelCatalogTests: XCTestCase {
    func testDefaultModelsForEachAgent() {
        let claudeDefault = AgentModelCatalog.defaultModel(for: .claude)
        XCTAssertEqual(claudeDefault.id, "sonnet")
        XCTAssertEqual(claudeDefault.displayName, "Claude 3.5 Sonnet")
        XCTAssertTrue(claudeDefault.isDefault)
        XCTAssertTrue(claudeDefault.isFreeOrSubscription)

        let codexDefault = AgentModelCatalog.defaultModel(for: .codex)
        XCTAssertEqual(codexDefault.id, "gpt-4o")
        XCTAssertEqual(codexDefault.displayName, "GPT-4o")
        XCTAssertTrue(codexDefault.isDefault)
        XCTAssertTrue(codexDefault.isFreeOrSubscription)

        let agyDefault = AgentModelCatalog.defaultModel(for: .agy)
        XCTAssertEqual(agyDefault.id, "pro")
        XCTAssertEqual(agyDefault.displayName, "Pro")
        XCTAssertTrue(agyDefault.isDefault)
        XCTAssertTrue(agyDefault.isFreeOrSubscription)

        let cursorDefault = AgentModelCatalog.defaultModel(for: .cursor)
        XCTAssertEqual(cursorDefault.id, "default")
        XCTAssertEqual(cursorDefault.displayName, "Cursor Default")
        XCTAssertTrue(cursorDefault.isDefault)
        XCTAssertTrue(cursorDefault.isFreeOrSubscription)

        let shellDefault = AgentModelCatalog.defaultModel(for: .shell)
        XCTAssertEqual(shellDefault.id, "default")
        XCTAssertEqual(shellDefault.displayName, "Default")
        XCTAssertTrue(shellDefault.isDefault)
        XCTAssertTrue(shellDefault.isFreeOrSubscription)
    }

    func testModelsListForEachAgent() {
        // Claude
        let claudeModels = AgentModelCatalog.models(for: .claude)
        XCTAssertEqual(claudeModels.count, 3)
        XCTAssertEqual(claudeModels.map(\.id), ["sonnet", "haiku", "opus"])
        XCTAssertEqual(claudeModels.map(\.displayName), ["Claude 3.5 Sonnet", "Claude 3.5 Haiku", "Claude 3 Opus"])
        XCTAssertEqual(claudeModels.map(\.isDefault), [true, false, false])
        XCTAssertTrue(claudeModels.allSatisfy(\.isFreeOrSubscription))

        // Codex
        let codexModels = AgentModelCatalog.models(for: .codex)
        XCTAssertEqual(codexModels.count, 3)
        XCTAssertEqual(codexModels.map(\.id), ["gpt-4o", "o3-mini", "o1-mini"])
        XCTAssertEqual(codexModels.map(\.displayName), ["GPT-4o", "o3-mini", "o1-mini"])
        XCTAssertEqual(codexModels.map(\.isDefault), [true, false, false])
        XCTAssertTrue(codexModels.allSatisfy(\.isFreeOrSubscription))

        // Agy
        let agyModels = AgentModelCatalog.models(for: .agy)
        XCTAssertEqual(agyModels.count, 3)
        XCTAssertEqual(agyModels.map(\.id), ["pro", "flash", "flash_lite"])
        XCTAssertEqual(agyModels.map(\.displayName), ["Pro", "Flash", "Flash Lite"])
        XCTAssertEqual(agyModels.map(\.isDefault), [true, false, false])
        XCTAssertTrue(agyModels.allSatisfy(\.isFreeOrSubscription))

        // Cursor
        let cursorModels = AgentModelCatalog.models(for: .cursor)
        XCTAssertEqual(cursorModels.count, 1)
        XCTAssertEqual(cursorModels.first?.id, "default")
        XCTAssertEqual(cursorModels.first?.displayName, "Cursor Default")
        XCTAssertEqual(cursorModels.first?.isDefault, true)
        XCTAssertEqual(cursorModels.first?.isFreeOrSubscription, true)

        // Shell
        let shellModels = AgentModelCatalog.models(for: .shell)
        XCTAssertTrue(shellModels.isEmpty)
    }

    func testFreeTierWhitelistValidation() {
        // Valid whitelisted models by ID
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "sonnet", for: .claude))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "haiku", for: .claude))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "opus", for: .claude))

        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "gpt-4o", for: .codex))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "o3-mini", for: .codex))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "o1-mini", for: .codex))

        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "pro", for: .agy))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "flash", for: .agy))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "flash_lite", for: .agy))

        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "default", for: .cursor))

        // Case-insensitivity support
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "SONNET", for: .claude))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "Haiku", for: .claude))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "GPT-4O", for: .codex))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "Pro", for: .agy))

        // Display name matching support
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "Claude 3.5 Sonnet", for: .claude))
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "Flash Lite", for: .agy))

        // Cross-agent rejection (models must belong to the given agent)
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "sonnet", for: .codex))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "gpt-4o", for: .claude))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "pro", for: .claude))

        // Rejection of non-whitelisted or pay-per-token API IDs
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "claude-3-5-sonnet-20241022", for: .claude))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "claude-3-opus-20240229", for: .claude))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "gpt-4-turbo", for: .codex))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "gpt-3.5-turbo", for: .codex))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "unknown-tier", for: .agy))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "", for: .claude))
        XCTAssertFalse(AgentModelCatalog.isFreeOrSubscription(model: "   ", for: .codex))
    }

    func testFallbackOrderingExcludingActiveModel() {
        // Claude fallback excluding current model
        let claudeFallbacks = AgentModelCatalog.fallbackModels(for: .claude, excluding: "sonnet")
        XCTAssertEqual(claudeFallbacks.map(\.id), ["haiku", "opus"])

        let claudeFallbacksHaiku = AgentModelCatalog.fallbackModels(for: .claude, excluding: "haiku")
        XCTAssertEqual(claudeFallbacksHaiku.map(\.id), ["sonnet", "opus"])

        // Excluding nil returns all in priority order
        let claudeAll = AgentModelCatalog.fallbackModels(for: .claude, excluding: nil)
        XCTAssertEqual(claudeAll.map(\.id), ["sonnet", "haiku", "opus"])

        // Excluding unknown model returns all in priority order
        let claudeUnknown = AgentModelCatalog.fallbackModels(for: .claude, excluding: "unknown-model")
        XCTAssertEqual(claudeUnknown.map(\.id), ["sonnet", "haiku", "opus"])

        // Codex fallback
        let codexFallbacks = AgentModelCatalog.fallbackModels(for: .codex, excluding: "gpt-4o")
        XCTAssertEqual(codexFallbacks.map(\.id), ["o3-mini", "o1-mini"])

        // Agy fallback
        let agyFallbacks = AgentModelCatalog.fallbackModels(for: .agy, excluding: "pro")
        XCTAssertEqual(agyFallbacks.map(\.id), ["flash", "flash_lite"])
    }

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

    func testCodableAndIdentifiableAgentModelInfo() throws {
        let original = AgentModelInfo(id: "custom-id", displayName: "Custom Model", isFreeOrSubscription: true, isDefault: false)
        XCTAssertEqual(original.id, "custom-id")

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AgentModelInfo.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.id, "custom-id")
        XCTAssertEqual(decoded.displayName, "Custom Model")
        XCTAssertTrue(decoded.isFreeOrSubscription)
        XCTAssertFalse(decoded.isDefault)
    }
}
