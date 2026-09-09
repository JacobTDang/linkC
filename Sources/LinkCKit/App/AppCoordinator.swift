import Foundation
import AppKit

/// How to start `claude` in a new session: fresh, continue the most recent conversation in
/// the folder, or resume (claude shows its own session picker). `--continue`/`--resume` use
/// claude's own per-directory history, so they also work for sessions started outside linkC.
public enum LaunchMode: String, Sendable, CaseIterable {
    case new
    case continueLast
    case resume

    var claudeArgs: [String] {
        switch self {
        case .new: return []
        case .continueLast: return ["--continue"]
        case .resume: return ["--resume"]
        }
    }
}

/// Wires the modules together: hook events drive the store and (focus-aware) notifications;
/// UI commands create / focus / stop sessions through the embedded-terminal manager. The pure
/// logic it orchestrates (state machine, focus policy, settings merge) is unit-tested; this
/// glue is covered by AppCoordinatorIntegrationTests via injected doubles.
@MainActor
public final class AppCoordinator {
    public let store = SessionStore()
    public let terminals: TerminalSessionManager
    /// Restorable cards for the home overview — previous sessions that are no longer live.
    /// Observable; the panel reacts to it the same way it reacts to the live session store.
    public let restorableStore = RestorableStore()
    /// Fed transcript paths from hook events; owned by the UI layer, optional so the
    /// coordinator works headless in tests.
    public var usageTracker: UsageTracker?

    /// Active multi-agent project swarms detected across sessions.
    public private(set) var swarms: [ProjectSwarm] = []

    /// Aggregates activity items and dossiers for project and global dashboard screens.
    public let dashboardAggregator = AgentDashboardAggregator()

    private let hookServer: HookServer
    private let notifications: NotificationManager
    private let claudePath: String
    private let settingsDir: URL
    private let userSettingsURL: URL
    private let claudeJsonURL: URL?
    /// Persists the session manifest so sessions survive quitting/crashing and can be restored.
    let manifest: WorkspaceManifest
    /// Per-run shared secret baked into every composed settings file and required by the hook
    /// server — no other local process can spoof session state at the loopback port.
    let hookToken = UUID().uuidString  // internal: tests need to send it
    /// True when the user is currently watching a given session id — panel open, linkC
    /// active, and that tab selected. Injected because it depends on UI-layer state the
    /// coordinator can't see. Invoked on the main actor.
    private let isWatching: @MainActor @Sendable (String) -> Bool
    private let agentPathResolver: (@Sendable (AgentKind) -> String?)?

    /// Hook events are funneled through this single stream and drained by one consumer task
    /// so `store.apply` runs strictly in arrival order — unstructured per-event tasks would
    /// not preserve ordering, and the reducer is last-writer-wins.
    private let eventStream: AsyncStream<HookEvent>
    private let eventContinuation: AsyncStream<HookEvent>.Continuation
    private var consumerTask: Task<Void, Never>?
    private var stateSweepTask: Task<Void, Never>?

