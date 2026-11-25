import Foundation

/// What one Claude session's status line says about that session itself, apart from the account's
/// rate limits (`ClaudeRateLimits`): the model it runs now, which a `/model` switch changes.
public struct ClaudeSessionStatus: Equatable, Sendable {
    /// The model's id, such as "claude-opus-5-5": the same form as a session's launch model.
    public let modelId: String?
    /// When the session's prompt cache goes cold, as the report says.
    public let cacheExpiresAt: Date?
    /// How much of the context window the conversation fills, 0–100, as the report says.
    public let contextPercent: Int?

    public init(modelId: String?, cacheExpiresAt: Date? = nil, contextPercent: Int? = nil) {
        self.modelId = modelId
        self.cacheExpiresAt = cacheExpiresAt
        self.contextPercent = contextPercent
    }

    private struct ModelPart: Decodable {
        struct Model: Decodable {
            let id: String?
        }
        let model: Model?
    }

    private struct CachePart: Decodable {
        struct PromptCache: Decodable {
            /// Epoch seconds.
            let expires_at: Double?
        }
        let prompt_cache: PromptCache?
    }

    private struct ContextPart: Decodable {
        struct ContextWindow: Decodable {
            let used_percentage: Double?
        }
        let context_window: ContextWindow?
    }

    /// The model the report names; nil when it names none. Throws when the report is not JSON or
    /// its `model` is not the shape Claude sends. Read apart from the cache, so a malformed cache
    /// field never costs the session its model.
    public static func modelId(in body: Data) throws -> String? {
        try JSONDecoder().decode(ModelPart.self, from: body).model?.id
    }

    /// How much of the context window the report says the conversation fills
    /// (`context_window.used_percentage`); nil when it says nothing. Throws when the report is not
    /// JSON or its `context_window` is not the shape Claude sends.
    public static func contextPercent(in body: Data) throws -> Int? {
        try JSONDecoder().decode(ContextPart.self, from: body).context_window?.used_percentage
            .map { Int($0.rounded()) }
    }

    /// When the report says the prompt cache goes cold; nil when it says nothing. Throws when the
    /// report is not JSON or its `prompt_cache` is not the shape Claude sends.
    public static func cacheExpiry(in body: Data) throws -> Date? {
        try JSONDecoder().decode(CachePart.self, from: body).prompt_cache?.expires_at
            .map(Date.init(timeIntervalSince1970:))
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

    /// Keeps the report's status for the session. A part of it that cannot be read is logged, and
    /// the other parts are still taken: a model that cannot be read keeps the last one; a cache time
    /// that cannot be read is dropped, since a time kept past its moment would read as cold; so is a
    /// context use, which an old figure would misstate.
    public func accept(sessionId: String, body: Data) {
        let model = Result { try ClaudeSessionStatus.modelId(in: body) }
        let cache = Result { try ClaudeSessionStatus.cacheExpiry(in: body) }
        let context = Result { try ClaudeSessionStatus.contextPercent(in: body) }
        // Described the same way every time, so the same failure compares equal (`StatusLineFile.describe`).
        let parts: [(String, Error?)] = [
            ("its model", model.failure), ("its prompt cache", cache.failure), ("its context use", context.failure)
        ]
        let problems = parts.compactMap { part, error in
            error.map { "\(part) — \(StatusLineFile.describe($0))" }
        }
        let failure = problems.isEmpty
            ? nil : "session \(sessionId)'s status line could not be read for " + problems.joined(separator: "; ")
        lock.lock()
        // A report none of whose parts reads (not JSON at all) changes nothing.
        if problems.count < parts.count {
            let last = statuses[sessionId]
            statuses[sessionId] = ClaudeSessionStatus(
                modelId: model.value ?? last?.modelId,
                cacheExpiresAt: cache.value ?? nil,
                contextPercent: context.value ?? nil)
        }
        let isNew = failure != nil && lastFailure[sessionId] != failure
        lastFailure[sessionId] = failure
        lock.unlock()
        if isNew, let failure { log(failure) }
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

private extension Result {
    /// The success, or nil for a failure.
    var value: Success? {
        if case .success(let value) = self { return value }
        return nil
    }

    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
