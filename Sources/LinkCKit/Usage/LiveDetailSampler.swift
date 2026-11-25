import Foundation

/// Each live session's first-hand detail, read off the main actor by its agent's `SessionLiveReader`
/// and kept for the next `projects.json` publish. The sweep asks for a read; one runs at a time,
/// and the publisher takes whatever the last one found.
///
/// A read blocks: on sqlite3, which may take seconds, and on files. It runs on a serial queue of
/// the sampler's own, never on a thread of the Swift concurrency pool, which it would tie up (as
/// `LiveProcessRunner.runCapturing` keeps its waits off that pool, D19a).
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

    private static let readQueueKey = DispatchSpecificKey<Void>()

    /// Whether the caller runs on a sampler's read queue.
    static var isOnReadQueue: Bool { DispatchQueue.getSpecific(key: readQueueKey) != nil }

    /// How long a listing of a process tree's open files stands: a record a session's process opens
    /// later, a new chat or rollout, is found within this.
    static let openFilesAge: TimeInterval = 10
    /// The same failure is said again only once this has passed, even when reads work in between:
    /// one that comes and goes would otherwise be said on every return.
    static let repeatAfter: TimeInterval = 10 * 60

    private let readers: [AgentKind: any SessionLiveReader]
    private let queue: DispatchQueue
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let listOpenFiles: @Sendable (pid_t) -> [String]

    // Under `lock`.
    private let lock = NSLock()
    private var details: [String: SessionLiveDetail] = [:]
    /// Each session's last failure said, and when.
    private var lastFailure: [String: (said: String, at: Date)] = [:]
    private var inFlight: Task<Void, Never>?

    // On the queue alone.
    /// Each session's last good read, with what it read: while its target is the same and the
    /// stamps of its reader's files have not moved, it stands.
    private var lastRead: [String: LastRead] = [:]
    /// Each session's process tree's open files, and when they were listed.
    private var openFilesSeen: [String: (pid: pid_t, at: Date, files: [String])] = [:]

    private struct LastRead {
        let target: LiveSessionTarget
        let sources: [String]
        let stamps: [FileStamp?]
        let detail: SessionLiveDetail
    }

    /// `openFiles` lists the files a process tree holds open; `now` is the clock.
    public init(readers: [AgentKind: any SessionLiveReader],
                log: @escaping @Sendable (String) -> Void = { NSLog("[linkC] %@", $0) },
                now: @escaping @Sendable () -> Date = { Date() },
                openFiles: @escaping @Sendable (pid_t) -> [String] = { ProcessSnooper.openFilePaths(inProcessTreeOf: $0) }) {
        self.readers = readers
        self.now = now
        self.listOpenFiles = openFiles
        self.queue = DispatchQueue(label: "linkc.live-detail", qos: .utility)
        self.queue.setSpecific(key: Self.readQueueKey, value: ())
        self.log = log
    }

    /// The last read's detail for the session; nil before one landed, for an agent with no reader,
    /// and after a read that failed outright. After a partial read, what it did read.
    public func detail(for sessionId: String) -> SessionLiveDetail? {
        lock.lock()
        defer { lock.unlock() }
        return details[sessionId]
    }

    /// Reads every session whose agent has a reader, on the sampler's queue, and forgets the rest.
    /// Does nothing while a read still runs. The task, which only waits for the queue, is returned
    /// so a test can wait for it.
    @discardableResult
    public func refresh(_ sessions: [Session]) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight == nil else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.queue.async {
                    self.pass(sessions)
                    continuation.resume()
                }
            }
        }
        inFlight = task
        return task
    }

    /// One read of every session, on the queue.
    private func pass(_ sessions: [Session]) {
        var read: [String: Result<SessionLiveDetail, Error>] = [:]
        for session in sessions {
            guard let reader = readers[session.agent] else { continue }
            let target = LiveSessionTarget(
                sessionId: session.id, agent: session.agent, cwd: session.cwd, agentSessionId: session.agentSessionId,
                openFiles: reader.readsOpenFiles ? openFiles(of: session) : [])
            read[session.id] = Result { try detail(of: target, by: reader) }
        }
        let live = Set(sessions.map(\.id))
        lastRead = lastRead.filter { live.contains($0.key) }
        openFilesSeen = openFilesSeen.filter { live.contains($0.key) }
        land(read, live: live)
    }

    /// The files the session's process tree holds open, as last listed while that listing is younger
    /// than `openFilesAge` and of the same process.
    private func openFiles(of session: Session) -> [String] {
        guard let pid = session.pid else { return [] }
        let now = now()
        if let seen = openFilesSeen[session.id], seen.pid == pid {
            let age = now.timeIntervalSince(seen.at)
            if age >= 0, age < Self.openFilesAge { return seen.files }
        }
        let files = listOpenFiles(pid)
        openFilesSeen[session.id] = (pid, now, files)
        return files
    }

    /// The last read's detail while nothing it read has changed, else a new read's.
    private func detail(of target: LiveSessionTarget, by reader: any SessionLiveReader) throws -> SessionLiveDetail {
        do {
            let sources = try reader.sources(of: target)
            // Stamped before the read: a write that lands after it moves a stamp for the next pass.
            let stamps = try sources.map(FileStamp.of)
            if !sources.isEmpty, let last = lastRead[target.sessionId],
               last.target == target, last.sources == sources, last.stamps == stamps {
                return last.detail
            }
            let detail = try reader.read(target)
            lastRead[target.sessionId] = sources.isEmpty ? nil : LastRead(target: target, sources: sources, stamps: stamps, detail: detail)
            return detail
        } catch {
            lastRead[target.sessionId] = nil
            throw error
        }
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
            case .failure(let error):
                // An old figure would misstate the session now: only what this read found stands.
                let partial = error as? PartialLiveRead
                details[id] = partial?.detail
                let failure = partial.map { "session \(id)'s own records could not all be read — \($0)" }
                    ?? "session \(id)'s own records could not be read — \(error)"
                let now = now()
                if let last = lastFailure[id], last.said == failure, now.timeIntervalSince(last.at) < Self.repeatAfter { continue }
                said.append(failure)
                lastFailure[id] = (failure, now)
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
