import Foundation

/// A dev terminal remembered across app runs. Shells don't resume — they re-open — so an
/// entry holds only what launching again needs: the folder, the title, and the command for
/// command-mode shells (docker logs, a dev server). Scrollback is honestly gone.
public struct RestorableShell: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let title: String
    /// Non-nil for command-mode shells, so a relaunch re-runs the same thing.
    public let command: String?
    /// Whether the shell was actively running when linkC quit or shut down.
    public var wasActiveOnQuit: Bool
    /// The agent kind detected running in this terminal shell, if any.
    public var detectedAgent: AgentKind?
    /// When the shell ended. `nil` means it was still live when last persisted.
    public var endedAt: Date?

    public init(
        id: String,
        cwd: String,
        title: String,
        command: String? = nil,
        wasActiveOnQuit: Bool = false,
        detectedAgent: AgentKind? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.command = command
        self.wasActiveOnQuit = wasActiveOnQuit
        self.detectedAgent = detectedAgent
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cwd
        case title
        case command
        case wasActiveOnQuit
        case detectedAgent
        case endedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        wasActiveOnQuit = try container.decodeIfPresent(Bool.self, forKey: .wasActiveOnQuit) ?? false
        detectedAgent = try container.decodeIfPresent(AgentKind.self, forKey: .detectedAgent)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encode(wasActiveOnQuit, forKey: .wasActiveOnQuit)
        try container.encodeIfPresent(detectedAgent, forKey: .detectedAgent)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
    }
}

/// Persists dev terminals to `<directory>/shells.json` so they survive quitting linkC —
/// the shell-side sibling of `WorkspaceManifest`, with the same discipline: atomic writes,
/// a missing/corrupt file loads empty (never block startup), and retention applied once at
/// load so history stays useful rather than archaeological.
public final class ShellManifest {
    private let fileURL: URL
    private let directory: URL
    public private(set) var entries: [RestorableShell]

    public init(directory: URL, now: Date = Date()) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("shells.json", isDirectory: false)
        let loaded = ShellManifest.load(from: fileURL)
        self.entries = ShellManifest.prune(loaded, now: now)
        if entries != loaded { save() }   // the file self-heals to the pruned set
    }

    /// Retention, applied once per launch: entries still marked live belong to a run that
    /// is dead by definition of loading — stamp them so their age-out clock starts; ended
    /// entries older than a week drop; and each folder+command keeps only its newest entry
    /// (two shells in one folder running different commands are different things).
    /// Shells marked `wasActiveOnQuit` are always retained and exempt from deduplication.
    static func prune(_ entries: [RestorableShell], now: Date) -> [RestorableShell] {
        var stamped = entries
        for i in stamped.indices where stamped[i].endedAt == nil {
            stamped[i].endedAt = now
        }
        // Every endedAt is non-nil past this point — the force-unwraps encode that.
        let freshInactive = stamped.filter {
            !$0.wasActiveOnQuit && now.timeIntervalSince($0.endedAt!) < Self.maxAge
        }
        var newest: [String: RestorableShell] = [:]
        for entry in freshInactive {
            let key = "\(entry.cwd)\u{0}\(entry.command ?? "")"
            guard let kept = newest[key] else {
                newest[key] = entry
                continue
            }
            // Ties (same-crash orphans share a stamp) keep the later entry — the newer shell.
            if entry.endedAt! >= kept.endedAt! { newest[key] = entry }
        }
        let retainedInactiveIds = Set(newest.values.map(\.id))
        return stamped.filter { $0.wasActiveOnQuit || retainedInactiveIds.contains($0.id) }
    }

    private static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Insert, or replace the entry with the same id. Persists.
    public func upsert(_ entry: RestorableShell) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    /// Stamp `endedAt` — the shell died, so it's now restorable. No-op for an unknown id
    /// or an already-stamped entry (the first timestamp wins).
    public func markEnded(id: String, at date: Date) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].endedAt == nil else { return }
        entries[i].endedAt = date
        save()
    }

    /// Forget an entry (relaunched into a fresh shell, or dismissed). Persists.
    public func remove(id: String) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before { save() }
    }

    // MARK: - IO

    private static func load(from fileURL: URL) -> [RestorableShell] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] } // missing → empty
        do {
            return try Self.decoder.decode([RestorableShell].self, from: data)
        } catch {
            NSLog("linkC: shell manifest at %@ is unreadable, treating as empty: %@",
                  fileURL.path, error.localizedDescription)
            return []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("linkC: failed to write shell manifest to %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
