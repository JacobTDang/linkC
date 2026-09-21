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
    /// Worker entries that hold no task: removed from the manifest.
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

        var winner: [String: String] = [:]   // contest key → the last entry's linkC id
        for entry in candidates { winner[contestKey(entry)] = entry.linkcId }

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
            } else {
                toEarlier.append(entry.linkcId)
            }
        }
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
