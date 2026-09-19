import Foundation
import Observation

/// What a session row says on its right, and a tone the sidebar colors it by. Coral means the
/// session wants you: blocked on a prompt, an error, or a finished turn nobody has looked at yet.
public struct SessionRowStatus: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case quiet, working, attention, error }

    public let text: String
    public let tone: Tone

    public var isCoral: Bool { tone == .attention || tone == .error }

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
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

    public func status(for session: Session, onScreen: Bool, rateLimited: Bool, now: Date) -> SessionRowStatus {
        Self.status(
            state: session.state, stateChangedAt: session.stateChangedAt, lastSeen: lastSeen[session.id],
            onScreen: onScreen, rateLimited: rateLimited, now: now)
    }

    /// The spec's state table. `lastSeen` is when the session was last on screen; `onScreen` is
    /// whether it is on screen right now.
    public nonisolated static func status(
        state: SessionState, stateChangedAt: Date, lastSeen: Date?, onScreen: Bool, rateLimited: Bool, now: Date
    ) -> SessionRowStatus {
        let age = AgeFormat.compact(from: stateChangedAt, to: now)
        switch state {
        case .starting:
            return SessionRowStatus(text: "starting", tone: .quiet)
        case .ready:
            return SessionRowStatus(text: "idle \(age)", tone: .quiet)
        case .working:
            return SessionRowStatus(text: "working", tone: .working)
        case .waitingPermission:
            return SessionRowStatus(text: "needs you · \(age)", tone: .attention)
        case .finished, .waitingIdle:
            let seen = onScreen || (lastSeen.map { $0 >= stateChangedAt } ?? false)
            return seen
                ? SessionRowStatus(text: "idle \(age)", tone: .quiet)
                : SessionRowStatus(text: "done · \(age)", tone: .attention)
        case .error:
            return SessionRowStatus(text: rateLimited ? "rate limited" : "error", tone: .error)
        case .ended:
            return SessionRowStatus(text: "ended", tone: .quiet)
        }
    }
}
