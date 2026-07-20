import Foundation

/// Resolves the external binary linkC drives. A GUI app launched from Finder has a minimal
/// PATH, so we probe known install locations rather than relying on `which`.
struct Preflight: Sendable {
    let claudePath: String

    enum PreflightError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let name): return "Couldn't find \(name). Install it or add it to a standard location."
            }
        }
    }

    static func resolve() throws -> Preflight {
        let home = NSHomeDirectory()
        let claude = try find("claude", candidates: [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", "\(home)/.local/bin/claude",
        ])
        return Preflight(claudePath: claude)
    }

    private static func find(_ name: String, candidates: [String]) throws -> String {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw PreflightError.missing(name)
    }
}
