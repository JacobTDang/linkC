import Foundation

public enum TerminalFiling {
    /// The project a terminal belongs to: its filing first; otherwise the deepest project whose
    /// folder is the terminal's folder or an ancestor of it, so `cd Sources` in an unfiled
    /// terminal keeps it in its project instead of ejecting it into a new one; otherwise nil.
    /// Paths compare standardized, path component by path component (not as string prefixes), so
    /// `/p/linkc2` is never mistaken for a subfolder of `/p/linkc`.
    public static func project(forTerminal id: String, cwd: String, filed: [String: String], projects: Set<String>) -> String? {
        if let explicit = filed[id] {
            return (explicit as NSString).standardizingPath
        }

        let cwdComponents = ((cwd as NSString).standardizingPath as NSString).pathComponents
        var best: String?
        var bestDepth = -1
        for p in projects {
            let standardizedProject = (p as NSString).standardizingPath
            let projectComponents = (standardizedProject as NSString).pathComponents
            guard projectComponents.count <= cwdComponents.count else { continue }
            guard Array(cwdComponents.prefix(projectComponents.count)) == projectComponents else { continue }
            if projectComponents.count > bestDepth {
                bestDepth = projectComponents.count
                best = standardizedProject
            }
        }
        return best
    }
}
