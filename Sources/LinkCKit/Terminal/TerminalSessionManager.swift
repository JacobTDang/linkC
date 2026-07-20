import Foundation
import Observation

/// Owns the live embedded terminals and which one is on screen. The single source of truth
/// for the terminal side of the panel; observable so the UI re-renders on add / remove /
/// select. All access is on the main actor.
@MainActor
@Observable
public final class TerminalSessionManager {
    public private(set) var sessions: [TerminalSession] = []
    public private(set) var selectedId: String?

    public init() {}

    /// Create a terminal for `id`, append it, and select it. Deliberately does NOT start a
    /// process — the caller drives `TerminalSession.start(...)` — so construction is
    /// side-effect free and unit-testable without spawning a real PTY.
    @discardableResult
    public func makeSession(id: String, cwd: String, title: String) -> TerminalSession {
        let session = TerminalSession(id: id, cwd: cwd, title: title)
        sessions.append(session)
        selectedId = id
        return session
    }

    public func session(id: String) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    /// Bring `id`'s terminal on screen. Ignores unknown ids.
    public func select(_ id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedId = id
    }

    /// Kill `id`'s child process and drop the session. Selection falls back to the last
    /// remaining terminal (or nil). Idempotent.
    public func terminate(_ id: String) {
        session(id: id)?.terminate()
        remove(id)
    }

    /// Drop `id` WITHOUT killing anything — used when the child has already exited on its own
    /// (its `onTerminated` fired). Selection falls back to the last remaining terminal (or
    /// nil). Idempotent.
    public func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        if selectedId == id {
            selectedId = sessions.last?.id
        }
    }
}
