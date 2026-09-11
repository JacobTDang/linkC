import Foundation
import CryptoKit

// MARK: - Task lifecycle

/// Lifecycle state of a delegated task. See spec §5.1 for the transition table.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case gating, queued, delivered, started, reported, done, failed, cancelled, expired

    public var isOpen: Bool {
        switch self {
        case .gating, .queued, .delivered, .started, .reported: return true
        case .done, .failed, .cancelled, .expired: return false
        }
    }

    public func canTransition(to next: TaskState) -> Bool {
        switch (self, next) {
        case (.gating, .queued), (.gating, .cancelled), (.gating, .expired):
            return true
        case (.queued, .delivered), (.queued, .cancelled), (.queued, .expired):
            return true
        case (.delivered, .started), (.delivered, .reported), (.delivered, .failed),
             (.delivered, .cancelled), (.delivered, .expired):
            return true
        case (.started, .reported), (.started, .failed), (.started, .cancelled), (.started, .expired):
            return true
        case (.reported, .done), (.reported, .failed), (.reported, .cancelled), (.reported, .expired):
            return true
        default:
            return false
        }
    }
}

/// The assignee's report, supplied through `linkc_complete_task`. For a verified task it is a
/// claim: linkC decides the outcome by running the verification at `sha`.
public struct TaskReport: Codable, Sendable, Equatable {
    public static let summaryLimit = 1_000

    public let status: String   // "done" | "failed"
    public let summary: String
    public let sha: String?
    public let commits: [String]

    public init(status: String, summary: String, sha: String? = nil, commits: [String] = []) {
        self.status = status
        self.summary = summary
        self.sha = sha
        self.commits = commits
    }
}

/// How linkC checks a task: the delegator's tests, committed at `baseSha` on `branch`, run by `command`.
public struct Verification: Codable, Sendable, Equatable {
    public static let defaultTimeoutSeconds = 600
    public static let timeoutRange = 1...3600

    public let branch: String
    public let baseSha: String
    public let command: String
    public let testPaths: [String]
    public let timeoutSeconds: Int

    public init(branch: String, baseSha: String, command: String, testPaths: [String],
                timeoutSeconds: Int = Verification.defaultTimeoutSeconds) {
        self.branch = branch
        self.baseSha = baseSha
        self.command = command
        self.testPaths = testPaths
        self.timeoutSeconds = timeoutSeconds
    }

    /// Nil when valid; otherwise what is wrong.
    public var validationError: String? {
        if branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "branch is empty" }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "command is empty" }
        if testPaths.isEmpty { return "test_paths is empty" }
        if baseSha.count != 40 || !baseSha.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return "base_sha must be a full 40-character lowercase SHA"
        }
        if !Verification.timeoutRange.contains(timeoutSeconds) { return "timeout_seconds must be between 1 and 3600" }
        return nil
    }
}

/// The result of a gate or a verification. `passed` means the check succeeded: for the gate,
/// that the tests ran and failed at base; for verification, that they passed at `sha`.
public struct Verdict: Codable, Sendable, Equatable {
    public static let tailLimit = 2_000

    public let passed: Bool
    public let sha: String?        // the commit the command ran at; nil if it never ran
    public let exitStatus: Int32?  // nil if the command never finished
    public let reason: String?     // set whenever passed == false
    public let stdoutTail: String
    public let stderrTail: String
    public let ranAt: Date

    public init(passed: Bool, sha: String?, exitStatus: Int32?, reason: String?,
                stdoutTail: String, stderrTail: String, ranAt: Date = Date()) {
        self.passed = passed
        self.sha = sha
        self.exitStatus = exitStatus
        self.reason = reason
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.ranAt = ranAt
    }

    /// A failed verdict reached without the command finishing.
    public static func notRun(reason: String, sha: String? = nil) -> Verdict {
        Verdict(passed: false, sha: sha, exitStatus: nil, reason: reason, stdoutTail: "", stderrTail: "")
    }
}

/// A delegated unit of work with exactly one assignee and an exclusive lease on `files`.
public struct TaskRecord: Codable, Sendable, Identifiable, Equatable {
    public static let leaseDuration: TimeInterval = 4 * 3600

    public let id: String
    public let fromAgent: AgentKind
    public let toAgent: AgentKind
    public var assigneeSessionId: String?
    public let prompt: String
    public let files: [String]
    public var state: TaskState
    public let hop: Int
    public let createdAt: Date
    public var deliveredAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var leaseExpiresAt: Date
    public var report: TaskReport?
    public var cancelReason: String?
    public var unreportedTurnEndNotified: Bool
    public var verification: Verification?
    public var gate: Verdict?
    public var verdict: Verdict?

    public var shortId: String { String(id.prefix(8)) }

