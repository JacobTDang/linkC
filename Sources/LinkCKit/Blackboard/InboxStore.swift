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
    /// Automatically prunes delivered messages older than 24 hours and caps total message history
    /// to the most recent 100 entries so inbox.json does not grow unboundedly.
    private func saveUnlocked(_ inbox: Inbox) throws {
        var prunedInbox = inbox
        let now = Date()
        let cutoff = now.addingTimeInterval(-24 * 3600)
        prunedInbox.messages.removeAll { msg in
            if msg.status == .delivered, let deliveredAt = msg.deliveredAt {
                return deliveredAt < cutoff
            }
            return false
        }
        if prunedInbox.messages.count > 100 {
            prunedInbox.messages = Array(prunedInbox.messages.suffix(100))
        }
        prunedInbox.tasks.removeAll { task in
            guard !task.state.isOpen else { return false }
            return (task.finishedAt ?? task.createdAt) < cutoff
        }
        prunedInbox.version = Inbox.currentVersion

        try ensureDirectoryExists()
        let data = try encoder.encode(prunedInbox)
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

    /// Enqueues a short, kind-tagged message. The store composes the frame; callers pass the bare body.
    /// Rejects framed bodies (loop guard), `.task` kind, completions without a task id, and 24 h duplicates.
    public func enqueue(
        from: AgentKind,
        to: AgentKind,
        kind: MessageKind,
        taskId: String? = nil,
        body: String,
        timeout: TimeInterval = 5.0
    ) throws -> PendingMessage {
        guard kind != .task else { throw InboxError.kindNotAllowed(.task) }
        guard !LinkCFrame.beginsWithMarker(body) else { throw InboxError.framedBody }

        let prompt: String
        switch kind {
        case .completion:
            guard let taskId else { throw InboxError.missingTaskId }
            prompt = "\(LinkCFrame.taskPrefix) \(taskId.prefix(8))] \(body)"
        case .notice:
            prompt = "\(LinkCFrame.noticePrefix) \(body)"
        case .peerNote:
            prompt = "\(LinkCFrame.peerNotePrefix) \(from.displayName)]: \(body)"
        case .command:
            prompt = body
        case .task:
            throw InboxError.kindNotAllowed(.task)
        }

        let hash = LinkCFrame.contentHash(from: from, to: to, kind: kind, prompt: prompt)
        return try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            let dedupeCutoff = Date().addingTimeInterval(-24 * 3600)
            if let existing = inbox.messages.first(where: {
                $0.contentHash == hash && $0.fromAgent == from && $0.toAgent == to && $0.createdAt >= dedupeCutoff
            }) {
                return existing
            }
            let message = PendingMessage(
                fromAgent: from,
                toAgent: to,
                prompt: prompt,
                claimedFiles: [],
                status: .queued,
                kind: kind,
                taskId: taskId,
                contentHash: hash
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
    public func markMessageDelivered(id: String, timeout: TimeInterval = 5.0) throws {
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

    // MARK: - Task lifecycle

    /// Creates a task with an exclusive lease on `files`. A task with a verification starts in
    /// `gating`; linkC delivers it only after confirming its tests fail at base. Refuses when
    /// another assignee holds an open lease on any of the files unless `force`. Idempotent for
    /// an identical assignee, prompt, and base.
    public func createTask(
        from: AgentKind,
        to: AgentKind,
        prompt: String,
        files: [String],
        hop: Int = 0,
        force: Bool = false,
        verification: Verification? = nil,
        timeout: TimeInterval = 5.0
    ) throws -> TaskRecord {
        guard hop <= 2 else { throw InboxError.hopLimit(hop) }
        guard !LinkCFrame.beginsWithMarker(prompt) else { throw InboxError.framedBody }
        if let reason = verification?.validationError { throw InboxError.invalidVerification(reason) }

        return try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            let normalized = files.map { ($0 as NSString).standardizingPath }

            if let existing = inbox.tasks.first(where: {
                $0.state.isOpen && $0.toAgent == to && $0.prompt == prompt
                    && $0.verification?.baseSha == verification?.baseSha
            }) {
                return existing
            }

            if !force && !normalized.isEmpty {
                let holders = inbox.tasks.filter { other in
                    other.state.isOpen && other.toAgent != to && !Set(other.files).isDisjoint(with: normalized)
                }
                if !holders.isEmpty { throw InboxError.leaseConflict(holders: holders) }
            }

            let task = TaskRecord(
                fromAgent: from, toAgent: to, prompt: prompt, files: normalized,
                state: verification == nil ? .queued : .gating, hop: hop, verification: verification
            )
            inbox.tasks.append(task)
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
            return task
        }
    }

    public func task(id: String, timeout: TimeInterval = 5.0) throws -> TaskRecord? {
        try withFileLock(timeout: timeout) {
            try loadUnlocked().tasks.first { $0.id == id }
        }
    }

    /// Open tasks, oldest first. `agent == nil` returns all; otherwise tasks assigned to `agent`.
    public func openTasks(for agent: AgentKind? = nil, timeout: TimeInterval = 5.0) throws -> [TaskRecord] {
        try withFileLock(timeout: timeout) {
            try loadUnlocked().tasks
                .filter { $0.state.isOpen && (agent == nil || $0.toAgent == agent) }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// Open tasks whose lease overlaps `files`, optionally ignoring a given assignee.
    public func leaseHolders(for files: [String], excludingAssignee: AgentKind? = nil, timeout: TimeInterval = 5.0) throws -> [TaskRecord] {
        let normalized = Set(files.map { ($0 as NSString).standardizingPath })
        return try withFileLock(timeout: timeout) {
            try loadUnlocked().tasks.filter { task in
                task.state.isOpen
                    && (excludingAssignee == nil || task.toAgent != excludingAssignee)
                    && !Set(task.files).isDisjoint(with: normalized)
            }
        }
    }

    public func markTaskDelivered(taskId: String, sessionId: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .delivered, timeout: timeout) { task in
            task.assigneeSessionId = sessionId
            task.deliveredAt = Date()
        }
    }

    public func markTaskStarted(taskId: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .started, timeout: timeout) { task in
            let now = Date()
            task.startedAt = now
            task.leaseExpiresAt = now.addingTimeInterval(TaskRecord.leaseDuration)
        }
    }

    public func completeTask(taskId: String, report: TaskReport, timeout: TimeInterval = 5.0) throws {
        guard !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InboxError.emptySummary
        }
        let target: TaskState = report.status == "failed" ? .failed : .done
        try transition(taskId: taskId, to: target, timeout: timeout) { task in
            task.report = report
            task.finishedAt = Date()
        }
    }

    public func cancelTask(taskId: String, reason: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .cancelled, timeout: timeout) { task in
            task.cancelReason = reason
            task.finishedAt = Date()
        }
    }

    /// The worker's report: `delivered | started → reported`. Enqueues nothing — the relay
    /// settles the task and tells the delegator. Extends the lease so a late report cannot
    /// expire while it waits for its verdict.
    public func reportTask(taskId: String, report: TaskReport, timeout: TimeInterval = 5.0) throws {
        let summary = report.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw InboxError.emptySummary }
        guard summary.count <= TaskReport.summaryLimit else { throw InboxError.summaryTooLong(count: summary.count) }
        guard report.status == "done" || report.status == "failed" else { throw InboxError.invalidReportStatus(report.status) }
        try transition(taskId: taskId, timeout: timeout, target: { task in
            if task.verification != nil && report.status == "done" && report.sha == nil { throw InboxError.shaRequired }
            return .reported
        }, mutate: { task in
            task.report = report
            task.leaseExpiresAt = Date().addingTimeInterval(TaskRecord.leaseDuration)
        })
    }

    /// Records the gate: `gating → queued` when the tests failed at base, else `→ cancelled`.
    public func resolveGate(taskId: String, verdict: Verdict, timeout: TimeInterval = 5.0) throws {
        let next: TaskState = verdict.passed ? .queued : .cancelled
        try transition(taskId: taskId, timeout: timeout, target: { task in
            guard task.state == .gating else { throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: next) }
            return next
        }, mutate: { task in
            task.gate = verdict
            if !verdict.passed {
                task.cancelReason = verdict.reason
                task.finishedAt = Date()
            }
        })
    }

    /// linkC's verdict on a verified task: `reported → done | failed`.
    public func adjudicate(taskId: String, verdict: Verdict, timeout: TimeInterval = 5.0) throws {
        let next: TaskState = verdict.passed ? .done : .failed
        try transition(taskId: taskId, timeout: timeout, target: { task in
            guard task.state == .reported else { throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: next) }
            guard task.verification != nil else { throw InboxError.notVerified(taskId) }
            return next
        }, mutate: { task in
            task.verdict = verdict
            task.finishedAt = Date()
        })
    }

    /// Settles an unverified task on the worker's word: `reported → done | failed`.
    public func acceptUnverified(taskId: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, timeout: timeout, target: { task in
            let next: TaskState = task.report?.status == "done" ? .done : .failed
            guard task.state == .reported else { throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: next) }
            guard task.verification == nil else { throw InboxError.verificationPresent(taskId) }
            return next
        }, mutate: { task in
            task.finishedAt = Date()
        })
    }

    /// linkC failing a task whose assignee can no longer report (its session ended).
    public func failTask(taskId: String, reason: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, timeout: timeout, target: { task in
            guard task.state == .delivered || task.state == .started else {
                throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: .failed)
            }
            return .failed
        }, mutate: { task in
            task.cancelReason = reason
            task.finishedAt = Date()
        })
    }

    public func expireTask(taskId: String, reason: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .expired, timeout: timeout) { task in
            task.cancelReason = reason
            task.finishedAt = Date()
        }
    }

    public func markUnreportedTurnEndNotified(taskId: String, timeout: TimeInterval = 5.0) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            guard let idx = inbox.tasks.firstIndex(where: { $0.id == taskId }) else {
                throw InboxError.taskNotFound(taskId)
            }
            inbox.tasks[idx].unreportedTurnEndNotified = true
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
        }
    }

    private func transition(
        taskId: String,
        to next: TaskState,
        timeout: TimeInterval,
        mutate: (inout TaskRecord) -> Void
    ) throws {
        try transition(taskId: taskId, timeout: timeout, target: { _ in next }, mutate: mutate)
    }

    /// `target` runs under the lock with the current record; it validates and names the next state.
    private func transition(
        taskId: String,
        timeout: TimeInterval,
        target: (TaskRecord) throws -> TaskState,
        mutate: (inout TaskRecord) -> Void
    ) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            guard let idx = inbox.tasks.firstIndex(where: { $0.id == taskId }) else {
                throw InboxError.taskNotFound(taskId)
            }
            let current = inbox.tasks[idx].state
            let next = try target(inbox.tasks[idx])
            guard current.canTransition(to: next) else {
                throw InboxError.illegalTransition(taskId: taskId, from: current, to: next)
            }
            inbox.tasks[idx].state = next
            mutate(&inbox.tasks[idx])
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
        }
    }
}
