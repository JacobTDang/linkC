import Foundation

/// A request from the `linkc` command for linkC to open an agent session. The command writes it into
/// `OpenRequestStore`'s folder, and linkC answers it with an `OpenResult` there.
public struct OpenRequest: Codable, Equatable, Sendable {
    /// Who wants the new session to carry a task: the agent the command ran under, and its linkC
    /// session when it runs in one.
    public struct TaskOrigin: Codable, Equatable, Sendable {
        public let fromAgent: AgentKind
        public let fromSessionId: String?

        public init(fromAgent: AgentKind, fromSessionId: String?) {
            self.fromAgent = fromAgent
            self.fromSessionId = fromSessionId
        }
    }

    public let id: String
    public let agent: AgentKind
    /// The folder the command ran in, canonical.
    public let folder: String
    public let prompt: String?
    public let tier: ModelTier?
    /// Set by `--task`: the session carries `prompt` as a task pinned to it.
    public let task: TaskOrigin?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, agent: AgentKind, folder: String, prompt: String?, tier: ModelTier?,
                task: TaskOrigin?, createdAt: Date = Date()) {
        self.id = id
        self.agent = agent
        self.folder = folder
        self.prompt = prompt
        self.tier = tier
        self.task = task
        self.createdAt = createdAt
    }
}

/// linkC's answer to an `OpenRequest`.
public struct OpenResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let sessionId: String?
    public let message: String

    public init(ok: Bool, sessionId: String?, message: String) {
        self.ok = ok
        self.sessionId = sessionId
        self.message = message
    }

    public static func opened(sessionId: String, message: String) -> OpenResult {
        OpenResult(ok: true, sessionId: sessionId, message: message)
    }

    public static func refused(_ message: String) -> OpenResult {
        OpenResult(ok: false, sessionId: nil, message: message)
    }
}

/// The folder the `linkc` command and linkC exchange requests and answers through: `<id>.json` is a
/// request, `<id>.result.json` its answer. Private to the user. Every file is written atomically, so a
/// reader never sees half of one.
public struct OpenRequestStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The folder in linkC's own Application Support folder.
    public static var applicationSupport: OpenRequestStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
            .appendingPathComponent("open-requests", isDirectory: true)
        return OpenRequestStore(directory: dir)
    }

    private static let resultSuffix = ".result.json"

    private func requestURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json", isDirectory: false) }
    private func resultURL(_ id: String) -> URL { directory.appendingPathComponent("\(id)\(Self.resultSuffix)", isDirectory: false) }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// Creates the folder, readable and writable by the user only.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func submit(_ request: OpenRequest) throws {
        try prepare()
        try Self.encoder.encode(request).write(to: requestURL(request.id), options: .atomic)
    }

    /// The valid requests not answered yet, oldest first. An I/O failure keeps a request for a later
    /// read; a corrupt or misnamed request can never be answered correctly and is removed.
    public func pending() -> [OpenRequest] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            NSLog("[linkC] open requests in %@ can't be listed — %@", directory.path, String(describing: error))
            return []
        }
        var requests: [OpenRequest] = []
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(Self.resultSuffix) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                NSLog("[linkC] open request %@ can't be read — %@", name, String(describing: error))
                continue
            }
            let request: OpenRequest
            do {
                request = try Self.decoder.decode(OpenRequest.self, from: data)
            } catch {
                NSLog("[linkC] open request %@ is corrupt, removing it — %@", name, String(describing: error))
                removeRequestFile(url, named: name)
                continue
            }
            guard request.id == String(name.dropLast(".json".count)) else {
                NSLog("[linkC] open request %@ has id %@, removing it", name, request.id)
                removeRequestFile(url, named: name)
                continue
            }
            requests.append(request)
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    private func removeRequestFile(_ url: URL, named name: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            NSLog("[linkC] open request %@ could not be removed — %@", name, String(describing: error))
        }
    }

    /// Writes the answer to `id` and removes the request.
    public func answer(_ id: String, with result: OpenResult) throws {
        try prepare()
        try Self.encoder.encode(result).write(to: resultURL(id), options: .atomic)
        try withdraw(id)
    }

    /// The answer to `id`, nil while there is none.
    public func result(for id: String) throws -> OpenResult? {
        let url = resultURL(id)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        do {
            return try Self.decoder.decode(OpenResult.self, from: data)
        } catch {
            let decodingError = error
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                NSLog("[linkC] open result %@ could not be removed — %@", id, String(describing: error))
            }
            throw decodingError
        }
    }

    public func removeResult(for id: String) throws {
        do {
            try FileManager.default.removeItem(at: resultURL(id))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// Removes the request `id`, answered or given up on. Nothing to remove is fine.
    public func withdraw(_ id: String) throws {
        do {
            try FileManager.default.removeItem(at: requestURL(id))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// Removes answers nobody collected because the command was killed or gave up before reading them.
    /// linkC calls this as it answers requests.
    public func removeStaleResults(olderThan age: TimeInterval, now: Date = Date()) {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } catch {
            NSLog("[linkC] open results in %@ can't be listed — %@", directory.path, String(describing: error))
            return
        }
        let cutoff = now.addingTimeInterval(-age)
        for url in urls where url.lastPathComponent.hasSuffix(Self.resultSuffix) {
            let modified: Date
            do {
                modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
            } catch {
                continue
            }
            guard modified < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                NSLog("[linkC] stale open result %@ could not be removed — %@", url.lastPathComponent, String(describing: error))
            }
        }
    }
}
