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
/// "nothing listed yet". Not `models.json`: that file already holds the tier → model settings.
/// `write` creates the folder.
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

    /// Moves a file that cannot be read to `<name>.corrupt`, so writing a fresh cache does not
    /// destroy it. Returns where it went.
    public func moveUnreadableAside() throws -> URL {
        let aside = url.appendingPathExtension("corrupt")
        if FileManager.default.fileExists(atPath: aside.path) {
            try FileManager.default.removeItem(at: aside)
        }
        try FileManager.default.moveItem(at: url, to: aside)
        return aside
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

    /// What the agent's own CLI listed on its last good refresh: nil when it was never listed, when
    /// the last refresh failed (the list may be stale), or when the list came back empty.
    public static func liveModels(for agent: AgentKind, lists: [AgentKind: AgentModelList]) -> [ListedModel]? {
        guard let list = lists[agent], list.fetchedAt != nil, list.error == nil, !list.models.isEmpty else { return nil }
        return list.models
    }

    /// What a model may be picked from when it is checked: the agent's live list when it has one,
    /// else everything `available` shows. The tier ids `available` adds are for display; a model the
    /// CLI no longer lists must not pass for one it offers.
    public static func choosable(
        for agent: AgentKind,
        lists: [AgentKind: AgentModelList],
        settings: AgentModelSettings
    ) -> [ListedModel] {
        liveModels(for: agent, lists: lists) ?? available(for: agent, lists: lists, settings: settings)
    }

    /// The models an agent may use: its cached (or fixed) list ∪ the ids set in its tiers, de-duplicated.
    /// For display; `choosable` is what a model is checked against.
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
