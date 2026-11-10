import XCTest
@testable import LinkCKit

final class ShimmerPolicyTests: XCTestCase {
    func testShimmerAnimatesOnlyWhenWorkingOnScreenPanelVisibleAndMotionAllowed() {
        // All conditions met -> true
        XCTAssertTrue(ShimmerPolicy.shouldAnimate(
            isWorking: true, isOnScreen: true, panelVisible: true, reduceMotion: false
        ))

        // Working but off-screen -> false
        XCTAssertFalse(ShimmerPolicy.shouldAnimate(
            isWorking: true, isOnScreen: false, panelVisible: true, reduceMotion: false
        ), "An off-screen working row must not animate")

        // Working on-screen but panel closed -> false
        XCTAssertFalse(ShimmerPolicy.shouldAnimate(
            isWorking: true, isOnScreen: true, panelVisible: false, reduceMotion: false
        ), "A row must not animate when the panel is not visible")

        // Working on-screen, panel visible, but Reduce Motion enabled -> false
        XCTAssertFalse(ShimmerPolicy.shouldAnimate(
            isWorking: true, isOnScreen: true, panelVisible: true, reduceMotion: true
        ), "Reduce Motion must suppress shimmer")

        // Not working -> false
        XCTAssertFalse(ShimmerPolicy.shouldAnimate(
            isWorking: false, isOnScreen: true, panelVisible: true, reduceMotion: false
        ), "Idle sessions must not animate")
    }

    /// The sweep's light spans its whole band, about 40% of the row (spec §2): clear, white at 70%, clear.
    func testTheSweepLightsFortyPercentOfTheRow() {
        XCTAssertEqual(HairlineSweep.bandFraction, 0.40)
        XCTAssertEqual(HairlineSweep.minimumBandWidth, 20)
        XCTAssertEqual(HairlineSweep.stops.map(\.location), [0, 0.5, 1])
        XCTAssertEqual(HairlineSweep.stops.map(\.opacity), [0, 0.70, 0])
        XCTAssertEqual(HairlineSweep.period, 1.6)
    }
}

