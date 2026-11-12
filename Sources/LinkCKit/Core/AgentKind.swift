import Foundation

/// The AI CLI agent (or general interactive shell) running in a session.
public enum AgentKind: String, Sendable, CaseIterable, Codable {
    case claude
    case agy
    case cursor
    case codex
    case grok
    case opencode
    case freebuff
    case shell

    /// Concise uppercase badge text for pills and cards.
    public var pillText: String {
        switch self {
        case .claude: return "CLAUDE"
        case .agy: return "AGY"
        case .cursor: return "CURSOR"
        case .codex: return "CODEX"
        case .grok: return "GROK"
        case .opencode: return "OPENCODE"
        case .freebuff: return "FREEBUFF"
        case .shell: return "SHELL"
        }
    }

    /// The brand accent color hex string.
    public var brandColorHex: String {
        switch self {
        case .claude: return "#D97757"    // coral
        case .agy: return "#7AA2F7"       // antigravity soft blue
        case .cursor: return "#00E5FF"    // cyan / neon
        case .codex: return "#10A37F"     // openAI emerald
        case .grok: return "#E5E5EA"      // xAI's mark is monochrome; light on the dark panel
        case .opencode: return "#FAB283"  // the accent of OpenCode's default theme
        case .freebuff: return "#FBF0DF"  // warm cream used by Freebuff's own UI
        case .shell: return "#8E8E93"     // neutral grey
        }
    }

    /// Human-readable display name for menus, dialogs, and prompts.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .agy: return "Antigravity (agy)"
        case .cursor: return "Cursor Agent"
        case .codex: return "Codex"
        case .grok: return "Grok (via Cursor)"
        case .opencode: return "OpenCode"
        case .freebuff: return "Freebuff"
        case .shell: return "Terminal (zsh)"
        }
    }

    /// The short name a sidebar row uses when nothing better names the session.
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .agy: return "agy"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        case .freebuff: return "Freebuff"
        case .shell: return "Terminal"
        }
    }

    /// The variable linkC sets on a terminal whose agent runs on another agent's CLI. Grok runs
    /// Cursor's, so this is how linkC's tool server tells a Grok worker from Cursor.
    public static let workerEnvironmentKey = "LINKC_WORKER"

    /// Every agent that can take a task: all but a plain shell, in declaration order.
    public static var peers: [AgentKind] { allCases.filter { $0 != .shell } }

    /// `peers` as text, for tool descriptions and errors: "claude, agy, cursor, codex, grok, opencode".
    public static var peerList: String { peers.map(\.rawValue).joined(separator: ", ") }

    /// Agents every launch names a model for, a tier or not, because their CLI's own default is not
    /// theirs: Grok's Cursor defaults to Auto, and OpenCode runs a session whose model it does not
    /// know on whatever it picks, which may be the user's local model.
    public static let alwaysNamesModel: Set<AgentKind> = [.grok, .opencode]
}

/// Metadata and argument specifications for AI CLI agents.
public struct AgentDescriptor: Sendable {
    public let kind: AgentKind
    public let binaryName: String
    public let defaultCandidatePaths: [String]
    public let yoloFlags: [String]
    public let continueArgs: [String]
    public let resumeArgs: [String]

