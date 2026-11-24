import Foundation

/// What one Claude session's status line says about that session itself, apart from the account's
/// rate limits (`ClaudeRateLimits`): the model it runs now, which a `/model` switch changes.
public struct ClaudeSessionStatus: Equatable, Sendable {
    /// The model's id, such as "claude-opus-5-5": the same form as a session's launch model.
    public let modelId: String?
    /// When the session's prompt cache goes cold, as the report says.
    public let cacheExpiresAt: Date?

    public init(modelId: String?, cacheExpiresAt: Date? = nil) {
        self.modelId = modelId
        self.cacheExpiresAt = cacheExpiresAt
    }

    private struct Report: Decodable {
        struct Model: Decodable {
            let id: String?
        }
        struct PromptCache: Decodable {
            /// Epoch seconds.
            let expires_at: Double?
        }
        let model: Model?
        let prompt_cache: PromptCache?
    }

    /// Throws when the report is not JSON; a field it lacks is nil.
    public static func decode(_ body: Data) throws -> ClaudeSessionStatus {
        let report = try JSONDecoder().decode(Report.self, from: body)
        return ClaudeSessionStatus(
            modelId: report.model?.id,
            cacheExpiresAt: report.prompt_cache?.expires_at.map(Date.init(timeIntervalSince1970:)))
    }
}

/// Each live Claude session's latest `ClaudeSessionStatus`, keyed by linkC session id. The status-line
/// feed writes it from its own queue while the coordinator reads it on the main actor, so a lock
/// guards it.
public final class ClaudeSessionStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: ClaudeSessionStatus] = [:]
    /// Each session's last failure said, so a status line that refreshes several times a turn says
    /// the same failure once. Cleared by a good report, so a failure that comes back is news again.
    private var lastFailure: [String: String] = [:]
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { NSLog("[linkC] %@", $0) }) {
        self.log = log
    }

    /// Keeps the report's status for the session. A report that is not JSON keeps the last one and is logged.
    public func accept(sessionId: String, body: Data) {
        let status: ClaudeSessionStatus
        do {
            status = try ClaudeSessionStatus.decode(body)
        } catch {
            // Described the same way every time, so the same failure compares equal (`StatusLineFile.describe`).
            let failure = "session \(sessionId)'s status line could not be read for its model — \(StatusLineFile.describe(error))"
            lock.lock()
            let isNew = lastFailure[sessionId] != failure
            lastFailure[sessionId] = failure
            lock.unlock()
            if isNew { log(failure) }
            return
        }
        lock.lock()
        statuses[sessionId] = status
        lastFailure[sessionId] = nil
        lock.unlock()
    }

    public func status(for sessionId: String) -> ClaudeSessionStatus? {
        lock.lock()
        defer { lock.unlock() }
        return statuses[sessionId]
    }

    /// Drops an ended session's status.
    public func forget(sessionId: String) {
        lock.lock()
        statuses[sessionId] = nil
        lastFailure[sessionId] = nil
        lock.unlock()
    }
}
