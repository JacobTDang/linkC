import Foundation

/// Debounces a screen-read agent's turn end: its activity line must stay absent for `quietPeriod` in a row.
public struct TurnEndDebounce {
    public let quietPeriod: TimeInterval
    private var absentSince: [String: Date] = [:]

    public init(quietPeriod: TimeInterval) {
        self.quietPeriod = quietPeriod
    }

    /// One poll of a working session. True once, when the activity line has been absent for
    /// `quietPeriod`; that ends the stretch, so the next absence starts timing afresh. A poll that
    /// sees the line resets the stretch.
    public mutating func poll(sessionId: String, isWorking: Bool, now: Date) -> Bool {
        if isWorking {
            absentSince.removeValue(forKey: sessionId)
            return false
        }
        guard let since = absentSince[sessionId] else {
            absentSince[sessionId] = now
            return false
        }
        guard now.timeIntervalSince(since) >= quietPeriod else { return false }
        absentSince.removeValue(forKey: sessionId)
        return true
    }

    /// Drops a session's idle stretch — when it stops working for any other reason, or closes.
    public mutating func forget(sessionId: String) {
        absentSince.removeValue(forKey: sessionId)
    }
}
