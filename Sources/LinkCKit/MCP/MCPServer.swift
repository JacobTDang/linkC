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
    /// True when the XCTest framework is loaded into this process — true for both `swift test`
    /// and an Xcode test run (either links it in), false for `linkc`/`linkc-mcp` running for
    /// real. Independent of Xcode-only environment variables, and a var (not the check inlined
    /// into `walk`) purely so a test can assert the detection itself works.
    static var isRunningUnderXCTest: Bool { NSClassFromString("XCTestCase") != nil }

    /// The real walk. `value`'s `static let` memoizes whatever this returns the first time it is
    /// read, via Swift's thread-safe one-time static initialization — no hand-rolled locking
    /// needed for that part. `walk` itself is `nonisolated(unsafe)` only because a mutable global
    /// needs an escape from strict concurrency checking; production code never reassigns it, and
    /// a test may reassign it solely to stand in for the real walk *before* first touching
    /// `value`, letting it count invocations without reading real processes — `@testable import`
    /// reaches it despite `internal`, so it need not be `public` itself. `value` is `public`
    /// because `MCPServer.init` is public and its default `sessionResolver` argument reads it
    /// directly, which Swift requires to be at least as visible as the initializer.
    ///
    /// The still-default `walk` (one a test never replaced) fails fast under XCTest instead of
    /// silently returning the real ancestor session: a test that forgot to inject
    /// `sessionResolver: { nil }` (or reassign `walk` first) would otherwise read whatever
    /// process happens to be running the test binary's ancestry, a flaky, unasserted hazard this
    /// doc already warned about.
    nonisolated(unsafe) static var walk: @Sendable () -> String? = {
        #if DEBUG
        if AncestorSessionCache.isRunningUnderXCTest {
            fatalError(
                "AncestorSessionCache.value was read for real under XCTest — a test forgot to " +
                "inject sessionResolver: { nil } to MCPServer.init (or reassign " +
                "AncestorSessionCache.walk before first use), and would otherwise read the real " +
                "ancestor session of the test-runner process."
            )
        }
        #endif
        return ProcessSnooper.sessionId(inAncestorsOf: getpid())
    }
    public static let value: String? = walk()
}

/// `LINKC_WORKER` from the nearest ancestor that carries it, read at most once per process like
/// `AncestorSessionCache`: Cursor's CLI passes its MCP servers only the registration's own `env`
/// block, so the mark linkC set on a Grok terminal never reaches `environment` directly.
public enum AncestorWorkerCache {
    /// Under XCTest, a test that injected no `workerResolver` reads no real process: it is simply
    /// not in a worker terminal. A test of the worker path injects its own resolver.
    public static let value: String? = {
        if AncestorSessionCache.isRunningUnderXCTest { return nil }
        return ProcessSnooper.environmentVariable(AgentKind.workerEnvironmentKey, inAncestorsOf: getpid())
    }()
}

/// Wraps a usage reader so its real read never runs on the caller's thread: the first call
/// kicks off a background read and returns "not read yet" immediately, and every call after
/// that returns whatever the most recent background read produced while triggering another one
/// to keep the cache fresh. `linkc-mcp` serves one request at a time on stdin, so a slow reader
/// on this path (Claude's transcript scan, ~1.3s against a large `~/.claude/projects`) would
/// otherwise stall every other tool call behind it.
final class BackgroundRefreshedUsageReader: @unchecked Sendable {
    private let agent: AgentKind
    private let read: @Sendable () -> AgentUsage
    private let lock = NSLock()
    private var cached: AgentUsage?
    private var refreshing = false

    init(agent: AgentKind, read: @escaping @Sendable () -> AgentUsage) {
        self.agent = agent
        self.read = read
    }

    func callAsFunction() -> AgentUsage {
        lock.lock()
        let current = cached
        let alreadyRefreshing = refreshing
        if !alreadyRefreshing { refreshing = true }
        lock.unlock()

        if !alreadyRefreshing {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let fresh = self.read()
                self.lock.lock()
                self.cached = fresh
                self.refreshing = false
                self.lock.unlock()
            }
        }

        return current ?? .unavailable(agent, reason: "usage not read yet — check again shortly")
    }
}

/// Wraps a usage reader so a burst of calls within `ttl` seconds of each other only pays for one
/// real read — used for Codex, whose reader stats its whole sessions directory on every call
/// (a rapid string of delegations to the same agent must not each repeat that scan).
final class TTLCachedUsageReader: @unchecked Sendable {
    private let agent: AgentKind
    private let read: @Sendable () -> AgentUsage
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: (value: AgentUsage, at: Date)?

    init(agent: AgentKind, ttl: TimeInterval = 5, now: @escaping @Sendable () -> Date = Date.init,
         read: @escaping @Sendable () -> AgentUsage) {
        self.agent = agent
        self.ttl = ttl
        self.now = now
        self.read = read
    }

    func callAsFunction() -> AgentUsage {
        lock.lock()
        let current = now()
        if let cached, current.timeIntervalSince(cached.at) < ttl {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let fresh = read()
        lock.lock()
        cached = (fresh, current)
        lock.unlock()
        return fresh
    }
}

/// Pure-Swift Model Context Protocol (MCP) server speaking JSON-RPC 2.0.
public final class MCPServer: Sendable {
    /// Switches `agent`'s model in the workspace: in `sessionId` when the caller named a task, else in
    /// the first session of `agent`.
    public typealias ModelSwitcher = @Sendable (_ agent: AgentKind, _ model: String, _ sessionId: String?, _ workspaceRoot: String) throws -> String
    public typealias AncestorResolver = @Sendable (_ pid: pid_t) -> (agent: AgentKind, pid: pid_t)?
    public typealias ModelSettingsProvider = @Sendable () -> AgentModelSettings
    public typealias SessionResolver = @Sendable () -> String?
    public typealias WorkerResolver = @Sendable () -> String?
    public typealias UsageReader = @Sendable () -> AgentUsage
    public typealias OpenCodeModelLister = @Sendable (_ folder: String) throws -> [String]

    /// How `linkc_close_worker` waits for linkC's answer to its request: it polls the task every
    /// `interval` seconds, up to `timeout`, calling `sleep` between polls. A seam, so a test can
    /// play the app's answer at each wait instead of really waiting.
    public struct CloseAnswerWait: Sendable {
        public var timeout: TimeInterval
        public var interval: TimeInterval
        public var sleep: @Sendable (TimeInterval) -> Void

        public init(timeout: TimeInterval, interval: TimeInterval, sleep: @escaping @Sendable (TimeInterval) -> Void) {
            self.timeout = timeout
            self.interval = interval
            self.sleep = sleep
        }

        /// A relay pass runs about once a second, and a request written to the inbox wakes one.
        public static let standard = CloseAnswerWait(
            timeout: 5, interval: 0.1, sleep: { Thread.sleep(forTimeInterval: $0) })
    }

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
    /// Falls back to an ancestor's real environment when ours has no `LINKC_WORKER`; see
    /// `AncestorWorkerCache`. Only `resolveCaller` reads it.
    public let workerResolver: WorkerResolver
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
    public let closeAnswerWait: CloseAnswerWait
    /// The models OpenCode offers in a folder, read on every OpenCode delegation: a free model can
    /// go at any time, and OpenCode runs a session whose model it does not know on whatever it picks.
    public let openCodeModels: OpenCodeModelLister
    /// Live model lists from the app's cache. The MCP server never runs a CLI to list models.
    public let modelLists: @Sendable () throws -> [AgentKind: AgentModelList]
    /// The app's list of known projects, which a `project` argument names one of (spec 2026-11-11
    /// cross-project §4).
    public let knownProjects: KnownProjectsFile

    /// Tools an unidentified caller may still use.
    public static let readOnlyTools: Set<String> = [
        "linkc_get_project_context", "linkc_check_conflicts", "linkc_get_inbox",
        "linkc_get_task", "linkc_get_models", "linkc_get_usage_status", "linkc_get_board",
        "linkc_list_projects"
    ]

    /// Tools whose `agent` argument is a target/filter rather than the caller's identity.
    public static let targetAgentTools: Set<String> = ["linkc_switch_model", "linkc_get_models"]

    public static let unidentifiedCallerMessage =
        "Cannot identify calling agent; pass agent: \"claude\" | \"agy\" | \"cursor\" | \"codex\" | \"grok\" | \"opencode\"."

    /// `linkc_edit_board`'s `steps` schema description: the only place an agent can discover the
    /// step grammar, so it names every verb's fields exactly, one short line each, matching
    /// `BoardEdit`'s own decoding.
    static let stepsSchemaDescription = """
        1 to 50 steps, applied in order, all or nothing. One verb per step, naming its fields exactly:
        add: {"add": name, "kind"?, "tech"?, "in"?: place, "does"?, "reached_by"?, "runs"?, "planned"?: bool, "columns"?: [column]}
        update: {"update": name, same optional fields, "rename"?: new name}
        remove: {"remove": name}
        connect: {"connect": from, "to": to, "label"?, "style"?: plain|conditional|control|bus, "bits"?: 1-4096 (bus only)}
        disconnect: {"disconnect": from, "to": to}
        place: {"place": label} or {"place": label, "rename": new label}
        remove_place: {"remove_place": label}
        note: {"note": text}
        remove_note: {"remove_note": exact text}
        system: {"system": one line}
        detail: {"detail": name}
        column: {"op": "column", "table": name, "column": name, "set"?: {column keys except name}, "drop"?: true} — adds the column when it's missing (needs "type"), changes it when present, drops it with "drop": true.
        a column: {"name", "type", "pk"?: bool, "nullable"?: bool, "unique"?: bool, "default"?, "references"?: "table.column", "status"?: "planned"}. "columns" and the "column" step only work on a "table" part.
        "kind": \(ComponentKind.groupedKindList) — any other kind is kept and drawn as a service. "memory" is the AI agent's checkpointer; "ram" is hardware memory. "table" is a database's own table, its box sized to fit its columns.
        "planned": true marks something not built yet — linkc_get_board shows it as "status": "planned".
        "tech": a known technology id or alias — \(BoardTech.knownIDs.joined(separator: ", "))
        A new arrow from a router defaults to conditional, from a control unit to control.
        Parts marked outside come from the parent board and are read-only here.
        """

