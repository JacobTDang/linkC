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
    /// *entered* a notifiable state (a transition, not a repeat).
    public static func apply(_ event: HookEvent, to session: Session) -> (session: Session, enteredNotifiable: Bool) {
        var s = session
        let old = s.state
        s.state = nextState(current: old, event: event.kind)
        if let cid = event.claudeSessionId { s.claudeSessionId = cid }
        s.lastEventAt = event.receivedAt
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
    public func create(cwd: String, title: String, id: String = UUID().uuidString) -> Session {
        let s = Session(id: id, cwd: cwd, title: title)
        sessions.append(s)
        return s
    }

    public func session(id: String) -> Session? { sessions.first { $0.id == id } }

    public func setKittyWindow(_ windowId: Int, for linkcId: String) {
        if let i = sessions.firstIndex(where: { $0.id == linkcId }) {
            sessions[i].kittyWindowId = windowId
        }
    }

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
    public var idleCount: Int { sessions.filter { $0.state.bucket == .idle }.count }
}
