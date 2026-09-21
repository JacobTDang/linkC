import Foundation
import Observation

/// Pure state-machine transitions. No side effects — trivially testable.
public enum SessionReducer {
    public static func nextState(current: SessionState, event: HookEventKind) -> SessionState {
        switch event {
        case .sessionStart: return .ready
        case .userPromptSubmit: return .working
        case .notificationPermission: return .waitingPermission
        // The idle-prompt nudge fires about 60 s into any idle prompt. With no turn run yet it is
        // not news, so a ready session stays ready.
        case .notificationIdle: return current == .ready ? .ready : .waitingIdle
        case .stop: return .finished
        case .stopFailure: return .error
        case .sessionEnd: return .ended
        // Questions and plan approvals prompt even under --dangerously-skip-permissions; the
        // tool finishing is what says the prompt was answered. Nothing else is moved, so a late
        // tool event cannot revive a finished turn.
        case .toolFinished: return current == .waitingPermission ? .working : current
        }
    }

    /// Apply an event to a session. Returns the updated session and whether it just
    /// *entered* a notifiable state (a transition, not a repeat). Real transitions stamp
    /// `stateChangedAt`; a re-asserted identical state keeps the original clock. One exception:
    /// the idle nudge after a finished turn is a reminder about that turn, not a new event.
    public static func apply(
        _ event: HookEvent, to session: Session, now: Date = Date()
    ) -> (session: Session, enteredNotifiable: Bool) {
        var s = session
        let old = s.state
        // A subagent cannot ask the user anything, so its finished tool says nothing about a
        // prompt the main turn is waiting on. (A parallel main-turn tool finishing after the
        // prompt appeared is indistinguishable here: the payload does not name the prompted tool.)
        let subagentTool = event.kind == .toolFinished && event.agentId != nil
        s.state = subagentTool ? old : nextState(current: old, event: event.kind)
        // The idle nudge after a finished turn is a reminder about that turn, not a new event:
        // the state moves on, but the turn keeps its clock, so a turn already seen stays seen.
        let nudgeAfterTurn = old == .finished && s.state == .waitingIdle
        if s.state != old && !nudgeAfterTurn { s.stateChangedAt = now }
        if let cid = event.claudeSessionId { s.claudeSessionId = cid }
        let entered = s.state.isNotifiable && s.state != old
        return (s, entered)
    }
}

public struct ApplyOutcome: Sendable, Equatable {
    public let session: Session?
    public let shouldConsiderNotifying: Bool
    public init(session: Session?, shouldConsiderNotifying: Bool) {
        self.session = session
        self.shouldConsiderNotifying = shouldConsiderNotifying
    }
}

/// The single source of truth for the UI. Observable; all access on the main actor.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [Session] = []

    public init() {}

    /// Register a linkC session before its tab is launched.
    @discardableResult
    public func create(cwd: String, title: String, id: String = UUID().uuidString, agentKind: AgentKind = .claude,
                       model: String? = nil, modelTier: ModelTier? = nil,
                       claudeSessionId: String? = nil, isWorker: Bool = false) -> Session {
        let s = Session(id: id, cwd: cwd, title: title, claudeSessionId: claudeSessionId, agentKind: agentKind,
                        model: model, modelTier: modelTier, isWorker: isWorker)
        sessions.append(s)
        return s
    }

    public func session(id: String) -> Session? { sessions.first { $0.id == id } }

    public func remove(id: String) { sessions.removeAll { $0.id == id } }

    /// The user opened this worker's terminal: from now on it is theirs, and never closed for them.
    public func adopt(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }), sessions[idx].isWorker else { return }
        sessions[idx].isWorker = false
    }

    /// Directly update a session's state and record stateChangedAt on real transitions.
    public func updateState(id: String, to newState: SessionState) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[idx].state != newState {
            sessions[idx].state = newState
            sessions[idx].stateChangedAt = Date()
        }
    }

    /// Record what a session is actually running after a hand switch.
    public func updateModel(id: String, model: String?, modelTier: ModelTier?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].model = model
        sessions[idx].modelTier = modelTier
    }

    /// Update a session's detected agent kind if it changes dynamically.
    public func updateAgentKind(id: String, to agentKind: AgentKind) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[idx].agentKind != agentKind {
            sessions[idx].agentKind = agentKind
        }
    }

    /// Apply an incoming hook event. An event carrying a linkC id binds to that session or to
    /// nothing; only an event with no linkC id binds by its Claude session id.
    /// Unknown / external events (no matching session) are ignored.
    @discardableResult
    public func apply(_ event: HookEvent) -> ApplyOutcome {
        var idx: Int?
        if let lid = event.linkcSessionId {
            // An event addressed to a linkC session belongs to that session alone. When it is
            // already gone — closing removes a session before its own SessionEnd arrives — the
            // event is dropped: falling back to the conversation id would land it on a sibling
            // sharing that conversation and end the wrong session.
            idx = sessions.firstIndex { $0.id == lid }
        } else if let cid = event.claudeSessionId {
            idx = sessions.firstIndex { $0.claudeSessionId == cid }
        }
        guard let i = idx else { return ApplyOutcome(session: nil, shouldConsiderNotifying: false) }
        let (updated, entered) = SessionReducer.apply(event, to: sessions[i])
        sessions[i] = updated
        return ApplyOutcome(session: updated, shouldConsiderNotifying: entered)
    }

    public var activeCount: Int { sessions.filter { $0.state.bucket == .active }.count }
    public var needsYouCount: Int { sessions.filter { $0.state.bucket == .needsYou }.count }
}
