import XCTest

final class InMemoryUserDefaultsTests: XCTestCase {
    /// cfprefsd writes a suite's plist about 30 s after the test process exits, whatever tearDown
    /// does — `removePersistentDomain`, removing each key and deleting the file were all measured
    /// to leave one behind. So a test suite that ever reaches the daemon leaks a file into
    /// `~/Library/Preferences`; the test double must keep every write in memory.
    func testWritesStayInMemoryAndNeverReachThePreferencesDaemon() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(Data([1, 2, 3]), forKey: "data")
        defaults.set(true, forKey: "flag")
        defaults.set("x", forKey: "text")

        XCTAssertEqual(defaults.data(forKey: "data"), Data([1, 2, 3]))
        XCTAssertEqual(defaults.object(forKey: "flag") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "text"), "x")
        let daemonView = try XCTUnwrap(UserDefaults(suiteName: defaults.suite))
        XCTAssertNil(daemonView.persistentDomain(forName: defaults.suite), "a write reached cfprefsd")
    }
}
