import Foundation

/// Who is calling the tool, resolved from the posting process — never assumed.
public struct MCPCaller: Sendable {
    public let agent: AgentKind
    public let pid: pid_t
    public var isIdentified: Bool { agent != .shell }
}

/// Caches the ancestor-walk session lookup for the life of the process: a process's ancestry
/// never changes while it runs, so re-walking `sysctl`'s `KERN_PROCARGS2` on every guarded tool
/// call for the life of a long-running `linkc-mcp` process would be wasted work. Only
/// `MCPServer`'s *default* `sessionResolver` goes through this cache — a resolver a caller
/// injects (every test, and any future caller that wants a fresh read) bypasses it entirely.
public enum AncestorSessionCache {
    /// The real walk. `value`'s `static let` memoizes whatever this returns the first time it is
    /// read, via Swift's thread-safe one-time static initialization — no hand-rolled locking
    /// needed for that part. `walk` itself is `nonisolated(unsafe)` only because a mutable global
    /// needs an escape from strict concurrency checking; production code never reassigns it, and
    /// a test may reassign it solely to stand in for the real walk *before* first touching
    /// `value`, letting it count invocations without reading real processes — `@testable import`
    /// reaches it despite `internal`, so it need not be `public` itself. `value` is `public`
    /// because `MCPServer.init` is public and its default `sessionResolver` argument reads it
    /// directly, which Swift requires to be at least as visible as the initializer.
    nonisolated(unsafe) static var walk: @Sendable () -> String? = {
        ProcessSnooper.sessionId(inAncestorsOf: getpid())
    }
    public static let value: String? = walk()
}

/// Pure-Swift Model Context Protocol (MCP) server speaking JSON-RPC 2.0.
public final class MCPServer: Sendable {
    public typealias ModelSwitcher = @Sendable (_ agent: AgentKind, _ model: String) throws -> String
    public typealias AncestorResolver = @Sendable (_ pid: pid_t) -> (agent: AgentKind, pid: pid_t)?
    public typealias ModelSettingsProvider = @Sendable () -> AgentModelSettings
    public typealias SessionResolver = @Sendable () -> String?
    public typealias UsageReader = @Sendable () -> AgentUsage

    public let workspaceRoot: String
    public let store: BlackboardStore
    public let inboxStore: InboxStore
    public let modelSwitcher: ModelSwitcher?
    public let environment: [String: String]
    public let ancestorResolver: AncestorResolver
    /// Falls back to an ancestor's real environment when ours has no `LINKC_SESSION` — Codex
    /// launches its MCP servers with only `LINKC_AGENT` in the registration's `env` block, so the
    /// session id never reaches `environment` there even though the Codex CLI process has it.
    /// The default resolver reads `AncestorSessionCache`, so the real ancestor walk runs at most
    /// once per process; an injected resolver (every test) bypasses that cache entirely.
    public let sessionResolver: SessionResolver
    /// Read fresh on every call, never cached: `linkc-mcp` builds one `MCPServer` for the life
    /// of the CLI process, so a stored value would freeze the mapping at startup and make the
    /// "set it in linkC settings" refusal a lie — an edit would never take effect. Mirrors how
    /// `AppCoordinator` reads its own copy of the same settings.
    public let modelSettings: ModelSettingsProvider
    /// What each agent has left, read from that agent's own records. Keyed by agent so a test
    /// can inject exactly the agents it cares about and leave the rest absent — an absent key
    /// renders as "no usage reader configured" rather than falling back to a real reader.
    public let usageReaders: [AgentKind: UsageReader]
    /// Agents whose registered reader can actually trigger a delegation warning. Declared as
    /// data, next to `usageReaders`, rather than as a hard-coded agent check in the delegate
    /// handler: the handler must consult this set, never an identity check, so that whether a
    /// reader can warn is decided once, where readers are registered, and stays correct even if
    /// a different reader is swapped in for an agent later.
    public let warnCapableAgents: Set<AgentKind>

    /// Tools an unidentified caller may still use.
    public static let readOnlyTools: Set<String> = [
        "linkc_get_project_context", "linkc_check_conflicts", "linkc_get_inbox",
        "linkc_get_task", "linkc_get_models", "linkc_get_usage_status", "linkc_get_board"
    ]

    /// Tools whose `agent` argument is a target/filter rather than the caller's identity.
    public static let targetAgentTools: Set<String> = ["linkc_switch_model", "linkc_get_models"]

    public static let unidentifiedCallerMessage =
        "Cannot identify calling agent; pass agent: \"claude\" | \"agy\" | \"cursor\" | \"codex\"."

    public init(
        workspaceRoot: String,
        store: BlackboardStore? = nil,
        inboxStore: InboxStore? = nil,
        modelSwitcher: ModelSwitcher? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ancestorResolver: @escaping AncestorResolver = { ProcessSnooper.detectAgent(inAncestorsOf: $0) },
        modelSettings: @escaping ModelSettingsProvider = { AgentModelStore.applicationSupport.load() },
        sessionResolver: @escaping SessionResolver = { AncestorSessionCache.value },
        usageReaders: [AgentKind: UsageReader] = MCPServer.defaultUsageReaders(),
        warnCapableAgents: Set<AgentKind> = MCPServer.defaultWarnCapableAgents
    ) {
        self.workspaceRoot = (workspaceRoot as NSString).standardizingPath
        self.store = store ?? BlackboardStore(workspaceRoot: workspaceRoot)
        self.inboxStore = inboxStore ?? InboxStore(workspaceRoot: workspaceRoot)
        self.modelSwitcher = modelSwitcher
        self.environment = environment
        self.ancestorResolver = ancestorResolver
        self.modelSettings = modelSettings
        self.sessionResolver = sessionResolver
        self.usageReaders = usageReaders
        self.warnCapableAgents = warnCapableAgents
    }

