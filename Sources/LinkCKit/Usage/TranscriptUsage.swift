import Foundation

/// One assistant message's token usage, parsed from a session transcript JSONL line.
public struct MessageUsage: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWrite5mTokens: Int
    public let cacheWrite1hTokens: Int
    public let outputTokens: Int
    /// Subagent traffic: counts toward totals (real tokens) but not context fill (its own window).
    public let isSidechain: Bool

    public var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }
    /// The conversation's context size as of this message — what the model was fed.
    public var contextTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
    public var totalTokens: Int { contextTokens + outputTokens }
}

/// Parses claude's transcript JSONL. Only assistant lines carrying `message.usage` yield a
/// record; everything else — user turns, tool results, malformed lines — is `nil`, silently:
/// a transcript is full of lines we don't care about, so nil here is selection, not failure.
public enum TranscriptUsage {
    public static func parseLine(_ line: String) -> MessageUsage? {
        guard
            let data = line.data(using: .utf8),
            let parsed = try? decoder.decode(Line.self, from: data),
            parsed.type == "assistant",
            let message = parsed.message,
            let usage = message.usage,
            let model = message.model,
            let rawTimestamp = parsed.timestamp,
            let timestamp = parseTimestamp(rawTimestamp)
        else { return nil }

        // Prefer the per-TTL breakdown; without it, bill the total at the cheaper 5m write
        // rate (a deliberate underestimate — every figure downstream is marked approximate).
        let write5m: Int
        let write1h: Int
        if let breakdown = usage.cacheCreation {
            write5m = breakdown.ephemeral5m ?? 0
            write1h = breakdown.ephemeral1h ?? 0
        } else {
            write5m = usage.cacheCreationInputTokens ?? 0
            write1h = 0
        }

        return MessageUsage(
            timestamp: timestamp,
            model: model,
            inputTokens: usage.inputTokens ?? 0,
            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h,
            outputTokens: usage.outputTokens ?? 0,
            isSidechain: parsed.isSidechain ?? false
        )
    }

    private static let decoder = JSONDecoder()

    // ISO8601, with and without fractional seconds — transcripts use both. Formatters are
    // not Sendable; create per call (parsing volume is a few thousand lines at worst).
    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    private struct Line: Decodable {
        let type: String?
        let isSidechain: Bool?
        let timestamp: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let inputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let outputTokens: Int?
        let cacheCreation: CacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreation = "cache_creation"
        }
    }

    private struct CacheCreation: Decodable {
        let ephemeral5m: Int?
        let ephemeral1h: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral5m = "ephemeral_5m_input_tokens"
            case ephemeral1h = "ephemeral_1h_input_tokens"
        }
    }
}
