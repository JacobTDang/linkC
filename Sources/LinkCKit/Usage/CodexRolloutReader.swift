import Foundation

/// What a Codex session's own rollout (`~/.codex/sessions/…/rollout-*.jsonl`) says about it: how full
/// its context is, and the step a running turn is on. The session is tied to its rollout by the file
/// its Codex process holds open, never by folder or start time.
public struct CodexRolloutReader: SessionLiveReader {
    /// How much of the rollout's end is read: the newest token count and the running turn's last
    /// tool call are near it.
    public static let tailBytes = 1 << 20

    public init() {}

    public func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail {
        // The newest, should a process hold more than one: rollout names begin with their start time.
        guard let path = target.openFiles.filter(Self.isRollout).max() else { return SessionLiveDetail() }
        return Self.detail(fromLines: try Self.tailLines(of: path))
    }

    static func isRollout(_ path: String) -> Bool {
        path.contains("/.codex/sessions/") && (path as NSString).lastPathComponent.hasPrefix("rollout-")
            && path.hasSuffix(".jsonl")
    }

    /// The last `tailBytes` of the file as lines, the first dropped when the read began mid-line.
    static func tailLines(of path: String) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private struct Line: Decodable {
        let type: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let name: String?
        let input: String?
        let arguments: String?
        let info: Info?
    }

    private struct Info: Decodable {
        struct Usage: Decodable { let total_tokens: Int? }
        let last_token_usage: Usage?
        let model_context_window: Int?
    }

    /// The context from the newest token count; the step from the last tool call after the newest
    /// turn start, unless that turn has ended.
    static func detail(fromLines lines: [String]) -> SessionLiveDetail {
        var contextPercent: Int?
        var step: String?
        var stepSeen = false
        for line in lines.reversed() {
            guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)), let payload = decoded.payload else { continue }
            switch (decoded.type, payload.type) {
            case ("event_msg", "token_count"):
                if contextPercent == nil, let used = payload.info?.last_token_usage?.total_tokens,
                   let window = payload.info?.model_context_window, window > 0 {
                    contextPercent = footerPercent(used: used, window: window)
                }
            case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
                // The newest turn is over: no tool call before this is a running step.
                stepSeen = true
            case ("event_msg", "task_started"):
                stepSeen = true
            case ("response_item", "custom_tool_call"), ("response_item", "function_call"):
                if !stepSeen {
                    step = label(name: payload.name, input: payload.input, arguments: payload.arguments)
                    stepSeen = true
                }
            default:
                break
            }
            if contextPercent != nil, stepSeen { break }
        }
        return SessionLiveDetail(contextPercent: contextPercent, step: step)
    }

    /// The tokens Codex counts as always in the context: prompts, tools, and room to compact.
    static let baselineTokens = 12_000

    /// How full the context is, as Codex's own footer shows it (codex-rs 0.163.0,
    /// `TokenUsage::percent_of_context_window_remaining`): the baseline comes off both the tokens
    /// used and the window, what is left is rounded, and the figure is 100 less that. A window no
    /// bigger than the baseline leaves nothing.
    static func footerPercent(used: Int, window: Int) -> Int {
        guard window > baselineTokens else { return 100 }
        let effective = Double(window - baselineTokens)
        let inUse = Double(max(0, used - baselineTokens))
        // `rounded()` rounds a half away from zero, as Rust's `f64::round` does.
        let left = (max(0, effective - inUse) / effective * 100).rounded()
        return 100 - Int(min(100, max(0, left)))
    }

    /// One line for a tool call, in the style of a Claude session's: a command by its first line, an
    /// edit by its file, a code-mode call by the first tool it calls.
    static func label(name: String?, input: String?, arguments: String?) -> String? {
        guard let name else { return nil }
        let args = arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        switch name {
        case "exec":
            // Code mode: JavaScript that calls Codex's tools.
            guard let code = input else { return nil }
            return codeLabel(code) ?? "Running code"
        case "js":
            if let title = (args["title"] as? String).map(firstLine), !title.isEmpty { return title }
            return "Running code"
        case "exec_command":
            return (args["cmd"] as? String).map { "$ \(firstLine($0))" } ?? name
        case "shell":
            return (args["command"] as? [String]).map { "$ \(firstLine($0.joined(separator: " ")))" } ?? name
        case "apply_patch":
            return patchLabel(input ?? (args["input"] as? String) ?? "") ?? "Editing files"
        default:
            return toolLabel(name)
        }
    }

    /// The first tool a code-mode call uses, labelled as that tool's own call would be.
    static func codeLabel(_ code: String) -> String? {
        guard let call = code.firstMatch(of: /tools\.([A-Za-z0-9_]+)\(/) else { return nil }
        let tool = String(call.1)
        let rest = String(code[call.range.upperBound...])
        switch tool {
        case "exec_command":
            guard let cmd = rest.firstMatch(of: /cmd\s*:\s*"((?:\\.|[^"\\])*)"/) else { return "$ …" }
            return "$ \(firstLine(unescape(String(cmd.1))))"
        case "apply_patch":
            return patchLabel(unescape(rest)) ?? "Editing files"
        case "write_stdin":
            return "Writing to a running command"
        default:
            return toolLabel(tool)
        }
    }

    /// An MCP tool by its own name, any other by its name.
    private static func toolLabel(_ tool: String) -> String {
        tool.hasPrefix("mcp__") ? "Using \(tool.components(separatedBy: "__").last ?? tool)" : tool
    }

    /// The first file a patch touches, by name.
    private static func patchLabel(_ patch: String) -> String? {
        guard let file = patch.firstMatch(of: /\*\*\* (?:Update|Add|Delete) File: ([^\n"\\]+)/) else { return nil }
        let path = String(file.1).trimmingCharacters(in: .whitespaces)
        return "✎ \((path as NSString).lastPathComponent)"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// A JavaScript string literal's common escapes, enough to read a command.
    private static func unescape(_ literal: String) -> String {
        literal.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