    /// Designated initializer — all collaborators injected (used by tests).
    public init(
        terminals: TerminalSessionManager,
        hookServer: HookServer,
        notifications: NotificationManager,
        claudePath: String,
        settingsDir: URL,
        userSettingsURL: URL,
        manifestDir: URL,
        agentPathResolver: (@Sendable (AgentKind) -> String?)? = nil,
        claudeJsonURL: URL? = nil,
        isWatching: @escaping @MainActor @Sendable (String) -> Bool
    ) {
        self.terminals = terminals
        self.hookServer = hookServer
        self.notifications = notifications
        self.claudePath = claudePath
        self.settingsDir = settingsDir
        self.userSettingsURL = userSettingsURL
        self.manifest = WorkspaceManifest(directory: manifestDir)
        self.agentPathResolver = agentPathResolver
        self.claudeJsonURL = claudeJsonURL
        self.isWatching = isWatching
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: HookEvent.self)
        // Everything the manifest already holds is from a previous run — surface it as restorable.
        syncRestorables()
    }

    /// Production initializer — builds the real hook server, notification center, and settings
    /// locations, while the app supplies the terminal manager it also renders and the watch
    /// probe it computes from panel state.
    public convenience init(
        claudePath: String,
        terminals: TerminalSessionManager,
        isWatching: @escaping @MainActor @Sendable (String) -> Bool
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let linkCDir = support.appendingPathComponent("linkC", isDirectory: true)
        self.init(
            terminals: terminals,
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(),
            claudePath: claudePath,
            settingsDir: linkCDir,
            userSettingsURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json"),
            manifestDir: linkCDir,
            isWatching: isWatching
        )
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    /// Headless / testing convenience initializer.
    public convenience init(
        workspaceDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-test-\(UUID().uuidString)")
    ) {
        self.init(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: "/usr/bin/true",
            settingsDir: workspaceDir,
            userSettingsURL: workspaceDir.appendingPathComponent("user-settings.json"),
            manifestDir: workspaceDir,
            isWatching: { _ in false }
        )
    }

    public func start() throws {
        sweepOrphanedSettingsFiles()
        try? MCPRegistrar.registerAll()
        hookServer.requiredToken = hookToken
        notifications.onActivate = { [weak self] id in
            Task { @MainActor in
                // A health alert has no session to select — but clicking it must still
                // bring linkC forward, which is the whole interaction. (An earlier guard
                // returned here instead, so clicking a "not responding" banner did
                // nothing at all.)
                guard !id.hasPrefix(Self.alertIdPrefix) else {
                    NSApp?.activate(ignoringOtherApps: true)
                    return
                }
                self?.focusSession(id)
            }
        }
        // Funnel every hook event into the serial stream; a single consumer drains it in
        // arrival order (see `eventStream`). The server's callback just enqueues — no
        // per-event task, so no reordering.
        hookServer.onEvent = { [eventContinuation] event in
            eventContinuation.yield(event)
        }
        // This Task inherits the coordinator's main-actor isolation, so `handle` (a
        // synchronous main-actor method) is a direct same-actor call — the `for await` on the
        // stream is the only suspension point, which is what preserves arrival order.
        consumerTask = Task { [weak self, eventStream] in
            for await event in eventStream {
                self?.handle(event)
            }
        }
        // Start receiving hooks immediately — do NOT gate this on the notification permission
        // dialog, which can block indefinitely on first launch.
        try hookServer.start()
        Task { await notifications.requestAuthorization() }
        restoreActiveSessions()
        if let lastId = UserDefaults.standard.string(forKey: "LinkCLastSelectedSessionId"),
           terminals.sessions.contains(where: { $0.id == lastId }) {
            terminals.select(lastId)
        }
        stateSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.sampleAgentStates()
                }
            }
        }
    }

    /// Snapshot all active sessions to the manifest with wasActiveOnQuit == true before shutdown.
    public func prepareForShutdown(selectedId: String? = nil) {
        for s in store.sessions where s.state != .ended {
            let liveAgent = terminals.session(id: s.id)?.sampleForegroundAgent() ?? s.agentKind
            manifest.upsert(RestorableSession(
                linkcId: s.id,
                claudeSessionId: s.claudeSessionId,
                cwd: s.cwd,
                title: s.title,
                agentKind: liveAgent,
                wasActiveOnQuit: true,
                endedAt: nil
            ))
        }
        let sel = selectedId ?? terminals.selectedId
        if let sel {
            UserDefaults.standard.set(sel, forKey: "LinkCLastSelectedSessionId")
        }
    }

    /// Stops the hook server and the event consumer. Called at app termination (and by tests).
    public func shutdown() {
        prepareForShutdown()
        eventContinuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
        stateSweepTask?.cancel()
        stateSweepTask = nil
        hookServer.stop()
    }

    // MARK: - Hook events → store → focus-aware notification

    func handle(_ event: HookEvent) {
        let outcome = store.apply(event)
        guard let session = outcome.session else { return } // unknown / external session

        if let tracker = usageTracker {
            // Every hook event names the session's transcript — bind it and refresh usage.
            if let transcriptPath = event.transcriptPath {
                tracker.bind(sessionId: session.id, transcriptPath: transcriptPath)
            }
            tracker.refreshSession(session.id)
            // The refresh above applies any real completions first; only then does the
            // backstop end whatever the transcript never closed out. User prompt submit
            // always sweeps previous turns' agents. Turn ends only sweep if no in-flight
            // subagents are currently running, preventing premature sweeps while parent
            // pauses for subagent execution.
            if event.kind == .userPromptSubmit {
                tracker.sweepAgents(session.id)
            } else if turnIsOver(session.state) {
                let hasRunningSubagents = tracker.sessionAgents(session.id).contains { $0.isRunning }
                if !hasRunningSubagents {
                    tracker.sweepAgents(session.id)
                }
            }
        }

        // Keep the manifest's claude conversation id current so a later restore can `--resume`
        // this exact conversation. Bind before any end-of-session handling below.
        if let cid = session.claudeSessionId {
            manifest.bindClaudeId(linkcId: session.id, claudeSessionId: cid)
        }

        // A terminated session is pruned (store row, its terminal, its settings file, its
        // dedupe entry) instead of lingering forever as a dead tab. No notification for an end.
        if session.state == .ended {
            cleanup(sessionId: session.id)
            return
        }

        if event.kind == .stopFailure {
            checkLimitsAndReroute(for: session.id)
        } else if event.kind == .stop || event.kind == .sessionStart {
            checkLimitsAndReroute(for: session.id)
            if event.kind == .stop {
                notifyDelegatorOnTaskCompletion(sessionId: session.id, workspacePath: session.cwd)
            }
            processPendingMessages(workspacePath: session.cwd)
        }

        guard outcome.shouldConsiderNotifying else { return }
        if FocusPolicy.shouldNotify(
            session: session,
            enteredNotifiable: true,
            isWatchingThisSession: isWatching(session.id)
        ) {
            notifications.post(session: session)
        }
    }

    /// States in which no subagent can legitimately still be running. `.working`/`.starting`
    /// are live; `.waitingPermission` pauses mid-turn — a sync subagent may be alive behind
    /// the permission prompt, so it must not sweep.
    private func turnIsOver(_ state: SessionState) -> Bool {
        switch state {
        case .ready, .waitingIdle, .finished, .error, .ended: return true
        case .starting, .working, .waitingPermission: return false
        }
    }

    /// Announce something that isn't a session — a watched service going down or coming
    /// back. Routed through the same notification manager so authorization, the sink, and
    /// click handling stay in one place.
    public func notify(id: String, title: String, body: String) {
        // A unique request id per alert: UNNotificationRequest's identifier IS the
        // dedupe key, so reusing one id per endpoint would make each new alert replace
        // the last in Notification Center — a down→up→down flap would leave only its
        // final state for someone who was away from the machine.
        notifications.postAlert(
            id: "\(Self.alertIdPrefix)\(id):\(UUID().uuidString)", title: title, body: body
        )
    }

    /// Marks a notification as "not a session" — clicking one must not be routed into
    /// session focus, where the id matches nothing and the app activates on no navigation.
    static let alertIdPrefix = "alert:"

    /// Remove a session everywhere it leaves state behind: the store, its terminal (dropped,
    /// not killed — the process is already dead here), its per-session settings file, its
    /// notification dedupe entry, and its usage-tracker dictionaries. Idempotent.
    private func cleanup(sessionId: String) {
        store.remove(id: sessionId)
        terminals.remove(sessionId)
        let settingsFile = settingsDir.appendingPathComponent("session-\(sessionId).json")
        try? FileManager.default.removeItem(at: settingsFile)
        notifications.forget(sessionId)
        usageTracker?.unbind(sessionId: sessionId)
        // The session ended or was stopped — keep its manifest entry but stamp it, so it becomes
        // a restorable card. (No-op when there is no entry, e.g. a launch that failed before start.)
        manifest.markEnded(linkcId: sessionId, at: Date())
        syncRestorables()
    }

    // MARK: - UI commands

    /// Spawns a teammate agent session in `workspacePath`, automatically synthesizing
    /// and writing a handoff memo to `<workspacePath>/.linkc/HANDOFF.md`.
    @discardableResult
    public func spawnTeammate(in workspacePath: String, agent: AgentKind = .claude, goal: String? = nil) throws -> Session {
        let norm = (workspacePath as NSString).standardizingPath
        let existingSession = store.sessions.last { session in
            let sessionNorm = (session.cwd as NSString).standardizingPath
            return sessionNorm == norm && session.state != .ended
        } ?? store.sessions.last { session in
            let sessionNorm = (session.cwd as NSString).standardizingPath
            return sessionNorm == norm
        }

        let sourceAgent = existingSession?.agentKind
        let recentOutput: String?
        if let existingSession {
            let out = terminals.session(id: existingSession.id)?.recentOutput(lines: 50)
            recentOutput = (out?.isEmpty ?? true) ? nil : out
        } else {
            recentOutput = nil
        }

        let gitSummary = inspectGitStatus(in: norm)

        var lastGoal: String? = goal
        if lastGoal == nil {
            let bbStore = BlackboardStore(workspaceRoot: norm)
            if let board = try? bbStore.load(timeout: 0.5) {
                if let lastAgent = board.activeAgents.last, !lastAgent.goal.isEmpty {
                    lastGoal = lastAgent.goal
                } else if let lastEvent = board.recentEvents.first, !lastEvent.details.isEmpty {
                    lastGoal = lastEvent.details
                }
            }
        }
        if lastGoal == nil {
            let inboxStore = InboxStore(workspaceRoot: norm)
            if let inbox = try? inboxStore.load(timeout: 0.5),
               let lastMsg = inbox.messages.last(where: { !$0.prompt.isEmpty }) {
                lastGoal = lastMsg.prompt
            }
        }

        try HandoffComposer.writeHandoffSync(
            workspacePath: workspacePath,
            sourceAgent: sourceAgent,
            lastGoal: lastGoal,
            gitSummary: gitSummary,
            recentTerminalOutput: recentOutput
        )

        return try newSession(cwd: workspacePath, agent: agent, mode: .new)
    }

    @discardableResult
    public func newSession(cwd: String, agent: AgentKind = .claude, mode: LaunchMode = .new) throws -> Session {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return try launch(cwd: cwd, title: title, agent: agent, mode: mode)
    }

    /// Spawn a session in `cwd` with the given agent and mode, wire its terminal, select it,
    /// and record it (live, no `endedAt`) in the manifest. The single launch path for both new
    /// sessions and restores. Fails loud: a launch error prunes any partial state and rethrows.
    @discardableResult
    private func launch(
        cwd: String,
        title: String,
        agent: AgentKind = .claude,
        mode: LaunchMode,
        resumeId: String? = nil,
        id: String? = nil
    ) throws -> Session {
        let session = store.create(cwd: cwd, title: title, id: id ?? UUID().uuidString, agentKind: agent)
        do {
            let terminal = terminals.makeSession(id: session.id, cwd: cwd, title: title, agentKind: agent)
            // A terminated child = an ended session: prune everything when the child exits.
            terminal.onTerminated = { [weak self] _ in
                self?.cleanup(sessionId: session.id)
            }

            let executable: String
            let args: [String]
            let env: [String: String] = ["LINKC_SESSION": session.id]

            if agent == .claude {
                try? DirectoryTrustManager.preApproveTrust(workspacePath: cwd, claudeJsonURL: claudeJsonURL)
                executable = claudePath
                let settingsPath = try writeSettings(for: session)
                args = Self.claudeLaunchArgs(mode: mode, resumeId: resumeId, settingsPath: settingsPath)
            } else {
                guard let resolved = agentPathResolver?(agent) ?? AgentDescriptor.resolveExecutable(for: agent) else {
                    throw LinkCError.process("Executable for \(agent.pillText) not found")
                }
                executable = resolved
                args = AgentDescriptor.arguments(for: agent, mode: mode)
            }

            try terminal.start(
                executable: executable,
                args: args,
                env: env
            )
            terminals.select(session.id)
            // Record the now-live session so it survives a quit/crash and can be restored.
            manifest.upsert(RestorableSession(
                linkcId: session.id,
                claudeSessionId: resumeId,
                cwd: cwd,
                title: title,
                agentKind: agent,
                wasActiveOnQuit: true,
                endedAt: nil
            ))
            syncRestorables()
            return session
        } catch {
            cleanup(sessionId: session.id) // fail loud: no ghost session or orphaned settings file
            throw error
        }
    }

    // MARK: - Restore

    /// Revives all sessions that were marked active when the app last shut down or were unended.
    public func restoreActiveSessions() {
        let activeEntries = manifest.entries.filter { $0.wasActiveOnQuit || $0.endedAt == nil }
        for var r in activeEntries {
            r.wasActiveOnQuit = false
            if FileManager.default.fileExists(atPath: r.cwd) {
                if (try? launch(
                    cwd: r.cwd,
                    title: r.title,
                    agent: r.agentKind,
                    mode: .continueLast,
                    resumeId: r.claudeSessionId,
                    id: r.linkcId
                )) == nil {
                    manifest.upsert(r)
                }
            } else {
                manifest.upsert(r)
            }
        }
        syncRestorables()
    }

    /// Resume a previous session as a fresh live one. Uses `claude --resume <id>` when the claude
    /// conversation id was captured, else `--continue` in the folder. On success the old
    /// restorable is consumed (the new live session carries its own fresh manifest entry).
    /// If `as: agent` is provided, overrides the session's recorded agent kind.
    @discardableResult
    public func restore(_ r: RestorableSession, as agent: AgentKind? = nil) throws -> Session {
        let targetAgent = agent ?? r.agentKind
        // A restorable with no captured claude id falls back to `--continue`, which attaches to
        // the folder's MOST RECENT conversation. If a live session already occupies that folder
        // (including one restored moments ago in the same Restore-all pass), a second
        // `--continue` would attach to the SAME conversation — two processes writing one
        // transcript. Refuse; the card stays and the user can restore it individually later.
        if targetAgent == .claude,
           (r.claudeSessionId ?? "").isEmpty,
           store.sessions.contains(where: { $0.cwd == r.cwd }) {
            throw LinkCError.process(
                "a session is already running in \(r.title) — restore this one after it ends, or dismiss it"
            )
        }
        let session = try launch(
            cwd: r.cwd,
            title: r.title,
            agent: targetAgent,
            mode: .continueLast,
            resumeId: targetAgent == .claude ? r.claudeSessionId : nil
        )
        manifest.remove(linkcId: r.linkcId)
        syncRestorables()
        return session
    }

    /// Restore every current restorable. Individual failures are collected and surfaced together
    /// (fail loud) rather than aborting the batch on the first error.
    public func restoreAll() throws {
        var failures: [String] = []
        for r in restorableStore.restorables { // snapshot; `restore` mutates the list
            do { try restore(r) } catch { failures.append("\(r.title): \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            throw LinkCError.process("Could not restore \(failures.count) session(s): \(failures.joined(separator: "; "))")
        }
    }

    /// Drop a restorable for good (the user dismissed the card).
    public func dismiss(_ r: RestorableSession) {
        manifest.remove(linkcId: r.linkcId)
        syncRestorables()
    }

    /// The current restorable cards. Convenience passthrough to the observable store.
    public var restorables: [RestorableSession] { restorableStore.restorables }

    /// Claude args shared by the new-session and restore paths. A captured claude conversation id
    /// always wins (`--resume <id>`); otherwise the mode's own flag is used, so a restore with no
    /// captured id (`mode: .continueLast`) falls back to `--continue` in the folder.
    public nonisolated static func launchArgs(mode: LaunchMode, resumeId: String?) -> [String] {
        if let resumeId, !resumeId.isEmpty { return ["--resume", resumeId] }
        return mode.claudeArgs
    }

    /// Claude launch arguments combining mode/resume flags, YOLO permission bypass flags,
    /// and the per-session settings file.
    public nonisolated static func claudeLaunchArgs(mode: LaunchMode, resumeId: String?, settingsPath: String) -> [String] {
        let yolo = AgentDescriptor.descriptor(for: .claude).yoloFlags
        return launchArgs(mode: mode, resumeId: resumeId) + yolo + ["--settings", settingsPath]
    }

    /// Recompute the restorable set: every manifest entry that is not currently a live session.
    private func syncRestorables() {
        let liveIds = Set(store.sessions.map(\.id))
        restorableStore.set(manifest.entries.filter { !liveIds.contains($0.linkcId) })
    }

    public func focusSession(_ id: String) {
        terminals.select(id)
        NSApp?.activate(ignoringOtherApps: true)
        if let s = store.session(id: id), s.agentKind != .claude, s.state.bucket == .needsYou {
            store.updateState(id: id, to: .ready)
        }
    }

    /// Periodically inspects all sessions to detect live agent kind and working/finished/idle state
    /// for non-Claude agents (AGY, Cursor, Codex, etc.) or sessions without hook events.
    public func sampleAgentStates() {
        var activePaths: Set<String> = []
        for session in store.sessions where session.state != .ended {
            activePaths.insert((session.cwd as NSString).standardizingPath)
            guard let term = terminals.session(id: session.id) else { continue }

            // Inspect terminal output for provider rate limits & auto-reroute
            checkLimitsAndReroute(for: session.id)

            // Detect dynamic agent kind changes in child process tree
            let liveAgent = term.sampleForegroundAgent()
            if liveAgent != session.agentKind && liveAgent != .shell {
                store.updateAgentKind(id: session.id, to: liveAgent)
            }

            // Claude has its own hook server providing exact event transitions.
            guard session.agentKind != .claude else { continue }

            guard let currentSession = store.session(id: session.id), currentSession.state != .error else { continue }

            let liveActivity = term.liveActivityLine()
            let isWorking = liveActivity != nil && !liveActivity!.isEmpty

            if isWorking {
                if currentSession.state.bucket != .active {
                    store.updateState(id: session.id, to: .working)
                }
            } else {
                // If it was working and now finished its turn
                if currentSession.state.bucket == .active {
                    store.updateState(id: session.id, to: .finished)
                    let updated = store.session(id: session.id) ?? currentSession
                    if FocusPolicy.shouldNotify(
                        session: updated,
                        enteredNotifiable: true,
                        isWatchingThisSession: isWatching(session.id)
                    ) {
                        notifications.post(session: updated)
                    }
                    notifyDelegatorOnTaskCompletion(sessionId: session.id, workspacePath: session.cwd)
                } else if currentSession.state == .starting {
                    store.updateState(id: session.id, to: .ready)
                }
            }
        }

        for path in activePaths {
            processPendingMessages(workspacePath: path)
        }
    }

    public func stopSession(_ id: String) {
        terminals.terminate(id)
        cleanup(sessionId: id)
    }

    public var hookPort: UInt16 { hookServer.port }

    // MARK: - Swarm & Collision Tracking

    /// Computes active multi-agent project swarms and inspects file collisions.
    public func sampleSwarms(additionalAgents: [String: [AgentKind]] = [:]) {
        var agentsByPath: [String: Set<AgentKind>] = [:]

        for session in store.sessions where session.state != .ended {
            let norm = (session.cwd as NSString).standardizingPath
            agentsByPath[norm, default: []].insert(session.agentKind)
        }

        for (path, agents) in additionalAgents {
            let norm = (path as NSString).standardizingPath
            for a in agents {
                agentsByPath[norm, default: []].insert(a)
            }
        }

        var newSwarms: [ProjectSwarm] = []
        for (path, agents) in agentsByPath where agents.count >= 2 {
            let store = BlackboardStore(workspaceRoot: path)
            var allCollisions: [CollisionWarning] = []
            if let board = try? store.load() {
                var seenFiles: [String: (AgentKind, pid_t, String)] = [:]
                for a in board.activeAgents {
                    for f in a.claimedFiles {
                        if let (otherAgent, otherPid, otherGoal) = seenFiles[f], otherPid != a.pid {
                            allCollisions.append(
                                CollisionWarning(
                                    conflictingAgent: otherAgent,
                                    pid: otherPid,
                                    conflictingFiles: [f],
                                    goal: otherGoal
                                )
                            )
                        } else {
                            seenFiles[f] = (a.agentKind, a.pid, a.goal)
                        }
                    }
                }
            }

            newSwarms.append(
                ProjectSwarm(
                    workspacePath: path,
                    activeAgents: Array(agents),
                    collisions: allCollisions
                )
            )
        }
        self.swarms = newSwarms
    }

    // MARK: - Agent Dashboard Integration

    public func fetchProjectDashboard(workspacePath: String) -> ProjectDashboardData {
        let norm = (workspacePath as NSString).standardizingPath
        let sessions = store.sessions.filter { ($0.cwd as NSString).standardizingPath == norm }.map { s in
            let term = terminals.session(id: s.id)
            let act = term?.liveActivityLine()
            let out = term?.recentOutput(lines: 15) ?? ""
            return (id: s.id, agent: s.agentKind, status: s.state.rawValue, activity: act, recentOutput: out)
        }
        return dashboardAggregator.aggregateProject(workspacePath: norm, liveSessions: sessions)
    }

    public func fetchProjectDashboardAsync(workspacePath: String) async -> ProjectDashboardData {
        let norm = (workspacePath as NSString).standardizingPath
        let sessions = store.sessions.filter { ($0.cwd as NSString).standardizingPath == norm }.map { s in
            let term = terminals.session(id: s.id)
            let act = term?.liveActivityLine()
            let out = term?.recentOutput(lines: 15) ?? ""
            return (id: s.id, agent: s.agentKind, status: s.state.rawValue, activity: act, recentOutput: out)
        }
        let aggregator = dashboardAggregator
        return await Task.detached {
            aggregator.aggregateProject(workspacePath: norm, liveSessions: sessions)
        }.value
    }

    public func fetchGlobalDashboard() -> GlobalDashboardData {
        let workspaces = Array(Set(store.sessions.map { ($0.cwd as NSString).standardizingPath }))
        let sessions = store.sessions.map { s in
            let term = terminals.session(id: s.id)
            let act = term?.liveActivityLine()
            let out = term?.recentOutput(lines: 15) ?? ""
            return (id: s.id, workspace: s.cwd, agent: s.agentKind, status: s.state.rawValue, activity: act, recentOutput: out)
        }
        return dashboardAggregator.aggregateGlobal(workspaces: workspaces, liveSessions: sessions)
    }

    public func fetchGlobalDashboardAsync() async -> GlobalDashboardData {
        let workspaces = Array(Set(store.sessions.map { ($0.cwd as NSString).standardizingPath }))
        let sessions = store.sessions.map { s in
            let term = terminals.session(id: s.id)
            let act = term?.liveActivityLine()
            let out = term?.recentOutput(lines: 15) ?? ""
            return (id: s.id, workspace: s.cwd, agent: s.agentKind, status: s.state.rawValue, activity: act, recentOutput: out)
        }
        let aggregator = dashboardAggregator
        return await Task.detached {
            aggregator.aggregateGlobal(workspaces: workspaces, liveSessions: sessions)
        }.value
    }

    // MARK: - Inbox Dispatcher & Limit Auto-Rerouting

    /// Dispatches pending queued messages for `workspacePath`. Auto-spawns recipient agents
    /// if not active, and injects the prompt via terminal PTY when the recipient session is idle/ready.
    public func processPendingMessages(workspacePath: String) {
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        guard let pending = try? inboxStore.fetchPending(), !pending.isEmpty else { return }

        for message in pending where message.status == .queued {
            var targetSession = store.sessions.first { s in
                let sNorm = (s.cwd as NSString).standardizingPath
                return sNorm == norm && s.agentKind == message.toAgent && s.state != .ended
            }

            if targetSession == nil {
                do {
                    let spawned = try spawnTeammate(in: norm, agent: message.toAgent, goal: message.prompt)
                    store.updateState(id: spawned.id, to: .ready)
                    targetSession = store.session(id: spawned.id) ?? spawned
                } catch {
                    continue
                }
            }

            guard let session = targetSession else { continue }

            switch session.state {
            case .ready, .finished, .waitingIdle:
                let formattedPrompt = message.prompt
                terminals.sendInput(sessionId: session.id, text: formattedPrompt)
                store.updateState(id: session.id, to: .working)
                try? inboxStore.markDelivered(id: message.id)
            case .working, .starting, .waitingPermission, .error, .ended:
                // Keep in queue until recipient session finishes or becomes ready
                break
            }
        }
    }

    /// Switches the active model for an agent session in the given workspace using free/subscription tier models.
    /// Injects the interactive switch command (e.g. `/model <modelName>`) directly into the agent's live terminal PTY.
    @discardableResult
    public func switchModel(in workspacePath: String, agent: AgentKind, to modelName: String) throws -> String {
        guard agent != .shell else {
            throw LinkCError.process("Cannot switch model on shell session.")
        }
        guard AgentModelCatalog.isFreeOrSubscription(model: modelName, for: agent) else {
            let allowed = AgentModelCatalog.models(for: agent).map { $0.id }.joined(separator: ", ")
            throw LinkCError.process("'\(modelName)' is not an allowed free or subscription-tier model for \(agent.displayName). Allowed models: \(allowed)")
        }
        let norm = (workspacePath as NSString).standardizingPath
        guard let session = store.sessions.first(where: {
            ($0.cwd as NSString).standardizingPath == norm && $0.agentKind == agent && $0.state != .ended
        }) else {
            throw LinkCError.process("No active session found for \(agent.displayName) in \(workspacePath).")
        }
        let cmd = AgentModelCatalog.interactiveSwitchCommand(model: modelName, for: agent)
        terminals.sendInput(sessionId: session.id, text: cmd)
        return "Switched \(agent.displayName) model to '\(modelName)' in session \(session.id)."
    }

    /// Evaluates terminal output of `sessionId` for provider rate limits and quota ceiling events.
    /// If a limit is detected, marks the agent limited in the inbox store and autonomous
    /// re-routing passes the task with a handoff memo to an available peer agent (max 2 hops).
    @discardableResult
    public func checkLimitsAndReroute(for sessionId: String) -> Bool {
        guard let session = store.session(id: sessionId) else { return false }
        guard session.agentKind != .shell else { return false }
        guard session.state != .ended else { return false }

        let norm = (session.cwd as NSString).standardizingPath
        let recentOutput = terminals.session(id: sessionId)?.recentOutput(lines: 50) ?? ""

        guard let match = LimitDetector.detectLimit(inOutput: recentOutput, agent: session.agentKind) else {
            return false
        }

        let inboxStore = InboxStore(workspaceRoot: norm)
        try? inboxStore.recordLimit(
            agent: session.agentKind,
            reason: match.matchedPattern,
            cooldown: match.cooldown
        )

        // Find candidate peer agents (excluding current agent, .shell, and limited agents)
        let supportedPeers: [AgentKind] = [.claude, .codex, .agy, .cursor]
        var candidates = supportedPeers.filter { candidate in
            guard candidate != session.agentKind else { return false }
            guard (try? inboxStore.isAgentLimited(agent: candidate)) == nil else { return false }
            let isInstalled: Bool
            if candidate == .claude {
                isInstalled = FileManager.default.isExecutableFile(atPath: claudePath) ||
                    (agentPathResolver?(candidate) ?? AgentDescriptor.resolveExecutable(for: candidate)) != nil
            } else if let resolver = agentPathResolver {
                isInstalled = resolver(candidate) != nil
            } else {
                isInstalled = AgentDescriptor.resolveExecutable(for: candidate) != nil
            }
            guard isInstalled else { return false }
            return true
        }

        candidates.sort { a, b in
            let aActive = store.sessions.contains { ( $0.cwd as NSString).standardizingPath == norm && $0.agentKind == a && $0.state != .ended }
            let bActive = store.sessions.contains { ( $0.cwd as NSString).standardizingPath == norm && $0.agentKind == b && $0.state != .ended }
            if aActive != bActive { return aActive && !bActive }
            return false
        }

        // Determine reroute count of active task (circuit breaker)
        let inbox = try? inboxStore.load()
        let currentMessage = inbox?.messages.last { msg in
            guard msg.toAgent == session.agentKind, let deliveredAt = msg.deliveredAt else { return false }
            if session.state == .working {
                return deliveredAt >= session.stateChangedAt.addingTimeInterval(-5)
            }
            return true
        }

        // Bi-directional notification to delegating peer agent if this was a delegated task
        if let currentMessage, currentMessage.fromAgent != session.agentKind {
            let alreadyNotified = inbox?.messages.contains { msg in
                msg.fromAgent == session.agentKind &&
                msg.toAgent == currentMessage.fromAgent &&
                msg.prompt.hasPrefix("[System Notice]") &&
                msg.createdAt >= currentMessage.createdAt
            } ?? false

            if !alreadyNotified {
                let fallback = AgentModelCatalog.fallbackModels(for: session.agentKind).first?.displayName ?? "fallback"
                let noticePrompt = "[System Notice] \(session.agentKind.displayName) reached usage limit: '\(match.matchedPattern)'. Free fallback model '\(fallback)' is available. Task paused."
                _ = try? inboxStore.enqueue(
                    from: session.agentKind,
                    to: currentMessage.fromAgent,
                    prompt: noticePrompt,
                    files: currentMessage.claimedFiles
                )
                notifications.post(
                    title: "linkC: \(session.agentKind.displayName) Rate Limited",
                    body: "\(session.agentKind.displayName) reached usage limit: '\(match.matchedPattern)'. Free fallback model '\(fallback)' is available."
                )
            }
        }

        let currentRerouteCount = currentMessage?.rerouteCount ?? 0
        let reroutedPrompt = currentMessage?.prompt ?? "Task rerouted from \(session.agentKind.displayName) due to rate limit (\(match.matchedPattern)). Please inspect .linkc/HANDOFF.md and continue."

        // If this task has already been rerouted by this session, avoid re-entrant duplicates
        let alreadyRerouted = inbox?.messages.contains { msg in
            guard msg.fromAgent == session.agentKind && msg.rerouteCount > currentRerouteCount else { return false }
            if let currentMessage {
                return msg.createdAt >= currentMessage.createdAt
            } else {
                return msg.prompt == reroutedPrompt && msg.createdAt >= session.stateChangedAt.addingTimeInterval(-60)
            }
        } ?? false
        if alreadyRerouted {
            return true
        }

        guard currentRerouteCount < 2, let targetCandidate = candidates.first else {
            // Circuit breaker tripped or no candidates available: stop re-routing
            store.updateState(id: session.id, to: .error)
            notifications.post(title: "linkC: Swarm Rate Limited", body: "All candidate agents in \(URL(fileURLWithPath: norm).lastPathComponent) are rate limited. Pausing auto-delegation.")
            return true
        }

        // Compose handoff memo
        let gitSummary = inspectGitStatus(in: norm)
        var lastGoal = currentMessage?.prompt
        if lastGoal == nil, let board = try? BlackboardStore(workspaceRoot: norm).load(timeout: 0.5) {
            lastGoal = board.activeAgents.last?.goal
        }

        _ = try? HandoffComposer.writeHandoffSync(
            workspacePath: norm,
            sourceAgent: session.agentKind,
            lastGoal: lastGoal,
            gitSummary: gitSummary,
            recentTerminalOutput: recentOutput
        )

        // Enqueue rerouted task to candidate with rerouteCount + 1
        let claimedFiles = currentMessage?.claimedFiles ?? []

        _ = try? inboxStore.enqueue(
            from: session.agentKind,
            to: targetCandidate,
            prompt: reroutedPrompt,
            files: claimedFiles,
            rerouteCount: currentRerouteCount + 1
        )

        store.updateState(id: session.id, to: .error)

        // Spawn candidate if needed and dispatch
        processPendingMessages(workspacePath: norm)
        return true
    }

    /// Autonotifies the delegating peer agent / orchestrator when a task assigned via inbox completes.
    /// Gathers the terminal summary/output and enqueues a completion message back to the delegator,
    /// triggering immediate dispatch so the orchestrator can autonomously proceed without human intervention.
    @discardableResult
    public func notifyDelegatorOnTaskCompletion(sessionId: String, workspacePath: String) -> Bool {
        guard let session = store.session(id: sessionId) else { return false }
        guard session.agentKind != .shell else { return false }

        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        guard let inbox = try? inboxStore.load() else { return false }

        // Find the last delivered task message targeted to this agent
        guard let currentMessage = inbox.messages.last(where: { msg in
            msg.toAgent == session.agentKind && msg.status == .delivered
        }) else { return false }

        // Must be delegated from a different agent (the delegating orchestrator)
        guard currentMessage.fromAgent != session.agentKind else { return false }

        // Avoid duplicate completion notices for the same delivered task
        let alreadyNotified = inbox.messages.contains { msg in
            msg.fromAgent == session.agentKind &&
            msg.toAgent == currentMessage.fromAgent &&
            msg.prompt.hasPrefix("[Task Completed by \(session.agentKind.displayName)]") &&
            msg.createdAt >= (currentMessage.deliveredAt ?? currentMessage.createdAt)
        }
        guard !alreadyNotified else { return false }

        let term = terminals.session(id: sessionId)
        let rawSummary = term?.recentOutput(lines: 30) ?? ""
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)

        let completionPrompt = """
        [Task Completed by \(session.agentKind.displayName)]
        Original Task: \(currentMessage.prompt)

        Result / Output:
        \(summary.isEmpty ? "(Task completed successfully with no terminal output)" : summary)
        """

        _ = try? inboxStore.enqueue(
            from: session.agentKind,
            to: currentMessage.fromAgent,
            prompt: completionPrompt,
            files: currentMessage.claimedFiles
        )

        notifications.post(
            title: "linkC: \(session.agentKind.displayName) Completed Task",
            body: "Task completed for \(currentMessage.fromAgent.displayName). Output autonotified to orchestrator."
        )

        // Immediately deliver to the orchestrator if its session is idle/ready
        processPendingMessages(workspacePath: norm)
        return true
    }

    // MARK: - Helpers

    /// Delete stale `session-*.json` files at startup. No session is live yet at this point,
    /// so every such file is an orphan from a crash referencing a dead hook port. Never touches
    /// `workspace.json` (the manifest).
    private func sweepOrphanedSettingsFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: settingsDir, includingPropertiesForKeys: nil) else { return }
        let orphans = files.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
        for file in orphans { try? FileManager.default.removeItem(at: file) }
        if !orphans.isEmpty {
            NSLog("linkC: swept %d orphaned session settings file(s)", orphans.count)
        }
    }

    private func writeSettings(for session: Session) throws -> String {
        let user = try? Data(contentsOf: userSettingsURL)
        let projectURL = URL(fileURLWithPath: session.cwd).appendingPathComponent(".claude/settings.json")
        let project = try? Data(contentsOf: projectURL)
        let data = try SettingsComposer.compose(userSettings: user, projectSettings: project, port: hookServer.port, token: hookToken)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let path = settingsDir.appendingPathComponent("session-\(session.id).json")
        try data.write(to: path)
        return path.path
    }

    private func inspectGitStatus(in workspacePath: String) -> String? {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let gitPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDir), isDir.boolValue else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["status", "-s"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let box = DataBox()
        let pipeLock = NSLock()
        let outDone = DispatchSemaphore(value: 0)
        let drainQueue = DispatchQueue(label: "linkc.git.drain", attributes: .concurrent)
        drainQueue.async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            pipeLock.lock()
            box.data = data
            pipeLock.unlock()
            outDone.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if exited.wait(timeout: .now() + 1.0) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.5)
            _ = outDone.wait(timeout: .now() + 0.5)
            return nil
        }

        _ = outDone.wait(timeout: .now() + 0.5)
        guard process.terminationStatus == 0 else { return nil }
        pipeLock.lock()
        let finalData = box.data
        pipeLock.unlock()
        let trimmed = String(data: finalData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
