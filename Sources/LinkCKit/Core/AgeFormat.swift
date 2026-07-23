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
}
