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
    /// Sessions disappear from `sessions` immediately when closed, but their SwiftTerm process
    /// monitor must live through exit so it can waitpid the child rather than leave a zombie.
    @ObservationIgnored private var terminatingSessions: [ObjectIdentifier: TerminalSession] = [:]

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
        guard let session = session(id: id) else { return }
        if session.isRunning {
            let key = ObjectIdentifier(session)
            session.onProcessReaped = { [weak self] in
                self?.terminatingSessions.removeValue(forKey: key)
            }
            terminatingSessions[key] = session
        }
        session.terminate()
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

    /// Injects input into the terminal session matching `sessionId`, if found. Returns `false`
    /// (and logs) when there is no such session — a missing or already-torn-down terminal — or
    /// when the session itself reports the send did not go through (`TerminalSession.sendInput`).
    /// A caller that marks delivery state on the strength of this call must not ignore that
    /// signal: `session(id:)?.sendInput(text)` used to swallow a missing session entirely, with
    /// no trace anywhere that the text never reached anything.
    @discardableResult
    public func sendInput(sessionId: String, text: String) -> Bool {
        guard let session = session(id: sessionId) else {
            NSLog("linkC: sendInput found no terminal for session %@ — input dropped", sessionId)
            return false
        }
        return session.sendInput(text)
    }
}
