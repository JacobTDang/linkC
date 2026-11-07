import Foundation

/// OpenCode's session listing, read for the one session linkC may continue in a folder.
///
/// OpenCode's own `--continue` takes the newest session of the whole project and moves into that
/// session's folder. A project is the repo's root commit, so every worktree of one repo is one
/// project, and folders with no commits share one. linkC continues only a session that ran in the
/// very folder it is opening.
public enum OpenCodeSessions {
    /// The arguments that list the sessions of the project `opencode` runs in. `--standalone`, so
    /// listing never starts OpenCode's shared background service when it is not running.
    public static let listArguments = ["session", "list", "--format", "json", "--standalone"]

    private struct Entry: Decodable {
        let id: String
        let directory: String
        let updated: Double
    }

    /// The id of the newest session that ran in `folder`, from `opencode session list --format
    /// json` output; nil when none did. OpenCode prints nothing for a project with no sessions.
    /// Throws on output that is not that listing.
    public static func newest(in folder: String, listing: String) throws -> String? {
        guard !listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: Data(listing.utf8))
        } catch {
            throw LinkCError.parse("OpenCode's session list could not be read — \(error)")
        }
        let target = ProjectPath.canonical(folder)
        return entries
            .filter { ProjectPath.canonical($0.directory) == target }
            .max { $0.updated < $1.updated }?
            .id
    }
}
