import Foundation

/// Compact elapsed-time glyphs for dense rows — "4m" carries the meaning; anything longer
/// is furniture. Negative intervals (clock skew) clamp to zero.
public enum AgeFormat {
    public static func compact(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        default: return "\(s / 3600)h"
        }
    }

    public static func compact(from start: Date, to now: Date = Date()) -> String {
        compact(now.timeIntervalSince(start))
    }

    /// Long spans, for things measured in days rather than minutes (a cloud box's uptime).
    /// `compact` deliberately tops out at hours — a session "26h" old is meaningful — so
    /// uptime gets its own scale rather than bending that one.
    public static func longSpan(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<3600: return "\(s / 60)m"
        case ..<(24 * 3600): return "\(s / 3600)h"
        case ..<(7 * 24 * 3600): return "\(s / (24 * 3600))d"
        default:
            let weeks = s / (7 * 24 * 3600)
            let days = (s % (7 * 24 * 3600)) / (24 * 3600)
            return days == 0 ? "\(weeks)w" : "\(weeks)w \(days)d"
        }
    }

    public static func longSpan(from start: Date, to now: Date = Date()) -> String {
        longSpan(now.timeIntervalSince(start))
    }
}
