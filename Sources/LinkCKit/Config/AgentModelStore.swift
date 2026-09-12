import Foundation

/// `<Application Support>/linkC/models.json`: which model each tier launches, per agent.
/// ```json
/// {"models":{"codex":{"light":"gpt-6-luna","standard":"gpt-6-sol","deep":"gpt-6-astra"}},
///  "defaultTiers":{"codex":"standard"}}
/// ```
/// Two processes read this: the app, to launch a session with `--model`, and `linkc-mcp`, to
/// refuse a delegation whose tier has no model. A missing file means "nothing configured yet"
/// and `load` quietly returns the seeded mapping. A present file that cannot be read or
/// decoded — a permissions error, an I/O error, or corrupt JSON — logs the path and error and
/// also returns the seeded mapping, so every caller always gets a usable one, but `save` checks
/// the existing file itself before writing: if it still cannot be read and decoded, the write
/// is refused and logged rather than replacing it. Only an absent file, or one linkC can verify
/// by reading it back, is ever overwritten.
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .seeded }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Loud: a permissions or I/O error hides a real file from us; the caller still
            // needs a usable mapping, but this must not look like "nothing configured yet".
            NSLog("linkC: could not read models.json at %@ — %@, using the seeded mapping",
                  fileURL.path, String(describing: error))
            return .seeded
        }
        guard let decoded = try? JSONDecoder().decode(AgentModelSettings.self, from: data) else {
            NSLog("linkC: models.json at %@ is corrupt, using the seeded mapping", fileURL.path)
            return .seeded
        }
        return decoded
    }

    public func save(_ settings: AgentModelSettings) {
        if FileManager.default.fileExists(atPath: fileURL.path), !canVerifyExistingFile() {
            // Loud: we cannot prove what is on disk right now, so we must not clobber it —
            // it may be a mapping a newer build or a hand-edit wrote that we just can't parse.
            NSLog("linkC: refusing to overwrite unreadable models.json at %@", fileURL.path)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            // Loud: a silently dropped edit looks exactly like a setting that did not take.
            NSLog("linkC: could not write models.json at %@ — %@", fileURL.path, String(describing: error))
        }
    }

    /// Whether the file currently at `fileURL` can be read and decoded as-is — the bar `save`
    /// requires of an existing file before it will replace it.
    private func canVerifyExistingFile() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return (try? JSONDecoder().decode(AgentModelSettings.self, from: data)) != nil
    }
}
