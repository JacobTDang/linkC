import Foundation

public enum TerminalFiling {
    /// The project a terminal belongs to: its filing, else a project whose folder is its folder, else nil.
    /// Paths compare standardized, as the rest of the sidebar compares them.
    public static func project(forTerminal id: String, cwd: String, filed: [String: String], projects: Set<String>) -> String? {
        if let explicit = filed[id] {
            return (explicit as NSString).standardizingPath
        }

        let standardizedCwd = (cwd as NSString).standardizingPath
        for p in projects {
            if standardizedCwd == (p as NSString).standardizingPath {
                return p
            }
        }

        return nil
    }
}
