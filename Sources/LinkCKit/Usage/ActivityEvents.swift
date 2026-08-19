import Foundation

/// "What is Claude doing right now?" — the most recent main-chain tool_use, formatted
/// for a one-line session row.
public struct CurrentActivity: Equatable, Sendable {
    public let toolUseId: String
    public let label: String

    public init(toolUseId: String, label: String) {
        self.toolUseId = toolUseId
        self.label = label
    }
}

/// Folds transcript lines (decoded via the shared `TranscriptLine`) into the session's
/// current activity. An assistant `tool_use` sets it and only the NEXT one replaces it —
/// a finished tool keeps its label through the thinking that follows (the last action
/// beats an absence; the turn-boundary sweep in the tracker is what wipes it). Sidechain
/// lines are skipped entirely — a subagent's inner Bash must not masquerade as the
/// session's own action.
public enum ActivityEvents {
    public static func apply(line: String, to current: CurrentActivity?) -> CurrentActivity? {
        guard let decoded = TranscriptLine.decode(line) else { return current }
        return apply(decoded, to: current)
    }

    /// The pre-decoded path — `UsageTracker` decodes each line once and feeds every
    /// consumer the same `TranscriptLine`.
    static func apply(_ decoded: TranscriptLine, to current: CurrentActivity?) -> CurrentActivity? {
        guard !decoded.isSidechain, case .blocks(let blocks) = decoded.content else { return current }

        var activity = current
        for block in blocks {
            if block.type == "tool_use", let id = block.id, let name = block.name {
                activity = CurrentActivity(toolUseId: id, label: label(tool: name, input: block.input))
            }
        }
        return activity
    }

    /// One-line row copy per tool. Claude's own description outranks raw arguments —
    /// "Reading the token block" beats the `cd …; sed …` it describes — except for
    /// subagents, which keep their ▸ mark. Then: the command, the touched file, or the
    /// bare tool name when there's nothing better to say.
    static func label(tool: String, input: TranscriptLine.Input?) -> String {
        if tool != "Agent", tool != "Task",
           let description = input?.description, !description.isEmpty {
            return description
        }
        switch tool {
        case "Bash":
            guard let command = input?.command?.split(separator: "\n").first.map(String.init),
                  !command.isEmpty else { return tool }
            return "$ \(command)"
        case "Edit", "Write", "NotebookEdit":
            // NotebookEdit carries its file under notebook_path, the others under file_path.
            guard let path = input?.filePath ?? input?.notebookPath else { return tool }
            return "✎ \((path as NSString).lastPathComponent)"
        case "Read":
            guard let path = input?.filePath else { return tool }
            return "⊙ \((path as NSString).lastPathComponent)"
        case "Agent", "Task":
            guard let description = input?.description else { return tool }
            return "▸ \(description)"
        default:
            return tool
        }
    }
}
