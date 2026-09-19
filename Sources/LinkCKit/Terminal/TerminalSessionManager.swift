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

    /// Called just before `selectedId` changes, whatever changes it, while the old value is still
    /// readable — so the app can record what was on screen before it leaves.
    @ObservationIgnored public var onSelectionWillChange: (@MainActor () -> Void)?

    public init() {}

    /// The single writer of `selectedId`: announces a real change first, ignores a no-op.
    private func setSelection(_ id: String?) {
        guard id != selectedId else { return }
        onSelectionWillChange?()
        selectedId = id
    }

    /// Create a terminal for `id`, append it, and select it unless `select` is false (a
    /// background launch leaves whatever is on screen alone). Deliberately does NOT start a
    /// process — the caller drives `TerminalSession.start(...)` — so construction is
    /// side-effect free and unit-testable without spawning a real PTY.
    @discardableResult
    public func makeSession(
        id: String, cwd: String, title: String, agentKind: AgentKind = .shell, select: Bool = true
    ) -> TerminalSession {
        let session = TerminalSession(id: id, cwd: cwd, title: title, agentKind: agentKind)
        sessions.append(session)
        if select { setSelection(id) }
        return session
    }

    public func session(id: String) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    /// Bring `id`'s terminal on screen. Ignores unknown ids.
    public func select(_ id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        setSelection(id)
    }

    /// Clears the selection; the right pane shows the launcher. Keeps every terminal alive; the
    /// panel controller treats a nil selection as a no-op, so this never closes the panel.
    public func deselect() {
        setSelection(nil)
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
            setSelection(sessions.last?.id)
        }
    }

    /// Injects input into the terminal session matching `sessionId`, if found.
    public func sendInput(sessionId: String, text: String) {
        session(id: sessionId)?.sendInput(text)
    }
}
