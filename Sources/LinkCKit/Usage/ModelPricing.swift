import Foundation

/// Built-in $/MTok rates for estimating what a session cost. Prefix-matched against the
/// transcript's model id; an unknown model returns nil and is excluded from estimates — a
/// wrong dollar figure is worse than none. Rates as of 2026-07 (cache read 0.1× input,
/// cache write 1.25×/2× input for 5m/1h TTL); sonnet-5 uses its introductory pricing.
public enum ModelPricing {
    private struct Rates {
        let input, output, cacheRead, cacheWrite5m, cacheWrite1h: Double
    }

    private static let table: [(prefix: String, rates: Rates)] = [
        ("claude-fable-5", Rates(input: 10, output: 50, cacheRead: 1.00, cacheWrite5m: 12.50, cacheWrite1h: 20.00)),
        ("claude-mythos", Rates(input: 10, output: 50, cacheRead: 1.00, cacheWrite5m: 12.50, cacheWrite1h: 20.00)),
        ("claude-opus-4-5", Rates(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10.00)),
        ("claude-opus-4-6", Rates(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10.00)),
        ("claude-opus-4-7", Rates(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10.00)),
        ("claude-opus-4-8", Rates(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10.00)),
        ("claude-sonnet-5", Rates(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4.00)),
        ("claude-sonnet-4", Rates(input: 3, output: 15, cacheRead: 0.30, cacheWrite5m: 3.75, cacheWrite1h: 6.00)),
        ("claude-haiku-4", Rates(input: 1, output: 5, cacheRead: 0.10, cacheWrite5m: 1.25, cacheWrite1h: 2.00)),
    ]

    /// Estimated dollars for one message, or nil when the model isn't in the table.
    public static func cost(of usage: MessageUsage) -> Double? {
        guard let rates = table.first(where: { usage.model.hasPrefix($0.prefix) })?.rates else {
            return nil
        }
        let perMTok = Double(usage.inputTokens) * rates.input
            + Double(usage.cacheReadTokens) * rates.cacheRead
            + Double(usage.cacheWrite5mTokens) * rates.cacheWrite5m
            + Double(usage.cacheWrite1hTokens) * rates.cacheWrite1h
            + Double(usage.outputTokens) * rates.output
        return perMTok / 1_000_000
    }
}
