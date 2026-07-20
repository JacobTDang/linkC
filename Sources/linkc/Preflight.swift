import Foundation

/// Resolves the external binaries linkC drives. A GUI app launched from Finder has a
/// minimal PATH, so we probe known install locations rather than relying on `which`.
struct Preflight: Sendable {
    let kittyPath: String
    let kittenPath: String
    let claudePath: String
    let socketPath: String

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
        let kitty = try find("kitty", candidates: [
            "/opt/homebrew/bin/kitty", "/usr/local/bin/kitty",
            "/Applications/kitty.app/Contents/MacOS/kitty",
        ])
        let kitten = try find("kitten", candidates: [
            "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten",
            "/Applications/kitty.app/Contents/MacOS/kitten",
        ])
        let claude = try find("claude", candidates: [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", "\(home)/.local/bin/claude",
        ])
        // Short socket path (macOS caps unix socket paths near 104 chars); scope per-user.
        let socket = "unix:/tmp/linkc-\(getuid()).sock"
        return Preflight(kittyPath: kitty, kittenPath: kitten, claudePath: claude, socketPath: socket)
    }

    private static func find(_ name: String, candidates: [String]) throws -> String {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw PreflightError.missing(name)
    }
}
