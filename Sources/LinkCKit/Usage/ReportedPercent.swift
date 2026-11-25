import Foundation

/// A percent an agent reports about itself, as the whole number linkC shows and publishes.
enum ReportedPercent {
    /// `value` rounded to a whole percent. Throws for one that is not a number or is outside 0–100:
    /// no window holds such a figure, and `Int(_:)` of one such as 1e30 or NaN traps.
    static func whole(_ value: Double) throws -> Int {
        guard value.isFinite, (0...100).contains(value) else {
            throw LinkCError.parse("\(value) is not a percentage from 0 to 100")
        }
        return Int(value.rounded())
    }
}
