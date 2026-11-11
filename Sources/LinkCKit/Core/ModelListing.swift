import Foundation

/// One model an agent's CLI listed: its id, and the name the CLI showed for it.
public struct ListedModel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Pure parsers that turn each CLI's model listing into `[ListedModel]`.
public enum ModelListParser {
    /// Agents whose models come from a CLI listing. Claude and Codex have fixed lists (`fixed(for:)`).
    /// Grok has no listing of its own: it reuses Cursor's.
    public static let listedAgents: [AgentKind] = [.agy, .cursor, .grok, .opencode]

    private static let zeroWidth: CharacterSet = {
        var set = CharacterSet()
        set.insert(Unicode.Scalar(0x200B)!) // zero-width space
        set.insert(Unicode.Scalar(0x200C)!)
        set.insert(Unicode.Scalar(0x200D)!)
        set.insert(Unicode.Scalar(0xFEFF)!)
        return set
    }()

    /// Strips zero-width characters and surrounding whitespace.
    private static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { !zeroWidth.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `agy models`: `id<TAB>name` lines after a "Fetching…" header. A line without the tab is not a
    /// model: the header, and anything agy prints instead of a list ("Error: not logged in").
    public static func agy(_ output: String) -> [ListedModel] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = clean(String(line))
            guard let tab = trimmed.firstIndex(of: "\t") else { return nil }
            let id = clean(String(trimmed[..<tab]))
            let name = clean(String(trimmed[trimmed.index(after: tab)...]))
            guard !id.isEmpty, !id.contains(where: \.isWhitespace), !name.isEmpty else { return nil }
            return ListedModel(id: id, name: name)
        }
    }

    /// `cursor-agent models`: `id - Name` lines after an "Available models" header.
    public static func cursor(_ output: String) -> [ListedModel] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = clean(String(line))
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.lowercased() != "available models" else { return nil }
            guard let sep = trimmed.range(of: " - ") else { return nil }
            let id = clean(String(trimmed[..<sep.lowerBound]))
            let name = clean(String(trimmed[sep.upperBound...]))
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return ListedModel(id: id, name: name)
        }
    }

    /// Grok's models from Cursor's list: ids that start with `grok-`.
    public static func grok(fromCursor output: String) -> [ListedModel] {
        cursor(output).filter { $0.id.hasPrefix("grok-") }
    }

    /// `opencode models --standalone`: one id per line; free only; name = id.
    public static func openCode(_ output: String) -> [ListedModel] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let id = clean(String(line))
            guard !id.isEmpty, OpenCodeFreeModels.isFree(id) else { return nil }
            return ListedModel(id: id, name: id)
        }
    }

    /// What `agent`'s CLI printed, as models. Output that yields none is an error, never an empty
    /// list: a CLI that printed text but no models (an error line, a changed format) must not pass
    /// for one that has none. Throws for an agent that has no listing command.
    public static func listing(_ output: String, for agent: AgentKind) throws -> [ListedModel] {
        let models: [ListedModel]
        switch agent {
        case .agy: models = Self.agy(output)
        case .cursor: models = Self.cursor(output)
        case .grok: models = Self.grok(fromCursor: output)
        case .opencode: models = Self.openCode(output)
        case .claude, .codex, .shell:
            throw LinkCError.process("\(agent.rawValue) has no model listing command")
        }
        guard !models.isEmpty else {
            let first = output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw LinkCError.process("\(agent.rawValue) models listed nothing: \(first ?? "(no output)")")
        }
        return models
    }

    /// Fixed lists for agents with no list command. Nil for agents that list from a CLI.
    public static func fixed(for agent: AgentKind) -> [ListedModel]? {
        switch agent {
        case .claude:
            return ["haiku", "sonnet", "opus"].map { ListedModel(id: $0, name: $0) }
        case .codex:
            return ["gpt-5.6-luna", "gpt-5.6-sol", "gpt-6-astra"].map { ListedModel(id: $0, name: $0) }
        case .agy, .cursor, .grok, .opencode, .shell:
            return nil
        }
    }
}

/// OpenCode's free-only rule: `opencode/*-free`, `opencode/big-pickle`, and `ollama/*`.
public enum OpenCodeFreeModels {
    public static func isFree(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("ollama/") { return true }
        if trimmed == "opencode/big-pickle" { return true }
        if trimmed.hasPrefix("opencode/"), trimmed.hasSuffix("-free") { return true }
        return false
    }
}

/// agy's quota pools: Gemini vs Claude/GPT. Nil for every other agent, and for an unknown agy id.
public enum ModelPool {
    /// agy: "gemini" for gemini-…, "claude-gpt" for claude-… and gpt-oss-…, nil otherwise; nil for every other agent.
    public static func pool(of model: String, agent: AgentKind) -> String? {
        guard agent == .agy else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("gemini-") { return "gemini" }
        if trimmed.hasPrefix("claude-") || trimmed.hasPrefix("gpt-oss-") { return "claude-gpt" }
        return nil
    }

    public static func displayName(_ pool: String) -> String {
        switch pool {
        case "gemini": return "Gemini"
        case "claude-gpt": return "Claude/GPT"
        default: return pool
        }
    }
}
