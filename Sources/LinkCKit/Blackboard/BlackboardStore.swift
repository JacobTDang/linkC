import Foundation
import Darwin

/// Thread-safe and process-safe storage manager for `.linkc/blackboard.json`.
/// Employs Darwin `flock(fd, LOCK_EX)` advisory locking and atomic temporary file replacement.
public final class BlackboardStore: Sendable {
    public let workspaceRoot: String

    public init(workspaceRoot: String) {
        self.workspaceRoot = (workspaceRoot as NSString).standardizingPath
    }

    private var linkcDirectory: URL {
        URL(fileURLWithPath: workspaceRoot, isDirectory: true).appendingPathComponent(".linkc", isDirectory: true)
    }

    private var blackboardURL: URL {
        linkcDirectory.appendingPathComponent("blackboard.json")
    }

    private var lockURL: URL {
        linkcDirectory.appendingPathComponent(".blackboard.lock")
    }

    private var decoder: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: linkcDirectory.path) {
            try fm.createDirectory(at: linkcDirectory, withIntermediateDirectories: true)
        }
    }

    /// Acquires an exclusive file lock, executes the block, and releases the lock.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectoryExists()
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw LinkCError.server("Failed to open blackboard lock file at \(lockURL.path)")
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        guard flock(fd, LOCK_EX) == 0 else {
            throw LinkCError.server("Failed to acquire flock on \(lockURL.path)")
        }

        return try body()
    }

    /// Loads the blackboard from disk without locking. Internal use inside locked regions or read-only checks.
    private func loadUnlocked() throws -> Blackboard {
        let fm = FileManager.default
        guard fm.fileExists(atPath: blackboardURL.path) else {
            return Blackboard(projectPath: workspaceRoot)
        }
        let data = try Data(contentsOf: blackboardURL)
        do {
            return try decoder.decode(Blackboard.self, from: data)
        } catch {
            // Corrupt file fallback
            return Blackboard(projectPath: workspaceRoot)
        }
    }

    /// Saves the blackboard atomically via a temporary file without locking. Internal use inside locked regions.
    private func saveUnlocked(_ board: Blackboard) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(board)
        let tmpURL = linkcDirectory.appendingPathComponent("blackboard.tmp.\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)
        _ = rename(tmpURL.path, blackboardURL.path)
    }

    /// Public load acquiring lock.
    public func load() throws -> Blackboard {
        try withFileLock {
            try loadUnlocked()
        }
    }

    /// Public raw save for testing or explicit writes.
    public func saveRaw(_ board: Blackboard) throws {
        try withFileLock {
            try saveUnlocked(board)
        }
    }

    /// Broadcasts an agent's current intent, updates heartbeats, and checks for conflicting files.
    public func broadcastIntent(
        agentKind: AgentKind,
        pid: pid_t,
        goal: String,
        files: [String],
        status: String = "working"
    ) throws -> [CollisionWarning] {
        try withFileLock {
            var board = try loadUnlocked()
            pruneStaleUnlocked(&board, olderThan: 900) // 15 min

            let normalizedClaimed = files.map { ($0 as NSString).standardizingPath }

            // Check conflicts against other active agents
            var warnings: [CollisionWarning] = []
            for other in board.activeAgents where other.pid != pid {
                let overlap = other.claimedFiles.filter { normalizedClaimed.contains($0) }
                if !overlap.isEmpty {
                    warnings.append(
                        CollisionWarning(
                            conflictingAgent: other.agentKind,
                            pid: other.pid,
                            conflictingFiles: overlap,
                            goal: other.goal
                        )
                    )
                }
            }

            // Update or insert this agent's record
            let agentId = "agent-\(agentKind.rawValue)-\(pid)"
            if let idx = board.activeAgents.firstIndex(where: { $0.pid == pid }) {
                board.activeAgents[idx].goal = goal
                board.activeAgents[idx].claimedFiles = normalizedClaimed
                board.activeAgents[idx].lastHeartbeat = Date()
                board.activeAgents[idx].status = status
            } else {
                let record = AgentRecord(
                    agentId: agentId,
                    agentKind: agentKind,
                    pid: pid,
                    goal: goal,
                    claimedFiles: normalizedClaimed,
                    lastHeartbeat: Date(),
                    status: status
                )
                board.activeAgents.append(record)
            }

            board.updatedAt = Date()
            board.recentEvents.insert(
                BlackboardEvent(
                    timestamp: Date(),
                    agentKind: agentKind,
                    action: "broadcast_intent",
                    details: "\(goal) [files: \(files.count)]"
                ),
                at: 0
            )
            if board.recentEvents.count > 50 {
                board.recentEvents = Array(board.recentEvents.prefix(50))
            }

            try saveUnlocked(board)
            return warnings
        }
    }

    /// Checks if files conflict with any other currently active agent.
    public func checkConflicts(files: [String], excludingPid: pid_t? = nil) throws -> [CollisionWarning] {
        try withFileLock {
            var board = try loadUnlocked()
            pruneStaleUnlocked(&board, olderThan: 900)

            let normalized = files.map { ($0 as NSString).standardizingPath }
            var warnings: [CollisionWarning] = []

            for other in board.activeAgents {
                if let excludingPid, other.pid == excludingPid { continue }
                let overlap = other.claimedFiles.filter { normalized.contains($0) }
                if !overlap.isEmpty {
                    warnings.append(
                        CollisionWarning(
                            conflictingAgent: other.agentKind,
                            pid: other.pid,
                            conflictingFiles: overlap,
                            goal: other.goal
                        )
                    )
                }
            }
            return warnings
        }
    }

    /// Posts a shared note to the blackboard.
    public func postNote(
        authorAgent: AgentKind,
        title: String,
        content: String,
        tags: [String] = []
    ) throws -> SharedNote {
        try withFileLock {
            var board = try loadUnlocked()
            let note = SharedNote(
                authorAgent: authorAgent,
                title: title,
                content: content,
                createdAt: Date(),
                tags: tags
            )
            board.sharedNotes.insert(note, at: 0)
            if board.sharedNotes.count > 100 {
                board.sharedNotes = Array(board.sharedNotes.prefix(100))
            }
            board.updatedAt = Date()
            board.recentEvents.insert(
                BlackboardEvent(
                    timestamp: Date(),
                    agentKind: authorAgent,
                    action: "post_note",
                    details: title
                ),
                at: 0
            )
            try saveUnlocked(board)
            return note
        }
    }

    /// Returns the complete project context, pruning stale agents first.
    public func getProjectContext() throws -> Blackboard {
        try withFileLock {
            var board = try loadUnlocked()
            let beforeCount = board.activeAgents.count
            pruneStaleUnlocked(&board, olderThan: 900)
            if board.activeAgents.count != beforeCount {
                try saveUnlocked(board)
            }
            return board
        }
    }

    /// Prunes agents whose lastHeartbeat exceeds the threshold.
    public func pruneStale(olderThan: TimeInterval = 900) throws {
        try withFileLock {
            var board = try loadUnlocked()
            pruneStaleUnlocked(&board, olderThan: olderThan)
            try saveUnlocked(board)
        }
    }

    private func pruneStaleUnlocked(_ board: inout Blackboard, olderThan: TimeInterval) {
        let now = Date()
        board.activeAgents.removeAll { now.timeIntervalSince($0.lastHeartbeat) > olderThan }
    }
}