    public static func descriptor(for kind: AgentKind) -> AgentDescriptor {
        let home = FileManager.default.homeDirectoryForCurrentUser.path as NSString
        switch kind {
        case .claude:
            return AgentDescriptor(
                kind: .claude,
                binaryName: "claude",
                defaultCandidatePaths: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
                yoloFlags: ["--dangerously-skip-permissions"],
                continueArgs: ["--continue"],
                resumeArgs: ["--resume"]
            )
        case .agy:
            return AgentDescriptor(
                kind: .agy,
                binaryName: "agy",
                defaultCandidatePaths: [
                    home.appendingPathComponent(".local/bin/agy"),
                    "/opt/homebrew/bin/agy",
                    "/usr/local/bin/agy"
                ],
                yoloFlags: ["--dangerously-skip-permissions"],
                continueArgs: ["--continue"],
                resumeArgs: ["--conversation"]
            )
        case .cursor:
            return AgentDescriptor(
                kind: .cursor,
                binaryName: "cursor",
                defaultCandidatePaths: [
                    home.appendingPathComponent(".local/bin/cursor"),
                    "/usr/local/bin/cursor",
                    "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
                ],
                yoloFlags: ["agent", "--yolo", "--trust", "--approve-mcps"],
                continueArgs: ["--continue"],
                resumeArgs: ["--resume"]
            )
        case .codex:
            return AgentDescriptor(
                kind: .codex,
                binaryName: "codex",
                defaultCandidatePaths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
                // Without the update check: when a newer release is out, Codex opens on an
                // "update available" prompt, and the first text linkC types into the session — a
                // worker's task — chose "Update now", so Codex updated itself and exited.
                yoloFlags: ["--dangerously-bypass-approvals-and-sandbox", "-c", "check_for_update_on_startup=false"],
                continueArgs: ["resume", "--last"],
                resumeArgs: ["resume"]
            )
        case .grok:
            // Grok runs on the Cursor plan through Cursor's own CLI; `environment(for:home:)` is
            // what sets a Grok terminal apart from a Cursor one.
            let cursor = descriptor(for: .cursor)
            return AgentDescriptor(
                kind: .grok,
                binaryName: cursor.binaryName,
                defaultCandidatePaths: cursor.defaultCandidatePaths,
                yoloFlags: cursor.yoloFlags,
                continueArgs: cursor.continueArgs,
                resumeArgs: cursor.resumeArgs
            )
        case .opencode:
            return AgentDescriptor(
                kind: .opencode,
                binaryName: "opencode",
                defaultCandidatePaths: [
                    "/opt/homebrew/bin/opencode",
                    "/usr/local/bin/opencode",
                    home.appendingPathComponent(".opencode/bin/opencode")
                ],
                // A private server for this session, so its environment — the model and linkC's tools in
                // `OPENCODE_CONFIG_CONTENT`, `LINKC_SESSION` — reaches it; the shared background service has
                // the environment of whatever started it. Every permission approved that the config does not deny.
                yoloFlags: ["--standalone", "--auto"],
                // linkC never resumes an OpenCode conversation: it would run on whatever model it last
                // used, which linkC cannot see and which may not be free. Continue, Resume and a
                // restore open a new conversation instead (AppCoordinator.launch).
                continueArgs: [],
                resumeArgs: []
            )
        case .freebuff:
            return AgentDescriptor(
                kind: .freebuff,
                binaryName: "freebuff",
                defaultCandidatePaths: [
                    home.appendingPathComponent(".local/bin/freebuff"),
                    "/opt/homebrew/bin/freebuff",
                    "/usr/local/bin/freebuff"
                ],
                yoloFlags: [],
                continueArgs: ["--continue"],
                resumeArgs: ["--continue"]
            )
        case .shell:
            return AgentDescriptor(
                kind: .shell,
                binaryName: "zsh",
                defaultCandidatePaths: ["/bin/zsh", "/bin/bash"],
                yoloFlags: [],
                continueArgs: [],
                resumeArgs: []
            )
        }
    }

    /// Build CLI arguments for launching the specified agent in `mode`. For Codex, `sessionId`
    /// also names the session to linkC's tool server: Codex serves every terminal's MCP servers
    /// from one shared daemon, so the server can't find its session by walking up the process
    /// tree. The override goes before `resume`, like every other flag.
    public static func arguments(for kind: AgentKind, mode: LaunchMode, sessionId: String? = nil) -> [String] {
        let desc = descriptor(for: kind)
        var args = desc.yoloFlags
        if kind == .codex, let sessionId {
            args += ["-c", "mcp_servers.\(MCPRegistrar.serverName).env.LINKC_SESSION=\"\(sessionId)\""]
        }
        switch mode {
        case .new:
            break
        case .continueLast:
            args.append(contentsOf: desc.continueArgs)
        case .resume:
            args.append(contentsOf: desc.resumeArgs)
        }
        return args
    }

    /// The name of Grok's own Cursor folder in the user's home.
    public static let grokConfigFolderName = ".cursor-grok"

    /// Grok's own Cursor folder: its chats and its saved default model, kept out of `~/.cursor`.
    /// Cursor's CLI saves every `--model` it is given as its default, so without this folder each
    /// Grok launch would move the user's own Cursor default to Grok.
    public static func grokConfigDirectory(home: URL) -> URL {
        home.appendingPathComponent(grokConfigFolderName, isDirectory: true)
    }

    /// The variable that keeps OpenCode from opening on its "Update Available" dialog.
    public static let openCodeAutoUpdateKey = "OPENCODE_DISABLE_AUTOUPDATE"

    /// The variable OpenCode reads inline config from, merged over its `opencode.json`.
    public static let openCodeConfigContentKey = "OPENCODE_CONFIG_CONTENT"

    /// What `kind`'s terminal needs beyond `LINKC_SESSION`. Grok: its own Cursor folder, and the
    /// mark linkC's tool server reads to tell it from Cursor. OpenCode: no update dialog — with a
    /// newer release out, OpenCode opens on one, and the first text linkC types (a worker's task)
    /// would answer it. linkC adds OpenCode's inline tool config at launch (AppCoordinator+OpenCode).
    public static func environment(for kind: AgentKind, home: URL) -> [String: String] {
        switch kind {
        case .grok:
            return [
                "CURSOR_CONFIG_DIR": grokConfigDirectory(home: home).path,
                AgentKind.workerEnvironmentKey: AgentKind.grok.rawValue
            ]
        case .opencode:
            return [openCodeAutoUpdateKey: "1"]
        default:
            return [:]
        }
    }

    /// Resolve an absolute executable path on disk for the agent.
    public static func resolveExecutable(for kind: AgentKind, fileManager: FileManager = .default) -> String? {
        let desc = descriptor(for: kind)
        for path in desc.defaultCandidatePaths {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
