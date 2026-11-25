import Foundation

/// The step a Cursor or Grok turn is on, read from the end of the chat's transcript: a JSONL file
/// the agent appends to as it works, with a line per message `{role, message: {content: [...]}}` and
/// a `{type: "turn_ended"}` line when a turn finishes. It records a tool when the agent starts it and
/// never what came of it, so the step is the last tool started in the turn, not a tool still running.
enum CursorTranscriptStep {
    private static let fileTools: Set<String> = ["Read", "ReadFile", "Write", "StrReplace", "Delete"]
    private static let labelLimit = 60

    /// The step of the turn the transcript ends in, or nil when the turn is over or has started no
    /// tool yet. Only the last `tailBytes` of the file are read; a line being written is passed over.
    static func label(inTranscriptAt url: URL, tailBytes: Int) throws -> String? {
        for line in try lastLines(of: url, tailBytes: tailBytes).reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                throw LinkCError.parse("a line of \(url.path) is not JSON")
            }
            if object["type"] as? String == "turn_ended" || object["role"] as? String == "user" { return nil }
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if let tool = content.last(where: { $0["type"] as? String == "tool_use" }) {
                return label(tool: tool["name"] as? String ?? "", input: tool["input"] as? [String: Any] ?? [:])
            }
        }
        return nil
    }

    static func label(tool name: String, input: [String: Any]) -> String {
        let label: String
        if name == "Shell", let command = input["command"] as? String,
           let first = command.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }) {
            label = "$ " + first.trimmingCharacters(in: .whitespaces)
        } else if fileTools.contains(name), let path = input["path"] as? String, !path.isEmpty {
            label = "\(name) \(URL(fileURLWithPath: path).lastPathComponent)"
        } else {
            label = name
        }
        return label.count > labelLimit ? String(label.prefix(labelLimit - 1)) + "…" : label
    }

    /// The complete lines in the last `tailBytes` of the file. The window starts one byte early, so
    /// its first piece is the end of a line it cut into, or nothing when it began on a line: either
    /// way it is dropped. A last line with no newline after it is kept only when it parses: it may
    /// be the line the agent is writing now.
    private static func lastLines(of url: URL, tailBytes: Int) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try handle.seek(toOffset: start == 0 ? 0 : start - 1)
        let bytes = [UInt8](try handle.readToEnd() ?? Data())

        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        if start > 0 { lines.removeFirst() }
        if bytes.last != 0x0A, let last = lines.last,
           (try? JSONSerialization.jsonObject(with: Data(last))) == nil {
            lines.removeLast()
        }
        return lines.filter { !$0.isEmpty }.map { String(decoding: $0, as: UTF8.self) }
    }
}
