import Foundation

/// A `UserDefaults` for tests that keeps every value in memory and never writes to cfprefsd.
/// The daemon writes a suite's plist about 30 s after the test process exits, whatever tearDown
/// does, so any test suite that reached it leaked a `~/Library/Preferences/<suite>.plist`.
/// Covers the calls linkC's stores make.
final class InMemoryUserDefaults: UserDefaults {
    let suite = "linkc-test-\(UUID().uuidString)"
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: suite)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
