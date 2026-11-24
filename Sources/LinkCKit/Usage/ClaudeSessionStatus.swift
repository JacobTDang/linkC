import Foundation

/// What one Claude session's status line says about that session itself, apart from the account's
/// rate limits (`ClaudeRateLimits`): the model it runs now, which a `/model` switch changes.
public struct ClaudeSessionStatus: Equatable, Sendable {
    public let modelId: String?
    /// The model as Claude names it, such as "Opus 5.5".
    public let modelName: String?

    public init(modelId: String?, modelName: String?) {
        self.modelId = modelId
        self.modelName = modelName
    }

    private struct Report: Decodable {
        struct Model: Decodable {
            let id: String?
            let display_name: String?
        }
        let model: Model?
    }

    /// Throws when the report is not JSON; a field it lacks is nil.
    ///
    /// Decoded with the plain JSON decoder: `display_name` is spelled as Claude sends it.
    public static func decode(_ body: Data) throws -> ClaudeSessionStatus {
        let report = try JSONDecoder().decode(Report.self, from: body)
        return ClaudeSessionStatus(modelId: report.model?.id, modelName: report.model?.display_name)
    }
}

/// Each live Claude session's latest `ClaudeSessionStatus`, keyed by linkC session id. The status-line
/// feed writes it from its own queue while the coordinator reads it on the main actor, so a lock
/// guards it.
public final class ClaudeSessionStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: ClaudeSessionStatus] = [:]
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
            log("session \(sessionId)'s status line could not be read for its model — \(error)")
            return
        }
        lock.lock()
        statuses[sessionId] = status
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
        lock.unlock()
    }
}
