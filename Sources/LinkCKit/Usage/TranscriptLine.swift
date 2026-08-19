import Foundation

/// One decoded transcript line — the single tolerant decode `AgentEvents` and
/// `ActivityEvents` share. They had drifted into near-verbatim private copies of this
/// scaffolding, and `UsageTracker` was paying a separate JSON decode for each; now a
/// line is decoded once and both consumers read the same shape. (`TranscriptUsage`
/// stays separate deliberately: it reads pricing-critical usage fields with its own
/// battle-tested parser, and folding it in would risk the cost figures for no reader.)
struct TranscriptLine {
    let isSidechain: Bool
    let timestamp: Date?
    let content: Content

    enum Content {
        case text(String)
        case blocks([Block])
    }

    struct Block {
        let type: String?
        let id: String?
        let name: String?
        let text: String?
        let input: Input?
        let toolUseId: String?
        /// tool_result content, string-or-block-array joined to one string.
        let resultText: String?
    }

    struct Input {
        let command: String?
        let filePath: String?
        let notebookPath: String?
        let description: String?
        let subagentType: String?
    }

    /// Nil only for non-JSON. A missing message or content decodes as empty blocks;
    /// one malformed block is skipped alone (transcript shapes vary — the whole line's
    /// events must never die with one odd block).
    static func decode(_ line: String) -> TranscriptLine? {
        guard let data = line.data(using: .utf8),
              let raw = try? Self.decoder.decode(RawLine.self, from: data) else { return nil }
        let content: Content
        switch raw.message?.content {
        case .text(let text): content = .text(text)
        case .blocks(let blocks):
            content = .blocks(blocks.map {
                Block(
                    type: $0.type, id: $0.id, name: $0.name, text: $0.text,
                    input: $0.input.map {
                        Input(command: $0.command, filePath: $0.filePath,
                              notebookPath: $0.notebookPath, description: $0.description,
                              subagentType: $0.subagentType)
                    },
                    toolUseId: $0.toolUseId,
                    resultText: $0.content?.joinedText
                )
            })
        case nil: content = .blocks([])
        }
        return TranscriptLine(
            isSidechain: raw.isSidechain ?? false,
            timestamp: raw.timestamp.flatMap(parseTimestamp),
            content: content
        )
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    private static let decoder = JSONDecoder()

    // MARK: - Raw shapes

    private struct RawLine: Decodable {
        let isSidechain: Bool?
        let timestamp: String?
        let message: RawMessage?
    }

    private struct RawMessage: Decodable {
        let content: RawContent?
    }

    /// Content is a string OR a block array; blocks decode individually so one malformed
    /// block cannot erase the events beside it.
    private enum RawContent: Decodable {
        case text(String)
        case blocks([RawBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                let failables = (try? container.decode([FailableBlock].self)) ?? []
                self = .blocks(failables.compactMap(\.block))
            }
        }
    }

    /// Always decodes; `block` is nil when the element didn't match `RawBlock`. Wrapping
    /// each element keeps the array's decode cursor advancing past bad entries.
    private struct FailableBlock: Decodable {
        let block: RawBlock?

        init(from decoder: Decoder) throws {
            block = try? RawBlock(from: decoder)
        }
    }

    private struct RawBlock: Decodable {
        let type: String?
        let id: String?
        let name: String?
        let text: String?
        let input: RawInput?
        let toolUseId: String?
        let content: RawResultPayload?

        enum CodingKeys: String, CodingKey {
            case type, id, name, text, input, content
            case toolUseId = "tool_use_id"
        }
    }

    private struct RawInput: Decodable {
        let command: String?
        let filePath: String?
        let notebookPath: String?
        let description: String?
        let subagentType: String?

        enum CodingKeys: String, CodingKey {
            case command, description
            case filePath = "file_path"
            case notebookPath = "notebook_path"
            case subagentType = "subagent_type"
        }
    }

    /// tool_result content: a block array in most transcripts, a bare string in some.
    private enum RawResultPayload: Decodable {
        case text(String)
        case blocks([RawResultContent])

        var joinedText: String {
            switch self {
            case .text(let string): return string
            case .blocks(let blocks): return blocks.compactMap(\.text).joined(separator: "\n")
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([RawResultContent].self))
            }
        }
    }

    private struct RawResultContent: Decodable {
        let text: String?
    }
}
