import Foundation

/// Reads how full an OpenCode conversation's context is, from OpenCode's own files (verified
/// against OpenCode 2.2.5): its SQLite database, whose `session_message` rows each hold one
/// message as JSON, and the model catalog it caches in `models.json`.
///
/// The context is worked out as OpenCode's sidebar works it out: the newest assistant message that
/// carries token counts, after the conversation's last finished compaction, sent `input`, got back
/// `output` and `reasoning`, and read and wrote the prompt cache (`cache.read`, `cache.write`);
/// those five counts together are what the next request starts from. The window is the
/// `limit.context` of the model that answered, in the catalog.
public struct OpenCodeLiveReader: SessionLiveReader {
    private let database: URL
    private let windows: ModelWindows

    public init(database: URL, modelsFile: URL) {
        self.database = database
        self.windows = ModelWindows(file: modelsFile)
    }

    /// OpenCode's files under `home`: `.local/share/opencode/opencode.db` and
    /// `.cache/opencode/models.json`.
    public init(home: URL) {
        self.init(
            database: home.appendingPathComponent(".local/share/opencode/opencode.db"),
            modelsFile: home.appendingPathComponent(".cache/opencode/models.json"))
    }

    /// An empty detail when linkC knows no conversation id, OpenCode has recorded no database yet,
    /// or the conversation has no request to count. Throws when what OpenCode recorded cannot be read.
    public func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
        guard let conversationId = target.agentSessionId,
              FileManager.default.fileExists(atPath: database.path) else { return SessionLiveDetail() }
        let rows = try SQLiteCLI.rows(Row.self, in: database.path, query: Self.lastRequestQuery(sessionId: conversationId))
        guard let row = rows.first else { return SessionLiveDetail() }
        let counts = [row.input, row.output, row.reasoning, row.cacheRead, row.cacheWrite]
        guard counts.allSatisfy({ $0 != nil }) else {
            throw LinkCError.process("OpenCode's newest request for \(conversationId) has tokens that are not all whole-number counts")
        }
        let used = counts.reduce(0) { $0 + ($1 ?? 0) }
        guard used > 0, let provider = row.providerID, let model = row.modelID,
              let window = try windows.contextWindow(provider: provider, model: model) else { return SessionLiveDetail() }
        let percent = (Double(used) / Double(window) * 100).rounded()
        return SessionLiveDetail(contextPercent: Int(min(percent, 100)))
    }

    /// The newest assistant message of the conversation that has token counts and follows its last
    /// finished compaction, with its counts and its model. Both `session_message` reads go through
    /// `session_message_session_type_seq_idx`: the database holds every conversation OpenCode has
    /// had, about a gigabyte, so nothing here may scan it.
    static func lastRequestQuery(sessionId: String) -> String {
        let id = "'" + sessionId.replacingOccurrences(of: "'", with: "''") + "'"
        return """
        select json_extract(data, '$.tokens.input') as input,
               json_extract(data, '$.tokens.output') as output,
               json_extract(data, '$.tokens.reasoning') as reasoning,
               json_extract(data, '$.tokens.cache.read') as cacheRead,
               json_extract(data, '$.tokens.cache.write') as cacheWrite,
               json_extract(data, '$.model.providerID') as providerID,
               json_extract(data, '$.model.id') as modelID
        from session_message
        where session_id = \(id) and type = 'assistant'
          and coalesce(json_type(data, '$.tokens'), 'null') <> 'null'
          and seq > coalesce((select max(seq) from session_message
                              where session_id = \(id) and type = 'compaction'
                                and json_extract(data, '$.status') = 'completed'), -1)
        order by seq desc
        limit 1
        """
    }

    /// A count that is not a whole number reads as nil, so the reader can say which message it was.
    private struct Row: Decodable {
        let input, output, reasoning, cacheRead, cacheWrite: Int?
        let providerID, modelID: String?

        enum CodingKeys: String, CodingKey {
            case input, output, reasoning, cacheRead, cacheWrite, providerID, modelID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            input = try? container.decode(Int.self, forKey: .input)
            output = try? container.decode(Int.self, forKey: .output)
            reasoning = try? container.decode(Int.self, forKey: .reasoning)
            cacheRead = try? container.decode(Int.self, forKey: .cacheRead)
            cacheWrite = try? container.decode(Int.self, forKey: .cacheWrite)
            providerID = try? container.decode(String.self, forKey: .providerID)
            modelID = try? container.decode(String.self, forKey: .modelID)
        }
    }
}

/// Each model's context window from OpenCode's cached catalog (`models.json[provider].models[model]
/// .limit.context`). The file is several megabytes, so it is read again only when it changes.
private final class ModelWindows: @unchecked Sendable {
    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private let file: URL
    private let lock = NSLock()
    private var cached: (stamp: Stamp, windows: [String: [String: Int]])?

    init(file: URL) {
        self.file = file
    }

    /// nil when the catalog is not there, or does not give the model a window. Throws when the
    /// catalog is there and cannot be read.
    func contextWindow(provider: String, model: String) throws -> Int? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = Stamp(modified: attributes[.modificationDate] as? Date ?? .distantPast,
                          size: (attributes[.size] as? Int) ?? 0)
        return try lock.withLock {
            if let cached, cached.stamp == stamp { return cached.windows[provider]?[model] }
            let windows = try Self.windows(in: Data(contentsOf: file), path: file.path)
            cached = (stamp, windows)
            return windows[provider]?[model]
        }
    }

    private static func windows(in data: Data, path: String) throws -> [String: [String: Int]] {
        let catalog: [String: Provider]
        do {
            catalog = try JSONDecoder().decode([String: Provider].self, from: data)
        } catch {
            throw LinkCError.process("OpenCode's models.json at \(path) is not the shape expected: \(error)")
        }
        return catalog.mapValues { provider in
            (provider.models ?? [:]).compactMapValues { model in
                guard let context = model.limit?.context, context > 0 else { return nil }
                return context
            }
        }
    }

    private struct Provider: Decodable {
        let models: [String: Model]?

        struct Model: Decodable {
            let limit: Limit?

            struct Limit: Decodable {
                let context: Int?

                init(from decoder: Decoder) throws {
                    context = try? decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .context)
                }

                enum CodingKeys: String, CodingKey { case context }
            }
        }
    }
}
