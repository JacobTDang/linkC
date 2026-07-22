import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp`. Status is read from the system every time, not
/// cached — a user who removes linkC from Login Items in System Settings must be reflected
/// correctly, never overridden by a stale stored bool. Register/unregister can throw in
/// unsigned or relocated-bundle contexts (test from the built `dist/linkC.app`, not swift run).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }
}