    public init(
        workspaceRoot: String,
        store: BlackboardStore? = nil,
        inboxStore: InboxStore? = nil,
        modelSwitcher: ModelSwitcher? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ancestorResolver: @escaping AncestorResolver = { ProcessSnooper.detectAgent(inAncestorsOf: $0) },
        modelSettings: @escaping ModelSettingsProvider = { AgentModelStore.applicationSupport.load() },
        sessionResolver: @escaping SessionResolver = { AncestorSessionCache.value },
        workerResolver: @escaping WorkerResolver = { AncestorWorkerCache.value },
        usageReaders: [AgentKind: UsageReader] = MCPServer.defaultUsageReaders(),
        warnCapableAgents: Set<AgentKind> = MCPServer.defaultWarnCapableAgents,
        closeAnswerWait: CloseAnswerWait = .standard,
        openCodeModels: @escaping OpenCodeModelLister = { try MCPServer.listOpenCodeModels(in: $0) },
        modelLists: @escaping @Sendable () throws -> [AgentKind: AgentModelList] = {
            try ModelListCache.applicationSupport.read()
        },
        knownProjects: KnownProjectsFile = .applicationSupport
    ) {
        self.workspaceRoot = (workspaceRoot as NSString).standardizingPath
        self.store = store ?? BlackboardStore(workspaceRoot: workspaceRoot)
        self.inboxStore = inboxStore ?? InboxStore(workspaceRoot: workspaceRoot)
        self.modelSwitcher = modelSwitcher
        self.environment = environment
        self.ancestorResolver = ancestorResolver
        self.modelSettings = modelSettings
        self.sessionResolver = sessionResolver
        self.workerResolver = workerResolver
        self.usageReaders = usageReaders
        self.warnCapableAgents = warnCapableAgents
        self.closeAnswerWait = closeAnswerWait
        self.openCodeModels = openCodeModels
        self.modelLists = modelLists
        self.knownProjects = knownProjects
    }

    /// The project a tool's `project` argument names, or nil when the call has none and so acts on
    /// this project. Throws the refusals of `ProjectRef.resolve`, and `KnownProjectsError` when the
    /// app's list can't be read.
    func targetProject(_ args: [String: Any]) throws -> KnownProject? {
        guard let raw = args["project"] else { return nil }
        guard let ref = raw as? String else {
            throw LinkCError.server("project must be a folder name or a full path")
        }
        return try ProjectRef.resolve(ref, among: knownProjects.read(), caller: workspaceRoot)
    }

    /// The real readers, wired to each agent's own on-disk records. `agy` and `cursor` write
    /// none, so they report why rather than guessing. Building this only constructs the reader
    /// values (cheap URL arithmetic); the home directory itself is touched solely when a
    /// reader's `read()` actually runs.
    ///
    /// Codex's reader is wrapped in a few-seconds cache — a rapid string of delegations must not
    /// each pay its full directory scan. Claude's reads the same status-line `rate_limits`
    /// cache the sidebar's own reading is fed from (`ClaudeRateLimits.usageReader`), falling
    /// back to the slower transcript scan only when no status line has ever been seen; that
    /// fallback is itself wrapped so its ~1.3s read never runs on the synchronous stdio path —
    /// see `BackgroundRefreshedUsageReader`.
    public static func defaultUsageReaders() -> [AgentKind: UsageReader] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexReader = CodexUsageReader(sessionsDirectory: home.appendingPathComponent(".codex/sessions"))
        let codex = TTLCachedUsageReader(agent: .codex, read: { codexReader.read() })
        let transcriptReader = ClaudeUsageReader(projectsDirectory: home.appendingPathComponent(".claude/projects"))
        let transcript = BackgroundRefreshedUsageReader(agent: .claude, read: { transcriptReader.read() })
        let claude = ClaudeRateLimits.usageReader(
            cacheURL: HookServer.defaultStatusLineCacheURL(), fallback: transcript.callAsFunction)
        return [
            .codex: codex.callAsFunction,
            .claude: claude,
            .agy: { .unavailable(.agy, reason: "agy writes no local session records") },
            .cursor: { .unavailable(.cursor, reason: "cursor writes no local session records") },
            .grok: { .unavailable(.grok, reason: "Grok runs on the Cursor plan, which writes no local session records") },
            .opencode: { .unavailable(.opencode, reason: "OpenCode's free models publish no quota locally") }
        ]
    }

    /// Agents whose reader in `defaultUsageReaders()` can warn a delegation: Codex's windows
    /// always carry a `usedPercent`; Claude's now can too, when its reader found a cached status
    /// line (its transcript fallback never does — Anthropic publishes no per-plan limit for that
    /// source). Declared as data rather than checking `toAgent`'s identity in the handler, so
    /// whether a reader can ever warn is decided once, here, next to where readers are
    /// registered. `agy` and `cursor` are absent from `defaultUsageReaders()` entirely and so
    /// cannot warn regardless.
    public static let defaultWarnCapableAgents: Set<AgentKind> = [.codex, .claude]

    /// `opencode models`, on a private server so listing never starts OpenCode's shared background
    /// service when it is not running.
    static let openCodeModelsArguments = ["models", "--standalone"]

