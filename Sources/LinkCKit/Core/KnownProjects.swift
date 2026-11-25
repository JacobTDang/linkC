import Foundation

/// A project another project can reach (spec 2026-11-11 cross-project §4): a sidebar project, or a
/// folder with a running `linkc-mcp`. The app lists them in `projects.json`, because the MCP server
/// runs outside the app and sees neither the sidebar nor the sessions.
public struct KnownProject: Codable, Equatable, Sendable {
    /// A live session in the project, as the app last saw it.
    public struct OpenSession: Codable, Equatable, Sendable {
        public enum Activity: String, Codable, Sendable {
            case idle, busy, starting
        }

        /// A subagent the session runs, as its agent's own files record it.
        public struct Subagent: Codable, Equatable, Sendable {
            /// What the session called it when it started it.
            public let name: String
            /// The step it is on, when its files say; absent when they don't.
            public let step: String?

            public init(name: String, step: String?) {
                self.name = name
                self.step = step
            }
        }

        public let id: String
        /// `AgentKind.rawValue`. A string, so a file written by a newer app that knows another agent
        /// still reads in an older server.
        public let agent: String
        public let activity: Activity
        /// What the session's row shows, for a panel beside another session. Absent in a file an
        /// older app wrote.
        public let title: String?
        /// `SessionState.rawValue`, finer than `activity`: a permission wait reads apart from work.
        public let state: String?
        /// When `state` began, ISO 8601.
        public let since: String?
        public let model: String?
        /// linkC started the session to carry a delegated task.
        public let worker: Bool?
        /// The action line the session's sidebar row reads while it works or waits on a permission.
        public let action: String?
        /// Subagents still running, absent when none: a session whose own turn ended can still be at work.
        public let subagents: Int?
        /// When the session's prompt cache goes cold, ISO 8601; absent when its lifetime is unknown.
        public let cacheExpiresAt: String?
        /// True when `cacheExpiresAt` is worked out from the provider's cache lifetime rather than
        /// reported by the agent; absent when reported.
        public let cacheEstimate: Bool?
        /// How full the session's context is, 0–100, as its agent reports it: of the context window,
        /// for every agent that reports one today. Absent when the agent reports nothing, and in a
        /// file an older app wrote.
        public let contextPercent: Int?
        /// The step a turn is on, as the agent's own hooks or files record it, which `action` may only
        /// read off the screen. Only while the session works or waits on a permission, as `action`;
        /// absent where the agent records none.
        public let step: String?
        /// The subagents running now, with their names and steps, where the agent's own files record
        /// them; absent when none runs. Shown at rest too, as `subagents` is: a session whose own turn
        /// ended can still be running them.
        public let subagentSteps: [Subagent]?

        public init(id: String, agent: String, activity: Activity, title: String? = nil, state: String? = nil,
                    since: String? = nil, model: String? = nil, worker: Bool? = nil, action: String? = nil,
                    subagents: Int? = nil, cacheExpiresAt: String? = nil, cacheEstimate: Bool? = nil,
                    contextPercent: Int? = nil, step: String? = nil, subagentSteps: [Subagent]? = nil) {
            self.id = id
            self.agent = agent
            self.activity = activity
            self.title = title
            self.state = state
            self.since = since
            self.model = model
            self.worker = worker
            self.action = action
            self.subagents = subagents
            self.cacheExpiresAt = cacheExpiresAt
            self.cacheEstimate = cacheEstimate
            self.contextPercent = contextPercent
            self.step = step
            self.subagentSteps = subagentSteps
        }

        public var agentKind: AgentKind? { AgentKind(rawValue: agent) }
    }

    /// The canonical folder path.
    public let path: String
    public let sessions: [OpenSession]

    public init(path: String, sessions: [OpenSession]) {
        self.path = path
        self.sessions = sessions
    }

    /// The folder's name, which is what a `project` argument usually gives.
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// One plan limit an agent reports, as `projects.json` lists it under `limits`, keyed by agent.
public struct KnownLimit: Codable, Equatable, Sendable {
    /// The window, as the agent's usage reader names it: `5h`, `7d`.
    public let label: String
    /// How much of it is used, 0–100.
    public let percent: Int
    /// When it resets, ISO 8601; absent when the agent does not say.
    public let resets: String?

