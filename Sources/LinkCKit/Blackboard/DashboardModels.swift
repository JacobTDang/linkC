import Foundation

/// The nature of an agent activity event in the swarm.
public enum AgentActivityKind: String, Codable, Sendable {
    case delegatedTask
    case completedTask
    case intentBroadcast
    case sharedNote
    case rateLimited
}

/// A unified, chronological event representing inter-agent communication or action.
public struct AgentActivityItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public let workspacePath: String
    public let projectTitle: String
    public let fromAgent: AgentKind
    public let toAgent: AgentKind?
    public let kind: AgentActivityKind
    public let title: String
    public let body: String
    public let claimedFiles: [String]

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        workspacePath: String,
        projectTitle: String,
        fromAgent: AgentKind,
        toAgent: AgentKind? = nil,
        kind: AgentActivityKind,
        title: String,
        body: String,
        claimedFiles: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.workspacePath = workspacePath
        self.projectTitle = projectTitle
        self.fromAgent = fromAgent
        self.toAgent = toAgent
        self.kind = kind
        self.title = title
        self.body = body
        self.claimedFiles = claimedFiles
    }
}

/// Cumulative deliverable and workspace impact summary for a single agent.
public struct AgentContributionDossier: Sendable, Identifiable, Equatable {
    public var id: String { "\(workspacePath)-\(agent.rawValue)" }
    public let agent: AgentKind
    public let workspacePath: String
    public let activeSessionId: String?
    public let status: String
    public let liveActivity: String?
    public let completedTasksCount: Int
    public let claimedFiles: [String]
    public let modifiedFiles: [String]
    public let lastDeliverable: String?
    public let notesAuthoredCount: Int

    public init(
        agent: AgentKind,
        workspacePath: String,
        activeSessionId: String? = nil,
        status: String = "idle",
        liveActivity: String? = nil,
        completedTasksCount: Int = 0,
        claimedFiles: [String] = [],
        modifiedFiles: [String] = [],
        lastDeliverable: String? = nil,
        notesAuthoredCount: Int = 0
    ) {
        self.agent = agent
        self.workspacePath = workspacePath
        self.activeSessionId = activeSessionId
        self.status = status
        self.liveActivity = liveActivity
        self.completedTasksCount = completedTasksCount
        self.claimedFiles = claimedFiles
        self.modifiedFiles = modifiedFiles
        self.lastDeliverable = lastDeliverable
        self.notesAuthoredCount = notesAuthoredCount
    }
}

public struct ProjectDashboardData: Sendable, Equatable {
    public let workspacePath: String
    public let projectTitle: String
    public let activityItems: [AgentActivityItem]
    public let dossiers: [AgentContributionDossier]
    public let sharedNotes: [SharedNote]
    public let collisions: [CollisionWarning]

    public init(
        workspacePath: String,
        projectTitle: String,
        activityItems: [AgentActivityItem] = [],
        dossiers: [AgentContributionDossier] = [],
        sharedNotes: [SharedNote] = [],
        collisions: [CollisionWarning] = []
    ) {
        self.workspacePath = workspacePath
        self.projectTitle = projectTitle
        self.activityItems = activityItems
        self.dossiers = dossiers
        self.sharedNotes = sharedNotes
        self.collisions = collisions
    }
}

public struct GlobalDashboardData: Sendable, Equatable {
    public let activityItems: [AgentActivityItem]
    public let dossiers: [AgentContributionDossier]
    public let activeProjectCount: Int

    public init(
        activityItems: [AgentActivityItem] = [],
        dossiers: [AgentContributionDossier] = [],
        activeProjectCount: Int = 0
    ) {
        self.activityItems = activityItems
        self.dossiers = dossiers
        self.activeProjectCount = activeProjectCount
    }
}
