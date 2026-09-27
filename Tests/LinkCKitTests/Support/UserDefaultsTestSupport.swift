import Foundation

/// Fully destroys an injectable `UserDefaults` suite created for a test: clears the domain,
/// flushes it through cfprefsd, then deletes the backing plist. `removePersistentDomain`
/// alone leaves that file behind — without this, every test that makes its own suite (prefs,
/// sidebar state, …) leaks one `~/Library/Preferences/<suite>.plist` into the real machine.
func destroyUserDefaultsSuite(_ defaults: UserDefaults, named suiteName: String) throws {
    defaults.removePersistentDomain(forName: suiteName)
    defaults.synchronize()
    let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suiteName).plist")
    guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
    try FileManager.default.removeItem(at: plistURL)
}
