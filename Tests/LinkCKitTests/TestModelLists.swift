import Foundation
@testable import LinkCKit

/// Model lists for tests that build an `MCPServer` or an `AppCoordinator`. Their default reads
/// `~/Library/Application Support/linkC`, which a test must never touch.
enum TestModelLists {
    /// Nothing has been listed yet: no agent has a cached list.
    static let none: @Sendable () throws -> [AgentKind: AgentModelList] = { [:] }

    /// `agy models` as agy 1.5.16 printed it on 2026-11-24. Effort lives in the ids: Flash lists
    /// low/medium/high, Hydrogen adds xhigh, GPT-OSS lists medium only, and the Claude ids list no
    /// level at all.
    static let agyListing = """
        Fetching available models...
        gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)
        gemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (XHigh)
        gemini-4-hydrogen-medium\tGemini 4 Hydrogen (Medium)
        gemini-4-hydrogen-low\tGemini 4 Hydrogen (Low)
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
        claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        """

    static var agyModels: [ListedModel] { ModelListParser.agy(agyListing) }

    /// agy's list as a good refresh left it in the cache.
    static let agy: @Sendable () throws -> [AgentKind: AgentModelList] = {
        [.agy: AgentModelList(models: ModelListParser.agy(agyListing), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))]
    }
}
