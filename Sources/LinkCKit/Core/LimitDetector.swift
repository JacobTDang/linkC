import Foundation

/// A detected API rate limit or quota exhaustion match.
public struct LimitMatch: Sendable, Equatable, Codable {
    public let agent: AgentKind
    public let matchedPattern: String
    public let cooldown: TimeInterval

    public init(
        agent: AgentKind,
        matchedPattern: String,
        cooldown: TimeInterval = LimitDetector.defaultCooldown
    ) {
        self.agent = agent
        self.matchedPattern = matchedPattern
        self.cooldown = cooldown
    }

    /// Converts this match into an `AgentLimitStatus` model for storage in the inbox bus.
    public func toAgentLimitStatus(now: Date = Date()) -> AgentLimitStatus {
        AgentLimitStatus(
            agent: agent,
            reason: matchedPattern,
            limitedAt: now,
            cooldownExpiresAt: now.addingTimeInterval(cooldown)
        )
    }
}

/// Detects provider rate limits and quota ceiling events in terminal output and hook failures.
public struct LimitDetector: Sendable {
    /// Default cooldown window applied when an agent hits a rate limit (15 minutes).
    public static let defaultCooldown: TimeInterval = 15 * 60

    private struct LimitRule: @unchecked Sendable {
        let canonicalPattern: String
        let regex: NSRegularExpression

        init(canonicalPattern: String, regexPattern: String? = nil, options: NSRegularExpression.Options = [.caseInsensitive]) {
            self.canonicalPattern = canonicalPattern
            let patternStr = regexPattern ?? NSRegularExpression.escapedPattern(for: canonicalPattern)
            self.regex = (try? NSRegularExpression(pattern: patternStr, options: options)) ?? NSRegularExpression()
        }
    }

    private static let ansiRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\].*?\\x07)", options: [])
    }()

    private static let claudeRules: [LimitRule] = [
        LimitRule(canonicalPattern: "You've reached your usage limit", regexPattern: "you(?:'|’)?ve (?:reached|hit) your (?:(?:usage|session|rate) )?limit"),
        LimitRule(canonicalPattern: "Rate limit reached", regexPattern: "\\brate limit reached\\b"),
        LimitRule(canonicalPattern: "credit balance too low", regexPattern: "\\bcredit balance too low\\b"),
        LimitRule(canonicalPattern: "Claude is currently unavailable", regexPattern: "claude.*(?:is currently unavailable|temporarily unavailable)"),
        LimitRule(canonicalPattern: "out of messages until", regexPattern: "out of messages until"),
        LimitRule(canonicalPattern: "exceeded your usage limit", regexPattern: "exceeded your (?:usage )?limit"),
        // Never match on reset wording alone. "resets at 3am" appears in ordinary prose — an
        // agent discussing a limit, or linkC's own notice about one — and reading that as
        // exhaustion made linkC cancel real work and synthesize tasks for peers that nobody
        // asked for. Only an agent's own exhaustion banner counts.
        LimitRule(canonicalPattern: "usage or session limit reached", regexPattern: "\\b(?:usage|session) limit reached\\b"),
        LimitRule(canonicalPattern: "usage cap hit or reached", regexPattern: "\\b(?:usage )?cap (?:hit|reached)\\b"),
        LimitRule(canonicalPattern: "You have reached your limit for Claude", regexPattern: "you have reached your limit for claude")
    ]

    private static let codexRules: [LimitRule] = [
        LimitRule(canonicalPattern: "429 Too Many Requests", regexPattern: "429\\s+Too\\s+Many\\s+Requests"),
        LimitRule(canonicalPattern: "Rate limit exceeded", regexPattern: "\\brate limit exceeded\\b"),
        LimitRule(canonicalPattern: "quota exceeded", regexPattern: "\\bquota exceeded\\b"),
        LimitRule(canonicalPattern: "Too Many Requests", regexPattern: "\\btoo many requests\\b")
    ]

    private static let agyRules: [LimitRule] = [
        LimitRule(canonicalPattern: "ResourceExhausted", regexPattern: "\\bResourceExhausted\\b"),
        LimitRule(canonicalPattern: "quota limit reached", regexPattern: "\\bquota limit reached\\b"),
        LimitRule(canonicalPattern: "Resource exhausted", regexPattern: "\\bresource exhausted\\b"),
        LimitRule(canonicalPattern: "quota exceeded", regexPattern: "\\bquota exceeded\\b")
    ]

    private static let cursorRules: [LimitRule] = [
        LimitRule(canonicalPattern: "Rate limit reached", regexPattern: "\\brate limit reached\\b"),
        LimitRule(canonicalPattern: "Rate limit exceeded", regexPattern: "\\brate limit exceeded\\b"),
        LimitRule(canonicalPattern: "429 Too Many Requests", regexPattern: "429\\s+Too\\s+Many\\s+Requests"),
        LimitRule(canonicalPattern: "quota exceeded", regexPattern: "\\bquota exceeded\\b")
    ]

    private static func rules(for agent: AgentKind) -> [LimitRule] {
        switch agent {
        case .claude: return claudeRules
        case .codex: return codexRules
        case .agy: return agyRules
        case .cursor: return cursorRules
        case .shell: return []
        }
    }

    /// Strips ANSI terminal escape sequences to ensure clean pattern matching.
    private static func stripAnsi(_ text: String) -> String {
        guard let ansiRegex = ansiRegex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return ansiRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// Inspects terminal output text for known rate limit or quota ceiling signatures of `agent`.
    /// Returns a `LimitMatch` if detected, or `nil` otherwise.
    public static func detectLimit(
        inOutput text: String,
        agent: AgentKind,
        defaultCooldown: TimeInterval = defaultCooldown
    ) -> LimitMatch? {
        guard !text.isEmpty else { return nil }
        let agentRules = rules(for: agent)
        guard !agentRules.isEmpty else { return nil }

        let cleanText = stripAnsi(text)
        guard !cleanText.isEmpty else { return nil }

        let range = NSRange(cleanText.startIndex..<cleanText.endIndex, in: cleanText)
        for rule in agentRules {
            if rule.regex.firstMatch(in: cleanText, options: [], range: range) != nil {
                return LimitMatch(
                    agent: agent,
                    matchedPattern: rule.canonicalPattern,
                    cooldown: defaultCooldown
                )
            }
        }

        return nil
    }

    /// Determines whether a hook event kind represents a rate-limited failure.
    public static func isHookFailureRateLimited(kind: HookEventKind) -> Bool {
        kind == .stopFailure
    }
}
