import Foundation

/// `<Application Support>/linkC/models.json`: which model each tier launches, per agent.
/// ```json
/// {"models":{"codex":{"light":"gpt-6-luna","standard":"gpt-6-sol","deep":"gpt-6-astra"}},
///  "defaultTiers":{"codex":"standard"}}
/// ```
/// Two processes read this: the app, to launch a session with `--model`, and `linkc-mcp`, to
/// refuse a delegation whose tier has no model. A missing file means "nothing configured yet"
/// and loads the seeded mapping; an unreadable one is logged and left alone, never rewritten
/// under the user.
public struct AgentModelStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("models.json", isDirectory: false)
    }

    /// The same directory the rest of linkC's own files live in.
    public static var applicationSupport: AgentModelStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AgentModelStore(directory: dir)
    }

    public var path: String { fileURL.path }

    public func load() -> AgentModelSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return .seeded }
        guard let decoded = try? JSONDecoder().decode(AgentModelSettings.self, from: data) else {
            NSLog("linkC: models.json at %@ is unreadable, using the seeded mapping", fileURL.path)
            return .seeded
        }
        return decoded
    }

    public func save(_ settings: AgentModelSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            // Loud: a silently dropped edit looks exactly like a setting that did not take.
            NSLog("linkC: could not write models.json at %@ — %@", fileURL.path, String(describing: error))
        }
    }
}
