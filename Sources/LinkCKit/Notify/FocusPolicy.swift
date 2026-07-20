import Foundation

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
