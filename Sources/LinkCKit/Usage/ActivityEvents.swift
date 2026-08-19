import Foundation

/// "What is Claude doing right now?" — the most recent main-chain tool_use that hasn't
/// seen its tool_result yet, formatted for a one-line session row.
public struct CurrentActivity: Equatable, Sendable {
    public let toolUseId: String
    public let label: String

    public init(toolUseId: String, label: String) {
        self.toolUseId = toolUseId
        self.label = label
    }
}

/// Folds transcript lines into the session's current activity. An assistant `tool_use`
/// sets it; a `tool_result` matching the recorded id clears it (thinking between tools
/// shows nothing, never a stale command); a newer `tool_use` simply replaces. Sidechain
/// lines are skipped entirely — a subagent's inner Bash must not masquerade as the
/// session's own action — and malformed blocks are skipped alone (the same tolerance as
/// `AgentEvents`, and for the same reason: transcript shapes vary).
public enum ActivityEvents {
    public static func apply(line: String, to current: CurrentActivity?) -> CurrentActivity? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawLine.self, from: data),
              raw.isSidechain != true,
              case .blocks(let blocks) = raw.message?.content else { return current }

        var activity = current
        for block in blocks {
            if block.type == "tool_use", let id = block.id, let name = block.name {
                activity = CurrentActivity(toolUseId: id, label: label(tool: name, input: block.input))
            }
            if block.type == "tool_result", let id = block.toolUseId, id == activity?.toolUseId {
                activity = nil
            }
        }
        return activity
    }

    /// One-line row copy per tool: the command itself, the touched file, the subagent's
    /// description — or the bare tool name when there's nothing better to say.
    static func label(tool: String, input: RawInput?) -> String {
        switch tool {
        case "Bash":
            guard let command = input?.command?.split(separator: "\n").first.map(String.init),
                  !command.isEmpty else { return tool }
            return "$ \(command)"
        case "Edit", "Write", "NotebookEdit":
            guard let path = input?.filePath else { return tool }
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

    // MARK: - Raw shapes (same tolerance discipline as AgentEvents)

    private struct RawLine: Decodable {
        let isSidechain: Bool?
        let message: RawMessage?
    }

    private struct RawMessage: Decodable {
        let content: RawContent?
    }

    /// Content is a string OR a block array; blocks decode individually so one malformed
    /// block cannot erase the events beside it.
    private enum RawContent: Decodable {
        case text
        case blocks([RawBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if (try? container.decode(String.self)) != nil {
                self = .text
            } else {
                let failables = (try? container.decode([FailableBlock].self)) ?? []
                self = .blocks(failables.compactMap(\.block))
            }
        }
    }

    private struct FailableBlock: Decodable {
        let block: RawBlock?

        init(from decoder: Decoder) throws {
            block = try? RawBlock(from: decoder)
        }
    }

    struct RawBlock: Decodable {
        let type: String?
        let id: String?
        let name: String?
        let input: RawInput?
        let toolUseId: String?

        enum CodingKeys: String, CodingKey {
            case type, id, name, input
            case toolUseId = "tool_use_id"
        }
    }

    struct RawInput: Decodable {
        let command: String?
        let filePath: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case command, description
            case filePath = "file_path"
        }
    }
}
