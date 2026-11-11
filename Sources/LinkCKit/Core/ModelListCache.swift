import Foundation

/// One agent's live model list, as last fetched (or last failed) by the app.
public struct AgentModelList: Codable, Equatable, Sendable {
    public var models: [ListedModel]
    public var fetchedAt: Date?
    public var error: String?

    public init(models: [ListedModel], fetchedAt: Date? = nil, error: String? = nil) {
        self.models = models
        self.fetchedAt = fetchedAt
        self.error = error
    }
}

/// `~/Library/Application Support/linkC/model-lists.json`: each agent's listed models.
/// A missing file reads as `[:]`. A file that can't be decoded throws — that must not look like
/// "nothing listed yet". (`models.json` already holds tier → model settings.)
public struct ModelListCache: Sendable {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("model-lists.json", isDirectory: false)
    }

    public init(url: URL) {
        self.url = url
    }

    public static var applicationSupport: ModelListCache {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ModelListCache(directory: dir)
    }

    public func read() throws -> [AgentKind: AgentModelList] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let raw = try decoder.decode([String: AgentModelList].self, from: data)
        var result: [AgentKind: AgentModelList] = [:]
        for (key, value) in raw {
            guard let agent = AgentKind(rawValue: key) else { continue }
            result[agent] = value
        }
        return result
    }

    public func write(_ lists: [AgentKind: AgentModelList]) throws {
        let keyed = Dictionary(uniqueKeysWithValues: lists.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(keyed)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The models an agent may use: its cached (or fixed) list ∪ the ids set in its tiers, de-duplicated.
    public static func available(
        for agent: AgentKind,
        lists: [AgentKind: AgentModelList],
        settings: AgentModelSettings
    ) -> [ListedModel] {
        var result: [ListedModel] = []
        var seen = Set<String>()
        let base = lists[agent]?.models ?? ModelListParser.fixed(for: agent) ?? []
        for model in base {
            let key = model.id.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(model)
        }
        for tier in ModelTier.resolutionOrder {
            guard let id = settings.model(for: agent, tier: tier) else { continue }
            let key = id.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(ListedModel(id: id, name: id))
        }
        return result
    }
}
