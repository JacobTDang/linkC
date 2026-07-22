import XCTest
@testable import LinkCKit

/// linkC's own preferences — UserDefaults-backed, injectable suite so tests never touch the
/// real domain. Launch-at-login is deliberately NOT here (the system owns that state).
@MainActor
final class AppPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "linkc-prefs-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDocumentedDefaults() {
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.hotKeyPreset, .none)
        XCTAssertTrue(prefs.showsUsageFooter)
    }

    func testRoundTripPersistence() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.hotKeyPreset = .optionSpace
        prefs.showsUsageFooter = false

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.hotKeyPreset, .optionSpace)
        XCTAssertFalse(reloaded.showsUsageFooter)
    }

    func testEveryPresetHasALabelAndConsistentKeycodes() {
        for preset in AppPreferences.HotKeyPreset.allCases {
            XCTAssertFalse(preset.label.isEmpty)
            if preset == .none {
                XCTAssertNil(preset.keyCode)
                XCTAssertNil(preset.carbonModifiers)
            } else {
                XCTAssertNotNil(preset.keyCode, preset.rawValue)
                XCTAssertNotNil(preset.carbonModifiers, preset.rawValue)
            }
        }
    }

    func testCorruptStoredValueFallsBackToDefault() {
        defaults.set("not-a-preset", forKey: "hotKeyPreset")
        XCTAssertEqual(AppPreferences(defaults: defaults).hotKeyPreset, .none)
    }
}
