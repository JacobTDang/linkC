import Foundation

/// What linkC does differently for Crush. See docs/superpowers/specs/2026-11-12-freebuff-kilo-crush-design.md §4.3.
extension AppCoordinator {
    /// What a Crush terminal adds to `LINKC_SESSION`: the folders of the session's own config, which
    /// pin the model — Crush's TUI takes no model flag (`CrushSessionConfig`). Fails loud: a Crush
    /// whose model cannot be pinned to a free one is never started.
    func crushEnvironment(sessionId: String, cwd: String, model: String?) throws -> [String: String] {
        guard let crushSessions else {
            throw LinkCError.process("Crush needs a home folder for its config, and linkC has none")
        }
        guard let model else {
            throw LinkCError.process("no model to pin Crush to — set a Crush model in linkC settings")
        }
        return try crushSessions.prepare(sessionId: sessionId, cwd: cwd, model: model)
    }

    /// Runs a deletion of Crush's per-session folders and says so, in the log and to the user, when it
    /// fails: a folder left behind may hold a model that overrides the free one. Nothing launches on
    /// it afterwards (`CrushSessionConfig.prepare` refuses a folder it cannot delete).
    func reportCrushCleanup(_ delete: () throws -> Void) {
        do {
            try delete()
        } catch {
            NSLog("[linkC] %@", String(describing: error))
            notifications.postLocal(title: "linkC: could not delete a Crush session's folder", body: String(describing: error))
        }
    }

    /// Says that a Crush session was brought back as a new conversation, in the log and to the
    /// user: its old one would have run on whatever model it last used.
    func tellCrushStartedFresh(title: String, folder: String) {
        let message = "Crush starts a new conversation on restore, so it only ever runs a free model."
        NSLog("[linkC] %@ (%@): %@", title, folder, message)
        notifications.postLocal(title: "linkC: Crush started a new conversation", body: "\(title): \(message)")
    }
}
