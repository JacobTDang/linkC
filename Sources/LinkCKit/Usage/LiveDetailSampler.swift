import Foundation

/// Each live session's first-hand detail, read off the main actor by its agent's `SessionLiveReader`
/// and kept for the next `projects.json` publish. The sweep asks for a read; one runs at a time,
/// and the publisher takes whatever the last one found.
public final class LiveDetailSampler: @unchecked Sendable {
    /// A live session, as the main actor sees it when it asks for a read.
    public struct Session: Equatable, Sendable {
        public let id: String
        public let agent: AgentKind
        public let cwd: String
        public let agentSessionId: String?
        /// The terminal's process, whose tree's open files are read; nil when it has none yet.
        public let pid: pid_t?

        public init(id: String, agent: AgentKind, cwd: String, agentSessionId: String?, pid: pid_t?) {
            self.id = id
            self.agent = agent
            self.cwd = cwd
            self.agentSessionId = agentSessionId
            self.pid = pid
        }
    }

    private let readers: [AgentKind: any SessionLiveReader]
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var details: [String: SessionLiveDetail] = [:]
    /// Each session's last failure said, so a read that fails every pass says it once.
    private var lastFailure: [String: String] = [:]
    private var inFlight: Task<Void, Never>?

    public init(readers: [AgentKind: any SessionLiveReader],
                log: @escaping @Sendable (String) -> Void = { NSLog("[linkC] %@", $0) }) {
        self.readers = readers
        self.log = log
    }

    /// The last read's detail for the session; nil before one landed, for an agent with no reader,
    /// and after a read that failed.
    public func detail(for sessionId: String) -> SessionLiveDetail? {
        lock.lock()
        defer { lock.unlock() }
        return details[sessionId]
    }

    /// Reads every session whose agent has a reader, off the main actor, and forgets the rest. Does
    /// nothing while a read still runs. The task is returned so a test can wait for it.
    @discardableResult
    public func refresh(_ sessions: [Session]) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight == nil else { return nil }
        let readers = readers
        let task = Task.detached(priority: .utility) { [weak self] in
            var read: [String: Result<SessionLiveDetail, Error>] = [:]
            for session in sessions {
                guard let reader = readers[session.agent] else { continue }
                let target = LiveSessionTarget(
                    sessionId: session.id, agent: session.agent, cwd: session.cwd, agentSessionId: session.agentSessionId,
                    openFiles: session.pid.map { ProcessSnooper.openFilePaths(inProcessTreeOf: $0) } ?? [])
                read[session.id] = Result { try reader.read(target) }
            }
            self?.land(read, live: Set(sessions.map(\.id)))
        }
        inFlight = task
        return task
    }

    private func land(_ read: [String: Result<SessionLiveDetail, Error>], live: Set<String>) {
        var said: [String] = []
        lock.lock()
        details = details.filter { live.contains($0.key) }
        lastFailure = lastFailure.filter { live.contains($0.key) }
        for (id, result) in read {
            switch result {
            case .success(let detail):
                details[id] = detail
                lastFailure[id] = nil
            case .failure(let error):
                // An old figure would misstate the session now: it goes.
                details[id] = nil
                let failure = "session \(id)'s own records could not be read — \(error)"
                if lastFailure[id] != failure { said.append(failure) }
                lastFailure[id] = failure
            }
        }
        inFlight = nil
        lock.unlock()
        said.forEach(log)
    }

    /// Waits for the read that runs now, if one does.
    public func settle() async {
        let task = lock.withLock { inFlight }
        await task?.value
    }
}