    public init(label: String, percent: Int, resets: String?) {
        self.label = label
        self.percent = percent
        self.resets = resets
    }
}

public enum KnownProjectsError: Error, Equatable, LocalizedError {
    /// No file: the app is not running (it removes the file when it quits) or has never run.
    case linkCNotRunning
    case unreadable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .linkCNotRunning:
            return "linkC isn't running, so other projects can't be reached."
        case .unreadable(let path, let reason):
            return "linkC's project list at \(path) could not be read: \(reason)"
        }
    }
}

/// `projects.json`: written by the app, read by every MCP server.
public struct KnownProjectsFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The file in linkC's own Application Support folder, beside `mcp-workspaces`.
    public static var applicationSupport: KnownProjectsFile {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
        return KnownProjectsFile(url: dir.appendingPathComponent("projects.json", isDirectory: false))
    }

    private struct Stored: Codable {
        let projects: [KnownProject]
        /// Each agent's plan limits, keyed by `AgentKind.rawValue`; absent when none is known, and in
        /// a file an older app wrote.
        let limits: [String: [KnownLimit]]?
    }

    public func read() throws -> [KnownProject] {
        try stored().projects
    }

    /// Each agent's plan limits, keyed by `AgentKind.rawValue`; empty when the file lists none.
    public func readLimits() throws -> [String: [KnownLimit]] {
        try stored().limits ?? [:]
    }

    private func stored() throws -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            throw KnownProjectsError.linkCNotRunning
        } catch {
            throw KnownProjectsError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            throw KnownProjectsError.unreadable(path: url.path, reason: String(describing: error))
        }
    }

    /// Replaces the file in one step, so a reader never sees half of it.
    public func write(_ projects: [KnownProject], limits: [String: [KnownLimit]] = [:]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Stored(projects: projects, limits: limits.isEmpty ? nil : limits)).write(to: url, options: .atomic)
    }

    /// Removes the file; a file already gone is fine.
    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

public enum ProjectRefError: Error, Equatable, LocalizedError {
    case unknown(String, known: [String])
    case ambiguous(String, paths: [String])
    case own(String)

    public var errorDescription: String? {
        switch self {
        case .unknown(let ref, let known):
            let list = known.isEmpty ? "No other project is known." : "Known projects: \(known.joined(separator: ", "))."
            return "No project \"\(ref)\" is known to linkC. \(list)"
        case .ambiguous(let ref, let paths):
            return "\"\(ref)\" names more than one project: \(paths.joined(separator: ", ")). Pass the full path."
        case .own(let ref):
            return "\"\(ref)\" is this project. Use the tool without project."
        }
    }
}

/// Resolves a tool's `project` argument (spec §4.2).
public enum ProjectRef {
    /// `ref` is a folder name (matched ignoring case) or a full path. `caller` is the calling server's
    /// own folder: naming it is refused, and a name it shares with exactly one other folder means that
    /// other folder.
    public static func resolve(_ ref: String, among projects: [KnownProject], caller: String) throws -> KnownProject {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = ProjectPath.canonical(caller)
        let others = projects.filter { $0.path != own }
        let knownNames = others.map(\.name).sorted()
        guard !trimmed.isEmpty else { throw ProjectRefError.unknown("", known: knownNames) }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = ProjectPath.canonical((trimmed as NSString).expandingTildeInPath)
            if path == own { throw ProjectRefError.own(trimmed) }
            guard let match = others.first(where: { $0.path == path }) else {
                throw ProjectRefError.unknown(trimmed, known: knownNames)
            }
            return match
        }

        let matches = others.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            if URL(fileURLWithPath: own).lastPathComponent.caseInsensitiveCompare(trimmed) == .orderedSame {
                throw ProjectRefError.own(trimmed)
            }
            throw ProjectRefError.unknown(trimmed, known: knownNames)
        default:
            throw ProjectRefError.ambiguous(trimmed, paths: matches.map(\.path).sorted())
        }
    }
}
