import Foundation

/// Claude Code's own rate-limit figures, as its status-line command receives them on stdin:
/// `rate_limits.five_hour` and `rate_limits.seven_day`, each `{used_percentage, resets_at}`
/// (percent 0–100, Unix seconds). Present only on Pro and Max plans and only after a session's
/// first reply; either window may be missing. Every other status-line field is ignored.
public enum ClaudeRateLimits {
    /// Why Claude's row has no figure when a status line of the user's own is configured: linkC
    /// never replaces it, so it never hears Claude's figures.
    public static let ownStatusLineReason = "your own status line is configured — linkC can't read Claude's usage"

    /// The windows in a status-line body, as a reading taken at `receivedAt`. nil when the body
    /// names neither window. Throws when the body is not the JSON Claude Code sends.
    public static func decode(_ body: Data, receivedAt: Date) throws -> AgentUsage? {
        let payload = try JSONDecoder().decode(Payload.self, from: body)
        guard let limits = payload.rateLimits else { return nil }
        var windows: [UsageWindow] = []
        if let window = limits.fiveHour { windows.append(window.usageWindow(label: "5h")) }
        if let window = limits.sevenDay { windows.append(window.usageWindow(label: "7d")) }
        guard !windows.isEmpty else { return nil }
        return AgentUsage(agent: .claude, windows: windows, planType: nil, observedAt: receivedAt, unavailableReason: nil)
    }

    /// The later of two readings. Readings hop to the main actor in separate tasks, so one taken
    /// earlier can land after one taken later. A reading with no timestamp must never displace one
    /// that has a timestamp.
    public static func newer(_ current: AgentUsage?, _ incoming: AgentUsage) -> AgentUsage {
        guard let current else {
            return incoming
        }
        guard let currentAt = current.observedAt else {
            return incoming
        }
        guard let incomingAt = incoming.observedAt else {
            return current
        }
        return incomingAt >= currentAt ? incoming : current
    }

    /// What the Usage section is given for Claude: the newest reading; failing that, why none
    /// can come; failing that, nil — no reading yet.
    public static func usage(reading: AgentUsage?, userOwnsStatusLine: Bool) -> AgentUsage? {
        if let reading { return reading }
        return userOwnsStatusLine ? .unavailable(.claude, reason: ownStatusLineReason) : nil
    }

    /// The newest status-line body `HookServer` cached to disk, decoded with the file's own
    /// mtime as `receivedAt` — the same figure the sidebar shows, read here by a process (like
    /// `linkc-mcp`) with no access to the in-process `onStatusLine` callback that produced it.
    /// nil when nothing has ever been cached (the ordinary case before a session's first reply,
    /// never logged), or when the cache exists but fails to decode (logged: a stale format must
    /// leave a trace, not read as "never cached" forever).
    public static func cachedReading(at url: URL) -> AgentUsage? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attributes[.modificationDate] as? Date
        else { return nil }
        do {
            return try decode(data, receivedAt: mtime)
        } catch {
            NSLog("[linkC] the cached status line at %@ could not be read — %@", url.path, String(describing: error))
            return nil
        }
    }

    /// What `MCPServer.defaultUsageReaders()` wires up for Claude: the cached status-line
    /// reading when one exists — the same source the sidebar shows — falling back to
    /// `fallback` (the transcript-based reader) only when no status line has ever been cached.
    /// Every fallback window's label is marked so its token count is never mistaken for the
    /// status line's percentage — a structurally different figure from a different source.
    public static func usageReader(cacheURL: URL, fallback: @escaping @Sendable () -> AgentUsage) -> @Sendable () -> AgentUsage {
        {
            if let cached = cachedReading(at: cacheURL) { return cached }
            let transcript = fallback()
            guard !transcript.windows.isEmpty else { return transcript }
            let labeled = transcript.windows.map { window in
                UsageWindow(label: "\(window.label), no status line seen yet", usedPercent: window.usedPercent,
                            tokens: window.tokens, resetsAt: window.resetsAt,
                            tokensAreLowerBound: window.tokensAreLowerBound)
            }
            return AgentUsage(agent: transcript.agent, windows: labeled, planType: transcript.planType,
                              observedAt: transcript.observedAt, unavailableReason: transcript.unavailableReason)
        }
    }

    private struct Payload: Decodable {
        let rateLimits: Limits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    private struct Limits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct Window: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        func usageWindow(label: String) -> UsageWindow {
            UsageWindow(label: label, usedPercent: usedPercentage, tokens: nil,
                        resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
    }
}
