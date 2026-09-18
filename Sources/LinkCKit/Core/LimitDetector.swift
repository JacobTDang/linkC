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
        /// How long a match keeps the agent limited; nil uses `defaultCooldown`.
        let cooldown: TimeInterval?

        init(
            canonicalPattern: String,
            regexPattern: String? = nil,
            options: NSRegularExpression.Options = [.caseInsensitive],
            cooldown: TimeInterval? = nil
        ) {
            self.canonicalPattern = canonicalPattern
            self.cooldown = cooldown
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
        LimitRule(canonicalPattern: "quota exceeded", regexPattern: "\\bquota exceeded\\b"),
        // Cursor's own usage-cap error, shown once the account's quota for the selected model is
        // spent. Every turn then fails at once, so without this linkC kept routing work to Cursor.
        // A spent quota does not come back in minutes: wait hours before trying Cursor again, but
        // not days, since switching Cursor to another model lifts the cap immediately.
        LimitRule(
            canonicalPattern: "Cursor usage cap",
            regexPattern: "you(?:'|’)?ve (?:reached|hit) your (?:(?:usage|session|rate) )?limit",
            cooldown: 6 * 3600
        )
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

    /// Finds the first occurrence of `needle` in `haystack`, or nil if it is not present in full.
    /// A hand-rolled scan rather than a stdlib/regex search: it only needs to work over plain
    /// `[Character]` and returns index ranges that line up directly with `firstIndex`/`removeSubrange`.
    private static func firstRange(of needle: [Character], in haystack: [Character]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let limit = haystack.count - needle.count
        var start = 0
        while start <= limit {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start..<(start + needle.count) }
            start += 1
        }
        return nil
    }

    /// Removes each entry of `injected` from `text`, once, by content — not by row, and not by
    /// age. A brief or notice can quote a limit phrase; the terminal echoes it straight back, and
    /// reading that echo as the agent's own exhaustion banner records a limit nobody hit. But a
    /// row-containment guard (an earlier attempt) over-suppressed: a standalone banner row that is
    /// just the phrase is also, trivially, a substring of a brief that quotes it, so dropping any
    /// row found inside any injection dropped the real banner too.
    ///
    /// So matching here is content-based and single-use: build a whitespace-free form of `text`
    /// alongside a map from each whitespace-free character back to its index in `text` (whitespace
    /// insensitivity matters because the terminal wraps a long injected line across rows, sometimes
    /// splitting mid-word with no space left at the break at all). For each injected entry, find its
    /// FIRST occurrence in the *remaining* whitespace-free text; if the whole entry is present,
    /// delete the original characters it maps to and also drop that span from the whitespace-free
    /// form/map, so a second copy of the same text — a real banner repeating a phrase an older brief
    /// quoted — is not also removed. An entry not fully present (say, its first half has scrolled
    /// off) suppresses nothing.
    private static func withoutInjected(_ text: String, injected: [String]) -> String {
        let typed = injected.map(stripAnsi).filter { !$0.isEmpty }
        guard !typed.isEmpty else { return text }

        let chars = Array(text)
        var condensed: [Character] = []
        var indexMap: [Int] = []
        condensed.reserveCapacity(chars.count)
        indexMap.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() where !c.isWhitespace {
            condensed.append(c)
            indexMap.append(i)
        }

        var removed = [Bool](repeating: false, count: chars.count)

        for entry in typed {
            let needle = entry.filter { !$0.isWhitespace }
            guard !needle.isEmpty else { continue }
            guard let range = firstRange(of: Array(needle), in: condensed) else { continue }
            for pos in range {
                removed[indexMap[pos]] = true
            }
            // Drop the matched span from the working copies so a later entry (or a repeat of this
            // same entry) cannot match the span just removed — only the banner's own occurrence,
            // elsewhere in the text, remains findable.
            condensed.removeSubrange(range)
            indexMap.removeSubrange(range)
        }

        guard removed.contains(true) else { return text }
        var result = ""
        result.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() where !removed[i] {
            result.append(c)
        }
        return result
    }

    /// Inspects terminal output text for known rate limit or quota ceiling signatures of `agent`.
    /// Returns a `LimitMatch` if detected, or `nil` otherwise. Pass everything linkC has typed into
    /// that terminal as `ignoringInjected`: only the agent's own output can report its limit.
    public static func detectLimit(
        inOutput text: String,
        agent: AgentKind,
        ignoringInjected injected: [String] = [],
        defaultCooldown: TimeInterval = defaultCooldown
    ) -> LimitMatch? {
        guard !text.isEmpty else { return nil }
        let agentRules = rules(for: agent)
        guard !agentRules.isEmpty else { return nil }

        let cleanText = withoutInjected(stripAnsi(text), injected: injected)
        guard !cleanText.isEmpty else { return nil }

        let range = NSRange(cleanText.startIndex..<cleanText.endIndex, in: cleanText)
        for rule in agentRules {
            if rule.regex.firstMatch(in: cleanText, options: [], range: range) != nil {
                return LimitMatch(
                    agent: agent,
                    matchedPattern: rule.canonicalPattern,
                    cooldown: rule.cooldown ?? defaultCooldown
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