    public init(
        id: String = UUID().uuidString,
        fromAgent: AgentKind,
        toAgent: AgentKind,
        assigneeSessionId: String? = nil,
        prompt: String,
        files: [String] = [],
        state: TaskState = .queued,
        hop: Int = 0,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        leaseExpiresAt: Date? = nil,
        report: TaskReport? = nil,
        cancelReason: String? = nil,
        unreportedTurnEndNotified: Bool = false,
        verification: Verification? = nil,
        gate: Verdict? = nil,
        verdict: Verdict? = nil
    ) {
        self.id = id
        self.fromAgent = fromAgent
        self.toAgent = toAgent
        self.assigneeSessionId = assigneeSessionId
        self.prompt = prompt
        self.files = files
        self.state = state
        self.hop = hop
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.leaseExpiresAt = leaseExpiresAt ?? createdAt.addingTimeInterval(TaskRecord.leaseDuration)
        self.report = report
        self.cancelReason = cancelReason
        self.unreportedTurnEndNotified = unreportedTurnEndNotified
        self.verification = verification
        self.gate = gate
        self.verdict = verdict
    }
}

// MARK: - Messages

/// What a message *is*. Only `.completion`, `.peerNote`, `.notice`, `.command` are created by v2;
/// `.task` exists to dispatch legacy v1 rows once after upgrade.
public enum MessageKind: String, Codable, Sendable {
    case task
    case completion
    case peerNote
    case notice
    case command
}

/// Frame markers that identify linkC-generated text. A body beginning with any of these is
/// rejected by `InboxStore` so a forwarded message can never become the body of another.
public enum LinkCFrame {
    public static let taskPrefix = "[linkC task"
    public static let noticePrefix = "[linkC notice]"
    public static let peerNotePrefix = "[Peer Note from"
    public static let legacyCompletionPrefix = "[Task Completed by"
    public static let legacySystemNoticePrefix = "[System Notice]"

    public static let allMarkers: [String] = [
        taskPrefix, noticePrefix, peerNotePrefix, legacyCompletionPrefix, legacySystemNoticePrefix
    ]

