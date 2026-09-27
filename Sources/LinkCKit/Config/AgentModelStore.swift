import Foundation

/// `<Application Support>/linkC/models.json`: which model each tier launches, per agent.
/// ```json
/// {"models":{"codex":{"light":"gpt-6-luna","standard":"gpt-6-sol","deep":"gpt-6-astra"}},
///  "defaultTiers":{"codex":"standard"}}
/// ```
/// Two processes read this: the app, to launch a session with `--model`, and `linkc-mcp`, to
/// refuse a delegation whose tier has no model. A missing file means "nothing configured yet"
/// and `load` quietly returns the seeded mapping.
///
/// The schema decodes leniently, so a file a newer build wrote never looks broken to an older
/// one: a top-level key this build doesn't know about is kept verbatim and carried forward by
/// `save`, and `"models"` or `"defaultTiers"` missing entirely takes an empty default instead of
/// failing the whole file. Only JSON that genuinely can't be read — a permissions/I/O error, or
/// syntax `JSONSerialization` itself rejects — falls back to the seeded mapping on `load`, and
/// on `save` is refused outright rather than overwritten, since it may be data this build simply
/// can't parse yet.
public struct AgentModelStore: Sendable {
    private let fileURL: URL
    private static let modelsKey = "models"
    private static let defaultTiersKey = "defaultTiers"

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
        do {
            return try parseLenient(data).settings
        } catch {
            NSLog("linkC: models.json at %@ is corrupt, using the seeded mapping — %@",
                  fileURL.path, String(describing: error))
            return .seeded
        }
    }

    /// Writes `settings`, refusing rather than clobbering an existing file it cannot read and
    /// decode. The result names why, so a refused edit stays visible to whoever asked for it
    /// instead of only reaching a log nobody sees.
    @discardableResult
    public func save(_ settings: AgentModelSettings) -> Result<Void, AgentModelStoreRefusal> {
        var extras: [String: JSONValue] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            switch readExistingExtras() {
            case .success(let existingExtras):
                extras = existingExtras
            case .failure(let refusal):
                // Loud: we cannot prove what is on disk right now, so we must not clobber it —
                // it may be a mapping a newer build or a hand-edit wrote that we just can't
                // parse yet.
                NSLog("linkC: %@", refusal.description)
                return .failure(refusal)
            }
        }
        let data: Data
        do {
            data = try encoded(settings, extras: extras)
        } catch {
            let refusal = AgentModelStoreRefusal.writeFailed(String(describing: error))
            NSLog("linkC: %@", refusal.description)
            return .failure(refusal)
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Loud: a silently dropped edit looks exactly like a setting that did not take.
            let refusal = AgentModelStoreRefusal.writeFailed(String(describing: error))
            NSLog("linkC: %@", refusal.description)
            return .failure(refusal)
        }
        return .success(())
    }

    /// Whether the file currently at `fileURL` can be read and decoded, and if so, every
    /// top-level key besides `"models"`/`"defaultTiers"` — carried forward so a newer build's
    /// fields survive a save.
    private func readExistingExtras() -> Result<[String: JSONValue], AgentModelStoreRefusal> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
        do {
            return .success(try parseLenient(data).extras)
        } catch let refusal as AgentModelStoreRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
    }

    /// Parses `data` as the lenient `models.json` schema. `"models"`/`"defaultTiers"` missing
    /// entirely takes an empty default rather than failing the whole file; either present with
    /// the wrong shape, or `data` not being valid JSON at all, throws `AgentModelStoreRefusal`.
    private func parseLenient(_ data: Data) throws -> (settings: AgentModelSettings, extras: [String: JSONValue]) {
        var top: [String: JSONValue]
        do {
            top = try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            throw AgentModelStoreRefusal.unreadable(String(describing: error))
        }
        let models: [String: [String: String]]
        if let value = top.removeValue(forKey: Self.modelsKey) {
            guard let decoded = value.stringTableOfTables else {
                throw AgentModelStoreRefusal.unreadable("\"models\" is not an object of string tables")
            }
            models = decoded
        } else {
            models = [:]
        }
        let defaultTiers: [String: String]
        if let value = top.removeValue(forKey: Self.defaultTiersKey) {
            guard let decoded = value.stringTable else {
                throw AgentModelStoreRefusal.unreadable("\"defaultTiers\" is not an object of strings")
            }
            defaultTiers = decoded
        } else {
            defaultTiers = [:]
        }
        return (AgentModelSettings(models: models, defaultTiers: defaultTiers), top)
    }

    /// Re-assembles `settings` and `extras` into the same top-level shape `parseLenient` reads,
    /// so a key this build doesn't model round-trips through a load and a save unchanged.
    private func encoded(_ settings: AgentModelSettings, extras: [String: JSONValue]) throws -> Data {
        var top = extras
        top[Self.modelsKey] = .object(settings.models.mapValues { tiers in
            JSONValue.object(tiers.mapValues(JSONValue.string))
        })
        top[Self.defaultTiersKey] = .object(settings.defaultTiers.mapValues(JSONValue.string))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(top)
    }
}

/// Why `save` did not write `models.json`.
public enum AgentModelStoreRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The existing file can't be read and decoded, so overwriting it risks losing data a newer
    /// build (or a hand edit) wrote that this build just can't parse yet.
    case unreadable(String)
    /// The encode-and-write itself failed (disk full, permissions, …).
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unreadable(let reason):
            return "models.json can't be read: \(reason). Fix or move the file."
        case .writeFailed(let reason):
            return "models.json could not be written: \(reason)."
        }
    }
}

private extension JSONValue {
    /// This value as `[String: String]`, or nil if it isn't a JSON object of strings.
    var stringTable: [String: String]? {
        guard case .object(let dict) = self else { return nil }
        var result: [String: String] = [:]
        for (key, value) in dict {
            guard case .string(let s) = value else { return nil }
            result[key] = s
        }
        return result
    }

    /// This value as `[String: [String: String]]`, or nil if it isn't a JSON object of objects
    /// of strings.
    var stringTableOfTables: [String: [String: String]]? {
        guard case .object(let dict) = self else { return nil }
        var result: [String: [String: String]] = [:]
        for (key, value) in dict {
            guard let inner = value.stringTable else { return nil }
            result[key] = inner
        }
        return result
    }
}
