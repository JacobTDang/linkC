import Foundation

/// What a relaunch does with each session that was live at quit: bring it back, file it under
/// Earlier, or drop it. Pure — every input is a value — so each rule is tested without launching
/// anything.
///
/// Two sessions must never land on one conversation. A Claude or OpenCode entry with an id reopens
/// exactly that conversation. An OpenCode entry without one continues the folder's newest
/// conversation that no session has open, and a Kilo or Crush entry opens a new one, so every one of
/// those comes back. Every other entry can only continue its folder's newest conversation for its
/// agent, so at most one per folder and agent may. Whenever entries compete, the user's own session
/// wins over a worker; among the user's (or, with none, among workers) the last in manifest order
/// wins, since it was launched most recently.
public struct RelaunchPlan: Equatable, Sendable {
    /// Entries to launch again, in manifest order.
    public let relaunch: [String]
    /// Entries kept, stamped ended, and shown under Earlier for the user to restore by hand.
    public let toEarlier: [String]
    /// Worker entries that hold no task or lost a contest: removed from the manifest.
    public let drop: [String]

    public init(relaunch: [String], toEarlier: [String], drop: [String]) {
        self.relaunch = relaunch
        self.toEarlier = toEarlier
        self.drop = drop
    }

    public static func make(entries: [RestorableSession], workersHoldingTasks: Set<String>) -> RelaunchPlan {
        var drop: [String] = []
        var candidates: [RestorableSession] = []
        for entry in entries {
            if entry.isWorker && !workersHoldingTasks.contains(entry.linkcId) {
                drop.append(entry.linkcId)
            } else {
                candidates.append(entry)
            }
        }

        // Contest key → the last user entry sharing it, and the last worker entry sharing it.
        // The user's own session always wins a contest it is in — a worker only ever wins a
        // contest with no user entry in it — so within each side "the last wins" still picks the
        // most recently launched.
        var lastUser: [String: String] = [:]
        var lastWorker: [String: String] = [:]
        for entry in candidates {
            if entry.isWorker { lastWorker[contestKey(entry)] = entry.linkcId }
            else { lastUser[contestKey(entry)] = entry.linkcId }
        }
        let winner = lastUser.merging(lastWorker) { user, _ in user }

        // An id-less Claude entry would continue its folder's newest conversation — the one a
        // Claude entry resuming by id in the same folder is about to reopen. Never both.
        let foldersResumingClaude = Set(candidates.filter(resumesClaudeById).map(folder))

        var relaunch: [String] = []
        var toEarlier: [String] = []
        for entry in candidates {
            let wonItsContest = winner[contestKey(entry)] == entry.linkcId
            let yieldsToResume = entry.agentKind == .claude && !resumesClaudeById(entry)
                && foldersResumingClaude.contains(folder(entry))
            if wonItsContest && !yieldsToResume {
                relaunch.append(entry.linkcId)
            } else if entry.isWorker {
                // A worker never goes under Earlier: it was linkC's, not the user's. Dropping it
                // ends its session record, so the relay fails its task and tells the delegator.
                drop.append(entry.linkcId)
            } else {
                toEarlier.append(entry.linkcId)
            }
        }
        // Two passes add to `drop` (workers holding no task, then workers that lost a contest);
        // put them back in manifest order, as the property promises.
        let position = Dictionary(
            entries.enumerated().map { ($0.element.linkcId, $0.offset) }, uniquingKeysWith: { first, _ in first })
        drop.sort { (position[$0] ?? .max) < (position[$1] ?? .max) }
        return RelaunchPlan(relaunch: relaunch, toEarlier: toEarlier, drop: drop)
    }

    private static func folder(_ entry: RestorableSession) -> String {
        ProjectPath.canonical(entry.cwd)
    }

    private static func resumesClaudeById(_ entry: RestorableSession) -> Bool {
        entry.agentKind == .claude && conversationToReopen(entry, as: .claude) != nil
    }

    /// The agents whose conversation linkC reopens by its id.
    static let reopensById: Set<AgentKind> = [.claude, .opencode]

    /// The conversation `entry` reopens when it comes back as `agent`: its recorded id, for Claude
    /// and OpenCode. Nil when it has none, or comes back as another agent, to whom the id means nothing.
    public static func conversationToReopen(_ entry: RestorableSession, as agent: AgentKind) -> String? {
        guard agent == entry.agentKind, reopensById.contains(agent),
              let id = entry.claudeSessionId, !id.isEmpty else { return nil }
        return id
    }

    /// Two entries with the same key would open the same conversation. Without an id, an OpenCode
    /// entry continues a conversation no session has open, and a Kilo or Crush entry opens a new
    /// one, so its key is its own.
    private static func contestKey(_ entry: RestorableSession) -> String {
        if let id = conversationToReopen(entry, as: entry.agentKind) {
            return "id|\(entry.agentKind.rawValue)|\(id)"
        }
        if entry.agentKind == .opencode || entry.agentKind == .kilo || entry.agentKind == .crush {
            return "new|\(entry.linkcId)"
        }
        return "continue|\(folder(entry))|\(entry.agentKind.rawValue)"
    }
}