    /// The models `opencode models` lists in `folder` — a project's own config can add providers.
    /// Throws when OpenCode is missing, the listing fails or does not answer in time, or it lists
    /// no models. `executable` is OpenCode's path, nil when it is not installed.
    public static func listOpenCodeModels(
        in folder: String,
        executable: String? = AgentDescriptor.resolveExecutable(for: .opencode),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: TimeInterval = 60
    ) throws -> [String] {
        guard let executable else {
            throw LinkCError.process("Executable for \(AgentKind.opencode.pillText) not found")
        }
        let result: ProcessResult
        do {
            result = try LiveProcessRunner.runCapturingSync(
                executable: executable, args: openCodeModelsArguments, cwd: URL(fileURLWithPath: folder),
                env: AgentDescriptor.environment(for: .opencode, home: home),
                timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            throw LinkCError.process("`opencode models` did not answer within \(seconds) seconds")
        }
        guard result.status == 0 else {
            throw LinkCError.process("`opencode models` exited \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let models = parseOpenCodeModels(result.stdout)
        guard !models.isEmpty else { throw LinkCError.process("`opencode models` listed no models") }
        return models
    }

    /// The free model ids in `opencode models`' output: its non-empty lines, trimmed, free only.
    static func parseOpenCodeModels(_ stdout: String) -> [String] {
        ModelListParser.openCode(stdout).map(\.id)
    }

    /// Identity: explicit `agent` arg → `LINKC_AGENT` env → ancestor process → `.shell` (unidentified),
    /// then a caller that resolved as Cursor inside a terminal linkC marked as Grok is Grok.
    func resolveCaller(_ args: [String: Any]) -> MCPCaller {
        let caller = resolveCallerIgnoringWorker(args)
        guard caller.agent == .cursor, let worker = cursorWorker() else { return caller }
        return MCPCaller(agent: worker, pid: caller.pid)
    }

    private func resolveCallerIgnoringWorker(_ args: [String: Any]) -> MCPCaller {
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

    /// The worker linkC launched on Cursor's CLI in this terminal, if it marked one. Grok runs
    /// Cursor's CLI: that CLI hands its MCP servers Cursor's registration, and the model inside may
    /// call itself cursor, so the mark decides. A mark other than `grok` is reported and ignored.
    private func cursorWorker() -> AgentKind? {
        let own = environment[AgentKind.workerEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        guard let raw = own ?? workerResolver() else { return nil }
        guard raw.lowercased() == AgentKind.grok.rawValue else {
            FileHandle.standardError.write(Data(
                "linkc-mcp: ignoring \(AgentKind.workerEnvironmentKey)=\(raw) — only grok runs on Cursor's CLI\n".utf8))
            return nil
        }
        return .grok
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
                "name": MCPRegistrar.serverName,
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
                        "agent": ["type": "string", "description": "Agent kind (\(AgentKind.allCases.map(\.rawValue).joined(separator: ", ")))"],
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
                    "properties": [
                        "project": [
                            "type": "string",
                            "description": "Optional. Another project's folder name or path; reads that project's context. With it, notes are titles only unless note is also set."
                        ],
                        "note": [
                            "type": "string",
                            "description": "Optional. A note title (matched ignoring case); returns that note in full."
                        ]
                    ]
                ]
            ],
            [
                "name": "linkc_list_projects",
                "description": "List the other projects linkC knows, one line each: name, path, and each open session's agent and whether it is idle or busy. Pass a name or path as `project` to linkc_ask, linkc_delegate_task, linkc_send_message, linkc_get_board or linkc_get_project_context.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "linkc_get_board",
                "description": "Read this project's Board — its architecture (system, places, components, notes) as JSON, exactly as `system-map.json` holds it minus layout. Use the exact names it shows with linkc_edit_board. Optional board: \"overview\" (default) or a detail board's slug. Parts marked outside come from the parent board and are read-only here.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "board": [
                            "type": "string",
                            "description": "Optional board to read: \"overview\" (default) or a detail board's slug."
                        ],
                        "project": [
                            "type": "string",
                            "description": "Optional. Another project's folder name or path; reads that project's Board."
                        ]
                    ]
                ]
            ],
            [
                "name": "linkc_edit_board",
                "description": "Change this project's Board with a list of steps, applied in order, all or nothing. Verbs: add, update, remove, connect, disconnect, place, remove_place, note, remove_note, system, detail, column. Optional board: \"overview\" (default) or a detail board's slug. Parts marked outside come from the parent board and are read-only here. When you add or change infrastructure (a service, database, cache, queue, host…), reflect it on the Board.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "board": [
                            "type": "string",
                            "description": "Optional board to edit: \"overview\" (default) or a detail board's slug."
                        ],
                        "steps": [
                            "type": "array",
                            "items": ["type": "object"],
                            "description": Self.stepsSchemaDescription
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
                "description": "Delegate a coding task, subtask, or follow-up prompt to a peer agent (e.g. \(AgentKind.peerList)), claiming files and enqueuing the prompt for delivery.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Target agent kind (\(AgentKind.peerList))"],
                        "prompt": ["type": "string", "description": "Task instructions and context to inject into recipient's terminal"],
                        "files": ["type": "array", "items": ["type": "string"], "description": "Optional list of files the delegated task will touch"],
                        "from": ["type": "string", "description": "Sender agent kind (optional, defaults to claude)"],
                        "pid": ["type": "integer", "description": "Process ID of the sender"],
                        "force": ["type": "boolean", "description": "Override an existing lease held by another assignee"],
                        "tier": ["type": "string", "description": "Model tier for this task: light, standard or deep. Defaults to the agent's configured default tier. Pass tier or model, not both."],
                        "model": ["type": "string", "description": "A specific model of the target agent, as an alternative to tier. Must be one the agent lists. Pass tier or model, not both."],
                        "project": ["type": "string", "description": "Optional. Another project's folder name or path; the task is created there."],
                        "verify": [
                            "type": "object",
                            "description": "Make this a verified task. linkC confirms the tests fail at base_sha before delivery, then runs command at the worker's reported sha and decides done or failed itself.",
                            "properties": [
                                "branch": ["type": "string", "description": "Branch the worker commits on; its tip must equal base_sha. linkC gates and verifies in the git worktree that has this branch checked out, else in the project root"],
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
                "name": "linkc_ask",
                "description": "Ask an agent in another project a question. It answers from its own context, and the answer (at most 1,000 characters) comes back to this session as a [linkC task …] line. Use linkc_list_projects to see the projects.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "Target project's folder name or path"],
                        "question": ["type": "string", "description": "The question to ask"],
                        "to": ["type": "string", "description": "Target agent kind (\(AgentKind.peerList)); defaults to claude"],
                        "tier": ["type": "string", "description": "Model tier: light, standard or deep"]
                    ],
                    "required": ["project", "question"]
                ]
            ],
            [
                "name": "linkc_send_message",
                "description": "Send a direct message or peer note to another agent in the workspace. Several workers of one agent can run at once: pass task_id to reach the worker holding that task.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Target agent kind (\(AgentKind.peerList)). Optional with reply_to (taken from the original message)."],
                        "message": ["type": "string", "description": "Message or note content to send"],
                        "from": ["type": "string", "description": "Sender agent kind (optional, defaults to claude)"],
                        "task_id": ["type": "string", "description": "Optional. The message goes to the worker holding this task, not the first session of the agent. Refused while the task has no worker yet."],
                        "project": ["type": "string", "description": "Optional. Another project's folder name or path; the message is delivered there."],
                        "reply_to": ["type": "string", "description": "Optional. Id of a cross-project message in this inbox to reply to."]
                    ],
                    "required": ["message"]
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
                "description": "Switch the active model for an agent in the workspace using free/subscription tier models (injecting /model <model> into the agent's terminal). Several workers of one agent can run at once: pass task_id to switch the worker holding that task.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent": ["type": "string", "description": "Agent kind (\(AgentKind.peerList)), defaults to the task's agent with task_id, else claude"],
                        "model": ["type": "string", "description": "Model name (e.g. sonnet, haiku, opus, gpt-4o, o3-mini, pro, flash, flash_lite)"],
                        "task_id": ["type": "string", "description": "Optional. Switches the worker holding this task, not the first session of the agent. Refused while the task has no worker yet."]
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
                        "agent": ["type": "string", "description": "Agent kind (\(AgentKind.peerList)), optional"]
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
                        "tests": ["type": "array", "items": ["type": "string"], "description": "Deprecated; ignored"],
                        "close_session": ["type": "boolean", "description": "Also ask linkC to close this session once your turn ends. Honoured only for a session linkC launched as a worker (any worker linkC launched, including one reused for a later task) that holds no other open task, waits on none it delegated, and is not the session on screen; otherwise the session stays and linkC says why. A finished worker closes by itself about a minute after it goes idle."]
                    ],
                    "required": ["task_id", "status", "summary"]
                ]
            ],
            [
                "name": "linkc_close_worker",
                "description": "Close the terminal session of the worker that carried a task you delegated, to free it before it closes by itself about a minute after it goes idle. linkC closes it only if it is a worker linkC launched, the session is idle, and it holds no other open task and waits on none it delegated; a session the user started or took over by typing into it, and the one selected in the panel, are never closed. Otherwise you get the reason.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["task_id": ["type": "string", "description": "A task you delegated; its reported or ended state is required"]],
                    "required": ["task_id"]
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

            case "linkc_list_projects":
                do {
                    return try listProjectsResult(id: id)
                } catch {
                    return errorResult(id: id, error)
                }

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
                do {
                    let noteTitle: String?
                    if let rawNote = args["note"] {
                        guard let title = rawNote as? String else { throw LinkCError.server("note must be a note title") }
                        noteTitle = title
                    } else {
                        noteTitle = nil
                    }
                    let target = try targetProject(args)
                    let boardStore = target.map { BlackboardStore(workspaceRoot: $0.path) } ?? store
                    return try projectContextResult(
                        id: id,
                        store: boardStore,
                        crossProjectName: target?.name,
                        noteTitle: noteTitle
                    )
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_get_board":
                let root: String
                do {
                    root = try targetProject(args)?.path ?? workspaceRoot
                } catch {
                    return errorResult(id: id, error)
                }
                do {
                    return try boardResult(id: id, root: root, boardArg: args["board"] as? String)
                } catch {
                    return toolResultResponse(id: id, text: BoardReport.sanitized(error.localizedDescription), isError: true)
                }

            case "linkc_edit_board":
                do {
                    let rawBoard = args["board"] as? String
                    let slug: String?
                    if let rawBoard, rawBoard != "overview" {
                        slug = rawBoard
                    } else {
                        slug = nil
                    }

                    if let slug {
                        let projectName = URL(fileURLWithPath: workspaceRoot).lastPathComponent
                        let catalog = try BoardCatalog.load(workspacePath: workspaceRoot, projectName: projectName)
                        guard BoardSlug.isValid(slug), catalog.entry(for: slug) != nil else {
                            let known = (["overview"] + catalog.entries.compactMap(\.slug)).joined(separator: ", ")
                            return toolResultResponse(id: id, text: "unknown board \"\(slug)\" — known boards: \(known)", isError: true)
                        }
                    }

                    let steps = try BoardEdit.steps(from: args["steps"])
                    let lines = try Self.editBoard(store: BoardMapStore(workspacePath: workspaceRoot, board: slug), steps: steps)
                    return toolResultResponse(id: id, text: lines.joined(separator: "\n") + "\nBoard updated.")
                } catch let refusal as BoardEditRefusal {
                    return toolResultResponse(id: id, text: refusal.description, isError: true)
                } catch {
                    return toolResultResponse(id: id, text: BoardReport.sanitized(error.localizedDescription), isError: true)
                }

            case "linkc_delegate_task":
                do {
                    let target = try targetProject(args)
                    let destStore = target.map { InboxStore(workspaceRoot: $0.path) } ?? inboxStore
                    let destRoot = target?.path ?? workspaceRoot
                    return try createDelegatedTask(
                        id: id, caller: caller, args: args, destStore: destStore, destRoot: destRoot,
                        crossProject: target.map { (name: $0.name, path: $0.path) }
                    )
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_ask":
                if args["verify"] != nil {
                    return toolResultResponse(id: id, text: "Error: an ask cannot be verified.", isError: true)
                }
                guard let question = args["question"] as? String, !question.isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'question'.", isError: true)
                }
                do {
                    guard let target = try targetProject(args) else {
                        return toolResultResponse(id: id, text: "Error: Missing required argument 'project'.", isError: true)
                    }
                    var askArgs = args
                    askArgs["prompt"] = question
                    if askArgs["to"] == nil { askArgs["to"] = AgentKind.claude.rawValue }
                    askArgs["files"] = [String]()
                    return try createDelegatedTask(
                        id: id, caller: caller, args: askArgs,
                        destStore: InboxStore(workspaceRoot: target.path), destRoot: target.path,
                        crossProject: (name: target.name, path: target.path),
                        isQuestion: true
                    )
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_send_message":
                guard let messageText = args["message"] as? String, !messageText.isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'message'.", isError: true)
                }
                let replyTo: String?
                if let rawReplyTo = args["reply_to"] {
                    guard let messageId = rawReplyTo as? String else {
                        return toolResultResponse(id: id, text: "reply_to must be a message id", isError: true)
                    }
                    replyTo = messageId
                } else {
                    replyTo = nil
                }
                if replyTo != nil || args["project"] != nil {
                    // An empty task_id names no task, as it does for a message to this project.
                    let taskIdGiven = args["task_id"] != nil
                        && (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) != ""
                    if taskIdGiven {
                        return toolResultResponse(id: id, text: "task_id cannot be combined with project or reply_to.", isError: true)
                    }
                    if messageText.count > PendingMessage.crossProjectMessageLimit {
                        return toolResultResponse(
                            id: id,
                            text: "Messages to another project are at most 2,000 characters. Point to a file path instead; both projects are on this Mac.",
                            isError: true
                        )
                    }
                }

                if let replyTo {
                    do {
                        return try crossProjectReplyResult(id: id, caller: caller, args: args, replyTo: replyTo, messageText: messageText)
                    } catch {
                        return errorResult(id: id, error)
                    }
                }

                do {
                    if let target = try targetProject(args) {
                        return try crossProjectSendResult(id: id, caller: caller, args: args, target: target, messageText: messageText)
                    }
                } catch {
                    return errorResult(id: id, error)
                }

                guard let toStr = args["to"] as? String, !toStr.isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'to'.", isError: true)
                }
                guard let toAgent = AgentKind(rawValue: toStr.lowercased()) else {
                    return toolResultResponse(id: id, text: "Error: Unknown agent '\(toStr)'. Supported agents: \(AgentKind.peerList).", isError: true)
                }

                do {
                    let worker = try taskWorker(args, agent: toAgent)
                    let destStore = worker?.store ?? inboxStore
                    // The worker of a task sent to another project is in that project: the message crosses
                    // projects, so it carries its origin and keeps to the cross-project size (spec §6.1, §6.3).
                    let ownRoot = ProjectPath.canonical(workspaceRoot)
                    let crossesProjects = worker.map { ProjectPath.canonical($0.root) != ownRoot } ?? false
                    if crossesProjects, messageText.count > PendingMessage.crossProjectMessageLimit {
                        return toolResultResponse(
                            id: id,
                            text: "Messages to another project are at most 2,000 characters. Point to a file path instead; both projects are on this Mac.",
                            isError: true
                        )
                    }
                    let pending = try destStore.enqueue(from: caller.agent, to: toAgent, kind: .peerNote,
                                                         toSessionId: worker?.sessionId, body: messageText,
                                                         fromProject: crossesProjects ? ownRoot : nil,
                                                         fromSessionId: crossesProjects ? callerSessionId() : nil)
                    if let worker {
                        return toolResultResponse(id: id, text: "Message queued for the \(toAgent.displayName) worker holding task \(worker.task.shortId) (ID: \(pending.id)). linkC delivers it when that worker is idle; if the worker has ended by then, the message fails.")
                    }
                    return toolResultResponse(id: id, text: "Message queued for \(toAgent.displayName) (ID: \(pending.id)). linkC will deliver it when idle.")
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_get_inbox":
                let inbox: Inbox
                do {
                    inbox = try inboxStore.load()
                } catch {
                    return errorResult(id: id, error)
                }
                let now = Date()
                var text = "# linkC Message Inbox\n\n"

                let activeLimits = inbox.agentLimits.filter { $0.cooldownExpiresAt > now }
                if !activeLimits.isEmpty {
                    text += "## Active Agent Limits & Cooldowns\n"
                    for limit in activeLimits {
                        let remainingSec = max(0, Int(limit.cooldownExpiresAt.timeIntervalSince(now)))
                        let remainingMin = remainingSec / 60
                        let scope = limit.pool.map { ", \(ModelPool.displayName($0)) pool" } ?? ""
                        text += "- **\(limit.agent.displayName)** (\(limit.agent.rawValue)\(scope)): \(limit.reason) (cooldown: \(remainingMin)m remaining)\n"
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
                let named = (args["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let worker: (task: TaskRecord, sessionId: String, store: InboxStore, root: String)?
                do {
                    worker = try taskWorker(args, agent: named.flatMap { AgentKind(rawValue: $0.lowercased()) })
                } catch {
                    return errorResult(id: id, error)
                }
                let agentStr = named ?? worker?.task.toAgent.rawValue ?? caller.agent.rawValue
                guard let agent = AgentKind(rawValue: agentStr.lowercased()) else {
                    return toolResultResponse(id: id, text: "Error: Unknown agent '\(agentStr)'. Supported agents: \(AgentKind.peerList).", isError: true)
                }
                guard agent != .shell else {
                    return toolResultResponse(id: id, text: "Error: Cannot switch model on shell session.", isError: true)
                }
                guard agent != .opencode else {
                    // OpenCode has no `/model <id>` command: typed in, it goes to the model as a prompt.
                    return toolResultResponse(id: id, text: "Error: opencode cannot switch a running session's model — delegate at another tier instead.", isError: true)
                }
                guard let model = args["model"] as? String, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return toolResultResponse(id: id, text: "Error: Missing required argument 'model'.", isError: true)
                }
                let typedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                let settings = modelSettings()
                let lists: [AgentKind: AgentModelList]
                do {
                    lists = try modelLists()
                } catch {
                    return toolResultResponse(id: id, text: "Error: could not read the live model lists — \(error)", isError: true)
                }
                let choosable = ModelListCache.choosable(for: agent, lists: lists, settings: settings)
                // The listed spelling is what the CLI is told, whatever case it was typed in.
                guard let listed = choosable.first(where: { $0.id.caseInsensitiveCompare(typedModel) == .orderedSame }) else {
                    let allowed = choosable.isEmpty ? "none listed yet" : choosable.map(\.id).joined(separator: ", ")
                    return toolResultResponse(id: id, text: "Error: '\(typedModel)' is not among the models \(agent.displayName) lists. Available: \(allowed)", isError: true)
                }
                let cleanModel = listed.id
                do {
                    if let limitStatus = try inboxStore.isAgentLimited(agent: agent, model: cleanModel) {
                        let refusal = try Self.limitRefusal(
                            agent: agent, limit: limitStatus, model: cleanModel,
                            readLists: { lists }, settings: settings, inboxStore: inboxStore)
                        return toolResultResponse(id: id, text: "Error: \(refusal)", isError: true)
                    }
                } catch {
                    return errorResult(id: id, error)
                }

                let destRoot = worker?.root ?? workspaceRoot
                let destStore = worker?.store ?? inboxStore
                if let modelSwitcher {
                    do {
                        let result = try modelSwitcher(agent, cleanModel, worker?.sessionId, destRoot)
                        return toolResultResponse(id: id, text: result)
                    } catch {
                        return errorResult(id: id, error)
                    }
                } else {
                    let cmd = AgentModelCatalog.interactiveSwitchCommand(model: cleanModel, for: agent)
                    do {
                        _ = try destStore.enqueue(from: agent, to: agent, kind: .command, toSessionId: worker?.sessionId, body: cmd)
                    } catch {
                        return errorResult(id: id, error)
                    }
                    return toolResultResponse(id: id, text: "Model switch requested: enqueued '\(cmd)' for \(agent.displayName). linkC will inject it via terminal PTY.")
                }

            case "linkc_get_models":
                let targetAgents: [AgentKind]
                if let agentStr = args["agent"] as? String, !agentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let a = AgentKind(rawValue: agentStr.lowercased()) else {
                        return toolResultResponse(id: id, text: "Error: Unknown agent '\(agentStr)'. Supported agents: \(AgentKind.peerList).", isError: true)
                    }
                    guard a != .shell else {
                        return toolResultResponse(id: id, text: "Error: Shell does not support AI models.", isError: true)
                    }
                    targetAgents = [a]
                } else {
                    targetAgents = [.claude, .codex, .agy, .cursor, .grok, .opencode]
                }

                let settings = modelSettings()
                let lists: [AgentKind: AgentModelList]
                do {
                    lists = try modelLists()
                } catch {
                    return toolResultResponse(id: id, text: "Error: could not read the live model lists — \(error)", isError: true)
                }
                var text = "# Models\n\n"
                let now = Date()
                for agent in targetAgents {
                    text += "## \(agent.displayName)\n"
                    let liveLimits: [AgentLimitStatus]
                    do {
                        liveLimits = try inboxStore.liveLimits(agent: agent)
                    } catch {
                        return errorResult(id: id, error)
                    }
                    if liveLimits.isEmpty {
                        text += "Status: Active / Available\n\n"
                    } else {
                        // One limit per quota pool for agy: each says which pool it covers, and the pools
                        // that are not limited are named, so a Gemini limit never reads as Claude being out.
                        for limit in liveLimits.sorted(by: { $0.cooldownExpiresAt > $1.cooldownExpiresAt }) {
                            let remainingMin = max(0, Int(limit.cooldownExpiresAt.timeIntervalSince(now))) / 60
                            let scope = limit.pool.map { " (\(ModelPool.displayName($0)) pool)" } ?? ""
                            text += "⚠️ **Rate Limited**\(scope): \(limit.reason) (\(remainingMin)m cooldown remaining)\n"
                        }
                        if agent == .agy, !liveLimits.contains(where: { $0.pool == nil }) {
                            let agyPools: [String] = ["gemini", "claude-gpt"]
                            let free = agyPools.filter { pool in !liveLimits.contains { $0.pool == pool } }
                            let names = free.map { "\(ModelPool.displayName($0)) pool" }
                            if !names.isEmpty {
                                text += "Available: \(names.joined(separator: ", "))\n"
                            }
                        }
                        text += "\n"
                    }
                    let list = lists[agent]
                    if let fetchedAt = list?.fetchedAt {
                        text += "- Listed \(AgeFormat.compact(from: fetchedAt, to: now)) ago\n"
                    }
                    if let error = list?.error {
                        text += "- Last refresh error: \(error)\n"
                    }
                    if agent == .cursor {
                        text += "- cursor cannot be pinned to a model\n\n"
                        continue
                    }
                    text += "### Tiers\n"
                    for tier in ModelTier.resolutionOrder {
                        let id = settings.model(for: agent, tier: tier) ?? "(not set)"
                        let marker = tier == settings.defaultTier(for: agent) ? " — default" : ""
                        text += "- **\(tier.rawValue)**: \(id)\(marker)\n"
                    }
                    let available = ModelListCache.available(for: agent, lists: lists, settings: settings)
                    text += "### Listed\n"
                    if available.isEmpty {
                        text += "- (none yet)\n"
                    } else {
                        for listed in available {
                            var line = "- \(listed.id)"
                            if listed.name != listed.id { line += " — \(listed.name)" }
                            let tiers = ModelTier.resolutionOrder.filter {
                                settings.model(for: agent, tier: $0)?.caseInsensitiveCompare(listed.id) == .orderedSame
                            }
                            if !tiers.isEmpty {
                                line += " (tier \(tiers.map(\.rawValue).joined(separator: ", ")))"
                            }
                            if let pool = ModelPool.pool(of: listed.id, agent: agent) {
                                line += " [pool \(ModelPool.displayName(pool))]"
                                if liveLimits.contains(where: { $0.pool == pool }) { line += " — limited" }
                            }
                            text += line + "\n"
                        }
                    }
                    if agent == .opencode {
                        text += "- opencode cannot switch a running session's model; delegate at another tier\n"
                    }
                    text += "\n"
                }
                text += "Edit tier defaults in linkC settings under MODELS.\n"
                return toolResultResponse(id: id, text: text)

            case "linkc_get_usage_status":
                let inbox: Inbox
                do {
                    inbox = try inboxStore.load()
                } catch {
                    return errorResult(id: id, error)
                }
                let now = Date()
                var text = "# Agent Usage\n\n"

                for agent in [AgentKind.codex, .claude, .agy, .cursor, .grok, .opencode] {
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

                        let scope = limit.pool.map { " — \(ModelPool.displayName($0)) pool" } ?? ""
                        text += "### \(limit.agent.displayName) (\(limit.agent.rawValue))\(scope)\n"
                        text += "- **Reason:** \(limit.reason)\n"
                        text += "- **Cooldown Remaining:** \(remainingMin)m (\(remainingSec)s)\n"
                        text += "- **Expires At:** \(limit.cooldownExpiresAt)\n\n"
                    }
                }

                return toolResultResponse(id: id, text: text)

            case "linkc_start_task":
                do {
                    let task = try requireOwnTask(args)
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
                    return errorResult(id: id, error)
                }

            case "linkc_complete_task":
                do {
                    let task = try requireOwnTask(args)
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
                    let closeSession: Bool
                    switch args["close_session"] {
                    case nil, is NSNull:
                        closeSession = false
                    case let flag as Bool:
                        closeSession = flag
                    default:
                        return toolResultResponse(id: id, text: "Error: close_session must be true or false.", isError: true)
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

                    var text: String
                    if task.verification == nil {
                        text = "Reported. Unverified task."
                    } else if status == "done", let sha {
                        text = "Reported. linkC is verifying at \(VerificationRunner.short(sha))."
                    } else {
                        text = "Reported. linkC will mark the task failed."
                    }
                    if closeSession {
                        text += " " + closeOwnSession(after: task)
                    }
                    return toolResultResponse(id: id, text: text)
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_close_worker":
                do {
                    let resolved = try requireTask(args)
                    let task = resolved.task
                    guard caller.agent == task.fromAgent, callerDelegated(task) else {
                        return toolResultResponse(id: id, text: "Error: only the agent that delegated task \(task.shortId) (\(task.fromAgent.displayName)) may close its worker.", isError: true)
                    }
                    let request = try resolved.store.requestClose(taskId: task.id, by: .delegator)
                    guard let answer = try awaitAnswer(to: request, on: task.id, store: resolved.store) else {
                        return toolResultResponse(id: id, text: "Close requested for the worker of task \(task.shortId), but linkC has not answered yet (is it running?). The request may still be acted on if the worker still qualifies; linkc_get_task(\"\(task.id)\") shows the outcome.")
                    }
                    if let refusal = answer.refusal {
                        return errorResult(id: id, InboxError.closeRefused(refusal))
                    }
                    return toolResultResponse(id: id, text: "Closed the worker that carried task \(task.shortId).")
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_cancel_task":
                do {
                    let resolved = try requireTask(args)
                    let task = resolved.task
                    let force = args["force"] as? Bool ?? false
                    let isAssignee = caller.agent == task.toAgent && callerMayAct(on: task)
                    guard force || caller.agent == task.fromAgent || isAssignee else {
                        return toolResultResponse(id: id, text: "Error: only \(task.fromAgent.displayName) or \(task.toAgent.displayName) may cancel task \(task.shortId); pass force: true to override.", isError: true)
                    }
                    let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedReason = (reason?.isEmpty == false) ? reason! : "cancelled by \(caller.agent.displayName)"
                    let wasDelivered = task.state == .delivered || task.state == .started
                    try resolved.store.cancelTask(taskId: task.id, reason: resolvedReason)
                    let successText = "Cancelled task \(task.shortId) (\(resolvedReason))."
                    if wasDelivered {
                        // The delegator (or anyone forcing it) stopping the work tells the worker to stop. The
                        // worker giving the task up tells the delegator instead: addressed to no session, so
                        // for a task from another project the relay forwards it home.
                        let notified = isAssignee ? task.fromAgent : task.toAgent
                        do {
                            if isAssignee {
                                _ = try resolved.store.enqueue(
                                    from: caller.agent, to: task.fromAgent, kind: .completion,
                                    taskId: task.id, body: "cancelled by its worker: \(resolvedReason)"
                                )
                            } else {
                                _ = try resolved.store.enqueue(
                                    from: caller.agent, to: task.toAgent, kind: .completion,
                                    taskId: task.id, toSessionId: task.assigneeSessionId,
                                    body: "cancelled: \(resolvedReason). Stop work on it."
                                )
                            }
                        } catch {
                            let warning = "Warning: task state was updated but notifying \(notified.displayName) failed: \(error.localizedDescription). They can run linkc_get_task(\"\(task.id)\")."
                            return toolResultResponse(id: id, text: "\(successText)\n\(warning)")
                        }
                    }
                    return toolResultResponse(id: id, text: successText)
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_get_task":
                do {
                    let resolved = try requireTask(args)
                    return toolResultResponse(id: id, text: taskMarkdown(resolved.task))
                } catch {
                    return errorResult(id: id, error)
                }

            case "linkc_my_tasks":
                guard caller.isIdentified else {
                    return toolResultResponse(id: id, text: Self.unidentifiedCallerMessage, isError: true)
                }
                let assigned: [TaskRecord]
                var delegatedLines: [String] = []
                do {
                    assigned = try inboxStore.openTasks(for: caller.agent).filter { callerMayAct(on: $0) }
                    let localDelegated = try inboxStore.openTasks().filter { $0.fromAgent == caller.agent && $0.toAgent != caller.agent }
                    delegatedLines = localDelegated.map { "- \(taskLine($0))" }
                    for pointer in try inboxStore.sentTasks() {
                        let name = URL(fileURLWithPath: pointer.project).lastPathComponent
                        let task: TaskRecord?
                        do {
                            task = try InboxStore(workspaceRoot: pointer.project).task(id: pointer.taskId)
                        } catch {
                            delegatedLines.append("- \(name): could not be read (\(error.localizedDescription))")
                            continue
                        }
                        guard let task else {
                            // The task is gone from that inbox: the pointer has nothing left to point at.
                            try inboxStore.dropSent(taskId: pointer.taskId)
                            continue
                        }
                        if task.state.isOpen { delegatedLines.append("- \(taskLine(task)) → \(name)") }
                    }
                } catch {
                    return errorResult(id: id, error)
                }
                var text = "# Open tasks for \(caller.agent.displayName)\n\n## Assigned to you (\(assigned.count))\n"
                text += assigned.isEmpty ? "_None._\n" : assigned.map { "- \(taskLine($0))" }.joined(separator: "\n") + "\n"
                text += "\n## Delegated by you (\(delegatedLines.count))\n"
                text += delegatedLines.isEmpty ? "_None._\n" : delegatedLines.joined(separator: "\n") + "\n"
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
        if let close = t.closeRequest {
            let outcome = close.refusal.map { "refused — \($0)" } ?? close.closedAt.map { "closed at \(iso.string(from: $0))" } ?? "pending"
            text += "- **Close request:** \(outcome) (asked by the \(close.by.rawValue))\n"
        }
        text += "\n## Brief\n\(t.prompt)\n"
        if let r = t.report {
            text += "\n## Report (\(r.status))\n\(r.summary)\n"
            if let sha = r.sha { text += "\n**Sha:** \(VerificationRunner.short(sha))\n" }
            if !r.commits.isEmpty { text += "\n**Commits:** \(r.commits.joined(separator: ", "))\n" }
        }
        if let v = t.verification {
            text += "\n## Verification\n- **Branch:** \(v.branch)\n- **Base:** \(VerificationRunner.short(v.baseSha))\n- **Command:** `\(v.command)`\n"
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

    /// The pieces of a limit refusal: the limit itself, and what is not limited.
    struct LimitDescription: Equatable {
        /// "agy's Gemini pool is limited until Fri 09:12 (quota exceeded)".
        let limit: String
        /// What is not limited, as a list; nil when everything is.
        let notLimited: String?
        /// Set when the model lists could not be read, and the unlimited models may be missing from the text.
        let caveat: String
    }

    /// "Fri 09:12": when a limit ends, in the reader's own time zone.
    static func limitEndText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// Refusal when a model (or its pool) is limited: names the limit, and what is not limited. A
    /// limit status that cannot be read throws; a list of models that cannot be read is said in the
    /// refusal itself, and the limit is still reported. `lockTimeout` is how long a store read waits
    /// for the inbox lock: the relay passes its own short one.
    static func limitRefusal(
        agent: AgentKind,
        limit: AgentLimitStatus,
        model: String?,
        readLists: () throws -> [AgentKind: AgentModelList],
        settings: AgentModelSettings,
        inboxStore: InboxStore,
        lockTimeout: TimeInterval = 5.0
    ) throws -> String {
        let described = try limitDescription(
            agent: agent, limit: limit, model: model, readLists: readLists, settings: settings,
            inboxStore: inboxStore, lockTimeout: lockTimeout)
        return "\(described.limit). Not limited: \(described.notLimited ?? "none").\(described.caveat)"
    }

    /// What a refusal for `limit` says, in pieces, for a caller that words the rest itself.
    static func limitDescription(
        agent: AgentKind,
        limit: AgentLimitStatus,
        model: String?,
        readLists: () throws -> [AgentKind: AgentModelList],
        settings: AgentModelSettings,
        inboxStore: InboxStore,
        lockTimeout: TimeInterval = 5.0
    ) throws -> LimitDescription {
        let until = limitEndText(limit.cooldownExpiresAt)
        let subject: String
        if let pool = limit.pool {
            subject = "\(agent.rawValue)'s \(ModelPool.displayName(pool)) pool"
        } else {
            subject = agent.rawValue
        }
        var caveat = ""
        let lists: [AgentKind: AgentModelList]
        do {
            lists = try readLists()
        } catch {
            NSLog("[linkC mcp] limit refusal — the model lists could not be read: %@", String(describing: error))
            lists = [:]
            caveat = " (The model lists could not be read: \(error).)"
        }
        let agyLimits = try inboxStore.liveLimits(agent: .agy, timeout: lockTimeout)
        var parts: [String] = []
        for peer in AgentKind.peers {
            if peer == .agy {
                for pool in ["gemini", "claude-gpt"] {
                    // The pool this refusal is about is limited; so is any pool a live limit covers.
                    if agent == .agy, pool == limit.pool { continue }
                    if agyLimits.contains(where: { $0.pool == nil || $0.pool == pool }) { continue }
                    let ids = ModelListCache.available(for: .agy, lists: lists, settings: settings)
                        .filter { ModelPool.pool(of: $0.id, agent: .agy) == pool }
                        .map(\.id)
                    let listed = ids.isEmpty ? "" : " (\(ids.joined(separator: ", ")))"
                    parts.append("agy's \(ModelPool.displayName(pool)) pool\(listed)")
                }
            } else if peer != agent, try inboxStore.isAgentLimited(agent: peer, timeout: lockTimeout) == nil {
                parts.append(peer.rawValue)
            }
        }
        return LimitDescription(
            limit: "\(subject) is limited until \(until) (\(limit.reason))",
            notLimited: parts.isEmpty ? nil : parts.joined(separator: ", "),
            caveat: caveat)
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
    private func resolveVerification(_ raw: [String: Any], in root: String? = nil) throws -> Verification {
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
        let workspace = URL(fileURLWithPath: root ?? workspaceRoot)
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

    private func taskIdArgument(_ args: [String: Any]) throws -> String {
        guard let taskId = (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !taskId.isEmpty else {
            throw LinkCError.server("Missing required argument 'task_id'.")
        }
        return taskId
    }

    /// Resolves `task_id` in this inbox only. The assignee's tools (`linkc_start_task`,
    /// `linkc_complete_task`) use it: a task this project sent elsewhere is not its to start or answer.
    private func requireOwnTask(_ args: [String: Any]) throws -> TaskRecord {
        let taskId = try taskIdArgument(args)
        guard let task = try inboxStore.task(matching: taskId) else { throw InboxError.taskNotFound(taskId) }
        return task
    }

    /// Resolves `task_id` in this inbox, or through a `sentTasks` pointer into the project that holds it
    /// (spec 2026-11-11 cross-project §5.4 / §6.3).
    private func requireTask(_ args: [String: Any]) throws -> (task: TaskRecord, store: InboxStore, root: String) {
        let taskId = try taskIdArgument(args)
        if let task = try inboxStore.task(matching: taskId) {
            return (task, inboxStore, workspaceRoot)
        }
        guard let pointer = try inboxStore.sentTask(matching: taskId) else {
            throw InboxError.taskNotFound(taskId)
        }
        let remote = InboxStore(workspaceRoot: pointer.project)
        if let task = try remote.task(id: pointer.taskId) {
            return (task, remote, ProjectPath.canonical(pointer.project))
        }
        try inboxStore.dropSent(taskId: pointer.taskId)
        throw InboxError.taskNotFound(taskId)
    }

    /// The task `args["task_id"]` names and the session holding it, or nil when no task is named. Throws
    /// when the task does not exist, no worker holds it yet, or it is for another agent than `agent`.
    /// Follows a `sentTasks` pointer so a message or model switch reaches the worker in the other project.
    private func taskWorker(_ args: [String: Any], agent: AgentKind?) throws -> (task: TaskRecord, sessionId: String, store: InboxStore, root: String)? {
        guard let taskId = (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !taskId.isEmpty else {
            return nil
        }
        let resolved = try requireTask(args)
        let task = resolved.task
        if let agent, agent != task.toAgent {
            throw LinkCError.server("Task \(task.shortId) is for \(task.toAgent.displayName), not \(agent.displayName).")
        }
        guard let sessionId = task.assigneeSessionId else {
            throw LinkCError.server("Task \(task.shortId) has no worker yet (it is \(task.state.rawValue)). Send this once the task has started.")
        }
        return (task, sessionId, resolved.store, resolved.root)
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

    /// Whether the caller is the session that delegated `task`. A task with no delegating session
    /// (written before they were recorded, or delegated from outside linkC), or a caller with no
    /// session id, is not locked out for the same reason as in `callerMayAct`.
    private func callerDelegated(_ task: TaskRecord) -> Bool {
        guard let delegator = task.fromSessionId,
              let caller = callerSessionId() else { return true }
        return delegator == caller
    }

    /// The reporting worker's own request to close its session, after its report is recorded:
    /// a sentence for the tool result. A refusal is stated, not raised — the report already
    /// landed and stays.
    private func closeOwnSession(after task: TaskRecord) -> String {
        do {
            _ = try inboxStore.requestClose(taskId: task.id, by: .worker)
            return "Close requested: linkC closes this session after your turn ends if it launched it as a worker, it holds no other open task, and nothing was typed into it after the task ended."
        } catch InboxError.closeRefused(let reason) {
            return "Not closing this session: \(reason)"
        } catch {
            return "Warning: the close request was not recorded: \(error.localizedDescription)"
        }
    }

    /// linkC's answer to `request`, polled from the task until `closeAnswerWait` runs out; nil when
    /// none came. Only the answer to this very request counts — an earlier one is not. The request
    /// is already recorded, so a poll that cannot take the inbox lock (the relay holds it while it
    /// decides) is not an answer yet, not a failure of the request; any other read error is.
    private func awaitAnswer(to request: CloseRequest, on taskId: String, store: InboxStore) throws -> CloseRequest? {
        var waited: TimeInterval = 0
        while true {
            let current: TaskRecord?
            do {
                current = try store.task(id: taskId)
            } catch LinkCError.lockTimeout {
                return nil
            }
            if let answer = current?.closeRequest, answer.id == request.id, !answer.isPending {
                return answer
            }
            guard waited < closeAnswerWait.timeout else { return nil }
            closeAnswerWait.sleep(closeAnswerWait.interval)
            waited += closeAnswerWait.interval
        }
    }

    /// Applies `steps` to the Board, load–apply–save, and retries once if the file changed on
    /// disk between the load and the save — the same race `handleToolsCall` never otherwise
    /// meets, since one `MCPServer` handles one call at a time, but another process (or another
    /// linkC session) can still write `system-map.json` in between. `beforeSave` is a seam a test
    /// uses to force that race; production never overrides it. Throws `BoardEditRefusal` for a
    /// bad step, or `LinkCError.server` when the file kept changing after the retry.
    static func editBoard(store: BoardMapStore, steps: [BoardEditStep], beforeSave: () throws -> Void = {}) throws -> [String] {
        let workspacePath = store.fileURL.deletingLastPathComponent().path
        var takenSlugs = try BoardDrill.takenSlugs(in: workspacePath)
        let currentBoardSlug = BoardSlug.slug(fromFileName: store.fileURL.lastPathComponent)

        let detailResolver: (String) -> String = { partName in
            let newSlug = BoardSlug.new(for: partName, under: currentBoardSlug, taken: takenSlugs)
            takenSlugs.insert(newSlug)
            return newSlug
        }

        let first = try store.load()
        let (applied, lines) = try BoardEdit.apply(steps, to: first?.map ?? .empty, detailSlug: detailResolver)
        let map = BoardLayout.arranged(applied)
        try createDetailFiles(for: steps, map: map, store: store)
        try beforeSave()
        do {
            _ = try store.save(map, expecting: first?.bytes)
            return lines
        } catch BoardMapStoreError.changedOnDisk {
            let second = try store.load()
            let (retriedApplied, retriedLines) = try BoardEdit.apply(steps, to: second?.map ?? .empty, detailSlug: detailResolver)
            let retriedMap = BoardLayout.arranged(retriedApplied)
            try createDetailFiles(for: steps, map: retriedMap, store: store)
            try beforeSave()
            do {
                _ = try store.save(retriedMap, expecting: second?.bytes)
                return retriedLines
            } catch BoardMapStoreError.changedOnDisk {
                throw LinkCError.server("the map kept changing while this edit was saved — try again")
            }
        }
    }

    private static func createDetailFiles(for steps: [BoardEditStep], map: BoardMap, store: BoardMapStore) throws {
        let workspacePath = store.fileURL.deletingLastPathComponent().path
        for step in steps {
            guard case .detail(let name) = step else { continue }
            guard let part = map.components.first(where: { $0.name.lowercased() == name.lowercased() }),
                  let slug = part.detail else { continue }
            do {
                try BoardDrill.createDetailFileIfMissing(slug: slug, part: part, parent: map, workspacePath: workspacePath)
            } catch {
                throw LinkCError.server("could not create detail board \"\(slug)\": \(error.localizedDescription)")
            }
        }
    }

    /// Shared body of `linkc_delegate_task` / `linkc_ask`. `destStore`/`destRoot` are this project or another.
    private func createDelegatedTask(
        id: Any?,
        caller: MCPCaller,
        args: [String: Any],
        destStore: InboxStore,
        destRoot: String,
        crossProject: (name: String, path: String)?,
        isQuestion: Bool = false
    ) throws -> Data? {
        // A known project whose folder was deleted since linkC listed it: any write there would create the
        // folder again, with an inbox nobody serves.
        if let crossProject {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: crossProject.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return toolResultResponse(id: id, text: "Error: \(crossProject.name)'s folder \(crossProject.path) no longer exists.", isError: true)
            }
        }
        guard let toStr = args["to"] as? String, !toStr.isEmpty else {
            return toolResultResponse(id: id, text: "Error: Missing required argument 'to'.", isError: true)
        }
        guard let toAgent = AgentKind(rawValue: toStr.lowercased()) else {
            return toolResultResponse(id: id, text: "Error: Unknown agent '\(toStr)'. Supported agents: \(AgentKind.peerList).", isError: true)
        }
        guard toAgent != .shell else {
            return toolResultResponse(id: id, text: "Error: Cannot delegate tasks to interactive terminal shell. Target an AI CLI agent (\(AgentKind.peerList)).", isError: true)
        }
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            return toolResultResponse(id: id, text: "Error: Missing required argument 'prompt'.", isError: true)
        }

        let files = args["files"] as? [String] ?? []
        let force = args["force"] as? Bool ?? false

        var verification: Verification?
        switch args["verify"] {
        case nil, is NSNull:
            break
        case let verify as [String: Any]:
            do {
                verification = try resolveVerification(verify, in: destRoot)
            } catch {
                return toolResultResponse(id: id, text: "Error: \(error.localizedDescription)", isError: true)
            }
        default:
            return toolResultResponse(id: id, text: "Error: verify must be an object.", isError: true)
        }

        // Read once per request: a stable view of the mapping for the whole handler,
        // never cached across calls — the next request reads whatever is on disk then.
        let settings = modelSettings()
        let modelArg: String?
        if let raw = args["model"] {
            guard let text = raw as? String else {
                return toolResultResponse(id: id, text: "Error: model must be a string.", isError: true)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            modelArg = trimmed.isEmpty ? nil : trimmed
        } else {
            modelArg = nil
        }
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
        if modelArg != nil, tierArg != nil {
            return toolResultResponse(id: id, text: "Error: pass tier or model, not both", isError: true)
        }

        // The cache is read only by a check that needs it: a model named by hand, or a tier of
        // an agent whose models come from its CLI. A missing file reads as "nothing listed yet".
        var readLists: [AgentKind: AgentModelList]?
        func lists() throws -> [AgentKind: AgentModelList] {
            if let readLists { return readLists }
            let read = try modelLists()
            readLists = read
            return read
        }
        let listsUnreadable: (Error) -> String = { "Error: could not read the live model lists — \($0)" }

        let tier: ModelTier?
        let model: String?
        if let modelArg {
            guard toAgent != .cursor else {
                return toolResultResponse(id: id, text: "Error: cursor cannot be pinned to a model.", isError: true)
            }
            let choosable: [ListedModel]
            do {
                choosable = ModelListCache.choosable(for: toAgent, lists: try lists(), settings: settings)
            } catch {
                return toolResultResponse(id: id, text: listsUnreadable(error), isError: true)
            }
            if toAgent == .opencode, !OpenCodeFreeModels.isFree(modelArg) {
                let free = choosable.filter { OpenCodeFreeModels.isFree($0.id) }.map(\.id).joined(separator: ", ")
                return toolResultResponse(
                    id: id,
                    text: "Error: \(modelArg) is not free — OpenCode runs free models only. Free models: \(free)",
                    isError: true)
            }
            // The listed spelling is what is stored and launched, whatever case it was typed in.
            guard let listed = choosable.first(where: { $0.id.caseInsensitiveCompare(modelArg) == .orderedSame }) else {
                let ids = choosable.map(\.id).joined(separator: ", ")
                return toolResultResponse(
                    id: id,
                    text: "Error: \(modelArg) is not among the models \(toAgent.displayName) lists. Available: \(ids)",
                    isError: true)
            }
            if toAgent == .opencode {
                let offered: [String]
                do {
                    offered = try openCodeModels(destRoot)
                } catch {
                    return toolResultResponse(
                        id: id,
                        text: "Error: could not check \(listed.id) against the models OpenCode lists — \(error)",
                        isError: true)
                }
                guard offered.contains(where: { $0.caseInsensitiveCompare(listed.id) == .orderedSame }) else {
                    return toolResultResponse(
                        id: id,
                        text: "Error: \(listed.id) is not among the models OpenCode lists — free models come and go; pick another.",
                        isError: true)
                }
            }
            model = listed.id
            tier = nil
        } else if let tierArg {
            guard let parsed = ModelTier(rawValue: tierArg.lowercased()) else {
                return toolResultResponse(id: id, text: "Error: tier must be light, standard or deep.", isError: true)
            }
            guard toAgent != .cursor else {
                return toolResultResponse(id: id, text: "Error: cursor cannot be pinned to a model.", isError: true)
            }
            tier = parsed
            model = nil
        } else if toAgent == .cursor {
            // Cursor was never tiered; an omitted tier keeps working exactly as before.
            tier = nil
            model = nil
        } else {
            tier = settings.defaultTier(for: toAgent)
            model = nil
        }
        if let tier {
            guard settings.model(for: toAgent, tier: tier) != nil else {
                return toolResultResponse(
                    id: id,
                    text: "Error: no model configured for \(toAgent.rawValue) tier \(tier.rawValue) — set it in linkC settings.",
                    isError: true)
            }
        }
        if toAgent == .opencode, let tier, let tierModel = settings.model(for: .opencode, tier: tier) {
            guard OpenCodeFreeModels.isFree(tierModel) else {
                return toolResultResponse(
                    id: id,
                    text: "Error: \(tierModel) (opencode tier \(tier.rawValue)) is not free — OpenCode runs free models only; set the tier in linkC settings.",
                    isError: true)
            }
        }
        // A tier whose model the agent's own list no longer has would start a worker the CLI
        // rejects. Refused now; an agent never listed (or whose last listing failed) is not blocked.
        if let tier, let tierModel = settings.model(for: toAgent, tier: tier),
           ModelListParser.listedAgents.contains(toAgent) {
            do {
                if let offered = ModelListCache.liveModels(for: toAgent, lists: try lists()),
                   !offered.contains(where: { $0.id.caseInsensitiveCompare(tierModel) == .orderedSame }) {
                    return toolResultResponse(
                        id: id,
                        text: "Error: \(toAgent.rawValue)'s \(tier.rawValue) tier is set to \(tierModel), which \(toAgent.rawValue) no longer offers. Pick another in Settings > Models. Offered: \(offered.map(\.id).joined(separator: ", ")).",
                        isError: true)
                }
            } catch {
                return toolResultResponse(id: id, text: listsUnreadable(error), isError: true)
            }
        }
        if toAgent == .opencode, let tier, let tierModel = settings.model(for: .opencode, tier: tier) {
            let offered: [String]
            do {
                offered = try openCodeModels(destRoot)
            } catch {
                return toolResultResponse(
                    id: id,
                    text: "Error: could not check opencode tier \(tier.rawValue)'s model \(tierModel) against the models OpenCode lists — \(error)",
                    isError: true)
            }
            guard offered.contains(tierModel) else {
                return toolResultResponse(
                    id: id,
                    text: "Error: \(tierModel) (opencode tier \(tier.rawValue)) is not among the models OpenCode lists — free models come and go; set the tier in linkC settings.",
                    isError: true)
            }
        }

        // The limit that applies is the one in the project that does the work, for the model it would run.
        let limitModel = model ?? tier.flatMap { settings.model(for: toAgent, tier: $0) }
        if let limitStatus = try destStore.isAgentLimited(agent: toAgent, model: limitModel) {
            let refusal = try Self.limitRefusal(
                agent: toAgent, limit: limitStatus, model: limitModel, readLists: lists,
                settings: settings, inboxStore: destStore)
            return toolResultResponse(id: id, text: "Error: \(refusal)", isError: true)
        }

        let fromProject = crossProject.map { _ in ProjectPath.canonical(workspaceRoot) }
        let task = try destStore.createTask(
            from: caller.agent, to: toAgent,
            fromSessionId: callerSessionId(),
            tier: tier, model: model,
            prompt: prompt, files: files,
            hop: try newTaskHop(),
            force: force, verification: verification,
            fromProject: fromProject, isQuestion: isQuestion
        )

        if let crossProject {
            do {
                try inboxStore.recordSent(SentTask(
                    taskId: task.id, project: ProjectPath.canonical(crossProject.path),
                    fromSessionId: callerSessionId()
                ))
            } catch {
                return toolResultResponse(
                    id: id,
                    text: "Error: task \(task.id) was created in \(crossProject.name) but this project won't track it: \(error.localizedDescription)",
                    isError: true
                )
            }
        }

        let successText: String
        if let crossProject {
            successText = "Task \(task.shortId) queued for \(toAgent.displayName) in \(crossProject.name). Track with linkc_get_task(\"\(task.id)\")."
        } else if let verification {
            successText = "Task \(task.shortId) created. linkC will confirm the tests fail at \(VerificationRunner.short(verification.baseSha)) before delivery."
        } else {
            successText = "Task \(task.id) queued for \(toAgent.displayName). It will be delivered when \(toAgent.displayName) is idle. Track with linkc_get_task(\"\(task.id)\")."
        }

        var usageNote = ""
        if warnCapableAgents.contains(toAgent),
           let window = usageReaders[toAgent]?().windowNeedingWarning,
           let percent = window.usedPercent {
            let resetSuffix = window.resetsAt.map { ", resets \(Self.formatReset($0, now: Date()))" } ?? ""
            usageNote = " \(toAgent.displayName) is at \(Self.formatPercent(percent)) of its \(window.label) window\(resetSuffix)."
        }

        if !files.isEmpty {
            do {
                // The files are paths in the project that does the work, so they are claimed on its board.
                let board = crossProject == nil ? store : BlackboardStore(workspaceRoot: destRoot)
                _ = try board.broadcastIntent(
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
    }

    /// The hop of a task this caller creates now: one past the open task this caller's session holds in its own
    /// inbox, or 0 when it holds none (spec 2026-11-11 cross-project §5.3). `createTask` refuses past 2, so the
    /// chain is cut across projects as well as within one. The highest hop wins when it holds several.
    private func newTaskHop() throws -> Int {
        guard let session = callerSessionId() else { return 0 }
        let held = try inboxStore.openTasks().filter { $0.assigneeSessionId == session }
        return (held.map(\.hop).max() ?? -1) + 1
    }

    /// `linkc_list_projects`: one line per known project other than the caller's (spec §4.1).
    private func listProjectsResult(id: Any?) throws -> Data? {
        let own = ProjectPath.canonical(workspaceRoot)
        let others = try knownProjects.read().filter { $0.path != own }
        guard !others.isEmpty else {
            return toolResultResponse(id: id, text: "No other project is known to linkC.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lines = others.map { project -> String in
            let path = project.path == home || project.path.hasPrefix(home + "/")
                ? "~" + project.path.dropFirst(home.count)
                : project.path
            let sessions: String
            if project.sessions.isEmpty {
                sessions = "no sessions"
            } else {
                sessions = project.sessions.map { "\($0.agent) \($0.activity.rawValue)" }.joined(separator: ", ")
            }
            return "\(project.name)  \(path)  \(sessions)"
        }
        return toolResultResponse(id: id, text: lines.joined(separator: "\n"))
    }

    /// `linkc_send_message(project:)` — write into the named project's inbox (spec §6).
    private func crossProjectSendResult(
        id: Any?,
        caller: MCPCaller,
        args: [String: Any],
        target: KnownProject,
        messageText: String
    ) throws -> Data? {
        guard let toStr = args["to"] as? String, !toStr.isEmpty else {
            return toolResultResponse(id: id, text: "Error: Missing required argument 'to'.", isError: true)
        }
        guard let toAgent = AgentKind(rawValue: toStr.lowercased()) else {
            return toolResultResponse(id: id, text: "Error: Unknown agent '\(toStr)'. Supported agents: \(AgentKind.peerList).", isError: true)
        }
        if let refusal = openSessionRefusal(to: toAgent, in: target) {
            return toolResultResponse(id: id, text: refusal, isError: true)
        }
        let pending = try InboxStore(workspaceRoot: target.path).enqueue(
            from: caller.agent,
            to: toAgent,
            kind: .peerNote,
            body: messageText,
            fromProject: ProjectPath.canonical(workspaceRoot),
            fromSessionId: callerSessionId(),
            chainDepth: 0
        )
        return toolResultResponse(
            id: id,
            text: "Message queued for \(toAgent.displayName) in \(target.name) (ID: \(pending.id)). linkC will deliver it when idle."
        )
    }

    /// `linkc_send_message(reply_to:)` — reply into the original message's project (spec §6).
    private func crossProjectReplyResult(
        id: Any?,
        caller: MCPCaller,
        args: [String: Any],
        replyTo: String,
        messageText: String
    ) throws -> Data? {
        guard let original = try inboxStore.message(matching: replyTo) else {
            return toolResultResponse(
                id: id,
                text: "Message \(replyTo) not found; send without reply_to.",
                isError: true
            )
        }
        guard let fromProject = original.fromProject else {
            return toolResultResponse(
                id: id,
                text: "Message \(original.id) did not come from another project; reply without reply_to.",
                isError: true
            )
        }
        if original.chainDepth + 1 >= PendingMessage.replyChainLimit {
            return toolResultResponse(
                id: id,
                text: "This conversation has gone back and forth 10 times. Ask the user before continuing.",
                isError: true
            )
        }
        let originName = URL(fileURLWithPath: fromProject).lastPathComponent
        if let rawProject = args["project"] {
            guard let projectArg = rawProject as? String else {
                return toolResultResponse(id: id, text: "project must be a folder name or a full path", isError: true)
            }
            if !Self.project(projectArg, names: fromProject) {
                return toolResultResponse(
                    id: id,
                    text: "project must match the message's origin (\(originName)), or be omitted.",
                    isError: true
                )
            }
        }
        if let toStr = args["to"] as? String, !toStr.isEmpty {
            guard let toAgent = AgentKind(rawValue: toStr.lowercased()) else {
                return toolResultResponse(id: id, text: "Error: Unknown agent '\(toStr)'. Supported agents: \(AgentKind.peerList).", isError: true)
            }
            if toAgent != original.fromAgent {
                return toolResultResponse(
                    id: id,
                    text: "to must be \(original.fromAgent.rawValue) (the message's sender), or be omitted.",
                    isError: true
                )
            }
        }
        let originPath = ProjectPath.canonical(fromProject)
        guard let destination = try knownProjects.read().first(where: { ProjectPath.canonical($0.path) == originPath }) else {
            return toolResultResponse(
                id: id,
                text: "\(originName) is no longer known to linkC; the reply was not sent.",
                isError: true
            )
        }
        let toAgent = original.fromAgent
        let toSessionId = original.fromSessionId
        if toSessionId == nil, let refusal = openSessionRefusal(to: toAgent, in: destination) {
            return toolResultResponse(id: id, text: refusal, isError: true)
        }
        let pending = try InboxStore(workspaceRoot: destination.path).enqueue(
            from: caller.agent,
            to: toAgent,
            kind: .peerNote,
            toSessionId: toSessionId,
            body: messageText,
            fromProject: ProjectPath.canonical(workspaceRoot),
            fromSessionId: callerSessionId(),
            chainDepth: original.chainDepth + 1
        )
        return toolResultResponse(
            id: id,
            text: "Reply queued for \(toAgent.displayName) in \(destination.name) (ID: \(pending.id))."
        )
    }

    /// Whether a reply's `project` argument names `origin`: its full path, or its folder name
    /// ignoring case. Compared directly, not resolved against the known projects, where a second
    /// folder with the same name would make the origin ambiguous.
    private static func project(_ ref: String, names origin: String) -> Bool {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let originPath = ProjectPath.canonical(origin)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return ProjectPath.canonical((trimmed as NSString).expandingTildeInPath) == originPath
        }
        return URL(fileURLWithPath: originPath).lastPathComponent.caseInsensitiveCompare(trimmed) == .orderedSame
    }

    /// Refusal when `projects.json` shows no live session of `to` in `project`.
    private func openSessionRefusal(to agent: AgentKind, in project: KnownProject) -> String? {
        let open = project.sessions.contains { $0.agentKind == agent }
        guard !open else { return nil }
        return "No \(agent.displayName) session is open in \(project.name). Use linkc_ask or linkc_delegate_task, which start one."
    }

    /// `linkc_get_board` body for this project's folder or another project's (spec §7).
    private func boardResult(id: Any?, root: String, boardArg: String?) throws -> Data? {
        let slug: String?
        if let boardArg, boardArg != "overview" {
            slug = boardArg
        } else {
            slug = nil
        }

        let projectName = URL(fileURLWithPath: root).lastPathComponent
        let catalog = try BoardCatalog.load(workspacePath: root, projectName: projectName)

        if let slug {
            guard BoardSlug.isValid(slug), catalog.entry(for: slug) != nil else {
                let known = (["overview"] + catalog.entries.compactMap(\.slug)).joined(separator: ", ")
                return toolResultResponse(id: id, text: "unknown board \"\(slug)\" — known boards: \(known)", isError: true)
            }
        }

        let map: BoardMap
        if let slug {
            map = try BoardDrill.open(slug, workspacePath: root, catalog: catalog)
        } else {
            guard let loaded = try BoardMapStore(workspacePath: root, board: nil).load() else {
                return toolResultResponse(id: id, text: "This project has no map yet — linkc_edit_board creates one.")
            }
            map = loaded.map
        }

        var text = try map.architectureJSON()
            + "\n\nVerbs: add, update, remove, connect, disconnect, place, remove_place, note, remove_note, system, detail. "
            + "Kinds: \(ComponentKind.groupedKindList) (any other kind is kept and drawn as a service). "
            + "\"memory\" is the AI agent's checkpointer; \"ram\" is hardware memory. "
            + "Parts marked outside come from the parent board and are read-only here."

        text += "\n\nBoards:\n"
        for entry in catalog.entries {
            let indent = String(repeating: "  ", count: entry.depth)
            let slugLabel = entry.slug ?? "overview"
            let pathLabel = entry.linked ? entry.path.joined(separator: " › ") : "(unlinked)"
            text += "\(indent)\(slugLabel) — \(pathLabel)\n"
        }

        return toolResultResponse(id: id, text: text)
    }

    /// `linkc_get_project_context` body for this project's store or another's. With
    /// `crossProjectName`, nothing is written in that project, notes are titles only unless
    /// `noteTitle` picks one, and the report points at the read-only tools (spec §7).
    private func projectContextResult(
        id: Any?,
        store: BlackboardStore,
        crossProjectName: String?,
        noteTitle: String?
    ) throws -> Data? {
        let board = try crossProjectName == nil ? store.getProjectContext() : store.readProjectContext()

        if let noteTitle {
            let trimmed = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = board.sharedNotes.filter { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
            guard let note = matches.first else {
                let titles = board.sharedNotes.map(\.title)
                let list = titles.isEmpty ? "This project has no notes." : "Known notes: \(titles.joined(separator: ", "))."
                return toolResultResponse(
                    id: id,
                    text: "No note \"\(noteTitle)\" in \(crossProjectName ?? "this project"). \(list)",
                    isError: true
                )
            }
            var text = "### \(note.title) (by \(note.authorAgent.displayName))\n"
            text += "\(note.content)\n"
            return toolResultResponse(id: id, text: text)
        }

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
            if crossProjectName != nil {
                for n in board.sharedNotes {
                    text += "- \(n.title)\n"
                }
                text += "\n"
            } else {
                for n in board.sharedNotes {
                    text += "### \(n.title) (by \(n.authorAgent.displayName))\n"
                    text += "\(n.content)\n\n"
                }
            }
        }

        // The project's own map of its components, when it keeps one. A map that cannot be read
        // says so: an agent must not be told a project has no components when it has a broken file.
        do {
            if let loaded = try BoardMapStore(workspacePath: board.projectPath).load() {
                text += BoardReport.markdown(for: loaded.map)
                if let crossProjectName {
                    text += "This board is read-only from here; read it with `linkc_get_board(project: \"\(crossProjectName)\")`.\n\n"
                } else {
                    text += "Read with `linkc_get_board`; change with `linkc_edit_board`.\n\n"
                }
            } else if crossProjectName != nil {
                text += "## System\n_No map yet._\n\n"
            } else {
                text += "## System\n_No map yet — `linkc_edit_board` starts one._\n\n"
            }
        } catch {
            // The message can carry a name straight from the file — sanitized the same
            // way every other field in this report is, since it lands in markdown too.
            text += "## System\n_The system map could not be read: \(BoardReport.sanitized(error.localizedDescription))_\n\n"
        }

        // Last, so it is the line an agent reads when it decides what to open next.
        if let crossProjectName, !board.sharedNotes.isEmpty {
            text += "Read one with linkc_get_project_context(project: \"\(crossProjectName)\", note: \"<title>\").\n"
        }

        return toolResultResponse(id: id, text: text)
    }

    /// The catch every tool handler in this file reaches for once it has nothing more specific
    /// to say: the thrown error's own description, reported as an `isError` tool result. Pulled
    /// out because this exact three-line `catch` block was pasted at every site with no sharper
    /// message for its own failure — one helper, one output shape, no copies to drift apart.
    private func errorResult(id: Any?, _ error: Error) -> Data? {
        toolResultResponse(id: id, text: error.localizedDescription, isError: true)
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
