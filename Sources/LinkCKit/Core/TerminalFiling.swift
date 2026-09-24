import Foundation

public enum TerminalFiling {
    /// The project a terminal belongs to: its filing, else a project whose folder is its folder, else nil.
    /// Paths compare standardized, as the rest of the sidebar compares them.
    public static func project(forTerminal id: String, cwd: String, filed: [String: String], projects: Set<String>) -> String? {
        if let explicit = filed[id] {
            return explicit
        }
        
        let url = URL(fileURLWithPath: cwd).standardized
        for p in projects {
            let pUrl = URL(fileURLWithPath: p).standardized
            if url.path == pUrl.path {
                return p
            }
        }
        
        return nil
    }
}