    /// True when the first non-whitespace characters of `text` are a marker.
    public static func beginsWithMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return allMarkers.contains { trimmed.hasPrefix($0) }
    }

    /// Kind inference for v1 rows that carry no `kind` field.
    public static func inferLegacyKind(prompt: String) -> MessageKind {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(legacyCompletionPrefix) || trimmed.hasPrefix(taskPrefix) { return .completion }
        if trimmed.hasPrefix(legacySystemNoticePrefix) || trimmed.hasPrefix(noticePrefix) { return .notice }
        if trimmed.hasPrefix(peerNotePrefix) { return .peerNote }
        return .task
    }

    /// SHA-256 hex of `from|to|kind|prompt`; used for 24 h dedupe.
    public static func contentHash(from: AgentKind, to: AgentKind, kind: MessageKind, prompt: String) -> String {
        let material = "\(from.rawValue)|\(to.rawValue)|\(kind.rawValue)|\(prompt)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors surfaced to callers as tool `isError` results.
public enum InboxError: Error, LocalizedError, Equatable {
    case leaseConflict(holders: [TaskRecord])
    case illegalTransition(taskId: String, from: TaskState, to: TaskState)
    case taskNotFound(String)
    case ambiguousTaskId(prefix: String, matches: [String])
    case framedBody
    case hopLimit(Int)
    case kindNotAllowed(MessageKind)
    case missingTaskId
    case emptySummary
    case invalidVerification(String)
    case summaryTooLong(count: Int)
    case shaRequired
    case invalidReportStatus(String)
    case notVerified(String)
    case verificationPresent(String)

    public var errorDescription: String? {
        switch self {
        case .leaseConflict(let holders):
            let list = holders.map { h in
                "\(h.files.joined(separator: ", ")) leased by \(h.toAgent.displayName) under task \(h.shortId) (\(h.state.rawValue))"
            }.joined(separator: "; ")
            return "Refused: \(list). Retry with force: true to override."
        case .illegalTransition(let taskId, let from, let to):
            return "Task \(taskId.prefix(8)) is \(from.rawValue); cannot move to \(to.rawValue)."
        case .taskNotFound(let id):
            return "Task \(id) not found."
        case .ambiguousTaskId(let prefix, let matches):
            let list = matches.map { "\($0.prefix(8)) (\($0))" }.joined(separator: ", ")
            return "Task id '\(prefix)' is ambiguous; it matches \(list). Pass the full id."
        case .framedBody:
            return "Rejected: body begins with a linkC frame marker; forwarded messages cannot be re-sent."
        case .hopLimit(let hop):
            return "Rejected: hop \(hop) exceeds the reroute limit of 2."
        case .kindNotAllowed(let kind):
            return "Rejected: message kind '\(kind.rawValue)' cannot be enqueued directly."
        case .missingTaskId:
            return "Rejected: completion messages require a task id."
        case .emptySummary:
            return "Rejected: summary must not be empty."
        case .invalidVerification(let reason):
            return "Rejected: invalid verify — \(reason)."
        case .summaryTooLong(let count):
            return "Rejected: summary is \(count) characters; the limit is 1,000."
        case .shaRequired:
            return "Rejected: this task is verified; report the sha of your commit."
        case .invalidReportStatus(let status):
            return "Rejected: status must be \"done\" or \"failed\", not \"\(status)\"."
        case .notVerified(let id):
            return "Task \(id.prefix(8)) has no verification."
        case .verificationPresent(let id):
            return "Task \(id.prefix(8)) is verified; linkC must adjudicate it."
        }
    }
}

/// Status of a cross-agent pending message in the inbox queue.
public enum MessageStatus: String, Codable, Sendable {
    case queued
    case delivering
    case delivered
    case failed
}

/// A short message routed to another agent (completion line, peer note, notice, or raw command).
public struct PendingMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public let fromAgent: AgentKind
    public let toAgent: AgentKind
    public let prompt: String
    public let claimedFiles: [String]
    public var status: MessageStatus
    public var rerouteCount: Int
    public let createdAt: Date
    public var deliveredAt: Date?
    public let kind: MessageKind
    public let taskId: String?
    public let contentHash: String

    public init(
        id: String = UUID().uuidString,
        fromAgent: AgentKind,
        toAgent: AgentKind,
        prompt: String,
        claimedFiles: [String] = [],
        status: MessageStatus = .queued,
        rerouteCount: Int = 0,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil,
        kind: MessageKind? = nil,
        taskId: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.fromAgent = fromAgent
        self.toAgent = toAgent
        self.prompt = prompt
        self.claimedFiles = claimedFiles
        self.status = status
        self.rerouteCount = rerouteCount
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        let resolvedKind = kind ?? LinkCFrame.inferLegacyKind(prompt: prompt)
        self.kind = resolvedKind
        self.taskId = taskId
        self.contentHash = contentHash ?? LinkCFrame.contentHash(from: fromAgent, to: toAgent, kind: resolvedKind, prompt: prompt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromAgent, toAgent, prompt, claimedFiles, status, rerouteCount, createdAt, deliveredAt, kind, taskId, contentHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fromAgent = try c.decode(AgentKind.self, forKey: .fromAgent)
        let toAgent = try c.decode(AgentKind.self, forKey: .toAgent)
        let prompt = try c.decode(String.self, forKey: .prompt)
        let kind = try c.decodeIfPresent(MessageKind.self, forKey: .kind) ?? LinkCFrame.inferLegacyKind(prompt: prompt)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            fromAgent: fromAgent,
            toAgent: toAgent,
            prompt: prompt,
            claimedFiles: try c.decodeIfPresent([String].self, forKey: .claimedFiles) ?? [],
            status: try c.decode(MessageStatus.self, forKey: .status),
            rerouteCount: try c.decodeIfPresent(Int.self, forKey: .rerouteCount) ?? 0,
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            deliveredAt: try c.decodeIfPresent(Date.self, forKey: .deliveredAt),
            kind: kind,
            taskId: try c.decodeIfPresent(String.self, forKey: .taskId),
            contentHash: try c.decodeIfPresent(String.self, forKey: .contentHash)
                ?? LinkCFrame.contentHash(from: fromAgent, to: toAgent, kind: kind, prompt: prompt)
        )
    }
}

/// Records rate limit or quota exhaustion status for an agent kind.
public struct AgentLimitStatus: Codable, Sendable, Equatable {
    public let agent: AgentKind
    public let reason: String
    public let limitedAt: Date
    public let cooldownExpiresAt: Date

    public init(
        agent: AgentKind,
        reason: String,
        limitedAt: Date = Date(),
        cooldownExpiresAt: Date
    ) {
        self.agent = agent
        self.reason = reason
        self.limitedAt = limitedAt
        self.cooldownExpiresAt = cooldownExpiresAt
    }
}

/// Container stored at `<workspaceRoot>/.linkc/inbox.json`.
public struct Inbox: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var workspacePath: String
    public var updatedAt: Date
    public var messages: [PendingMessage]
    public var agentLimits: [AgentLimitStatus]
    public var tasks: [TaskRecord]

    public init(
        version: Int = Inbox.currentVersion,
        workspacePath: String,
        updatedAt: Date = Date(),
        messages: [PendingMessage] = [],
        agentLimits: [AgentLimitStatus] = [],
        tasks: [TaskRecord] = []
    ) {
        self.version = version
        self.workspacePath = workspacePath
        self.updatedAt = updatedAt
        self.messages = messages
        self.agentLimits = agentLimits
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case version, workspacePath, updatedAt, messages, agentLimits, tasks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: Inbox.currentVersion,
            workspacePath: try c.decode(String.self, forKey: .workspacePath),
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            messages: try c.decodeIfPresent([PendingMessage].self, forKey: .messages) ?? [],
            agentLimits: try c.decodeIfPresent([AgentLimitStatus].self, forKey: .agentLimits) ?? [],
            tasks: try c.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
        )
    }
}
