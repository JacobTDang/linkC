import Foundation
import Observation

/// Pure state-machine transitions. No side effects — trivially testable.
public enum SessionReducer {
    public static func nextState(current: SessionState, event: HookEventKind) -> SessionState {
        switch event {
        case .sessionStart: return .ready
        case .userPromptSubmit: return .working
        case .notificationPermission: return .waitingPermission
        case .notificationIdle: return .waitingIdle
        case .stop: return .finished
        case .stopFailure: return .error
        case .sessionEnd: return .ended
        }
    }

    /// Apply an event to a session. Returns the updated session and whether it just
    /// *entered* a notifiable state (a transition, not a repeat). Real transitions stamp
    /// `stateChangedAt`; a re-asserted identical state keeps the original clock.
    public static func apply(
        _ event: HookEvent, to session: Session, now: Date = Date()
    ) -> (session: Session, enteredNotifiable: Bool) {
        var s = session
        let old = s.state
        s.state = nextState(current: old, event: event.kind)
        if s.state != old { s.stateChangedAt = now }
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
    public func create(cwd: String, title: String, id: String = UUID().uuidString, agentKind: AgentKind = .claude) -> Session {
        let s = Session(id: id, cwd: cwd, title: title, agentKind: agentKind)
        sessions.append(s)
        return s
    }

    public func session(id: String) -> Session? { sessions.first { $0.id == id } }

    public func remove(id: String) { sessions.removeAll { $0.id == id } }

    /// Apply an incoming hook event. Binds by linkC id, else by Claude session id.
    /// Unknown / external events (no matching session) are ignored.
    @discardableResult
    public func apply(_ event: HookEvent) -> ApplyOutcome {
        var idx: Int?
        if let lid = event.linkcSessionId { idx = sessions.firstIndex { $0.id == lid } }
        if idx == nil, let cid = event.claudeSessionId { idx = sessions.firstIndex { $0.claudeSessionId == cid } }
        guard let i = idx else { return ApplyOutcome(session: nil, shouldConsiderNotifying: false) }
        let (updated, entered) = SessionReducer.apply(event, to: sessions[i])
        sessions[i] = updated
        return ApplyOutcome(session: updated, shouldConsiderNotifying: entered)
    }

    public var activeCount: Int { sessions.filter { $0.state.bucket == .active }.count }
    public var needsYouCount: Int { sessions.filter { $0.state.bucket == .needsYou }.count }
}
