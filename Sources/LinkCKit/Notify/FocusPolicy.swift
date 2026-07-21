import Foundation

/// Decides whether a state change should raise a notification.
/// Default policy: notify on entry to a "needs you" state UNLESS the user is actively
/// watching that session right now (panel open, linkC active, and its tab selected).
public enum FocusPolicy {
    public static func shouldNotify(
        session: Session,
        enteredNotifiable: Bool,
        isWatchingThisSession: Bool
    ) -> Bool {
        guard enteredNotifiable else { return false }
        return !isWatchingThisSession
    }
}
