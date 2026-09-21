import Foundation

/// What a relaunch does with each session that was live at quit: bring it back, file it under
/// Earlier, or drop it. Pure — every input is a value — so each rule is tested without launching
/// anything.
///
/// Two sessions must never land on one conversation. A Claude entry with an id resumes exactly
/// that conversation; every other entry can only continue its folder's newest conversation for
/// its agent, so at most one per folder and agent may. Whenever entries compete, the last in
/// manifest order wins: it was launched most recently.
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
        (entry.cwd as NSString).standardizingPath
    }

    private static func resumesClaudeById(_ entry: RestorableSession) -> Bool {
        entry.agentKind == .claude && !(entry.claudeSessionId ?? "").isEmpty
    }

    /// Two entries with the same key would open the same conversation.
    private static func contestKey(_ entry: RestorableSession) -> String {
        if resumesClaudeById(entry), let id = entry.claudeSessionId {
            return "id|\(id)"
        }
        return "continue|\(folder(entry))|\(entry.agentKind.rawValue)"
    }
}
