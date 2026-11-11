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

/// The hairline sweep along a working row (spec §2): a band about 40% of the row, clear → white 70% → clear,
/// looping every 1.6 s.
public enum HairlineSweep {
    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let opacity: Double
    }
    public static let bandFraction: Double = 0.40
    public static let minimumBandWidth: Double = 20
    public static let stops: [Stop] = [Stop(location: 0, opacity: 0), Stop(location: 0.5, opacity: 0.70),
                                      Stop(location: 1, opacity: 0)]
    public static let period: Double = 1.6
}
