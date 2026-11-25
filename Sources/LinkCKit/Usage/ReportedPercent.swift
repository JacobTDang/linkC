import Foundation

/// A percent an agent reports about itself, as the whole number linkC shows and publishes.
enum ReportedPercent {
    /// `value` rounded to a whole percent from 0 to 100. A figure within rounding of that range
    /// (above -0.5, below 100.5) is held to it: a provider's own rounding can put a full window a hair
    /// past 100. Throws for one that is not a number or lies further out: no window holds such a
    /// figure, and `Int(_:)` of one such as 1e30 or NaN traps.
    static func whole(_ value: Double) throws -> Int {
        guard value.isFinite, value > -0.5, value < 100.5 else {
            throw LinkCError.parse("\(value) is not a percentage from 0 to 100")
        }
        return min(100, max(0, Int(value.rounded())))
    }
}
