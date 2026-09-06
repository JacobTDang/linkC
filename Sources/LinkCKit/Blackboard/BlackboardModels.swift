import Foundation

public struct CollisionWarning: Codable, Sendable, Equatable {
    public let conflictingAgent: AgentKind
    public let pid: pid_t
    public let conflictingFiles: [String]
    public let goal: String

    public init(conflictingAgent: AgentKind, pid: pid_t, conflictingFiles: [String], goal: String) {
        self.conflictingAgent = conflictingAgent
        self.pid = pid
        self.conflictingFiles = conflictingFiles
        self.goal = goal
    }
}

public struct AgentRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String { agentId }
    public let agentId: String
    public let agentKind: AgentKind
    public let pid: pid_t
    public var goal: String
    public var claimedFiles: [String]
    public var lastHeartbeat: Date
    public var status: String

    public init(
        agentId: String,
        agentKind: AgentKind,
        pid: pid_t,
        goal: String,
        claimedFiles: [String],
        lastHeartbeat: Date = Date(),
        status: String = "working"
    ) {
        self.agentId = agentId
        self.agentKind = agentKind
        self.pid = pid
        self.goal = goal
        self.claimedFiles = claimedFiles
        self.lastHeartbeat = lastHeartbeat
        self.status = status
    }
}

public struct SharedNote: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let authorAgent: AgentKind
    public let title: String
    public let content: String
    public let createdAt: Date
    public let tags: [String]

    public init(
        id: String = UUID().uuidString,
        authorAgent: AgentKind,
        title: String,
        content: String,
        createdAt: Date = Date(),
        tags: [String] = []
    ) {
        self.id = id
        self.authorAgent = authorAgent
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.tags = tags
    }
}

public struct BlackboardEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let agentKind: AgentKind
    public let action: String
    public let details: String

    public init(timestamp: Date = Date(), agentKind: AgentKind, action: String, details: String) {
        self.timestamp = timestamp
        self.agentKind = agentKind
        self.action = action
        self.details = details
    }
}

public struct Blackboard: Codable, Sendable, Equatable {
    public var version: Int
    public var projectPath: String
    public var updatedAt: Date
    public var activeAgents: [AgentRecord]
    public var sharedNotes: [SharedNote]
    public var recentEvents: [BlackboardEvent]

    public init(
        version: Int = 1,
        projectPath: String,
        updatedAt: Date = Date(),
        activeAgents: [AgentRecord] = [],
        sharedNotes: [SharedNote] = [],
        recentEvents: [BlackboardEvent] = []
    ) {
        self.version = version
        self.projectPath = projectPath
        self.updatedAt = updatedAt
        self.activeAgents = activeAgents
        self.sharedNotes = sharedNotes
        self.recentEvents = recentEvents
    }
}
