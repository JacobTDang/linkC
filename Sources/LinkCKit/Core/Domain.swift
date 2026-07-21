import Foundation

/// Errors surfaced across linkC modules. Fail loud — never swallow these.
public enum LinkCError: Error, Sendable, Equatable {
    case parse(String)
    case process(String)
    case server(String)
}

/// The lifecycle state of a single Claude Code session, derived purely from hook events.
public enum SessionState: String, Sendable, Codable, CaseIterable, Equatable {
    case starting            // tab launched, no hook seen yet
    case ready               // SessionStart seen; idle, awaiting first prompt
    case working             // a prompt is being processed
    case waitingPermission   // Claude needs a permission decision
    case waitingIdle         // Claude is idle, waiting for input
    case finished            // Claude finished responding (turn complete)
    case error               // turn ended on an API error
    case ended               // session terminated

    public enum Bucket: String, Sendable, Equatable { case idle, active, needsYou }

    public var bucket: Bucket {
        switch self {
        case .starting, .ready, .ended: return .idle
        case .working: return .active
        case .waitingPermission, .waitingIdle, .finished, .error: return .needsYou
        }
    }

    /// Whether entering this state is a candidate for a notification (subject to focus policy).
    public var isNotifiable: Bool { bucket == .needsYou }
}

/// A normalized hook event. `kind` is carried in the `X-LinkC-Event` header we configure,
/// so it never depends on parsing Claude's body event name.
public enum HookEventKind: String, Sendable, Equatable, CaseIterable {
    case sessionStart = "session_start"
    case userPromptSubmit = "user_prompt_submit"
    case notificationPermission = "notification_permission"
    case notificationIdle = "notification_idle"
    case stop = "stop"
    case stopFailure = "stop_failure"
    case sessionEnd = "session_end"
}

public struct HookEvent: Sendable, Equatable {
    public let kind: HookEventKind
    /// From the `X-LinkC-Session` header. Empty/nil means an external (non-linkC) session → ignored.
    public let linkcSessionId: String?
    public let claudeSessionId: String?
    public let cwd: String?

    public init(
        kind: HookEventKind,
        linkcSessionId: String?,
        claudeSessionId: String?,
        cwd: String?
    ) {
        self.kind = kind
        self.linkcSessionId = (linkcSessionId?.isEmpty ?? true) ? nil : linkcSessionId
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
    }
}

/// One managed Claude Code session.
public struct Session: Sendable, Identifiable, Equatable {
    /// linkC's own id (UUID string), injected as `LINKC_SESSION` and the kitty `linkc_session` user var.
    public let id: String
    public var claudeSessionId: String?
    public var cwd: String
    public var title: String
    public var state: SessionState

    public init(
        id: String,
        cwd: String,
        title: String,
        state: SessionState = .starting,
        claudeSessionId: String? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.state = state
        self.claudeSessionId = claudeSessionId
    }
}
