import Foundation
import Observation

/// A session recorded in the workspace manifest so it can be restored after the app quits.
/// While a session is live its entry has no `endedAt`; once the session ends (or is stopped)
/// `endedAt` is stamped and the entry becomes a restorable card on the home overview.
public struct RestorableSession: Codable, Equatable, Identifiable, Sendable {
    /// linkC's own session id (the `LINKC_SESSION` value). Stable across the session's life.
    public let linkcId: String
    /// claude's real conversation id, once a hook event has bound it. `nil` → fall back to
    /// `claude --continue` in the folder rather than `--resume <id>`.
    public var claudeSessionId: String?
    public let cwd: String
    public let title: String
    /// The agent running in this session (e.g. claude, agy, cursor, codex). Defaults to .claude.
    public var agentKind: AgentKind
    /// Whether the session was actively running when linkC quit or shut down.
    public var wasActiveOnQuit: Bool
    /// When the session ended/stopped. `nil` means it was still live when last persisted.
    public var endedAt: Date?

    public var id: String { linkcId }

    public init(
        linkcId: String,
        claudeSessionId: String? = nil,
        cwd: String,
        title: String,
        agentKind: AgentKind = .claude,
        wasActiveOnQuit: Bool = false,
        endedAt: Date? = nil
    ) {
        self.linkcId = linkcId
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
        self.title = title
        self.agentKind = agentKind
        self.wasActiveOnQuit = wasActiveOnQuit
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case linkcId
        case claudeSessionId
        case cwd
        case title
        case agentKind
        case wasActiveOnQuit
        case endedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        linkcId = try container.decode(String.self, forKey: .linkcId)
        claudeSessionId = try container.decodeIfPresent(String.self, forKey: .claudeSessionId)
        cwd = try container.decode(String.self, forKey: .cwd)
        title = try container.decode(String.self, forKey: .title)
        agentKind = try container.decodeIfPresent(AgentKind.self, forKey: .agentKind) ?? .claude
        wasActiveOnQuit = try container.decodeIfPresent(Bool.self, forKey: .wasActiveOnQuit) ?? false
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(linkcId, forKey: .linkcId)
        try container.encodeIfPresent(claudeSessionId, forKey: .claudeSessionId)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(title, forKey: .title)
        try container.encode(agentKind, forKey: .agentKind)
        try container.encode(wasActiveOnQuit, forKey: .wasActiveOnQuit)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
    }
}

extension RestorableSession {
    /// Human label for when the session ended: `nil` while live, "ended just now" inside a
    /// minute (either direction, so slight clock skew never renders "in 0s"), otherwise the
    /// abbreviated relative form ("ended 5m ago"). The formatter is built per call —
    /// `RelativeDateTimeFormatter` is not Sendable, and restorable rows are few and re-render
    /// rarely, so a shared instance isn't worth the isolation it would force.
    public func endedLabel(now: Date) -> String? {
        guard let endedAt else { return nil }
        if abs(now.timeIntervalSince(endedAt)) < 60 { return "ended just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "ended " + formatter.localizedString(for: endedAt, relativeTo: now)
    }
}

/// Persists the set of known sessions to `<directory>/workspace.json` so they survive quitting
/// or crashing the app. Holds the in-memory list as the single mirror of that file; every
/// mutation writes the file back atomically. Fails loud on write errors (NSLog) and tolerates a
/// missing or corrupt file on load (treated as empty, logged) — a bad manifest must never block
/// the app from starting.
public final class WorkspaceManifest {
    private let fileURL: URL
    private let directory: URL
    public private(set) var entries: [RestorableSession]

    public init(directory: URL, now: Date = Date()) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("workspace.json", isDirectory: false)
        let loaded = WorkspaceManifest.load(from: fileURL)
        self.entries = WorkspaceManifest.prune(loaded, now: now)
        if entries != loaded { save() }   // the file self-heals to the pruned set
    }

