import Foundation

public enum TerminalFiling {
    /// The project a terminal belongs to: its filing first; otherwise the project whose folder is
    /// exactly the terminal's folder; otherwise nil. A subfolder is its own folder, not part of its
    /// parent project. Paths compare standardized, as the rest of the sidebar compares them.
    public static func project(forTerminal id: String, cwd: String, filed: [String: String], projects: Set<String>) -> String? {
        if let explicit = filed[id] {
            return ProjectPath.canonical(explicit)
        }
        let canonicalCwd = ProjectPath.canonical(cwd)
        return projects.map { ProjectPath.canonical($0) }.first { $0 == canonicalCwd }
    }
}
