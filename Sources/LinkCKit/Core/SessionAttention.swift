import Foundation
import Observation

/// What a session row says on its right, and a tone the sidebar colors it by. Coral means the
/// session wants you: blocked on a prompt, an error, or a finished turn nobody has looked at yet.
public struct SessionRowStatus: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case quiet, working, attention, error }

    public enum Format: Equatable, Sendable {
        case fixed(String)
        case age(prefix: String, since: Date)
    }

    public let format: Format
    public let tone: Tone
    public let text: String

    public var isCoral: Bool { tone == .attention || tone == .error }

    public init(format: Format, tone: Tone, now: Date = Date()) {
        self.format = format
        self.tone = tone
        self.text = Self.formatText(format: format, now: now)
    }

    public init(text: String, tone: Tone) {
        self.format = .fixed(text)
        self.tone = tone
        self.text = text
    }

    public static func == (lhs: SessionRowStatus, rhs: SessionRowStatus) -> Bool {
        lhs.format == rhs.format && lhs.tone == rhs.tone && lhs.text == rhs.text
    }

    public func text(now: Date) -> String {
        Self.formatText(format: format, now: now)
    }

    private static func formatText(format: Format, now: Date) -> String {
        switch format {
        case .fixed(let text):
            return text
        case .age(let prefix, let since):
            let age = AgeFormat.compact(from: since, to: now)
            return prefix.isEmpty ? age : "\(prefix) \(age)"
        }
    }

    /// The update cadence for this status: 1.0 s while seconds-resolution age is visible (<60s),
    /// 15.0 s once in minute/hour resolution, or 3600.0 s when fixed / no age is shown.
    public func cadence(now: Date = Date()) -> TimeInterval {
        switch format {
        case .fixed:
            return 3600.0
        case .age(_, let since):
            let elapsed = max(0, now.timeIntervalSince(since))
            return elapsed < 60.0 ? 1.0 : 15.0
        }
    }
}

/// Pure scheduling rule for age labels: ticks every 1.0s until since + 60s, then backs off to every 15.0s.
public enum AgeScheduleRule {
    /// Returns the next tick date after `current` for an age label whose countdown began at `since`.
    public static func nextTick(after current: Date, since: Date) -> Date {
        let boundary = since.addingTimeInterval(60.0)
        if current < boundary {
            let nextSecond = current.addingTimeInterval(1.0)
            return min(nextSecond, boundary)
        } else {
            return current.addingTimeInterval(15.0)
        }
    }
}

/// Remembers when each session was last on screen, so a finished turn reads coral only until the
/// user has looked at it (Codex's unread dot). In memory only: after a relaunch every restored
/// session restarts at `.starting`, so nothing from before the relaunch reads as unseen.
@MainActor
@Observable
public final class SessionAttention {
    private(set) var lastSeen: [String: Date] = [:]

    public init() {}

    /// Record that `session` is on screen at `date`. Writes only when that changes the outcome —
    /// once per state — so a once-a-second caller does not re-render the sidebar every second.
    public func markSeen(_ session: Session, at date: Date) {
        if (lastSeen[session.id] ?? .distantPast) < session.stateChangedAt {
            lastSeen[session.id] = date
        }
    }

    /// Forget sessions that no longer exist.
    public func retain(only ids: Set<String>) {
        for id in lastSeen.keys where !ids.contains(id) {
            lastSeen[id] = nil
        }
    }

    public func status(for session: Session, onScreen: Bool, rateLimited: Bool, now: Date = Date()) -> SessionRowStatus {
        Self.status(
            state: session.state, stateChangedAt: session.stateChangedAt, lastSeen: lastSeen[session.id],
            onScreen: onScreen, rateLimited: rateLimited, now: now)
    }

    /// The spec's state table. `lastSeen` is when the session was last on screen; `onScreen` is
    /// whether it is on screen right now.
    public nonisolated static func status(
        state: SessionState, stateChangedAt: Date, lastSeen: Date?, onScreen: Bool, rateLimited: Bool, now: Date = Date()
    ) -> SessionRowStatus {
        switch state {
        case .starting:
            return SessionRowStatus(format: .fixed("starting"), tone: .quiet, now: now)
        case .ready:
            return SessionRowStatus(format: .age(prefix: "idle", since: stateChangedAt), tone: .quiet, now: now)
        case .working:
            return SessionRowStatus(format: .fixed("working"), tone: .working, now: now)
        case .waitingPermission:
            return SessionRowStatus(format: .age(prefix: "needs you ·", since: stateChangedAt), tone: .attention, now: now)
        case .finished, .waitingIdle:
            let seen = onScreen || (lastSeen.map { $0 >= stateChangedAt } ?? false)
            return seen
                ? SessionRowStatus(format: .age(prefix: "idle", since: stateChangedAt), tone: .quiet, now: now)
                : SessionRowStatus(format: .age(prefix: "done ·", since: stateChangedAt), tone: .attention, now: now)
        case .error:
            return SessionRowStatus(format: .fixed(rateLimited ? "rate limited" : "error"), tone: .error, now: now)
        case .ended:
            return SessionRowStatus(format: .fixed("ended"), tone: .quiet, now: now)
        }
    }
}
