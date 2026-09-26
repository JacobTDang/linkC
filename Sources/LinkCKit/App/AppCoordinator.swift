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
    /// Previous sessions that are no longer live — the sidebar's Earlier section.
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
    let notifications: NotificationManager
    let claudePath: String
    private let settingsDir: URL
    private let userSettingsURL: URL
    private let claudeJsonURL: URL?
    /// The home whose real config files linkC may write: every agent's folder trust, and linkC's MCP
    /// server registration. nil writes none of them. Only the production initializer passes the real
    /// home — the test suite used to add each of its temp folders to the developer's own config, over
    /// ten thousand entries, and rewrite every agent's MCP config on each run.
    private let userHome: URL?
    /// Persists the session manifest so sessions survive quitting/crashing and can be restored.
    let manifest: WorkspaceManifest
    /// Per-run shared secret baked into every composed settings file and required by the hook
    /// server — no other local process can spoof session state at the loopback port.
    let hookToken = UUID().uuidString  // internal: tests need to send it
    /// Claude's newest rate-limit reading, from any linkC-launched session's status line. In
    /// memory only: relaunching a session leaves it alone, since this instance lives on
    /// regardless — only restarting linkC itself clears it, and the Usage row then waits for
    /// the next report.
    private var claudeRateLimits: AgentUsage?
    /// Whether the latest Claude launch found a status line of the user's own, so linkC added none.
    private var claudeStatusLineIsUsers = false

    /// What the sidebar's Usage section shows for Claude.
    public var claudeUsage: AgentUsage? {
        ClaudeRateLimits.usage(reading: claudeRateLimits, userOwnsStatusLine: claudeStatusLineIsUsers)
    }
    /// True when the user is currently watching a given session id — panel open, linkC
    /// active, and that tab selected. Injected because it depends on UI-layer state the
    /// coordinator can't see. Invoked on the main actor.
    private let isWatching: @MainActor @Sendable (String) -> Bool
    let agentPathResolver: (@Sendable (AgentKind) -> String?)?
    /// Runs task gates and verifications off the main actor; injected so tests can script verdicts.
    let verifier: any TaskVerifier
    /// Workspaces with a verification run in flight, mapped to the task id running there — at
    /// most one run per workspace. The task id lets expiry skip exactly the task being verified.
    var verificationsInFlight: [String: String] = [:]
    /// What linkC has typed into each session's terminal, newest last, keyed by session id.
    /// `checkLimitsAndReroute` uses this to recognize its own text echoed back by the CLI so it is
    /// never read as that agent's own limit banner. Lives here rather than on `TerminalSession`:
    /// extensions cannot hold stored properties. Bounded to the last `injectedHistoryLimit` entries
    /// per session; recorded by every coordinator call that injects text into a session
    /// (`switchModel`, `dispatchTasks`, `dispatchMessages` — see `recordInjection`).
    ///
    /// No time bound: suppression in `LimitDetector` is by content, once per injected entry, not by
    /// age (see `LimitDetector.withoutInjected`). A previous time-bounded version guarded a fixed
    /// window and then let the same unchanged echo start reading as a fresh banner once the window
    /// elapsed — a `.completion` only ever lands on an IDLE session, and delivering it does not make
    /// the agent do anything, so nothing forces new output; the stale echo just sat there and
    /// "aged into" a false positive. Content-based, single-use suppression has no such window to
    /// outlive, and still lets a real banner through when it repeats a phrase an older brief quoted
    /// — that occurrence is not the one already removed.
    private var injectedText: [String: [String]] = [:]
    private static let injectedHistoryLimit = 20

    /// A teammate spawn the relay could not complete.
    struct SpawnFailure: Equatable, Sendable {
        let agent: AgentKind
        let workspacePath: String
        let error: String
    }
    /// The most recent spawn failure (missing executable, a launch error, ...). Without this,
    /// `_ = try? spawnTeammate(...)` swallowed the failure entirely: the task just sat
    /// `.queued`, retried once a second, with nothing anywhere saying why. Holds only the
    /// latest failure — a "last known problem" marker, not a log — so it's assertable in tests
    /// and available for the UI to surface later. Set from `AppCoordinator+Relay.swift`; no
    /// access modifier (matches `verificationsInFlight` above) since that setter lives in a
    /// different file in the same module.
    var lastSpawnFailure: SpawnFailure?
    /// Per session: the last screen signature seen and when it last changed — the watchdog's
    /// "gone quiet" clock. In memory only, so the clock restarts after a relaunch. Stored here
    /// rather than in the watchdog extension because extensions cannot hold stored properties.
    private var screenSignatures: [String: (signature: String, since: Date)] = [:]
    /// Notices already reported to the user as undeliverable, by message id. Also in memory: a
    /// notice still stuck after a relaunch is worth one more mention.
    var undeliveredNoticesReported: Set<String> = []

    /// When `sessionId`'s screen last changed; nil if it has never been sampled.
    func screenUnchangedSince(_ sessionId: String) -> Date? { screenSignatures[sessionId]?.since }
    /// The current tier → model mapping. A closure, not a value, so a settings edit is seen on
    /// the next spawn without anyone re-injecting anything.
    private let modelSettings: @MainActor @Sendable () -> AgentModelSettings
    /// Minimum interval between injections into the same terminal. Tests can override it.
    public static let injectionGap: TimeInterval = 2
    let injectionGap: TimeInterval
    private var turnEndDebounce: TurnEndDebounce
    var lastInjectionAt: [String: Date] = [:]

    /// How long `dispatchTasks` requires a session to have been paste-ready before delivering
    /// to it. Defaults to `AppCoordinator.defaultDeliverySettle`; tests inject 0 so a mock's
    /// near-instant negotiation is immediately a candidate without a real sleep. Production
    /// never overrides this — see `AppCoordinator.defaultDeliverySettle` for the measurement
    /// behind the default.
    let deliverySettle: TimeInterval
    /// Clock `dispatchTasks` reads when comparing `deliverySettle` against a session's
    /// `pasteReadySince`. Defaults to the real wall clock; tests inject a controllable one so
    /// the settle threshold can be proven — withheld before it elapses, delivered after — without
    /// an actual sleep.
    let now: @MainActor @Sendable () -> Date

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
        userHome: URL? = nil,
        verifier: any TaskVerifier = VerificationRunner(),
        modelSettings: @escaping @MainActor @Sendable () -> AgentModelSettings = { AgentModelStore.applicationSupport.load() },
        deliverySettle: TimeInterval = AppCoordinator.defaultDeliverySettle,
        injectionGap: TimeInterval = AppCoordinator.injectionGap,
        turnEndQuietPeriod: TimeInterval = 5.0,
        now: @escaping @MainActor @Sendable () -> Date = Date.init,
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
        self.userHome = userHome
        self.verifier = verifier
        self.modelSettings = modelSettings
        self.injectionGap = injectionGap
        self.deliverySettle = deliverySettle
        self.turnEndDebounce = TurnEndDebounce(quietPeriod: turnEndQuietPeriod)
        self.now = now
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
        modelSettings: @escaping @MainActor @Sendable () -> AgentModelSettings = { AgentModelStore.applicationSupport.load() },
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
            userHome: FileManager.default.homeDirectoryForCurrentUser,
            modelSettings: modelSettings,
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
        // Registration rewrites every agent's real config, so it needs a home to write to.
        if let userHome {
            do {
                try MCPRegistrar.registerAll(home: userHome)
            } catch {
                NSLog("[linkC mcp] start: registering the MCP server failed — %@", String(describing: error))
            }
        }
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
        // Readings hop to the main actor in separate tasks; `newer` keeps the latest taken,
        // whatever order they land in.
        hookServer.onStatusLine = { [weak self] reading in
            Task { @MainActor in
                guard let self else { return }
                self.claudeRateLimits = ClaudeRateLimits.newer(self.claudeRateLimits, reading)
            }
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
                endedAt: nil,
                isWorker: s.isWorker
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
                relayTurnEnd(sessionId: session.id, workspacePath: session.cwd)
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
        let wasWorker = store.session(id: sessionId)?.isWorker ?? false
        store.remove(id: sessionId)
        terminals.remove(sessionId)
        let settingsFile = settingsDir.appendingPathComponent("session-\(sessionId).json")
        try? FileManager.default.removeItem(at: settingsFile)
        notifications.forget(sessionId)
        screenSignatures.removeValue(forKey: sessionId)
        turnEndDebounce.forget(sessionId: sessionId)
        usageTracker?.unbind(sessionId: sessionId)
        injectedText.removeValue(forKey: sessionId)
        lastInjectionAt.removeValue(forKey: sessionId)
        if wasWorker {
            // A worker was linkC's, not the user's: its report is in the task record, so it
            // leaves nothing under Earlier.
            manifest.remove(linkcId: sessionId)
        } else {
            // The session ended or was stopped — keep its manifest entry but stamp it, so it
            // becomes a restorable card. (No-op when there is no entry, e.g. a launch that failed
            // before start.)
            manifest.markEnded(linkcId: sessionId, at: Date())
        }
        syncRestorables()
    }

    // MARK: - UI commands

    /// Spawns a teammate agent session in `workspacePath`, automatically synthesizing
    /// and writing a handoff memo to `<workspacePath>/.linkc/HANDOFF.md`.
    @discardableResult
    public func spawnTeammate(
        in workspacePath: String, agent: AgentKind = .claude, goal: String? = nil, tier: ModelTier? = nil,
        asWorker: Bool = false
    ) throws -> Session {
        let norm = ProjectPath.canonical(workspacePath)
        let existingSession = store.sessions.last { session in
            return session.cwd == norm && session.state != .ended
        } ?? store.sessions.last { session in
            return session.cwd == norm
        }

        let sourceAgent = existingSession?.agentKind
        let recentOutput: String?
        if let existingSession {
            let out = terminals.session(id: existingSession.id)?.recentOutput(lines: 50)
            recentOutput = (out?.isEmpty ?? true) ? nil : out
        } else {
            recentOutput = nil
        }

        let gitSummary = gitStatusSummary(in: norm)

        let lastGoal = resolveHandoffGoal(workspacePath: norm, explicit: goal)

        try HandoffComposer.writeHandoffSync(
            workspacePath: workspacePath,
            sourceAgent: sourceAgent,
            lastGoal: lastGoal,
            gitSummary: gitSummary,
            recentTerminalOutput: recentOutput
        )

        // A teammate starts in the background — the relay spawns these while the user is
        // working elsewhere, and selecting one raises the panel over whatever they were doing.
        return try newSession(cwd: workspacePath, agent: agent, mode: .new, tier: tier, select: false, asWorker: asWorker)
    }

    @discardableResult
    public func newSession(
        cwd: String, agent: AgentKind = .claude, mode: LaunchMode = .new, tier: ModelTier? = nil,
        select: Bool = true, asWorker: Bool = false
    ) throws -> Session {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return try launch(cwd: cwd, title: title, agent: agent, mode: mode, tier: tier, asWorker: asWorker, select: select)
    }

    /// The model configured for `agent` at `tier`, or nil when the mapping has no entry — a
    /// missing or emptied model, not a substitute. Shared by `launch` (which then leaves the
    /// session unpinned) and the relay's dispatch (which refuses to spawn at all).
    func resolvedModel(for agent: AgentKind, tier: ModelTier) -> String? {
        modelSettings().model(for: agent, tier: tier)
    }

    /// The tier `model` belongs to for `agent`, or nil when nothing maps to it — used to
    /// re-derive a session's pin after a hand switch. `modelSettings` is private to this file;
    /// this is the relay's access point onto it.
    func tier(forModel model: String, agent: AgentKind) -> ModelTier? {
        modelSettings().tier(forModel: model, agent: agent)
    }

    /// Records that linkC just typed `text` into `sessionId`'s terminal. Every call the coordinator
    /// makes to inject text into a session must call this right alongside `terminals.sendInput`.
    func recordInjection(sessionId: String, text: String) {
        recordInjection(sessionId: sessionId, texts: [text])
    }

    /// A batch keeps each prompt in the echo history and stamps its one injection once.
    func recordInjection(sessionId: String, texts: [String]) {
        var entries = injectedText[sessionId] ?? []
        entries.append(contentsOf: texts)
        if entries.count > Self.injectedHistoryLimit {
            entries.removeFirst(entries.count - Self.injectedHistoryLimit)
        }
        injectedText[sessionId] = entries
        lastInjectionAt[sessionId] = now()
    }

    /// Everything linkC has typed into `sessionId`'s terminal, passed to the limit detector so an
    /// echo of linkC's own text is never read as the agent's own banner. No age filtering: the
    /// detector suppresses each entry once, by content (see `LimitDetector.withoutInjected`), so
    /// there is nothing here for a clock to bound.
    func recentlyInjectedTexts(sessionId: String) -> [String] {
        injectedText[sessionId] ?? []
    }

    /// Spawn a session in `cwd` with the given agent and mode, wire its terminal, select it when
    /// `select` is true, and record it (live, no `endedAt`) in the manifest. The single launch path
    /// for both new sessions and restores. Selection waits for a successful start, so a failed
    /// launch never moves what is on screen. Fails loud: a launch error prunes any partial state
    /// and rethrows.
    @discardableResult
    private func launch(
        cwd: String,
        title: String,
        agent: AgentKind = .claude,
        mode: LaunchMode,
        resumeId: String? = nil,
        id: String? = nil,
        tier: ModelTier? = nil,
        asWorker: Bool = false,
        select: Bool
    ) throws -> Session {
        // A tier only ever pins a brand-new process. For Codex, `.continueLast`/`.resume` argv
        // starts with the `resume` subcommand (see AgentDescriptor), so appending `--model <id>`
        // after it — as this function does for `.new` — would land the flag after the subcommand
        // instead of before it. No caller pairs a tier with anything but `.new` today; refuse the
        // combination outright rather than ever build that argv.
        guard tier == nil || mode == .new else {
            throw LinkCError.process("a tier can only pin a new session; \(mode) reuses an existing session's model")
        }
        let model = tier.flatMap { resolvedModel(for: agent, tier: $0) }
        let session = store.create(cwd: cwd, title: title, id: id ?? UUID().uuidString, agentKind: agent,
                                   model: model, modelTier: model == nil ? nil : tier,
                                   claudeSessionId: resumeId, isWorker: asWorker)
        do {
            let terminal = terminals.makeSession(id: session.id, cwd: cwd, title: title, agentKind: agent, select: false)
            // A terminated child = an ended session: prune everything when the child exits.
            terminal.onTerminated = { [weak self] _ in
                self?.cleanup(sessionId: session.id)
            }

            let executable: String
            let args: [String]
            let env: [String: String] = ["LINKC_SESSION": session.id]

            if agent == .claude {
                // An explicit trust file wins; otherwise the user's home. With neither, nothing is written.
                if let trustFile = claudeJsonURL ?? userHome?.appendingPathComponent(".claude.json") {
                    do {
                        try DirectoryTrustManager.preApproveTrust(workspacePath: cwd, claudeJsonURL: trustFile)
                    } catch {
                        NSLog("[linkC] launch: could not pre-approve trust for %@ — %@", cwd, String(describing: error))
                    }
                }
                executable = claudePath
                let settingsPath = try writeSettings(for: session)
                args = Self.claudeLaunchArgs(mode: mode, resumeId: resumeId, settingsPath: settingsPath)
                    + (model.map { AgentModelCatalog.launchArguments(model: $0, for: agent) } ?? [])
            } else {
                // Codex and agy open a folder they have not seen on a trust dialog; trust it first, as
                // `preApproveTrust` does for Claude. Detecting that dialog stays the fallback, so a
                // failure here is logged rather than stopping the launch.
                if let userHome {
                    do {
                        switch agent {
                        case .codex:
                            try DirectoryTrustManager.preApproveCodexTrust(
                                workspacePath: cwd, configURL: userHome.appendingPathComponent(".codex/config.toml"))
                        case .agy:
                            try DirectoryTrustManager.preApproveAgyTrust(
                                workspacePath: cwd, settingsURL: userHome.appendingPathComponent(".gemini/antigravity-cli/settings.json"))
                        default:
                            break
                        }
                    } catch {
                        NSLog("[linkC] launch: could not pre-approve %@ trust for %@ — %@",
                              agent.displayName, cwd, String(describing: error))
                    }
                }
                // An injected resolver's own "not found" answer (nil) must not be papered over
                // by a fallback to the real disk: `agentPathResolver?(agent) ?? ...` cannot
                // distinguish "no resolver was given" from "the resolver was asked and said no",
                // so a caller that deliberately simulates a missing executable would silently
                // find whatever the same kind happens to have installed for real. Only fall
                // back to disk when no resolver was injected at all — matching how
                // `checkLimitsAndReroute`'s own candidate check already treats it.
                let resolved: String?
                if let agentPathResolver {
                    resolved = agentPathResolver(agent)
                } else {
                    resolved = AgentDescriptor.resolveExecutable(for: agent)
                }
                guard let resolved else {
                    throw LinkCError.process("Executable for \(agent.pillText) not found")
                }
                executable = resolved
                args = AgentDescriptor.arguments(for: agent, mode: mode, sessionId: session.id)
                    + (model.map { AgentModelCatalog.launchArguments(model: $0, for: agent) } ?? [])
            }

            try terminal.start(
                executable: executable,
                args: args,
                env: env
            )
            if select { terminals.select(session.id) }
            // Record the now-live session so it survives a quit/crash and can be restored.
            manifest.upsert(RestorableSession(
                linkcId: session.id,
                claudeSessionId: resumeId,
                cwd: cwd,
                title: title,
                agentKind: agent,
                wasActiveOnQuit: true,
                endedAt: nil,
                isWorker: asWorker
            ))
            syncRestorables()
            return session
        } catch {
            cleanup(sessionId: session.id) // fail loud: no ghost session or orphaned settings file
            throw error
        }
    }

    // MARK: - Restore

    /// Brings back the sessions that were live when linkC last quit — each on its own
    /// conversation, never two on one (see `RelaunchPlan`). Entries that lose a contest for a
    /// conversation go under Earlier; workers that no longer hold a task are dropped.
    public func restoreActiveSessions() {
        let active = manifest.entries.filter { $0.wasActiveOnQuit || $0.endedAt == nil }
        let plan = RelaunchPlan.make(entries: active, workersHoldingTasks: workersHoldingOpenTasks(active))
        for id in plan.drop { manifest.remove(linkcId: id) }
        for id in plan.toEarlier { manifest.markEnded(linkcId: id, at: now()) }
        for var r in active where plan.relaunch.contains(r.linkcId) {
            r.wasActiveOnQuit = false
            if FileManager.default.fileExists(atPath: r.cwd) {
                do {
                    try launch(
                        cwd: r.cwd,
                        title: r.title,
                        agent: r.agentKind,
                        mode: .continueLast,
                        resumeId: r.agentKind == .claude ? r.claudeSessionId : nil,
                        id: r.linkcId,
                        asWorker: r.isWorker,
                        select: !r.isWorker
                    )
                } catch {
                    NSLog("[linkC] relaunch: %@ could not restart — %@", r.title, String(describing: error))
                    // A worker that never came back holds nothing for the user to restore by
                    // hand — its report is already in the task record (see `dismiss`/idle close).
                    // Only the user's own entry stays under Earlier.
                    if r.isWorker { manifest.remove(linkcId: r.linkcId) } else { manifest.upsert(r) }
                }
            } else {
                manifest.upsert(r)
            }
        }
        syncRestorables()
    }

    /// The worker entries that still hold an open task in their workspace. An inbox that cannot
    /// be read is logged, and its workers are treated as holding nothing — the user's own
    /// sessions do not depend on it.
    private func workersHoldingOpenTasks(_ entries: [RestorableSession]) -> Set<String> {
        var holding: Set<String> = []
        let folders = Set(entries.filter(\.isWorker).map { ProjectPath.canonical($0.cwd) })
        for folder in folders where workspaceExists(folder) {
            do {
                holding.formUnion(try InboxStore(workspaceRoot: folder).openTasks().compactMap(\.assigneeSessionId))
            } catch {
                NSLog("[linkC] relaunch: open tasks for %@ could not be read — its workers stay closed: %@",
                      folder, String(describing: error))
            }
        }
        return holding
    }

    /// Resume a previous session as a fresh live one. Uses `claude --resume <id>` when the claude
    /// conversation id was captured, else `--continue` in the folder. On success the old
    /// restorable is consumed (the new live session carries its own fresh manifest entry).
    /// If `as: agent` is provided, overrides the session's recorded agent kind.
    @discardableResult
    public func restore(_ r: RestorableSession, as agent: AgentKind? = nil) throws -> Session {
        let targetAgent = agent ?? r.agentKind
        // Two live sessions must never land on one conversation. A Claude entry with a captured
        // id resumes exactly that id; anything else — a Claude entry with no id, or any other
        // agent — falls back to `--continue`/`resume --last`, which attaches to the folder's MOST
        // RECENT conversation for that agent. Refuse whichever way this entry would collide with
        // a session already live (including one restored moments ago in the same Restore-all
        // pass, or one a relaunch already brought back onto this entry's id/folder); the card
        // stays and the user can restore it individually later.
        let resumesById = targetAgent == .claude && !(r.claudeSessionId ?? "").isEmpty
        let folder = ProjectPath.canonical(r.cwd)
        if store.sessions.contains(where: { live in
            resumesById
                ? live.claudeSessionId == r.claudeSessionId
                : live.agentKind == targetAgent && live.cwd == folder
        }) {
            throw LinkCError.process(
                "a \(targetAgent.displayName) conversation is already open in \(r.title) — restore this one after it ends, or dismiss it"
            )
        }
        let session = try launch(
            cwd: r.cwd,
            title: r.title,
            agent: targetAgent,
            mode: .continueLast,
            resumeId: targetAgent == .claude ? r.claudeSessionId : nil,
            select: true
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

    /// Invoked with a session id right after `focusSession` moves the selection onto it —
    /// whether that came from a click (`AppModel.focus`) or from clicking a macOS notification
    /// (`notifications.onActivate` calls `focusSession` directly, bypassing `AppModel.focus`).
    /// Lets the UI layer react to any focus of a session the same way, e.g. dropping an open
    /// Board or screen that would otherwise stay on top of the newly-selected session.
    public var onSessionFocused: ((String) -> Void)?

    public func focusSession(_ id: String) {
        terminals.select(id)
        onSessionFocused?(id)
        // Opening a worker's terminal makes it the user's: they are using it now.
        store.adopt(id: id)
        manifest.markAdopted(linkcId: id)
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
            activePaths.insert(session.cwd)
            guard let term = terminals.session(id: session.id) else { continue }

            if session.agentKind != .shell, term.processId > 0 {
                try? BlackboardStore(workspaceRoot: session.cwd)
                    .heartbeat(agentKind: session.agentKind, pid: term.processId, timeout: 0.5)
            }

            // The watchdog's progress signal, taken from the same once-a-second row read.
            let signature = term.screenSignature()
            if screenSignatures[session.id]?.signature != signature {
                screenSignatures[session.id] = (signature, now())
            }

            // Inspect terminal output for provider rate limits & auto-reroute
            checkLimitsAndReroute(for: session.id)

            // `.error` here means checkLimitsAndReroute found no capable peer (or none at all)
            // for this agent's last limit — not that the session itself is broken. Its own
            // recorded cooldown is the authority on whether that is still true; once the
            // cooldown has ended, recover on its own rather than waiting for a person to click
            // the tab (`focusSession` is the only other place that clears `.error`). This runs
            // for every agent kind, including Claude, whose own state otherwise comes from hook
            // events that never touch this mark.
            if let current = store.session(id: session.id), current.state == .error {
                let norm = session.cwd
                do {
                    if try InboxStore(workspaceRoot: norm).isAgentLimited(agent: session.agentKind) == nil {
                        store.updateState(id: session.id, to: .ready)
                    }
                } catch {
                    NSLog("[linkC relay] sampleAgentStates: %@ cooldown check — %@", session.agentKind.displayName, String(describing: error))
                }
            }

            // Detect dynamic agent kind changes in child process tree
            let liveAgent = term.sampleForegroundAgent()
            if liveAgent != session.agentKind && liveAgent != .shell {
                store.updateAgentKind(id: session.id, to: liveAgent)
            }

            // Claude has its own hook server providing exact event transitions.
            guard session.agentKind != .claude else { continue }

            guard let currentSession = store.session(id: session.id), currentSession.state != .error else { continue }

            // A folder-trust dialog has no spinner, so it read as an idle session and the relay
            // typed briefs into it. Hold the session as needing the user until it is answered.
            if term.showsTrustPrompt() {
                if currentSession.state != .waitingPermission {
                    store.updateState(id: session.id, to: .waitingPermission)
                    let updated = store.session(id: session.id) ?? currentSession
                    if FocusPolicy.shouldNotify(
                        session: updated,
                        enteredNotifiable: true,
                        isWatchingThisSession: isWatching(session.id)
                    ) {
                        notifications.post(session: updated)
                    }
                }
                continue
            }
            // Only the trust dialog puts a screen-read session in `.waitingPermission`, so once it
            // is gone the session is ready for input again.
            if currentSession.state == .waitingPermission {
                store.updateState(id: session.id, to: .ready)
            }

            let liveActivity = term.liveActivityLine()
            let isWorking = liveActivity != nil && !liveActivity!.isEmpty

            if isWorking {
                if currentSession.state.bucket != .active {
                    store.updateState(id: session.id, to: .working)
                }
            } else {
                // A booting TUI is also silent. Promote only once the agent CLI is actually
                // running, or the relay types the next frame into a process that cannot read it.
                if currentSession.state == .starting,
                   ProcessSnooper.detectAgent(atOrUnder: term.processId) != nil {
                    store.updateState(id: session.id, to: .ready)
                }
            }

            // An idle stretch only counts while the session stays working; any other state ends it,
            // so it can never carry into the next task's turn.
            guard currentSession.state.bucket == .active else {
                turnEndDebounce.forget(sessionId: session.id)
                continue
            }
            if turnEndDebounce.poll(sessionId: session.id, isWorking: isWorking, now: now()) {
                store.updateState(id: session.id, to: .finished)
                let updated = store.session(id: session.id) ?? currentSession
                if FocusPolicy.shouldNotify(
                    session: updated,
                    enteredNotifiable: true,
                    isWatchingThisSession: isWatching(session.id)
                ) {
                    notifications.post(session: updated)
                }
                if relayTurnEnd(sessionId: session.id, workspacePath: session.cwd) > 0 {
                    // A turn read as ended while a task is open is either the agent stopping short or
                    // the screen read being wrong; the rows it was read from tell which.
                    NSLog("[linkC relay] %@ read as done with a task open; its last rows:\n%@",
                          session.agentKind.displayName, term.recentScreenRows(12).joined(separator: "\n"))
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
            let norm = session.cwd
            agentsByPath[norm, default: []].insert(session.agentKind)
        }

        for (path, agents) in additionalAgents {
            let norm = ProjectPath.canonical(path)
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
        let norm = ProjectPath.canonical(workspacePath)
        let sessions = store.sessions.filter { $0.cwd == norm }.map { s in
            let term = terminals.session(id: s.id)
            let act = term?.liveActivityLine()
            let out = term?.recentOutput(lines: 15) ?? ""
            return (id: s.id, agent: s.agentKind, status: s.state.rawValue, activity: act, recentOutput: out)
        }
        return dashboardAggregator.aggregateProject(workspacePath: norm, liveSessions: sessions)
    }

    public func fetchProjectDashboardAsync(workspacePath: String) async -> ProjectDashboardData {
        let norm = ProjectPath.canonical(workspacePath)
        let sessions = store.sessions.filter { $0.cwd == norm }.map { s in
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
        let workspaces = Array(Set(store.sessions.map(\.cwd)))
        let sessions = store.sessions.map { s in
            let term = terminals.session(id: s.id)
            let act = term?.liveActivityLine()
            let out = term?.recentOutput(lines: 15) ?? ""
            return (id: s.id, workspace: s.cwd, agent: s.agentKind, status: s.state.rawValue, activity: act, recentOutput: out)
        }
        return dashboardAggregator.aggregateGlobal(workspaces: workspaces, liveSessions: sessions)
    }

    public func fetchGlobalDashboardAsync() async -> GlobalDashboardData {
        let workspaces = Array(Set(store.sessions.map(\.cwd)))
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
        let norm = ProjectPath.canonical(workspacePath)
        guard let session = store.sessions.first(where: {
            $0.cwd == norm && $0.agentKind == agent && $0.state != .ended
        }) else {
            throw LinkCError.process("No active session found for \(agent.displayName) in \(workspacePath).")
        }
        let cmd = AgentModelCatalog.interactiveSwitchCommand(model: modelName, for: agent)
        terminals.sendInput(sessionId: session.id, text: cmd)
        recordInjection(sessionId: session.id, text: cmd)
        return "Switched \(agent.displayName) model to '\(modelName)' in session \(session.id)."
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
        let projectDir = URL(fileURLWithPath: session.cwd).appendingPathComponent(".claude")
        let project = try? Data(contentsOf: projectDir.appendingPathComponent("settings.json"))
        let projectLocalURL = projectDir.appendingPathComponent("settings.local.json")
        var projectLocal = try? Data(contentsOf: projectLocalURL)
        // linkC never needed this file before and only reads it to decide whether to add its
        // own status line — unlike the user's and the project's settings.json, a syntax error
        // here must not block launching a session. Empty/missing data already reads as "defines
        // nothing" further down, so only genuinely malformed, non-empty content is swapped out.
        if let raw = projectLocal, !raw.isEmpty, !((try? JSONSerialization.jsonObject(with: raw)) is [String: Any]) {
            NSLog("[linkC] %@ has malformed JSON — launching as if it defined no status line", projectLocalURL.path)
            projectLocal = nil
        }
        let data = try SettingsComposer.compose(
            userSettings: user, projectSettings: project, projectLocalSettings: projectLocal,
            port: hookServer.port, token: hookToken)
        claudeStatusLineIsUsers = try SettingsComposer.definesStatusLine(
            user: user, project: project, projectLocal: projectLocal)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let path = settingsDir.appendingPathComponent("session-\(session.id).json")
        try data.write(to: path)
        return path.path
    }

    /// `git status --porcelain` for the handoff memo, or nil when the folder is not a git
    /// repository or has no changes. A git failure inside a repository is logged. One-second
    /// timeout: callers run on the main actor.
    func gitStatusSummary(in workspacePath: String) -> String? {
        let workspace = URL(fileURLWithPath: workspacePath)
        guard GitClient.isRepository(workspace) else { return nil }
        do {
            let text = try GitClient(timeout: 1).statusPorcelain(in: workspace)
            return text.isEmpty ? nil : text
        } catch {
            NSLog("[linkC] git status for %@ — %@", workspacePath, String(describing: error))
            return nil
        }
    }
}
