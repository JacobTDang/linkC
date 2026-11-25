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
    public static let listedAgents: [AgentKind] = [.agy, .cursor, .grok, .opencode, .kilo, .crush]

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

    /// `kilo models`: one id per line; free only (spec §4.3); name = id.
    public static func kilo(_ output: String) -> [ListedModel] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let id = clean(String(line))
            guard !id.isEmpty, KiloFreeModels.isFree(id) else { return nil }
            return ListedModel(id: id, name: id)
        }
    }

    /// `crush models`: one `provider/model` id per line; free OpenRouter models only; name = id.
    public static func crush(_ output: String) -> [ListedModel] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let id = clean(String(line))
            guard !id.isEmpty, CrushFreeModels.isFree(id) else { return nil }
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
        case .kilo: models = Self.kilo(output)
        case .crush: models = Self.crush(output)
        case .claude, .codex, .freebuff, .shell:
            throw LinkCError.process("\(agent.rawValue) has no model listing command")
        }
        guard !models.isEmpty else {
            let first = output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let message = "\(agent.rawValue) models listed nothing: \(first ?? "(no output)")"
            throw LinkCError.process(agent == .kilo ? KiloLogin.reporting(message) : message)
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
        case .agy, .cursor, .grok, .opencode, .freebuff, .kilo, .crush, .shell:
            return nil
        }
    }
}

/// OpenCode's free-only rule: an id ending in `-free` under any provider (`opencode/`, `opencode-go/`, …),
/// `opencode/big-pickle`, or a local `ollama/*` model. Everything else is refused.
public enum OpenCodeFreeModels {
    public static func isFree(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("ollama/") { return true }
        if trimmed == "opencode/big-pickle" { return true }
        if trimmed.hasSuffix("-free") {
            if let slashIndex = trimmed.firstIndex(of: "/"),
               slashIndex > trimmed.startIndex,
               trimmed.endIndex > trimmed.index(after: slashIndex) {
                return true
            }
        }
        return false
    }
}

/// OpenCode Go's free pool: OpenCode lists `opencode-go/*` models only while Go is connected.
public enum OpenCodeGo {
    /// The model an OpenCode session runs for `model`: `opencode-go/<name>` for an `opencode/<name>`
    /// model when `listed`, OpenCode's cached list, has that exact id and it is free; else `model`.
    public static func model(for model: String, listed: [ListedModel]) -> String {
        guard model.hasPrefix("opencode/") else { return model }
        let candidate = "opencode-go/" + model.dropFirst("opencode/".count)
        guard listed.contains(where: { $0.id == candidate }), OpenCodeFreeModels.isFree(candidate) else { return model }
        return candidate
    }
}

/// Kilo's free-only rule (spec §4.3): starts with `kilo/` and either ends in `:free`, ends in
/// `-free`, or the last path component is `free`.
public enum KiloFreeModels {
    public static func isFree(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("kilo/") else { return false }
        if trimmed.hasSuffix(":free") || trimmed.hasSuffix("-free") { return true }
        return (trimmed as NSString).lastPathComponent == "free"
    }
}

/// Crush's free-only rule: an OpenRouter model whose id ends in `:free` (`openrouter/<model>:free`).
/// The one rule every Crush path uses: the `crush models` parser, the Settings picker, delegation,
/// launch, and the per-session config that pins the model.
public enum CrushFreeModels {
    public static let provider = "openrouter/"
    public static let suffix = ":free"

    public static func isFree(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(provider) && trimmed.hasSuffix(suffix)
            && trimmed.count > provider.count + suffix.count
    }
}

/// Quota pools: models of one agent that are capped separately. agy's Gemini vs Claude/GPT, and
/// OpenCode's anonymous free tier (`opencode/*`), OpenCode Go (`opencode-go/*`) and local Ollama
/// (`ollama/*`). Every other agent has one quota.
public enum ModelPool {
    /// `agent`'s pools, in the order a notice names them; empty for an agent with one quota.
    public static func pools(for agent: AgentKind) -> [String] {
        switch agent {
        case .agy: return ["gemini", "claude-gpt"]
        case .opencode: return ["opencode-go", "opencode", "ollama"]
        default: return []
        }
    }

    /// The pool `model` draws on, or nil for an agent with one quota and for a model in none of its pools.
    public static func pool(of model: String, agent: AgentKind) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch agent {
        case .agy:
            if trimmed.hasPrefix("gemini-") { return "gemini" }
            if trimmed.hasPrefix("claude-") || trimmed.hasPrefix("gpt-oss-") { return "claude-gpt" }
            return nil
        case .opencode:
            if trimmed.hasPrefix("opencode-go/") { return "opencode-go" }
            if trimmed.hasPrefix("opencode/") { return "opencode" }
            if trimmed.hasPrefix("ollama/") { return "ollama" }
            return nil
        default:
            return nil
        }
    }

    public static func displayName(_ pool: String) -> String {
        switch pool {
        case "gemini": return "Gemini"
        case "claude-gpt": return "Claude/GPT"
        case "opencode": return "OpenCode"
        case "opencode-go": return "OpenCode Go"
        case "ollama": return "Ollama"
        default: return pool
        }
    }
}
