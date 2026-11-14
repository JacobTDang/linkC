import Foundation

/// How linkC names an OpenCode conversation so it can reopen exactly that one, and how it reads
/// OpenCode's own answers about a conversation. Verified against OpenCode 2.2.5:
/// - `--session <id>` reopens the conversation, or creates it under that id on its first message.
///   The id must start with "ses".
/// - A reopened conversation runs on the model it last used, ahead of the model linkC pins in
///   `OPENCODE_CONFIG_CONTENT`. So linkC reads that model (`session export`) before reopening it.
/// - `session list` lists the whole project (every worktree of a repo), newest first.
public enum OpenCodeConversations {
    /// A conversation id OpenCode accepts, marked as linkC's.
    public static func newId() -> String {
        "ses_linkc" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The flags that open (or create) the conversation `conversationId`.
    public static func launchArguments(conversationId: String) -> [String] {
        ["--session", conversationId]
    }

    /// `session export` without the transcript text: linkC reads only the model.
    static func exportArguments(conversationId: String) -> [String] {
        ["session", "export", conversationId, "--standalone", "--sanitize"]
    }

    /// The project's conversations, on a private server so that the lookup never starts
    /// OpenCode's shared background service.
    static let listArguments = ["session", "list", "--standalone", "--format", "json"]

    /// The model the conversation last ran on, as linkC writes it: "provider/id".
    static func model(fromExport json: String) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let info = (object as? [String: Any])?["info"] as? [String: Any],
              let model = info["model"] as? [String: Any],
              let provider = model["providerID"] as? String, !provider.isEmpty,
              let id = model["id"] as? String, !id.isEmpty else {
            throw LinkCError.process("`opencode session export` gave no model for the conversation")
        }
        return "\(provider)/\(id)"
    }

    /// The ids in `session list --format json` whose folder is `folder`, in the list's order
    /// (newest first).
    static func ids(fromList json: String, in folder: String) throws -> [String] {
        guard let entries = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else {
            throw LinkCError.process("`opencode session list` did not print a JSON list")
        }
        let wanted = ProjectPath.canonical(folder)
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, let directory = entry["directory"] as? String,
                  ProjectPath.canonical(directory) == wanted else { return nil }
            return id
        }
    }

    /// True when `session export` failed only because OpenCode has no such conversation: a
    /// conversation linkC named that never got a message.
    static func isMissing(_ result: ProcessResult) -> Bool {
        result.status != 0 && result.stderr.contains("Session not found")
    }
}

/// What linkC asks OpenCode before it reopens a conversation. A seam: tests answer for OpenCode.
public struct OpenCodeConversationReader: Sendable {
    /// The model the conversation last ran on ("opencode/big-pickle"), or nil when OpenCode has no
    /// conversation with that id. Throws when OpenCode cannot answer.
    public var model: @Sendable (_ conversationId: String, _ folder: String) throws -> String?
    /// The folder's conversations, newest first. Throws when OpenCode cannot answer.
    public var conversations: @Sendable (_ folder: String) throws -> [String]

    public init(model: @escaping @Sendable (String, String) throws -> String?,
                conversations: @escaping @Sendable (String) throws -> [String]) {
        self.model = model
        self.conversations = conversations
    }

    /// For a coordinator that was given no reader: every question fails, saying so.
    public static let unavailable = OpenCodeConversationReader(
        model: { _, _ in throw LinkCError.process("linkC cannot read OpenCode's conversations here") },
        conversations: { _ in throw LinkCError.process("linkC cannot read OpenCode's conversations here") })

    /// Asks the installed `opencode`. Each lookup takes a fraction of a second; `timeout` bounds a
    /// stalled one.
    public static func live(timeout: TimeInterval) -> OpenCodeConversationReader {
        OpenCodeConversationReader(
            model: { id, folder in
                let result = try run(OpenCodeConversations.exportArguments(conversationId: id), in: folder, timeout: timeout)
                if OpenCodeConversations.isMissing(result) { return nil }
                return try OpenCodeConversations.model(fromExport: try output(of: result, command: "session export"))
            },
            conversations: { folder in
                let result = try run(OpenCodeConversations.listArguments, in: folder, timeout: timeout)
                return try OpenCodeConversations.ids(fromList: try output(of: result, command: "session list"), in: folder)
            })
    }

    private static func run(_ args: [String], in folder: String, timeout: TimeInterval) throws -> ProcessResult {
        guard let executable = AgentDescriptor.resolveExecutable(for: .opencode) else {
            throw LinkCError.process("Executable for \(AgentKind.opencode.pillText) not found")
        }
        do {
            return try LiveProcessRunner.runCapturingSync(
                executable: executable, args: args, cwd: URL(fileURLWithPath: folder),
                env: AgentDescriptor.environment(for: .opencode, home: FileManager.default.homeDirectoryForCurrentUser),
                timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            throw LinkCError.process("`opencode \(args.prefix(2).joined(separator: " "))` did not answer within \(seconds) seconds")
        }
    }

    private static func output(of result: ProcessResult, command: String) throws -> String {
        guard result.status == 0 else {
            throw LinkCError.process("`opencode \(command)` exited \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }
}
