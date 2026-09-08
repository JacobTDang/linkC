import Foundation
import Darwin

/// Thread-safe and process-safe storage manager for `<workspaceRoot>/.linkc/inbox.json`.
/// Employs Darwin `flock(fd, LOCK_EX)` advisory locking and atomic temporary file replacement,
/// matching the locking and persistence architecture of `BlackboardStore`.
public final class InboxStore: Sendable {
    public let workspaceRoot: String

    public init(workspaceRoot: String) {
        self.workspaceRoot = (workspaceRoot as NSString).standardizingPath
    }

    private var linkcDirectory: URL {
        URL(fileURLWithPath: workspaceRoot, isDirectory: true).appendingPathComponent(".linkc", isDirectory: true)
    }

    private var inboxURL: URL {
        linkcDirectory.appendingPathComponent("inbox.json")
    }

    private var lockURL: URL {
        linkcDirectory.appendingPathComponent(".inbox.lock")
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
    /// If `timeout > 0`, polls with non-blocking `flock(..., LOCK_EX | LOCK_NB)` until acquired or timed out.
    /// If `timeout <= 0`, blocks indefinitely.
    func withFileLock<T>(timeout: TimeInterval = 5.0, _ body: () throws -> T) throws -> T {
        try ensureDirectoryExists()
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw LinkCError.server("Failed to open inbox lock file at \(lockURL.path)")
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        if timeout > 0 {
            let start = Date()
            var acquired = false
            while !acquired {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    acquired = true
                    break
                }
                let err = errno
                if err == EWOULDBLOCK || err == EAGAIN {
                    if Date().timeIntervalSince(start) >= timeout {
                        throw LinkCError.server("Timed out acquiring inbox lock after \(timeout)s at \(lockURL.path)")
                    }
                    usleep(5_000) // 5ms sleep between attempts
                } else {
                    throw LinkCError.server("Failed to acquire flock on \(lockURL.path): errno \(err)")
                }
            }
        } else {
            guard flock(fd, LOCK_EX) == 0 else {
                throw LinkCError.server("Failed to acquire flock on \(lockURL.path): errno \(errno)")
            }
        }

        return try body()
    }

    /// Loads the inbox from disk without locking. Internal use inside locked regions.
    private func loadUnlocked() throws -> Inbox {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inboxURL.path) else {
            return Inbox(workspacePath: workspaceRoot)
        }
        let data = try Data(contentsOf: inboxURL)
        do {
            return try decoder.decode(Inbox.self, from: data)
        } catch {
            // Corrupt file fallback
            return Inbox(workspacePath: workspaceRoot)
        }
    }

    /// Saves the inbox atomically via a temporary file without locking. Internal use inside locked regions.
    private func saveUnlocked(_ inbox: Inbox) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(inbox)
        let tmpURL = linkcDirectory.appendingPathComponent("inbox.tmp.\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)
        _ = rename(tmpURL.path, inboxURL.path)
    }

    /// Public load acquiring lock.
    public func load(timeout: TimeInterval = 5.0) throws -> Inbox {
        try withFileLock(timeout: timeout) {
            try loadUnlocked()
        }
    }

    /// Public raw save for testing or explicit writes.
    public func saveRaw(_ inbox: Inbox, timeout: TimeInterval = 5.0) throws {
        try withFileLock(timeout: timeout) {
            try saveUnlocked(inbox)
        }
    }

    /// Appends a new pending message to the queue with `.queued` status.
    public func enqueue(
        from: AgentKind,
        to: AgentKind,
        prompt: String,
        files: [String] = [],
        rerouteCount: Int = 0,
        timeout: TimeInterval = 5.0
    ) throws -> PendingMessage {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            let normalizedFiles = files.map { ($0 as NSString).standardizingPath }
            let message = PendingMessage(
                id: UUID().uuidString,
                fromAgent: from,
                toAgent: to,
                prompt: prompt,
                claimedFiles: normalizedFiles,
                status: .queued,
                rerouteCount: rerouteCount,
                createdAt: Date(),
                deliveredAt: nil
            )
            inbox.messages.append(message)
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
            return message
        }
    }

    /// Returns pending messages in FIFO order (those with status `.queued`).
    public func fetchPending(timeout: TimeInterval = 5.0) throws -> [PendingMessage] {
        try withFileLock(timeout: timeout) {
            let inbox = try loadUnlocked()
            return inbox.messages.filter { $0.status == .queued }
        }
    }

    /// Marks a message as delivered and stamps `deliveredAt`.
    public func markDelivered(id: String, timeout: TimeInterval = 5.0) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            guard let index = inbox.messages.firstIndex(where: { $0.id == id }) else {
                throw LinkCError.server("Message with ID \(id) not found in inbox")
            }
            inbox.messages[index].status = .delivered
            inbox.messages[index].deliveredAt = Date()
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
        }
    }

    /// Records a rate limit or exhaustion cooldown for an agent kind.
    public func recordLimit(
        agent: AgentKind,
        reason: String,
        cooldown: TimeInterval,
        timeout: TimeInterval = 5.0
    ) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            let now = Date()
            let expiresAt = now.addingTimeInterval(cooldown)
            let status = AgentLimitStatus(
                agent: agent,
                reason: reason,
                limitedAt: now,
                cooldownExpiresAt: expiresAt
            )
            if let index = inbox.agentLimits.firstIndex(where: { $0.agent == agent }) {
                inbox.agentLimits[index] = status
            } else {
                inbox.agentLimits.append(status)
            }
            inbox.updatedAt = now
            try saveUnlocked(inbox)
        }
    }

    /// Returns the active limit status for an agent kind if cooldown has not expired; returns nil otherwise.
    public func isAgentLimited(agent: AgentKind, timeout: TimeInterval = 5.0) throws -> AgentLimitStatus? {
        try withFileLock(timeout: timeout) {
            let inbox = try loadUnlocked()
            let now = Date()
            guard let status = inbox.agentLimits.first(where: { $0.agent == agent }) else {
                return nil
            }
            if status.cooldownExpiresAt > now {
                return status
            }
            return nil
        }
    }
}
