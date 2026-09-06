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

    private let hookServer: HookServer
    private let notifications: NotificationManager
    private let claudePath: String
    private let settingsDir: URL
    private let userSettingsURL: URL
    /// Persists the session manifest so sessions survive quitting/crashing and can be restored.
    private let manifest: WorkspaceManifest
    /// Per-run shared secret baked into every composed settings file and required by the hook
    /// server — no other local process can spoof session state at the loopback port.
    let hookToken = UUID().uuidString  // internal: tests need to send it
    /// True when the user is currently watching a given session id — panel open, linkC
    /// active, and that tab selected. Injected because it depends on UI-layer state the
    /// coordinator can't see. Invoked on the main actor.
    private let isWatching: @MainActor @Sendable (String) -> Bool

    /// Hook events are funneled through this single stream and drained by one consumer task
    /// so `store.apply` runs strictly in arrival order — unstructured per-event tasks would
    /// not preserve ordering, and the reducer is last-writer-wins.
    private let eventStream: AsyncStream<HookEvent>
    private let eventContinuation: AsyncStream<HookEvent>.Continuation
    private var consumerTask: Task<Void, Never>?

    /// Designated initializer — all collaborators injected (used by tests).
    public init(
        terminals: TerminalSessionManager,
        hookServer: HookServer,
        notifications: NotificationManager,
        claudePath: String,
        settingsDir: URL,
        userSettingsURL: URL,
        manifestDir: URL,
        isWatching: @escaping @MainActor @Sendable (String) -> Bool
    ) {
        self.terminals = terminals
        self.hookServer = hookServer
        self.notifications = notifications
        self.claudePath = claudePath
        self.settingsDir = settingsDir
        self.userSettingsURL = userSettingsURL
        self.manifest = WorkspaceManifest(directory: manifestDir)
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
                    NSApp.activate(ignoringOtherApps: true)
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
    }

    /// Stops the hook server and the event consumer. Called at app termination (and by tests).
    public func shutdown() {
        eventContinuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
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
            // backstop end whatever the transcript never closed out. Both turn boundaries
            // sweep: at turn end nothing sync survives, and at prompt submit anything
            // already parsed belongs to an earlier turn (a resumed session replays its
            // whole history — those spawns would otherwise show as running for the entire
            // first turn). Late async completions still resurface via the sweep flag.
            if turnIsOver(session.state) || event.kind == .userPromptSubmit {
                tracker.sweepAgents(session.id)
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

    @discardableResult
    public func newSession(cwd: String, agent: AgentKind = .claude, mode: LaunchMode = .new) throws -> Session {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return try launch(cwd: cwd, title: title, agent: agent, mode: mode)
    }

    /// Spawn a session in `cwd` with the given agent and mode, wire its terminal, select it,
    /// and record it (live, no `endedAt`) in the manifest. The single launch path for both new
    /// sessions and restores. Fails loud: a launch error prunes any partial state and rethrows.
    @discardableResult
    private func launch(cwd: String, title: String, agent: AgentKind = .claude, mode: LaunchMode, resumeId: String? = nil) throws -> Session {
        let session = store.create(cwd: cwd, title: title, agentKind: agent)
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
                executable = claudePath
                let settingsPath = try writeSettings(for: session)
                args = Self.launchArgs(mode: mode, resumeId: resumeId) + ["--settings", settingsPath]
            } else {
                guard let resolved = AgentDescriptor.resolveExecutable(for: agent) else {
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
            manifest.upsert(RestorableSession(linkcId: session.id, claudeSessionId: nil, cwd: cwd, title: title))
            syncRestorables()
            return session
        } catch {
            cleanup(sessionId: session.id) // fail loud: no ghost session or orphaned settings file
            throw error
        }
    }

    // MARK: - Restore

    /// Resume a previous session as a fresh live one. Uses `claude --resume <id>` when the claude
    /// conversation id was captured, else `claude --continue` in the folder. On success the old
    /// restorable is consumed (the new live session carries its own fresh manifest entry).
    @discardableResult
    public func restore(_ r: RestorableSession) throws -> Session {
        // A restorable with no captured claude id falls back to `--continue`, which attaches to
        // the folder's MOST RECENT conversation. If a live session already occupies that folder
        // (including one restored moments ago in the same Restore-all pass), a second
        // `--continue` would attach to the SAME conversation — two processes writing one
        // transcript. Refuse; the card stays and the user can restore it individually later.
        if (r.claudeSessionId ?? "").isEmpty,
           store.sessions.contains(where: { $0.cwd == r.cwd }) {
            throw LinkCError.process(
                "a session is already running in \(r.title) — restore this one after it ends, or dismiss it"
            )
        }
        let session = try launch(cwd: r.cwd, title: r.title, agent: .claude, mode: .continueLast, resumeId: r.claudeSessionId)
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
    public static func launchArgs(mode: LaunchMode, resumeId: String?) -> [String] {
        if let resumeId, !resumeId.isEmpty { return ["--resume", resumeId] }
        return mode.claudeArgs
    }

    /// Recompute the restorable set: every manifest entry that is not currently a live session.
    private func syncRestorables() {
        let liveIds = Set(store.sessions.map(\.id))
        restorableStore.set(manifest.entries.filter { !liveIds.contains($0.linkcId) })
    }

    public func focusSession(_ id: String) {
        terminals.select(id)
        NSApp.activate(ignoringOtherApps: true)
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
}
