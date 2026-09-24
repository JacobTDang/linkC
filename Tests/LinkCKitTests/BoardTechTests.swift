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
        XCTAssertEqual(BoardTech.knownIDs.count, 69) // 47 Simple Icons + 22 AI brands from lobe-icons
        for id in BoardTech.knownIDs {
            let info = try XCTUnwrap(BoardTech.info(id), id)
            let image = try XCTUnwrap(NSImage(data: Data(info.svg.utf8)), "\(id) does not load")
            XCTAssertTrue(image.isValid, id)
            XCTAssertTrue(image.representations.contains { String(describing: type(of: $0)).contains("SVG") }, id)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), id)
            XCTAssertFalse(info.displayName.isEmpty, id)
        }
    }

    func testTheAIBrandsLoad() throws {
        for id in ["openai", "anthropic", "gemini", "mistral", "meta", "deepseek", "ollama", "huggingface", "langchain", "langgraph",
                   "llamaindex", "crewai", "groq", "perplexity", "cohere", "qwen", "xai", "mcp", "openrouter", "vertexai", "bedrock", "azure"] {
            let info = try XCTUnwrap(BoardTech.info(id), id)
            let image = try XCTUnwrap(NSImage(data: Data(info.svg.utf8)), id)
            XCTAssertTrue(image.isValid, id)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), id)
        }
        XCTAssertEqual(BoardTech.knownIDs.count, 69)
        XCTAssertEqual(BoardTech.canonical("gpt"), "openai")
        XCTAssertEqual(BoardTech.canonical("grok"), "xai")
        XCTAssertEqual(BoardTech.canonical("llama"), "meta")
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

    /// A component named like an agent still draws its explicit `tech`: inference from the name
    /// — agent names included — only applies when `tech` is nil or empty. `agent(for:)` checks
    /// `tech` first and never falls back to the name once `tech` is set to something else.
    func testATechOverridesAnAgentLikeName() {
        let component = BoardComponent(name: "claude", kind: .service, tech: "postgresql")
        XCTAssertNil(BoardTech.agent(for: component), "an explicit tech must not fall back to matching the name")
        XCTAssertEqual(BoardTech.resolve(component)?.id, "postgresql", "the explicit tech wins over the agent-like name")
    }

    /// Same rule for a name that would otherwise resolve to an ordinary tech logo: an unrelated
    /// explicit `tech` — even one nobody recognises — must not fall back to the name either.
    func testAnUnknownTechDoesNotFallBackToTheName() {
        let component = BoardComponent(name: "redis", kind: .cache, tech: "oracle")
        XCTAssertNil(BoardTech.resolve(component), "an unknown tech draws the kind's icon, not the name's logo")
    }

    /// An empty `tech` — a hand-edited file's stray `"tech": ""`, say — is "no tech" exactly like
    /// nil: inference from the name still applies.
    func testAnEmptyTechIsTreatedAsNoTechForNameInference() {
        XCTAssertEqual(BoardTech.agent(for: BoardComponent(name: "claude", kind: .service, tech: "")), .claude)
        XCTAssertEqual(BoardTech.resolve(BoardComponent(name: "Redis", kind: .cache, tech: ""))?.id, "redis")
    }
}
