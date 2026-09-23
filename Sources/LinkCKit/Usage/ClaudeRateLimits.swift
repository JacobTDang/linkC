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