    /// Retention, applied once per launch: restorable history should stay useful, not
    /// archaeological. Entries still live in the file belong to a run that is dead by
    /// definition of loading — stamp them so their age-out clock starts; ended entries
    /// older than a week drop; and each folder keeps only its newest entry (the Resume…
    /// launcher still reaches every older conversation through claude's own picker).
    /// Sessions marked `wasActiveOnQuit` are always retained and exempt from folder deduplication.
    static func prune(_ entries: [RestorableSession], now: Date) -> [RestorableSession] {
        var stamped = entries
        for i in stamped.indices where !stamped[i].wasActiveOnQuit && stamped[i].endedAt == nil {
            stamped[i].endedAt = now
        }
        // Inactive entries have endedAt stamped if previously nil.
        let freshInactive = stamped.filter {
            !$0.wasActiveOnQuit && ($0.endedAt.map { now.timeIntervalSince($0) < Self.maxAge } ?? false)
        }
        var newestByFolder: [String: RestorableSession] = [:]
        for entry in freshInactive {
            guard let entryEnded = entry.endedAt else { continue }
            guard let kept = newestByFolder[entry.cwd], let keptEnded = kept.endedAt else {
                newestByFolder[entry.cwd] = entry
                continue
            }
            if entryEnded > keptEnded {
                newestByFolder[entry.cwd] = entry
            } else if entryEnded == keptEnded,
                      entry.claudeSessionId != nil || kept.claudeSessionId == nil {
                // Same-crash orphans tie on the stamped date. A bound conversation id wins
                // (precise `--resume` beats `--continue`); on a pure tie the later entry —
                // the newer session, by upsert order — wins.
                newestByFolder[entry.cwd] = entry
            }
        }
        let retainedInactiveIds = Set(newestByFolder.values.map(\.linkcId))
        return stamped.filter { $0.wasActiveOnQuit || retainedInactiveIds.contains($0.linkcId) }
    }

    private static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Insert `entry`, or replace the existing entry with the same linkC id. Persists.
    public func upsert(_ entry: RestorableSession) {
        if let i = entries.firstIndex(where: { $0.linkcId == entry.linkcId }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    /// Bind claude's real conversation id onto an existing entry (so a later restore can
    /// `--resume` the exact conversation). No-op for an unknown id; only persists on a change.
    public func bindClaudeId(linkcId: String, claudeSessionId: String) {
        guard let i = entries.firstIndex(where: { $0.linkcId == linkcId }),
              entries[i].claudeSessionId != claudeSessionId else { return }
        entries[i].claudeSessionId = claudeSessionId
        save()
    }

    /// Stamp `endedAt` on an existing entry — it is now restorable. No-op for an unknown id
    /// or when already ended with wasActiveOnQuit == false (a stop's synchronous cleanup
    /// and the child's async exit both call this; the first timestamp wins, no redundant disk write).
    public func markEnded(linkcId: String, at date: Date) {
        guard let i = entries.firstIndex(where: { $0.linkcId == linkcId }) else { return }
        let changed = entries[i].wasActiveOnQuit || entries[i].endedAt == nil
        guard changed else { return }
        entries[i].wasActiveOnQuit = false
        if entries[i].endedAt == nil {
            entries[i].endedAt = date
        }
        save()
    }

    /// Drop an entry entirely (restored into a fresh session, or dismissed by the user). Persists.
    public func remove(linkcId: String) {
        let before = entries.count
        entries.removeAll { $0.linkcId == linkcId }
        if entries.count != before { save() }
    }

    // MARK: - IO

    private static func load(from fileURL: URL) -> [RestorableSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] } // missing → empty
        do {
            return try Self.decoder.decode([RestorableSession].self, from: data)
        } catch {
            NSLog("linkC: workspace manifest at %@ is unreadable, treating as empty: %@",
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
            NSLog("linkC: failed to write workspace manifest to %@: %@", fileURL.path, error.localizedDescription)
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

/// Observable holder for the restorable cards shown on the home overview. The coordinator
/// recomputes and assigns this whenever the manifest or the live session set changes, so the
/// panel reacts the same way it does to the live session store.
@MainActor
@Observable
public final class RestorableStore {
    public private(set) var restorables: [RestorableSession] = []

    public init() {}

    /// Replace the list, but only when it actually differs — avoids needless view invalidations.
    public func set(_ next: [RestorableSession]) {
        if next != restorables { restorables = next }
    }
}
