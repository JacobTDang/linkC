import Foundation

/// The AI CLI agent (or general interactive shell) running in a session.
public enum AgentKind: String, Sendable, CaseIterable, Codable {
    case claude
    case agy
    case cursor
    case codex
    case shell

    /// Concise uppercase badge text for pills and cards.
    public var pillText: String {
        switch self {
        case .claude: return "CLAUDE"
        case .agy: return "AGY"
        case .cursor: return "CURSOR"
        case .codex: return "CODEX"
        case .shell: return "SHELL"
        }
    }

    /// The brand accent color hex string.
    public var brandColorHex: String {
        switch self {
        case .claude: return "#D97757"    // coral
        case .agy: return "#7AA2F7"       // gemini soft blue
        case .cursor: return "#00E5FF"    // cyan / neon
        case .codex: return "#10A37F"     // openAI emerald
        case .shell: return "#8E8E93"     // neutral grey
        }
    }
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
                yoloFlags: ["agent", "--yolo"],
                continueArgs: ["--continue"],
                resumeArgs: ["--resume"]
            )
        case .codex:
            return AgentDescriptor(
                kind: .codex,
                binaryName: "codex",
                defaultCandidatePaths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
                yoloFlags: ["--dangerously-bypass-approvals-and-sandbox"],
                continueArgs: ["resume", "--last"],
                resumeArgs: ["resume"]
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

    /// Build CLI arguments for launching the specified agent in `mode`.
    public static func arguments(for kind: AgentKind, mode: LaunchMode) -> [String] {
        let desc = descriptor(for: kind)
        var args = desc.yoloFlags
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
