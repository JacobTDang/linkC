import Foundation

/// Pure policy deciding when a smooth shimmer animation is allowed to run.
///
/// An active shimmer must run ONLY when:
/// 1. The target session or item is actively working
/// 2. The row hosting it is currently on screen
/// 3. The parent panel or window is currently visible
/// 4. The user has not enabled accessibility Reduce Motion
public enum ShimmerPolicy {
    public static func shouldAnimate(
        isWorking: Bool,
        isOnScreen: Bool,
        panelVisible: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isWorking && isOnScreen && panelVisible && !reduceMotion
    }
}
