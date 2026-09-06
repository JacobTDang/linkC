import Foundation

/// Pure-Swift Model Context Protocol (MCP) server speaking JSON-RPC 2.0.
public final class MCPServer: Sendable {
    public let workspaceRoot: String
    public let store: BlackboardStore

    public init(workspaceRoot: String, store: BlackboardStore? = nil) {
        self.workspaceRoot = (workspaceRoot as NSString).standardizingPath
        self.store = store ?? BlackboardStore(workspaceRoot: workspaceRoot)
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
                "tools": [:]
            ],
            "serverInfo": [
                "name": "linkc-multiplier",
                "version": "0.1.0"
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
                "description": "Get context on all peer agents active in this workspace, their goals, claimed files, and shared notes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
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
            ]
        ]
        return successResponse(id: id, result: ["tools": tools])
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) -> Data? {
        guard let name = params["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        do {
            switch name {
            case "linkc_broadcast_intent":
                let goal = args["goal"] as? String ?? "Working"
                let files = args["files"] as? [String] ?? []
                let agentStr = args["agent"] as? String ?? "claude"
                let agentKind = AgentKind(rawValue: agentStr) ?? .claude
                let pid = (args["pid"] as? Int).map { pid_t($0) } ?? getpid()
                let status = args["status"] as? String ?? "working"

                let warnings = try store.broadcastIntent(
                    agentKind: agentKind,
                    pid: pid,
                    goal: goal,
                    files: files,
                    status: status
                )

                var responseText = "Intent recorded: '\(goal)' for \(agentKind.displayName) (PID \(pid)). Claimed \(files.count) files."
                if !warnings.isEmpty {
                    responseText += "\n\n⚠️ Collision Warnings:"
                    for w in warnings {
                        responseText += "\n- Agent '\(w.conflictingAgent.displayName)' (PID \(w.pid)) is also working on: \(w.conflictingFiles.joined(separator: ", ")) (Goal: '\(w.goal)')"
                    }
                }

                return toolResultResponse(id: id, text: responseText)

            case "linkc_check_conflicts":
                let files = args["files"] as? [String] ?? []
                let pid = (args["pid"] as? Int).map { pid_t($0) }
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
                let agentStr = args["agent"] as? String ?? "claude"
                let agentKind = AgentKind(rawValue: agentStr) ?? .claude
                let tags = args["tags"] as? [String] ?? []

                let note = try store.postNote(
                    authorAgent: agentKind,
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

                return toolResultResponse(id: id, text: text)

            default:
                return errorResponse(id: id, code: -32601, message: "Unknown tool: \(name)")
            }
        } catch {
            return errorResponse(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func toolResultResponse(id: Any?, text: String) -> Data? {
        let result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ]
        ]
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