    /// The real readers, wired to each agent's own on-disk records. `agy` and `cursor` write
    /// none, so they report why rather than guessing. Building this only constructs the reader
    /// values (cheap URL arithmetic); the home directory itself is touched solely when a
    /// reader's `read()` actually runs.
    public static func defaultUsageReaders() -> [AgentKind: UsageReader] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codex = CodexUsageReader(sessionsDirectory: home.appendingPathComponent(".codex/sessions"))
        let claude = ClaudeUsageReader(projectsDirectory: home.appendingPathComponent(".claude/projects"))
        return [
            .codex: { codex.read() },
            .claude: { claude.read() },
            .agy: { .unavailable(.agy, reason: "agy writes no local session records") },
            .cursor: { .unavailable(.cursor, reason: "cursor writes no local session records") }
        ]
    }

    /// Agents whose reader in `defaultUsageReaders()` can warn a delegation: only the Codex
    /// reader's windows ever carry a `usedPercent`. The transcript usage reader's windows never
    /// do (Anthropic publishes no per-plan limit), so it is left out here rather than excluded by
    /// checking `toAgent == .claude` in the handler — that identity check would stay wrong
    /// forever if a percentage-reporting source were later registered for `.claude`. `agy` and
    /// `cursor` are absent from `defaultUsageReaders()` entirely and so cannot warn regardless.
    public static let defaultWarnCapableAgents: Set<AgentKind> = [.codex]

    /// Identity: explicit `agent` arg → `LINKC_AGENT` env → ancestor process → `.shell` (unidentified).
    func resolveCaller(_ args: [String: Any]) -> MCPCaller {
        let explicitPid = (args["pid"] as? Int).map { pid_t($0) }
        if let s = (args["agent"] as? String) ?? (args["from"] as? String),
           let kind = AgentKind(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           kind != .shell {
            return MCPCaller(agent: kind, pid: explicitPid ?? getppid())
        }
        if let env = environment["LINKC_AGENT"], let kind = AgentKind(rawValue: env.lowercased()), kind != .shell {
            return MCPCaller(agent: kind, pid: explicitPid ?? getppid())
        }
        if let found = ancestorResolver(getpid()) {
            return MCPCaller(agent: found.agent, pid: explicitPid ?? found.pid)
        }
        return MCPCaller(agent: .shell, pid: explicitPid ?? getppid())
    }

    /// The caller's linkC session: `LINKC_SESSION` env → `sessionResolver` (an ancestor's real
    /// environment). A caller whose registration never passed the variable down — Codex's MCP
    /// servers, notably — still resolves to the session its CLI process carries.
    private func callerSessionId() -> String? {
        if let session = environment["LINKC_SESSION"], !session.isEmpty { return session }
        return sessionResolver()
    }

    /// Processes a single JSON-RPC 2.0 message buffer and returns the response Data, or nil if no response is needed (e.g. notifications).
    public func handleMessage(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorResponse(id: nil, code: -32700, message: "Parse error")
        }

        let id = json["id"]
        guard let method = json["method"] as? String else {
            // Notifications or responses without method
            return nil
        }

        // Notifications don't receive responses per JSON-RPC spec
        if id == nil {
            return nil
        }

        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return handleInitialize(id: id)
        case "tools/list":
            return handleToolsList(id: id)
        case "tools/call":
            return handleToolsCall(id: id, params: params)
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleInitialize(id: Any?) -> Data? {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "linkc-multiplier",
                "version": "0.3.0"
            ]
        ]
        return successResponse(id: id, result: result)
    }

    private func handleToolsList(id: Any?) -> Data? {
        let tools: [[String: Any]] = [
            [
                "name": "linkc_broadcast_intent",
                "description": "Broadcast what task/goal you are currently working on and which files you intend to modify, checking for conflicts with peer agents.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "goal": ["type": "string", "description": "Goal or task description"],
                        "files": ["type": "array", "items": ["type": "string"], "description": "List of relative file paths to claim/modify"],
                        "agent": ["type": "string", "description": "Agent kind (claude, agy, cursor, codex, shell)"],
                        "pid": ["type": "integer", "description": "Process ID of the agent"],
                        "status": ["type": "string", "description": "Status: working, done, etc."]
                    ],
                    "required": ["goal"]
                ]
            ],
            [
                "name": "linkc_get_project_context",
                "description": "Get this project's system map — its components, how each is reached, and what exists versus what is only intended — plus all peer agents active in this workspace, their goals, claimed files, and shared notes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "linkc_get_board",
                "description": "Read this project's Board — its architecture (system, places, components, notes) as JSON, exactly as `system-map.json` holds it minus layout. Use the exact names it shows with linkc_edit_board.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "linkc_edit_board",
                "description": "Change this project's Board with a list of steps, applied in order, all or nothing. Verbs: add, update, remove, connect, disconnect, place, remove_place, note, remove_note, system. linkC places everything on the canvas; the user sees it live. When you add or change infrastructure (a service, database, cache, queue, host…), reflect it on the Board.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "items": ["type": "object"],
                            "description": "1 to 50 steps, applied in order, all or nothing. For example, to add a component: { \"add\": \"redis\", \"kind\": \"cache\", \"in\": \"Local docker\", \"does\": \"…\", \"reached_by\": \"…\", \"runs\": \"…\", \"planned\": true } — only \"add\" is required. To connect two components: { \"connect\": \"api\", \"to\": \"redis\", \"label\": \"session cache\" }."
                        ]
                    ],
                    "required": ["steps"]
                ]
            ],
            [
                "name": "linkc_check_conflicts",
                "description": "Check if specific files are currently claimed or being modified by another peer agent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "files": ["type": "array", "items": ["type": "string"], "description": "Files to check"],
                        "pid": ["type": "integer", "description": "Your process ID"]
                    ],
                    "required": ["files"]
                ]
            ],
            [
                "name": "linkc_post_note",
                "description": "Post a shared architectural note, finding, or task handoff for other peer agents in this project.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Note title"],
                        "content": ["type": "string", "description": "Markdown content"],
                        "agent": ["type": "string", "description": "Agent kind"],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Tags"]
                    ],
                    "required": ["title", "content"]
                ]
            ],
            [
                "name": "linkc_delegate_task",
                "description": "Delegate a coding task, subtask, or follow-up prompt to a peer agent (e.g. claude, agy, cursor, codex), claiming files and enqueuing the prompt for delivery.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Target agent kind (claude, agy, cursor, codex)"],
                        "prompt": ["type": "string", "description": "Task instructions and context to inject into recipient's terminal"],
                        "files": ["type": "array", "items": ["type": "string"], "description": "Optional list of files the delegated task will touch"],
                        "from": ["type": "string", "description": "Sender agent kind (optional, defaults to claude)"],
                        "pid": ["type": "integer", "description": "Process ID of the sender"],
                        "force": ["type": "boolean", "description": "Override an existing lease held by another assignee"],
                        "tier": ["type": "string", "description": "Model tier for this task: light, standard or deep. Defaults to the agent's configured default tier."],
                        "verify": [
                            "type": "object",
                            "description": "Make this a verified task. linkC confirms the tests fail at base_sha before delivery, then runs command at the worker's reported sha and decides done or failed itself.",
                            "properties": [
                                "branch": ["type": "string", "description": "Branch the worker commits on; its tip must equal base_sha"],
                                "base_sha": ["type": "string", "description": "Commit holding the tests you wrote"],
                                "command": ["type": "string", "description": "Shell command that runs those tests; exit 0 means they pass"],
                                "test_paths": ["type": "array", "items": ["type": "string"], "description": "Test files the worker must not modify"],
                                "timeout_seconds": ["type": "integer", "description": "1-3600, default 600"]
                            ],
                            "required": ["branch", "base_sha", "command", "test_paths"]
                        ]
                    ],
                    "required": ["to", "prompt"]
                ]
            ],
            [
                "name": "linkc_send_message",
                "description": "Send a direct message or peer note to another agent in the workspace.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Target agent kind (claude, agy, cursor, codex)"],
                        "message": ["type": "string", "description": "Message or note content to send"],
                        "from": ["type": "string", "description": "Sender agent kind (optional, defaults to claude)"]
                    ],
                    "required": ["to", "message"]
                ]
            ],
            [
                "name": "linkc_get_inbox",
                "description": "Get the current queue of pending messages, delivery status, and any active agent rate limits.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "linkc_switch_model",
                "description": "Switch the active model for an agent in the workspace using free/subscription tier models (injecting /model <model> into the agent's terminal).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent": ["type": "string", "description": "Agent kind (claude, agy, cursor, codex), defaults to claude"],
                        "model": ["type": "string", "description": "Model name (e.g. sonnet, haiku, opus, gpt-4o, o3-mini, pro, flash, flash_lite)"]
                    ],
                    "required": ["model"]
                ]
            ],
            [
                "name": "linkc_get_models",
                "description": "List all available free-tier and subscription-included models for an agent or all agents, indicating the default model and current rate-limit cooldowns.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent": ["type": "string", "description": "Agent kind (claude, agy, cursor, codex), optional"]
                    ]
                ]
            ],
            [
                "name": "linkc_get_usage_status",
                "description": "Report what each agent has left, read from that agent's own records: usage windows with percent-used or token counts, reset times, plan type, how old the reading is, and why nothing is known when it isn't — plus active rate limits recorded across the workspace.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "linkc_start_task",
                "description": "Acknowledge and start a task delivered to you (delivered → started). Call this first when you begin work on a [linkC task …] brief.",
                "inputSchema": ["type": "object", "properties": ["task_id": ["type": "string"]], "required": ["task_id"]]
            ],
            [
                "name": "linkc_complete_task",
                "description": "Report the result of a task you were assigned. Commit first and pass that commit's sha. For a verified task linkC runs the tests itself and tells the delegator the outcome in one line.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string"],
                        "status": ["type": "string", "enum": ["done", "failed"]],
                        "summary": ["type": "string", "description": "What changed, at most 1,000 characters"],
                        "sha": ["type": "string", "description": "The commit holding your work; required for a verified task reported done"],
                        "commits": ["type": "array", "items": ["type": "string"]],
                        "tests": ["type": "array", "items": ["type": "string"], "description": "Deprecated; ignored"]
                    ],
                    "required": ["task_id", "status", "summary"]
                ]
            ],
            [
                "name": "linkc_cancel_task",
                "description": "Cancel a task you delegated or were assigned. If it was already delivered, a one-line stop notice is injected into the assignee's terminal.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string"],
                        "reason": ["type": "string"],
                        "force": ["type": "boolean", "description": "Cancel a task you are neither delegator nor assignee of"]
                    ],
                    "required": ["task_id"]
                ]
            ],
            [
                "name": "linkc_get_task",
                "description": "Fetch the full record of a task by id: state, full brief, files, report.",
                "inputSchema": ["type": "object", "properties": ["task_id": ["type": "string"]], "required": ["task_id"]]
            ],
            [
                "name": "linkc_my_tasks",
                "description": "List open tasks assigned to you, then open tasks you delegated, one line each.",
                "inputSchema": ["type": "object", "properties": [:]]
            ]
        ]
        return successResponse(id: id, result: ["tools": tools])
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) -> Data? {
        guard let name = params["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let identityArgs = Self.targetAgentTools.contains(name) ? args.filter { $0.key != "agent" } : args
        let caller = resolveCaller(identityArgs)
        if !caller.isIdentified && !Self.readOnlyTools.contains(name) {
            return toolResultResponse(id: id, text: Self.unidentifiedCallerMessage, isError: true)
        }
        if caller.isIdentified {
            try? store.heartbeat(agentKind: caller.agent, pid: caller.pid)
        }

        do {
            switch name {
            case "linkc_broadcast_intent":
                let goal = args["goal"] as? String ?? "Working"
                let files = args["files"] as? [String] ?? []
                let status = args["status"] as? String ?? "working"

                let warnings = try store.broadcastIntent(
                    agentKind: caller.agent,
                    pid: caller.pid,
                    goal: goal,
                    files: files,
                    status: status
                )

                var responseText = "Intent recorded: '\(goal)' for \(caller.agent.displayName) (PID \(caller.pid)). Claimed \(files.count) files."
                if !warnings.isEmpty {
                    responseText += "\n\n⚠️ Collision Warnings:"
                    for w in warnings {
                        responseText += "\n- Agent '\(w.conflictingAgent.displayName)' (PID \(w.pid)) is also working on: \(w.conflictingFiles.joined(separator: ", ")) (Goal: '\(w.goal)')"
                    }
                }

                return toolResultResponse(id: id, text: responseText)

            case "linkc_check_conflicts":
                let files = args["files"] as? [String] ?? []
                let pid: pid_t? = (args["pid"] as? Int).map { pid_t($0) } ?? (caller.isIdentified ? caller.pid : nil)
                let warnings = try store.checkConflicts(files: files, excludingPid: pid)

                if warnings.isEmpty {
                    return toolResultResponse(id: id, text: "Clean: No conflicts detected on \(files.count) files.")
                } else {
                    var responseText = "⚠️ Collision Warnings detected:"
                    for w in warnings {
                        responseText += "\n- Agent '\(w.conflictingAgent.displayName)' (PID \(w.pid)) has claimed: \(w.conflictingFiles.joined(separator: ", ")) (Goal: '\(w.goal)')"
                    }
                    return toolResultResponse(id: id, text: responseText)
                }

            case "linkc_post_note":
                let title = args["title"] as? String ?? "Note"
                let content = args["content"] as? String ?? ""
                let tags = args["tags"] as? [String] ?? []

                let note = try store.postNote(
                    authorAgent: caller.agent,
                    title: title,
                    content: content,
                    tags: tags
                )
                return toolResultResponse(id: id, text: "Shared note posted: '\(note.title)' (ID: \(note.id))")

            case "linkc_get_project_context":
                let board = try store.getProjectContext()
                var text = "# Project Shared Context: \(board.projectPath)\n"
                text += "Active Agents: \(board.activeAgents.count)\n\n"

                if board.activeAgents.isEmpty {
                    text += "_No other active agents currently recorded._\n\n"
                } else {
                    text += "## Active Peer Agents\n"
                    for a in board.activeAgents {
                        text += "- **\(a.agentKind.displayName)** (PID \(a.pid)) — \(a.status)\n"
                        text += "  - Goal: \(a.goal)\n"
                        if !a.claimedFiles.isEmpty {
                            text += "  - Claimed Files: \(a.claimedFiles.joined(separator: ", "))\n"
                        }
                    }
                    text += "\n"
                }

                if !board.sharedNotes.isEmpty {
                    text += "## Shared Notes & Decisions\n"
                    for n in board.sharedNotes {
                        text += "### \(n.title) (by \(n.authorAgent.displayName))\n"
                        text += "\(n.content)\n\n"
                    }
                }

                // The project's own map of its components, when it keeps one. A map that cannot be read
                // says so: an agent must not be told a project has no components when it has a broken file.
                do {
                    if let loaded = try BoardMapStore(workspacePath: board.projectPath).load() {
                        text += BoardReport.markdown(for: loaded.map)
                        text += "Read with `linkc_get_board`; change with `linkc_edit_board`.\n\n"
                    } else {
                        text += "## System\n_No map yet — `linkc_edit_board` starts one._\n\n"
                    }
                } catch {
                    // The message can carry a name straight from the file — sanitized the same
                    // way every other field in this report is, since it lands in markdown too.
                    text += "## System\n_The system map could not be read: \(BoardReport.sanitized(error.localizedDescription))_\n\n"
                }

                return toolResultResponse(id: id, text: text)

            case "linkc_get_board":
                do {
                    guard let loaded = try BoardMapStore(workspacePath: workspaceRoot).load() else {
                        return toolResultResponse(id: id, text: "This project has no map yet — linkc_edit_board creates one.")
                    }
                    let text = try loaded.map.architectureJSON()
                        + "\n\nVerbs: add, update, remove, connect, disconnect, place, remove_place, note, remove_note, system. "
                        + "Kinds: service, database, cache, queue, storage, host, external (any other kind is kept and drawn as a service)."
                    return toolResultResponse(id: id, text: text)
                } catch {
                    return toolResultResponse(id: id, text: BoardReport.sanitized(error.localizedDescription), isError: true)
                }

            case "linkc_edit_board":
                do {
                    let steps = try BoardEdit.steps(from: args["steps"])
                    let lines = try Self.editBoard(store: BoardMapStore(workspacePath: workspaceRoot), steps: steps)
                    return toolResultResponse(id: id, text: lines.joined(separator: "\n") + "\nBoard updated.")
                } catch let refusal as BoardEditRefusal {
                    return toolResultResponse(id: id, text: refusal.description, isError: true)
                } catch {
                    return toolResultResponse(id: id, text: BoardReport.sanitized(error.localizedDescription), isError: true)
                }

            case "linkc_delegate_task":
                guard let toStr = args["to"] as? String, !toStr.isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'to'.", isError: true)
                }
                guard let toAgent = AgentKind(rawValue: toStr.lowercased()) else {
                    return toolResultResponse(id: id, text: "Error: Unknown agent '\(toStr)'. Supported agents: claude, agy, cursor, codex.", isError: true)
                }
                guard toAgent != .shell else {
                    return toolResultResponse(id: id, text: "Error: Cannot delegate tasks to interactive terminal shell. Target an AI CLI agent (claude, codex, agy, cursor).", isError: true)
                }
                guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'prompt'.", isError: true)
                }

                // Check if recipient is currently in a rate-limit cooldown
                do {
                    if let limitStatus = try inboxStore.isAgentLimited(agent: toAgent) {
                        let peerCandidates: [AgentKind] = [.claude, .agy, .cursor, .codex].filter { $0 != toAgent }
                        var availablePeers: [String] = []
                        for peer in peerCandidates {
                            if (try inboxStore.isAgentLimited(agent: peer)) == nil {
                                availablePeers.append(peer.rawValue)
                            }
                        }
                        let peerListStr = availablePeers.isEmpty ? "none" : availablePeers.joined(separator: ", ")
                        let errorMsg = "Cannot delegate to '\(toAgent.rawValue)': agent is currently in limit cooldown (reason: \(limitStatus.reason)). Alternative available peer agents: \(peerListStr)."
                        return toolResultResponse(id: id, text: errorMsg, isError: true)
                    }
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

                let files = args["files"] as? [String] ?? []
                let force = args["force"] as? Bool ?? false

                var verification: Verification?
                switch args["verify"] {
                case nil, is NSNull:
                    break
                case let verify as [String: Any]:
                    do {
                        verification = try resolveVerification(verify)
                    } catch {
                        return toolResultResponse(id: id, text: "Error: \(error.localizedDescription)", isError: true)
                    }
                default:
                    return toolResultResponse(id: id, text: "Error: verify must be an object.", isError: true)
                }

                // Read once per request: a stable view of the mapping for the whole handler,
                // never cached across calls — the next request reads whatever is on disk then.
                let settings = modelSettings()
                // A non-string `tier` is malformed and refused outright; a string is trimmed and,
                // if empty or all whitespace, treated the same as an absent argument.
                let tierArg: String?
                if let raw = args["tier"] {
                    guard let text = raw as? String else {
                        return toolResultResponse(id: id, text: "Error: tier must be light, standard or deep.", isError: true)
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    tierArg = trimmed.isEmpty ? nil : trimmed
                } else {
                    tierArg = nil
                }
                let tier: ModelTier?
                if let tierArg {
                    guard let parsed = ModelTier(rawValue: tierArg.lowercased()) else {
                        return toolResultResponse(id: id, text: "Error: tier must be light, standard or deep.", isError: true)
                    }
                    guard toAgent != .cursor else {
                        return toolResultResponse(id: id, text: "Error: cursor cannot be pinned to a model.", isError: true)
                    }
                    tier = parsed
                } else if toAgent == .cursor {
                    // Cursor was never tiered; an omitted tier keeps working exactly as before.
                    tier = nil
                } else {
                    tier = settings.defaultTier(for: toAgent)
                }
                if let tier {
                    guard settings.model(for: toAgent, tier: tier) != nil else {
                        return toolResultResponse(
                            id: id,
                            text: "Error: no model configured for \(toAgent.rawValue) tier \(tier.rawValue) — set it in linkC settings.",
                            isError: true)
                    }
                }

                let task: TaskRecord
                do {
                    task = try inboxStore.createTask(from: caller.agent, to: toAgent,
                                                     fromSessionId: callerSessionId(),
                                                     tier: tier,
                                                     prompt: prompt, files: files,
                                                     force: force, verification: verification)
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

                let successText = verification.map {
                    "Task \(task.shortId) created. linkC will confirm the tests fail at \(VerificationRunner.short($0.baseSha)) before delivery."
                } ?? "Task \(task.id) queued for \(toAgent.displayName). It will be delivered when \(toAgent.displayName) is idle. Track with linkc_get_task(\"\(task.id)\")."

                // Warn when the target is nearly out, without ever blocking or failing the
                // delegation. Whether a reader can ever produce a warning is decided once, in
                // `warnCapableAgents`, next to where readers are registered — not here by
                // checking the target's identity. A reader left out of that set (the transcript
                // usage reader today) is never called at all, so its read cost is never paid for
                // a warning it could never carry.
                var usageNote = ""
                if warnCapableAgents.contains(toAgent),
                   let window = usageReaders[toAgent]?().windowNeedingWarning,
                   let percent = window.usedPercent {
                    let resetSuffix = window.resetsAt.map { ", resets \(Self.formatReset($0, now: Date()))" } ?? ""
                    usageNote = " \(toAgent.displayName) is at \(Self.formatPercent(percent)) of its \(window.label) window\(resetSuffix)."
                }

                if !files.isEmpty {
                    do {
                        _ = try store.broadcastIntent(
                            agentKind: caller.agent,
                            pid: caller.pid,
                            goal: "Delegated task \(task.shortId) to \(toAgent.displayName)",
                            files: files,
                            status: "delegating"
                        )
                    } catch {
                        let warning = "Warning: task was created but the blackboard broadcast failed: \(error.localizedDescription)."
                        return toolResultResponse(id: id, text: "\(successText)\n\(warning)\(usageNote)")
                    }
                }

                return toolResultResponse(id: id, text: "\(successText)\(usageNote)")

            case "linkc_send_message":
                guard let toStr = args["to"] as? String, !toStr.isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'to'.", isError: true)
                }
                guard let toAgent = AgentKind(rawValue: toStr.lowercased()) else {
                    return toolResultResponse(id: id, text: "Error: Unknown agent '\(toStr)'. Supported agents: claude, agy, cursor, codex.", isError: true)
                }
                guard let messageText = args["message"] as? String, !messageText.isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'message'.", isError: true)
                }

                do {
                    let pending = try inboxStore.enqueue(from: caller.agent, to: toAgent, kind: .peerNote, body: messageText)
                    return toolResultResponse(id: id, text: "Message queued for \(toAgent.displayName) (ID: \(pending.id)). linkC will deliver it when idle.")
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_get_inbox":
                let inbox: Inbox
                do {
                    inbox = try inboxStore.load()
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }
                let now = Date()
                var text = "# linkC Message Inbox\n\n"

                let activeLimits = inbox.agentLimits.filter { $0.cooldownExpiresAt > now }
                if !activeLimits.isEmpty {
                    text += "## Active Agent Limits & Cooldowns\n"
                    for limit in activeLimits {
                        let remainingSec = max(0, Int(limit.cooldownExpiresAt.timeIntervalSince(now)))
                        let remainingMin = remainingSec / 60
                        text += "- **\(limit.agent.displayName)** (\(limit.agent.rawValue)): \(limit.reason) (cooldown: \(remainingMin)m remaining)\n"
                    }
                    text += "\n"
                } else {
                    text += "## Active Agent Limits\n_No active rate limits recorded._\n\n"
                }

                let openTasks = inbox.tasks.filter { $0.state.isOpen }.sorted { $0.createdAt < $1.createdAt }
                text += "## Open Tasks (\(openTasks.count))\n"
                if openTasks.isEmpty {
                    text += "_No open tasks._\n\n"
                } else {
                    for t in openTasks {
                        let age = Int(now.timeIntervalSince(t.createdAt) / 60)
                        text += "- \(taskLine(t)) — \(age)m old, \(t.files.count) file(s)\n"
                    }
                    text += "\n"
                }

                let pending = inbox.messages.filter { $0.status == .queued || $0.status == .delivering }
                text += "## Pending Messages (\(pending.count))\n"
                if pending.isEmpty {
                    text += "_No pending messages in queue._\n"
                } else {
                    for msg in pending {
                        text += "### Message \(msg.id) [\(msg.kind.rawValue)] [\(msg.status.rawValue.uppercased())]\n"
                        text += "- **From:** \(msg.fromAgent.displayName) → **To:** \(msg.toAgent.displayName)\n"
                        if let taskId = msg.taskId { text += "- **Task:** \(taskId.prefix(8))\n" }
                        if !msg.claimedFiles.isEmpty {
                            text += "- **Claimed Files:** \(msg.claimedFiles.joined(separator: ", "))\n"
                        }
                        if msg.rerouteCount > 0 {
                            text += "- **Reroute Count:** \(msg.rerouteCount)\n"
                        }
                        text += "- **Content:** \(msg.prompt.prefix(200))\n\n"
                    }
                }

                let history = inbox.messages.filter { $0.status == .delivered || $0.status == .failed }
                if !history.isEmpty {
                    text += "## Message History (\(history.count))\n"
                    for msg in history.suffix(10) {
                        text += "- [\(msg.status.rawValue)] \(msg.fromAgent.displayName) → \(msg.toAgent.displayName): \(msg.prompt.prefix(40))...\n"
                    }
                }

                return toolResultResponse(id: id, text: text)

            case "linkc_switch_model":
                let agentStr = (args["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? caller.agent.rawValue
                guard let agent = AgentKind(rawValue: agentStr.lowercased()) else {
                    return toolResultResponse(id: id, text: "Error: Unknown agent '\(agentStr)'. Supported agents: claude, agy, cursor, codex.", isError: true)
                }
                guard agent != .shell else {
                    return toolResultResponse(id: id, text: "Error: Cannot switch model on shell session.", isError: true)
                }
                guard let model = args["model"] as? String, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'model'.", isError: true)
                }
                let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                // Validate against the mapping `linkc_get_models` actually reports — not the
                // separate, stale AgentModelCatalog whitelist, which would reject every id this
                // agent is really configured to run.
                let configured = modelSettings().configuredModels(for: agent)
                guard configured.contains(where: { $0.caseInsensitiveCompare(cleanModel) == .orderedSame }) else {
                    let allowed = configured.isEmpty ? "none configured — set one in linkC settings" : configured.joined(separator: ", ")
                    return toolResultResponse(id: id, text: "Error: '\(cleanModel)' is not a configured model for \(agent.displayName). Configured models: \(allowed)", isError: true)
                }

                if let modelSwitcher {
                    do {
                        let result = try modelSwitcher(agent, cleanModel)
                        return toolResultResponse(id: id, text: result)
                    } catch {
                        return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                    }
                } else {
                    let cmd = AgentModelCatalog.interactiveSwitchCommand(model: cleanModel, for: agent)
                    do {
                        _ = try inboxStore.enqueue(from: agent, to: agent, kind: .command, body: cmd)
                    } catch {
                        return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                    }
                    return toolResultResponse(id: id, text: "Model switch requested: enqueued '\(cmd)' for \(agent.displayName). linkC will inject it via terminal PTY.")
                }

            case "linkc_get_models":
                let targetAgents: [AgentKind]
                if let agentStr = args["agent"] as? String, !agentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let a = AgentKind(rawValue: agentStr.lowercased()) else {
                        return toolResultResponse(id: id, text: "Error: Unknown agent '\(agentStr)'. Supported agents: claude, agy, cursor, codex.", isError: true)
                    }
                    guard a != .shell else {
                        return toolResultResponse(id: id, text: "Error: Shell does not support AI models.", isError: true)
                    }
                    targetAgents = [a]
                } else {
                    targetAgents = [.claude, .codex, .agy, .cursor]
                }

                let settings = modelSettings()
                var text = "# Configured Models by Tier\n\n"
                let now = Date()
                for agent in targetAgents {
                    text += "## \(agent.displayName)\n"
                    let limit: AgentLimitStatus?
                    do {
                        limit = try inboxStore.isAgentLimited(agent: agent)
                    } catch {
                        return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                    }
                    if let limit {
                        let remainingSec = max(0, Int(limit.cooldownExpiresAt.timeIntervalSince(now)))
                        let remainingMin = remainingSec / 60
                        text += "⚠️ **Rate Limited**: \(limit.reason) (\(remainingMin)m cooldown remaining)\n\n"
                    } else {
                        text += "Status: Active / Available\n\n"
                    }
                    if agent == .cursor {
                        text += "- cursor cannot be pinned to a model\n\n"
                        continue
                    }
                    for tier in ModelTier.resolutionOrder {
                        let id = settings.model(for: agent, tier: tier) ?? "(not set)"
                        let marker = tier == settings.defaultTier(for: agent) ? " — default" : ""
                        text += "- **\(tier.rawValue)**: \(id)\(marker)\n"
                    }
                    text += "\n"
                }
                text += "Edit these in linkC settings under MODELS.\n"
                return toolResultResponse(id: id, text: text)

            case "linkc_get_usage_status":
                let inbox: Inbox
                do {
                    inbox = try inboxStore.load()
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }
                let now = Date()
                var text = "# Agent Usage\n\n"

                for agent in [AgentKind.codex, .claude, .agy, .cursor] {
                    let usage = usageReaders[agent]?() ?? .unavailable(agent, reason: "no usage reader configured for this agent")
                    text += Self.renderUsageSection(usage, now: now)
                }

                let activeLimits = inbox.agentLimits.filter { $0.cooldownExpiresAt > now }
                if activeLimits.isEmpty {
                    text += "## Active Rate Limits\n_No active rate limits recorded across workspace agents._\n\n"
                } else {
                    text += "## Active Rate Limits (\(activeLimits.count))\n"
                    for limit in activeLimits {
                        let remainingSec = max(0, Int(limit.cooldownExpiresAt.timeIntervalSince(now)))
                        let remainingMin = remainingSec / 60

                        text += "### \(limit.agent.displayName) (\(limit.agent.rawValue))\n"
                        text += "- **Reason:** \(limit.reason)\n"
                        text += "- **Cooldown Remaining:** \(remainingMin)m (\(remainingSec)s)\n"
                        text += "- **Expires At:** \(limit.cooldownExpiresAt)\n\n"
                    }
                }

                return toolResultResponse(id: id, text: text)

            case "linkc_start_task":
                do {
                    let task = try requireTask(args)
                    guard caller.agent == task.toAgent else {
                        return toolResultResponse(id: id, text: "Error: task \(task.shortId) is assigned to \(task.toAgent.displayName), not \(caller.agent.displayName).", isError: true)
                    }
                    guard callerMayAct(on: task) else {
                        return toolResultResponse(id: id, text: "Error: task \(task.shortId) is assigned to another session.", isError: true)
                    }
                    try inboxStore.markTaskStarted(taskId: task.id)
                    let updated = try inboxStore.task(id: task.id) ?? task
                    return toolResultResponse(id: id, text: "Started: \(taskLine(updated))")
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_complete_task":
                do {
                    let task = try requireTask(args)
                    guard caller.agent == task.toAgent else {
                        return toolResultResponse(id: id, text: "Error: task \(task.shortId) is assigned to \(task.toAgent.displayName), not \(caller.agent.displayName).", isError: true)
                    }
                    guard callerMayAct(on: task) else {
                        return toolResultResponse(id: id, text: "Error: task \(task.shortId) is assigned to another session.", isError: true)
                    }
                    let status = (args["status"] as? String ?? "").lowercased()
                    guard status == "done" || status == "failed" else {
                        return toolResultResponse(id: id, text: "Error: 'status' must be \"done\" or \"failed\".", isError: true)
                    }
                    let summary = (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !summary.isEmpty else {
                        return toolResultResponse(id: id, text: InboxError.emptySummary.localizedDescription, isError: true)
                    }
                    var sha: String?
                    if let raw = (args["sha"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        do {
                            sha = try GitClient().resolveCommit(raw, in: URL(fileURLWithPath: workspaceRoot))
                        } catch {
                            return toolResultResponse(id: id, text: "Error: sha: \(error.localizedDescription). Commit your work, then report that commit's sha.", isError: true)
                        }
                    }
                    // `tests` is still accepted from older callers and ignored: linkC runs the tests itself.
                    let report = TaskReport(status: status, summary: summary, sha: sha, commits: args["commits"] as? [String] ?? [])
                    try inboxStore.reportTask(taskId: task.id, report: report)

                    let text: String
                    if task.verification == nil {
                        text = "Reported. Unverified task."
                    } else if status == "done", let sha {
                        text = "Reported. linkC is verifying at \(VerificationRunner.short(sha))."
                    } else {
                        text = "Reported. linkC will mark the task failed."
                    }
                    return toolResultResponse(id: id, text: text)
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_cancel_task":
                do {
                    let task = try requireTask(args)
                    let force = args["force"] as? Bool ?? false
                    let isAssignee = caller.agent == task.toAgent && callerMayAct(on: task)
                    guard force || caller.agent == task.fromAgent || isAssignee else {
                        return toolResultResponse(id: id, text: "Error: only \(task.fromAgent.displayName) or \(task.toAgent.displayName) may cancel task \(task.shortId); pass force: true to override.", isError: true)
                    }
                    let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedReason = (reason?.isEmpty == false) ? reason! : "cancelled by \(caller.agent.displayName)"
                    let wasDelivered = task.state == .delivered || task.state == .started
                    try inboxStore.cancelTask(taskId: task.id, reason: resolvedReason)
                    let successText = "Cancelled task \(task.shortId) (\(resolvedReason))."
                    if wasDelivered {
                        do {
                            _ = try inboxStore.enqueue(from: caller.agent, to: task.toAgent, kind: .completion, taskId: task.id, body: "cancelled: \(resolvedReason). Stop work on it.")
                        } catch {
                            let warning = "Warning: task state was updated but notifying \(task.toAgent.displayName) failed: \(error.localizedDescription). They can run linkc_get_task(\"\(task.id)\")."
                            return toolResultResponse(id: id, text: "\(successText)\n\(warning)")
                        }
                    }
                    return toolResultResponse(id: id, text: successText)
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_get_task":
                do {
                    let task = try requireTask(args)
                    return toolResultResponse(id: id, text: taskMarkdown(task))
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_my_tasks":
                guard caller.isIdentified else {
                    return toolResultResponse(id: id, text: Self.unidentifiedCallerMessage, isError: true)
                }
                let assigned: [TaskRecord]
                let delegated: [TaskRecord]
                do {
                    assigned = try inboxStore.openTasks(for: caller.agent).filter { callerMayAct(on: $0) }
                    delegated = try inboxStore.openTasks().filter { $0.fromAgent == caller.agent && $0.toAgent != caller.agent }
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }
                var text = "# Open tasks for \(caller.agent.displayName)\n\n## Assigned to you (\(assigned.count))\n"
                text += assigned.isEmpty ? "_None._\n" : assigned.map { "- \(taskLine($0))" }.joined(separator: "\n") + "\n"
                text += "\n## Delegated by you (\(delegated.count))\n"
                text += delegated.isEmpty ? "_None._\n" : delegated.map { "- \(taskLine($0))" }.joined(separator: "\n") + "\n"
                return toolResultResponse(id: id, text: text)

            default:
                return errorResponse(id: id, code: -32601, message: "Unknown tool: \(name)")
            }
        } catch {
            return errorResponse(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    func taskLine(_ t: TaskRecord) -> String {
        let firstLine = t.prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? t.prompt
        return "\(t.shortId) [\(t.state.rawValue)] from \(t.fromAgent.displayName) → \(t.toAgent.displayName): \(firstLine.prefix(80))"
    }

    private func taskMarkdown(_ t: TaskRecord) -> String {
        let iso = ISO8601DateFormatter()
        var text = "# Task \(t.shortId) — \(t.state.rawValue)\n\n"
        text += "- **ID:** \(t.id)\n"
        text += "- **From:** \(t.fromAgent.displayName) → **To:** \(t.toAgent.displayName)\n"
        text += "- **Hop:** \(t.hop)\n"
        text += "- **Created:** \(iso.string(from: t.createdAt))\n"
        if let d = t.deliveredAt { text += "- **Delivered:** \(iso.string(from: d))\n" }
        if let s = t.startedAt { text += "- **Started:** \(iso.string(from: s))\n" }
        if let f = t.finishedAt { text += "- **Finished:** \(iso.string(from: f))\n" }
        text += "- **Lease expires:** \(iso.string(from: t.leaseExpiresAt))\n"
        if !t.files.isEmpty { text += "- **Files:** \(t.files.joined(separator: ", "))\n" }
        if let r = t.cancelReason { text += "- **Reason:** \(r)\n" }
        text += "\n## Brief\n\(t.prompt)\n"
        if let r = t.report {
            text += "\n## Report (\(r.status))\n\(r.summary)\n"
            if let sha = r.sha { text += "\n**Sha:** \(sha)\n" }
            if !r.commits.isEmpty { text += "\n**Commits:** \(r.commits.joined(separator: ", "))\n" }
        }
        if let v = t.verification {
            text += "\n## Verification\n- **Branch:** \(v.branch)\n- **Base:** \(v.baseSha)\n- **Command:** `\(v.command)`\n"
            text += "- **Protected tests:** \(v.testPaths.joined(separator: ", "))\n- **Timeout:** \(v.timeoutSeconds)s\n"
        }
        if let gate = t.gate { text += "\n## Gate\n" + verdictMarkdown(gate) }
        if let verdict = t.verdict { text += "\n## Verdict\n" + verdictMarkdown(verdict) }
        return text
    }

    private func verdictMarkdown(_ v: Verdict) -> String {
        var text = "- **Result:** \(v.passed ? "passed" : "failed")\n"
        if let sha = v.sha { text += "- **At:** \(sha)\n" }
        if let exit = v.exitStatus { text += "- **Exit:** \(exit)\n" }
        if let reason = v.reason { text += "- **Reason:** \(reason)\n" }
        if !v.stdoutTail.isEmpty { text += "\n**stdout (tail)**\n```\n\(v.stdoutTail)\n```\n" }
        if !v.stderrTail.isEmpty { text += "\n**stderr (tail)**\n```\n\(v.stderrTail)\n```\n" }
        return text
    }

    /// One agent's section of `linkc_get_usage_status`'s report: a heading (with plan type when
    /// known), one line per window, and either the observation age or why nothing is known.
    private static func renderUsageSection(_ usage: AgentUsage, now: Date) -> String {
        let planSuffix = usage.planType.map { " — plan \($0)" } ?? ""
        var text = "## \(usage.agent.displayName)\(planSuffix)\n"

        guard !usage.windows.isEmpty else {
            let reason = usage.unavailableReason ?? "no reading available"
            text += "- no usage data available: \(reason)\n\n"
            return text
        }

        for window in usage.windows {
            text += renderUsageWindow(window, now: now)
        }
        if usage.windows.allSatisfy({ $0.usedPercent == nil }) {
            // Today only Claude's reader takes this shape — Anthropic publishes no per-plan
            // limit, so its windows carry token counts and never a percentage.
            let publisher = usage.agent == .claude ? "Anthropic" : usage.agent.displayName
            text += "- no percentage available — \(publisher) publishes no per-plan limit\n"
        }
        if let observedAt = usage.observedAt {
            let age = relativeAge(observedAt, now: now)
            text += usage.isStale
                ? "- observed \(age) ago — stale, older than \(Int(AgentUsage.staleAfter / 60))m\n"
                : "- observed \(age) ago\n"
        }
        text += "\n"
        return text
    }

    /// One window's line: percent or token count first (a lower-bound token count says so, never
    /// presenting a truncated read as an exact total), then the reset time when known.
    private static func renderUsageWindow(_ window: UsageWindow, now: Date) -> String {
        var figure: String
        if let percent = window.usedPercent {
            figure = "\(formatPercent(percent)) used"
        } else if let tokens = window.tokens {
            let formatted = UsageFormat.tokens(tokens)
            figure = window.tokensAreLowerBound ? "at least \(formatted) tokens" : "\(formatted) tokens"
        } else {
            figure = "no data"
        }
        if let resetsAt = window.resetsAt {
            // A reset time already behind `now` is stale information, not a future promise —
            // showing it as if it were still ahead would read as a countdown to a moment that
            // already happened.
            figure += resetsAt > now ? ", resets \(formatReset(resetsAt, now: now))" : ", reset since this reading"
        }
        return "- **\(window.label)**: \(figure)\n"
    }

    /// "23%", never "23.0%" — one decimal only when the figure isn't a whole number.
    private static func formatPercent(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))%" }
        return String(format: "%.1f%%", value)
    }

    /// "14:04 (in 2h 11m)" for a reset within the next day, "Sep 18 09:21" further out.
    private static func formatReset(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
        formatter.dateFormat = sameDay ? "HH:mm" : "MMM d HH:mm"
        let absolute = formatter.string(from: date)

        let interval = date.timeIntervalSince(now)
        guard interval > 0, interval < 24 * 3600 else { return absolute }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let relative = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return "\(absolute) (in \(relative))"
    }

    /// "4m", "3h" — coarse enough for a usage report, not a stopwatch.
    private static func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    /// Checks `verify` against the workspace's git and returns it with base_sha fully resolved.
    private func resolveVerification(_ raw: [String: Any]) throws -> Verification {
        func field(_ key: String) throws -> String {
            guard let value = (raw[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw LinkCError.server("verify.\(key) is required")
            }
            return value
        }
        let branch = try field("branch")
        let baseArg = try field("base_sha")
        let command = try field("command")
        guard let paths = raw["test_paths"] as? [String], !paths.isEmpty else {
            throw LinkCError.server("verify.test_paths is required")
        }
        let timeout: Int
        switch raw["timeout_seconds"] {
        case nil, is NSNull:
            timeout = Verification.defaultTimeoutSeconds
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            // JSON has one number type: 600 and 600.0 are integers, 600.5 is not.
            guard let whole = Int(exactly: number.doubleValue) else {
                throw LinkCError.server("verify.timeout_seconds must be an integer")
            }
            timeout = whole
        default:
            throw LinkCError.server("verify.timeout_seconds must be an integer")
        }

        let git = GitClient()
        let workspace = URL(fileURLWithPath: workspaceRoot)
        let base: String
        do { base = try git.resolveCommit(baseArg, in: workspace) } catch {
            throw LinkCError.server("verify.base_sha: \(error.localizedDescription)")
        }
        let tip: String
        do { tip = try git.resolveCommit(branch, in: workspace) } catch {
            throw LinkCError.server("verify.branch: \(error.localizedDescription)")
        }
        guard tip == base else {
            throw LinkCError.server("verify.branch '\(branch)' is at \(VerificationRunner.short(tip)), not base \(VerificationRunner.short(base)); commit the tests on that branch first")
        }
        for path in paths {
            guard try git.fileExists(path, at: base, in: workspace) else {
                throw LinkCError.server("verify.test_paths '\(path)' does not exist at \(VerificationRunner.short(base))")
            }
        }
        return Verification(branch: branch, baseSha: base, command: command, testPaths: paths, timeoutSeconds: timeout)
    }

    private func requireTask(_ args: [String: Any]) throws -> TaskRecord {
        guard let taskId = (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !taskId.isEmpty else {
            throw LinkCError.server("Missing required argument 'task_id'.")
        }
        guard let task = try inboxStore.task(matching: taskId) else { throw InboxError.taskNotFound(taskId) }
        return task
    }

    /// A task delivered to a specific session belongs to that session. Several sessions of one
    /// kind run at once now that sessions are pinned per tier, and a sibling that never received
    /// the brief must not be able to settle it. A task with no assignee yet is open to its kind,
    /// and a caller with no session id is not locked out — linkC cannot prove it is not the
    /// assignee, and refusing would break agents started outside linkC.
    private func callerMayAct(on task: TaskRecord) -> Bool {
        guard let assignee = task.assigneeSessionId,
              let caller = callerSessionId() else { return true }
        return assignee == caller
    }

    /// Applies `steps` to the Board, load–apply–save, and retries once if the file changed on
    /// disk between the load and the save — the same race `handleToolsCall` never otherwise
    /// meets, since one `MCPServer` handles one call at a time, but another process (or another
    /// linkC session) can still write `system-map.json` in between. `beforeSave` is a seam a test
    /// uses to force that race; production never overrides it. Throws `BoardEditRefusal` for a
    /// bad step, or `LinkCError.server` when the file kept changing after the retry.
    static func editBoard(store: BoardMapStore, steps: [BoardEditStep], beforeSave: () throws -> Void = {}) throws -> [String] {
        let first = try store.load()
        let (map, lines) = try BoardEdit.apply(steps, to: first?.map ?? .empty)
        try beforeSave()
        do {
            _ = try store.save(map, expecting: first?.bytes)
            return lines
        } catch BoardMapStoreError.changedOnDisk {
            let second = try store.load()
            let (retriedMap, retriedLines) = try BoardEdit.apply(steps, to: second?.map ?? .empty)
            try beforeSave()
            do {
                _ = try store.save(retriedMap, expecting: second?.bytes)
                return retriedLines
            } catch BoardMapStoreError.changedOnDisk {
                throw LinkCError.server("the map kept changing while this edit was saved — try again")
            }
        }
    }

    private func toolResultResponse(id: Any?, text: String, isError: Bool = false) -> Data? {
        var result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ]
        ]
        if isError {
            result["isError"] = true
        }
        return successResponse(id: id, result: result)
    }

    private func successResponse(id: Any?, result: [String: Any]) -> Data? {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id {
            payload["id"] = id
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> Data? {
        let errorObj: [String: Any] = [
            "code": code,
            "message": message
        ]
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": errorObj
        ]
        if let id {
            payload["id"] = id
        } else {
            payload["id"] = NSNull()
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
