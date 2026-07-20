import Foundation

// STUB — implemented in Task: Notify module.

/// Decides whether a state change should raise a notification.
/// Default policy: notify on entry to a "needs you" state UNLESS the user is actively
/// watching that session (its tab focused and kitty frontmost).
public enum FocusPolicy {
    public static func shouldNotify(
        session: Session,
        enteredNotifiable: Bool,
        kittyIsFrontmost: Bool,
        focusedLinkcSession: String?
    ) -> Bool {
        guard enteredNotifiable else { return false }
        let watchingThis = kittyIsFrontmost && focusedLinkcSession == session.id
        return !watchingThis
    }
}

/// Wraps UNUserNotificationCenter. Implemented in the Notify task.
@MainActor
public final class NotificationManager {
    /// Invoked with a session id when the user clicks a notification.
    public var onActivate: ((String) -> Void)?

    public init() {}

    public func requestAuthorization() async {}

    /// Post a notification describing the session's new state.
    public func notify(session: Session) {}

    /// Human-readable copy for a session's current state (pure; testable).
    public static func message(for session: Session) -> String? {
        switch session.state {
        case .finished: return "\(session.title) · finished"
        case .waitingPermission: return "\(session.title) · needs permission"
        case .waitingIdle: return "\(session.title) · waiting for input"
        case .error: return "\(session.title) · ended with an error"
        default: return nil
        }
    }
}
