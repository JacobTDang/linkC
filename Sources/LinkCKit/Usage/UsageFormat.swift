import Foundation

/// Compact display formatting for usage figures. Deterministic (en_US_POSIX) — these are
/// terse dashboard glyphs, not localized prose.
public enum UsageFormat {
    /// 950 → "950", 12_400 → "12.4k", 142_000 → "142k", 3_140_000 → "3.1M". One decimal,
    /// dropped when it's zero — "41M", never "41.0M".
    public static func tokens(_ count: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            var figure = String(format: "%.1f", value)
            if figure.hasSuffix(".0") { figure = String(figure.dropLast(2)) }
            return figure + suffix
        }
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return scaled(Double(count) / 1000, "k")
        default: return scaled(Double(count) / 1_000_000, "M")
        }
    }

    /// "~$1.87" — always approximate; a positive sub-cent amount floors at "~$0.01" so real
    /// spend never displays as free.
    public static func dollars(_ amount: Double) -> String {
        if amount > 0, amount < 0.01 { return "~$0.01" }
        return String(format: "~$%.2f", amount)
    }

    /// "~2am" / "~7:30am" — minutes only when non-zero.
    public static func resetTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let minute = calendar.component(.minute, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = minute == 0 ? "ha" : "h:mma"
        return "~" + formatter.string(from: date).lowercased()
    }
}
