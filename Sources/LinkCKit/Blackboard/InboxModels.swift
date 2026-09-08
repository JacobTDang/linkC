import Foundation

/// Status of a cross-agent pending message in the inbox queue.
public enum MessageStatus: String, Codable, Sendable {
    case queued
    case delivering
    case delivered
    case failed
}

/// A pending task or informational message routed to another agent.
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

    public init(
        id: String = UUID().uuidString,
        fromAgent: AgentKind,
        toAgent: AgentKind,
        prompt: String,
        claimedFiles: [String] = [],
        status: MessageStatus = .queued,
        rerouteCount: Int = 0,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil
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
    public var version: Int
    public var workspacePath: String
    public var updatedAt: Date
    public var messages: [PendingMessage]
    public var agentLimits: [AgentLimitStatus]

    public init(
        version: Int = 1,
        workspacePath: String,
        updatedAt: Date = Date(),
        messages: [PendingMessage] = [],
        agentLimits: [AgentLimitStatus] = []
    ) {
        self.version = version
        self.workspacePath = workspacePath
        self.updatedAt = updatedAt
        self.messages = messages
        self.agentLimits = agentLimits
    }
}
