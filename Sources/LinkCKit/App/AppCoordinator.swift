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
    public typealias OpenCodeModelLister = @Sendable (_ folder: String) async throws -> [String]

    enum OpenCodeModelAvailability: Equatable {
        case checking
        case available
        /// A permanent answer: no model is configured for the tier, or the model is not among those
        /// OpenCode lists.
        case refused(String)
        /// The listing itself failed (OpenCode missing, a non-zero exit, a timeout, no models), so
        /// nothing is known about the model.
        case uncheckable(String)
    }

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
    /// Where the selected session is remembered between launches. nil remembers nothing: only the
    /// production initializer passes `.standard`, so a test never reads or writes the real domain —
    /// a shared global that made `testStartRestoresTabSelectionFromUserDefaults` depend on which
    /// test had run before it.
    private let defaults: UserDefaults?
    static let lastSelectedSessionKey = "LinkCLastSelectedSessionId"
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
    /// How to read what each agent has left, keyed by agent kind — the same closures the MCP
    /// server's usage-status tool calls (`MCPServer.defaultUsageReaders()`). Read from
    /// `checkLimitsAndReroute` (a different file in this module, hence no access modifier —
    /// matches `lastSpawnFailure` above) to rest a rerouted session until the agent's real reset
    /// instead of a fixed cooldown. Empty by default: every test builds the coordinator through
    /// the designated initializer directly, and none of them wants a limit's cooldown silently
    /// swayed by whatever is sitting in this machine's real `~/.codex` or `~/.claude` right now.
    /// Only the production initializer wires the real readers.
    let usageReaders: [AgentKind: MCPServer.UsageReader]
    /// True when the user is currently watching a given session id — panel open, linkC
    /// active, and that tab selected. Injected because it depends on UI-layer state the
    /// coordinator can't see. Invoked on the main actor.
    private let isWatching: @MainActor @Sendable (String) -> Bool
    let agentPathResolver: (@Sendable (AgentKind) -> String?)?
    /// Lists models away from the main actor. Results are reused briefly so the once-per-second
    /// relay never blocks on OpenCode, while withdrawn free models are noticed within seconds.
    let openCodeModels: OpenCodeModelLister
    private struct OpenCodeModelListing {
        enum ListingResult {
            case success([String])
            case failure(String)
        }
        let checkedAt: Date
        let result: ListingResult
    }
    private var openCodeModelListings: [String: OpenCodeModelListing] = [:]
    private var openCodeModelChecksInFlight: Set<String> = []
    static let openCodeModelListingMaxAge: TimeInterval = 5
    /// A failed listing is kept longer, so a broken OpenCode is listed at most once a minute per folder.
    static let openCodeModelFailedListingMaxAge: TimeInterval = 60
    /// How long the app waits for `opencode models`: less than the 20 s `linkc` waits for its open
    /// request, so the command hears "could not check" rather than nothing. Public: it is read by the
    /// public initializer's default `openCodeModels`.
    public static let openCodeModelListingTimeout: TimeInterval = 10
    var openCodeModelCheckCount = 0
    /// OpenCode refusals the user has been told of, one per queued task or message, so a pass that meets the
    /// same one again says nothing to them. Pruned by the dispatch passes to what is still queued.
    var openCodeRefusalUsersTold: Set<OpenCodeRefusalKey> = []
    /// OpenCode refusals whose notice has reached the delegator's inbox. A notice that could not be written is
    /// missing here, so every later pass tries it again. Pruned like `openCodeRefusalUsersTold`.
    var openCodeRefusalNoticesSent: Set<OpenCodeRefusalKey> = []
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

    /// What a delegator was told about a held task: the end of the limit holding it, or nil when the
    /// notice named none. A task is told again only when this changes.
    struct LimitHoldNotice: Equatable {
        let until: Date?
    }

    /// A notice to a delegator that did not reach the inbox, and is sent again until it does.
    struct PendingDelegatorNotice: Equatable {
        let workspace: String
        let sender: AgentKind
        let delegator: AgentKind
        let taskId: String?
        let body: String
    }

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
    /// `fingerprint` is the rows the signature was worked out from: a screen with the same
    /// fingerprint has the same signature, so it is not worked out again.
    private var screenSignatures: [String: (fingerprint: Int, signature: String, since: Date)] = [:]
    /// Notices already reported to the user as undeliverable, by message id, keyed by workspace.
    /// Also in memory: a notice still stuck after a relaunch is worth one more mention. Pruned by
    /// `dispatchMessages` to the ids still `.queued` in that workspace's inbox, so a notice that
    /// is later delivered or expires is forgotten rather than tracked for the app's whole lifetime.
    var undeliveredNoticesReported: [String: Set<String>] = [:]
    /// Per workspace, the queued tasks whose delegator was told that a limit holds them, and the end
    /// the notice named. A task stays marked only while it is held, so one pass says it once and the
    /// next says nothing, until the end it was told moves.
    var limitHoldNoticesSent: [String: [String: LimitHoldNotice]] = [:]
    /// Notices for a delegator that the inbox could not take when they were sent. The next relay
    /// tick of their workspace sends them again; one leaves only when it has been written.
    var pendingDelegatorNotices: [PendingDelegatorNotice] = []
    /// Per session id, the task a limit has held with that worker: one that names its model, which is
    /// never moved to another agent, so it carries on with its worker once the limit ends. The worker
    /// is told to when its session recovers; the entry is dropped then, or with the session.
    var limitHeldModelTasks: [String: String] = [:]
    /// Recent-output signature captured the moment a limit was last recorded for a session, keyed
    /// by session id. A later detection whose recent output hashes the same is the identical old
    /// banner still sitting in the scrollback after a cooldown expired and `sampleAgentStates`
    /// returned the session to `.ready` — recording a fresh limit from it would re-arm the
    /// cooldown forever from output that never changed. Only output that actually changed (a
    /// different signature) can count as a new limit. Cleared by `cleanup`. In-process only, like
    /// `screenSignature()` above — see its own doc comment.
    var limitSignatures: [String: String] = [:]
    /// Per session: what `checkLimitsAndReroute` last ran the limit rules over. The rules read only
    /// the screen, the agent kind and what linkC has typed, so the same three give the same answer
    /// and the scan is skipped — except while a reroute is held for that session, when the rules run
    /// every tick so the hold can end as soon as the worker is quiet or the banner goes. Cleared by
    /// `cleanup`.
    var limitScans: [String: LimitScan] = [:]
    /// Per session: the reroute `checkLimitsAndReroute` is holding back because the worker is busy.
    /// Cleared by `cleanup`.
    var limitHolds: [String: LimitHold] = [:]
    /// How long a reroute is held back for a worker that stays busy, from when the hold began. A
    /// worker whose state stays working, or whose screen keeps changing, must not keep its task
    /// for ever once the agent is out of quota.
    static let limitHoldCap: TimeInterval = 180
    /// Finds a provider limit in a session's recent output, given what linkC has typed into it.
    /// The real rules unless a test substitutes a counter.
    var limitDetection: (_ output: String, _ agent: AgentKind, _ injected: [String]) -> LimitMatch? = {
        LimitDetector.detectLimit(inOutput: $0, agent: $1, ignoringInjected: $2)
    }

    /// When `sessionId`'s screen last changed; nil if it has never been sampled.
    func screenUnchangedSince(_ sessionId: String) -> Date? { screenSignatures[sessionId]?.since }

    /// What says `session` is busy right now, or nil when it is quiet: its state is working, Codex's
    /// footer says a terminal it started is still running (its turn can end with one left), or its
    /// screen changed within the turn-end quiet period (a state that has not caught up, or a turn
    /// end misread, still shows in the screen). `checkLimitsAndReroute` holds a reroute back while
    /// the worker is busy: moving its task would put a second agent in a checkout it is still using.
    func activity(of session: Session, screen: ScreenSnapshot) -> String? {
        if session.state.bucket == .active { return "its session is still working" }
        if session.agentKind == .codex, screen.showsBackgroundTerminals() {
            return "it still has a background terminal running"
        }
        guard let since = screenUnchangedSince(session.id) else { return nil }
        let quiet = now().timeIntervalSince(since)
        guard quiet < turnEndDebounce.quietPeriod else { return nil }
        return "its screen changed \(Int(max(0, quiet)))s ago"
    }
    /// The current tier → model mapping. A closure, not a value, so a settings edit is seen on
    /// the next spawn without anyone re-injecting anything.
    private let modelSettings: @MainActor @Sendable () -> AgentModelSettings
    /// Live model lists from `ModelListCache`. Injected so tests need no Application Support file.
    public let modelLists: @MainActor @Sendable () throws -> [AgentKind: AgentModelList]
    /// Refreshes CLI model lists at launch and every 6 hours. Tests can replace or leave nil.
    public var modelListRefresher: ModelListRefresher?
    /// Minimum interval between injections into the same terminal. Tests can override it.
    public static let injectionGap: TimeInterval = 2
    let injectionGap: TimeInterval
    private var turnEndDebounce: TurnEndDebounce
    /// How long a working session's activity line must stay away before its turn reads as ended.
    var turnEndQuietPeriod: TimeInterval { turnEndDebounce.quietPeriod }
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
    /// Hears each Claude session's status line through a file it writes, and hands the rate limits
    /// to the hook server's status-line path. See `SettingsComposer.statusLineCommand`.
    private let statusLines: StatusLineFeed
    private var consumerTask: Task<Void, Never>?
    /// The one loop behind every periodic sample: the sessions, the relay and, while `panelVisible`,
    /// the app's own sampling (`panelSweep`). Its spacing follows `TickCadence`.
    var sweepTicker: SweepTicker?
    /// Wakes `sweepTicker` when a workspace's inbox file is replaced, so a new delegation never
    /// waits out the slow interval. A burst of writes still makes one pass: the ticker holds
    /// woken passes `TickCadence.minimumWakeGap` apart. Watches the workspaces the relay works on:
    /// those with a live session or a running linkC MCP server.
    private var inboxWatcher: InboxWatcher?
    private let sweepClock: any Clock<Duration>
    /// The folders where linkC's MCP server runs (`MCPWorkspaceRegistry`), served even with no session there.
    private let mcpWorkspaces: @MainActor @Sendable () -> Set<String>
    /// Where the app publishes known projects for out-of-process MCP servers. Nil: publish nothing (tests).
    private let knownProjectsFile: KnownProjectsFile?
    /// Sidebar project paths (`SidebarState.projectOrder`), folded into the known-projects list.
    private let sidebarProjects: @MainActor @Sendable () -> [String]
    /// Last contents written to `knownProjectsFile`, so a rewrite only happens when they change.
    private var lastPublishedProjects: [KnownProject]?
    /// How many times `projects.json` was written this run — test seam for rewrite-on-change.
    private(set) var knownProjectsWriteCount = 0
    /// Where the `linkc` command leaves its requests; nil turns the command off.
    let openRequests: OpenRequestStore?
    /// Wakes a pass when the `linkc` command leaves a request.
    private var openRequestWatcher: FolderWatcher?
    /// Prompts the `linkc` command asked for, by session id, waiting for their agent to be ready (`typeOpeningPrompts`).
    var openingPrompts: [String: OpeningPrompt] = [:]
    /// What the last relay pass found in each workspace, so choosing the next interval reads
    /// nothing. Internal: the relay writes it (see `AppCoordinator+Relay.swift`).
    var relayWork = RelayWork()
    /// The task states each folder had at the last relay pass, for Discord's task events.
    var taskEvents = TaskEventFeed()

    /// Whether the app has something on screen that needs its own sampling: the menu-bar panel, or a
    /// window that shows live terminals. The app decides which, and sets it through `setPanelVisible`.
    public private(set) var panelVisible = false
    /// The app's own sampling that only matters while the panel is visible or a torn-off window is open
    /// (terminals, sidebar). Runs on every tick while `panelVisible`, after the sessions are sampled, and
    /// once on its own when `panelVisible` turns true (see `setPanelVisible`).
    public var panelSweep: (@MainActor () async -> Void)?
    /// Told the id of a session the `linkc` command opened, so the app can give it a window.
    public var onCommandSessionOpened: ((String) -> Void)?

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
        defaults: UserDefaults? = nil,
        verifier: any TaskVerifier = VerificationRunner(),
        modelSettings: @escaping @MainActor @Sendable () -> AgentModelSettings = { AgentModelStore.applicationSupport.load() },
        modelLists: @escaping @MainActor @Sendable () throws -> [AgentKind: AgentModelList] = {
            try ModelListCache.applicationSupport.read()
        },
        modelListRefresher: ModelListRefresher? = nil,
        usageReaders: [AgentKind: MCPServer.UsageReader] = [:],
        deliverySettle: TimeInterval = AppCoordinator.defaultDeliverySettle,
        injectionGap: TimeInterval = AppCoordinator.injectionGap,
        turnEndQuietPeriod: TimeInterval = 5.0,
        now: @escaping @MainActor @Sendable () -> Date = Date.init,
        sweepClock: any Clock<Duration> = ContinuousClock(),
        mcpWorkspaces: @escaping @MainActor @Sendable () -> Set<String> = { [] },
        knownProjectsFile: KnownProjectsFile? = nil,
        sidebarProjects: @escaping @MainActor @Sendable () -> [String] = { [] },
        openRequests: OpenRequestStore? = nil,
        openCodeModels: @escaping OpenCodeModelLister = { folder in
            try await Task.detached {
                try MCPServer.listOpenCodeModels(in: folder, timeout: AppCoordinator.openCodeModelListingTimeout)
            }.value
        },
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
        self.defaults = defaults
        self.verifier = verifier
        self.modelSettings = modelSettings
        self.modelLists = modelLists
        self.modelListRefresher = modelListRefresher
        self.usageReaders = usageReaders
        self.injectionGap = injectionGap
        self.deliverySettle = deliverySettle
        self.turnEndDebounce = TurnEndDebounce(quietPeriod: turnEndQuietPeriod)
        self.now = now
        self.sweepClock = sweepClock
        self.mcpWorkspaces = mcpWorkspaces
        self.knownProjectsFile = knownProjectsFile
        self.sidebarProjects = sidebarProjects
        self.openRequests = openRequests
        self.openCodeModels = openCodeModels
        self.isWatching = isWatching
        self.statusLines = StatusLineFeed(
            directory: settingsDir.appendingPathComponent("status-lines", isDirectory: true),
            deliver: { [hookServer] body, reading in hookServer.acceptStatusLine(body: body, reading: reading) })
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: HookEvent.self)
        // Everything the manifest already holds is from a previous run — surface it as restorable.
        syncRestorables()
    }

    func openCodeModelAvailability(in folder: String, tier: ModelTier) -> OpenCodeModelAvailability {
        guard let model = resolvedModel(for: .opencode, tier: tier) else {
            return .refused("no model configured for opencode tier \(tier.rawValue) — set it in linkC's Settings > Models")
        }
        return openCodeModelAvailability(
            in: folder, model: model, subject: "\(model) (opencode tier \(tier.rawValue))",
            checked: "opencode tier \(tier.rawValue)'s model \(model)", remedy: "set the tier in linkC settings")
    }

    /// Whether OpenCode may run `model` in `folder` right now: free, and listed by OpenCode itself.
    /// `subject` names the model in a refusal, `checked` in the message that it could not be checked;
    /// `remedy` says what to do about a refusal.
    func openCodeModelAvailability(
        in folder: String, model: String, subject: String, checked: String? = nil, remedy: String
    ) -> OpenCodeModelAvailability {
        guard OpenCodeFreeModels.isFree(model) else {
            return .refused("\(subject) is not free — OpenCode runs free models only; \(remedy)")
        }
        let norm = ProjectPath.canonical(folder)
        if let listing = openCodeModelListings[norm] {
            let age = now().timeIntervalSince(listing.checkedAt)
            switch listing.result {
            case .success(let models) where age <= Self.openCodeModelListingMaxAge:
                guard models.contains(model) else {
                    return .refused("\(subject) is not among the models OpenCode lists — free models come and go; \(remedy)")
                }
                return .available
            case .failure(let reason) where age <= Self.openCodeModelFailedListingMaxAge:
                return .uncheckable("could not check \(checked ?? subject) against the models OpenCode lists — \(reason)")
            case .success, .failure:
                break
            }
        }
        if openCodeModelChecksInFlight.insert(norm).inserted {
            let lister = openCodeModels
            Task { [weak self] in
                let result: OpenCodeModelListing.ListingResult
                do { result = .success(try await lister(norm)) }
                catch { result = .failure(String(describing: error)) }
                guard let self else { return }
                self.openCodeModelListings[norm] = OpenCodeModelListing(checkedAt: self.now(), result: result)
                self.openCodeModelChecksInFlight.remove(norm)
                self.openCodeModelCheckCount += 1
                // The pass that was waiting for this answer need not wait out an idle interval.
                self.sweepTicker?.wake()
            }
        }
        return .checking
    }

    /// Production initializer — builds the real hook server, notification center, and settings
    /// locations, while the app supplies the terminal manager it also renders and the watch
    /// probe it computes from panel state.
    public convenience init(
        claudePath: String,
        terminals: TerminalSessionManager,
        modelSettings: @escaping @MainActor @Sendable () -> AgentModelSettings = { AgentModelStore.applicationSupport.load() },
        sidebarProjects: @escaping @MainActor @Sendable () -> [String] = { [] },
        isWatching: @escaping @MainActor @Sendable (String) -> Bool
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let linkCDir = support.appendingPathComponent("linkC", isDirectory: true)
        self.init(
            terminals: terminals,
            hookServer: HookServer(port: 0, statusLineCacheURL: HookServer.defaultStatusLineCacheURL()),
            notifications: NotificationManager(),
            claudePath: claudePath,
            settingsDir: linkCDir,
            userSettingsURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json"),
            manifestDir: linkCDir,
            userHome: FileManager.default.homeDirectoryForCurrentUser,
            defaults: .standard,
            modelSettings: modelSettings,
            modelListRefresher: ModelListRefresher(),
            usageReaders: MCPServer.defaultUsageReaders(),
            mcpWorkspaces: { MCPWorkspaceRegistry.applicationSupport.liveWorkspaces() },
            knownProjectsFile: .applicationSupport,
            sidebarProjects: sidebarProjects,
            openRequests: .applicationSupport,
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
            hookServer: HookServer(port: 0, statusLineCacheURL: workspaceDir.appendingPathComponent("claude-status-line.json")),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: "/usr/bin/true",
            settingsDir: workspaceDir,
            userSettingsURL: workspaceDir.appendingPathComponent("user-settings.json"),
            manifestDir: workspaceDir,
            modelLists: { try ModelListCache(directory: workspaceDir).read() },
            isWatching: { _ in false }
        )
    }

    public func start() throws {
        sweepOrphanedSettingsFiles()
        statusLines.sweep()
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
        if let lastId = defaults?.string(forKey: Self.lastSelectedSessionKey),
           terminals.sessions.contains(where: { $0.id == lastId }) {
            terminals.select(lastId)
        }
        inboxWatcher = InboxWatcher { [weak self] in
            Task { @MainActor in self?.sweepTicker?.wake() }
        }
        let ticker = SweepTicker(
            clock: sweepClock,
            interval: { [weak self] in self?.sweepInterval() ?? TickCadence.idle },
            pass: { [weak self] in await self?.sweepTick() }
        )
        sweepTicker = ticker
        ticker.start()
        if let openRequests {
            do {
                try openRequests.prepare()
                openRequestWatcher = try FolderWatcher(directory: openRequests.directory) { [weak self] in
                    Task { @MainActor in self?.sweepTicker?.wake() }
                }
            } catch {
                NSLog("[linkC] the linkc command's request folder %@ can't be watched; requests are read on each sweep — %@",
                      openRequests.directory.path, String(describing: error))
            }
        }
        // The ticker sleeps before its first pass. A folder where only an MCP server runs, or a sidebar
        // project with no session yet, may already hold tasks queued while linkC was not running, and the
        // `linkc` command may have left a request (it can be what launched linkC): serve them now, not an
        // idle interval later. A known-projects file also needs its first write. The request folder is read
        // after its watcher is set up, so a request left in between wakes a pass too.
        if knownProjectsFile != nil
            || !mcpWorkspaces().isEmpty
            || !sidebarProjects().isEmpty
            || openRequests.map({ !$0.pending().isEmpty }) == true {
            ticker.wake()
        }
        if let modelListRefresher {
            Task { await modelListRefresher.start() }
        }
    }

    /// Tells the coordinator whether the panel, or a window that needs the same sampling, is on screen.
    /// Showing it gives the panel's own sampling one look at once, so the panel never opens on data
    /// that is seconds old, and holds the one-second cadence while it stays open. The session sweep
    /// and the relay do not run on show: the app sets this before the window appears, so a full pass
    /// here would run on the main thread in the middle of the opening animation. The sleep in progress
    /// is cut short and chosen again instead, so that pass follows within a second.
    public func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        guard visible else { return }
        sweepTicker?.reschedule()
        Task { [weak self] in
            // Hidden again before this got to run: there is nothing on screen to sample for.
            guard let self, panelVisible else { return }
            await panelSweep?()
        }
    }

    private func sweepInterval() -> Duration {
        TickCadence.interval(
            panelVisible: panelVisible,
            sessionStates: store.sessions.map(\.state),
            hasRelayWork: !relayWork.isEmpty || !openingPrompts.isEmpty
        )
    }

    /// One pass of the sweep: keep the inbox watches and the relay's notes on the workspaces that have a
    /// live session or a running linkC MCP server, sample the sessions and run the relay, then the app's
    /// own sampling while `panelVisible`. A folder with only an MCP server is one where an agent started
    /// outside linkC (a shell, another terminal app) can queue tasks: its relay runs here, since no
    /// session's sampling covers it. The watches come first, so a write after them wakes the next pass
    /// and one before them is read by this one.
    private func sweepTick() async {
        let liveSessions = store.sessions.filter { $0.state != .ended }
        let sessionFolders = Set(liveSessions.map { ProjectPath.canonical($0.cwd) })
        let mcpFolders = mcpWorkspaces()
        let serverOnlyFolders = mcpFolders.subtracting(sessionFolders)
        let workspaces = sessionFolders.union(serverOnlyFolders)
        let sidebar = sidebarProjects()
        let knownPaths = KnownProjectsPublisher.paths(sidebar: sidebar, mcpFolders: mcpFolders, sessions: store.sessions)
        let watched = workspaces.union(knownPaths)
        relayWork.retain(only: watched)
        taskEvents.retain(only: watched)
        inboxWatcher?.watch(workspaces: watched)
        sampleAgentStates()
        // After the sampling, so the file holds the states it just settled.
        publishKnownProjects(sidebar: sidebar, mcpFolders: mcpFolders)
        for folder in serverOnlyFolders.sorted() {
            processPendingMessages(workspacePath: folder)
        }
        for folder in knownPaths.subtracting(workspaces).sorted() {
            let open: Bool
            do {
                open = try InboxStore(workspaceRoot: folder).hasOpenWork(timeout: Self.relayLockTimeout)
            } catch {
                // A contended lock is the next tick's to retry; anything else (a corrupt inbox) is the
                // project's to be told about, not skipped without a word.
                if isRelayLockTimeout(error) {
                    NSLog("[linkC relay] sweepTick: %@ — inbox lock still contended after %.1fs; retrying next tick",
                          folder, Self.relayLockTimeout)
                } else {
                    NSLog("[linkC relay] sweepTick: %@ open-work check — %@", folder, String(describing: error))
                }
                continue
            }
            if open {
                processPendingMessages(workspacePath: folder)
            }
        }
        handleOpenRequests()
        typeOpeningPrompts()
        if panelVisible { await panelSweep?() }
    }

    /// Test seam: run one sweep pass without waiting on the ticker.
    func runSweepTickForTests() async {
        await sweepTick()
    }

    private func publishKnownProjects(sidebar: [String], mcpFolders: Set<String>) {
        guard let knownProjectsFile else { return }
        let projects = KnownProjectsPublisher.projects(sidebar: sidebar, mcpFolders: mcpFolders, sessions: store.sessions)
        // Also when the file is gone: a deleted `projects.json` would otherwise stay deleted until the
        // contents next changed, and every MCP server would report linkC as not running.
        if lastPublishedProjects == projects,
           FileManager.default.fileExists(atPath: knownProjectsFile.url.path) { return }
        do {
            try knownProjectsFile.write(projects)
            lastPublishedProjects = projects
            knownProjectsWriteCount += 1
        } catch {
            NSLog("[linkC] projects.json — %@", String(describing: error))
        }
    }

    /// Snapshot all active sessions to the manifest with wasActiveOnQuit == true before shutdown.
    public func prepareForShutdown(selectedId: String? = nil) {
        for s in store.sessions where s.state != .ended {
            var liveAgent = s.agentKind
            if let term = terminals.session(id: s.id), !term.isHookDriven {
                liveAgent = term.sampleForegroundAgent(fresh: true)
            }
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
            defaults?.set(sel, forKey: Self.lastSelectedSessionKey)
        }
    }

    /// Stops the hook server and the event consumer. Called at app termination (and by tests).
    public func shutdown() {
        prepareForShutdown()
        eventContinuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
        sweepTicker?.stop()
        sweepTicker = nil
        inboxWatcher?.stop()
        inboxWatcher = nil
        openRequestWatcher?.stop()
        openRequestWatcher = nil
        modelListRefresher?.stop()
        hookServer.stop()
        statusLines.sweep()
        if let knownProjectsFile {
            do {
                try knownProjectsFile.remove()
            } catch {
                NSLog("[linkC] projects.json remove — %@", String(describing: error))
            }
            lastPublishedProjects = nil
        }
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
            cleanup(sessionId: session.id, end: .reportedEnded)
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
    public func notify(id: String, title: String, body: String, tone: LinkCEvent.Tone) {
        // A unique request id per alert: UNNotificationRequest's identifier IS the
        // dedupe key, so reusing one id per endpoint would make each new alert replace
        // the last in Notification Center — a down→up→down flap would leave only its
        // final state for someone who was away from the machine.
        notifications.postAlert(
            id: "\(Self.alertIdPrefix)\(id):\(UUID().uuidString)", title: title, body: body, tone: tone
        )
    }

    /// A macOS notification linkC never forwards to Discord.
    public func postLocalNotification(title: String, body: String) {
        notifications.postLocal(title: title, body: body)
    }

    /// Told every event linkC posts, for Discord (spec 2026-11-05): alerts, task changes, closed workers.
    public var onEvent: ((LinkCEvent) -> Void)? {
        get { notifications.onEvent }
        set { notifications.onEvent = newValue }
    }

    /// Marks a notification as "not a session" — clicking one must not be routed into
    /// session focus, where the id matches nothing and the app activates on no navigation.
    static let alertIdPrefix = "alert:"

    /// Why a session is being cleaned up.
    enum SessionEnd {
        /// Its process ended by itself.
        case processExited
        /// linkC or the user ended it.
        case stopped
        /// Its launch threw.
        case launchFailed
        /// A hook event reported it ended.
        case reportedEnded
    }

    /// Remove a session everywhere it leaves state behind: the store, its terminal (dropped,
    /// not killed — the process is already dead here), its per-session settings file, its
    /// notification dedupe entry, and its usage-tracker dictionaries. Idempotent.
    func cleanup(sessionId: String, end: SessionEnd) {
        let ending = store.session(id: sessionId)
        let wasWorker = ending?.isWorker ?? false
        // A model-task worker (model set, no tier) whose process ends by itself while still
        // `.starting` fails those tasks at once: waiting the queue out would only respawn the same
        // rejected model every pass. A session the user closed, or a launch that threw, rejected
        // nothing. A tier worker keeps today's behaviour even when it also carries a model id.
        if end == .processExited, let ending, ending.isWorker, ending.state == .starting,
           ending.modelTier == nil, let model = ending.model {
            failModelTasksRejectedAtLaunch(
                session: ending, model: model, screen: terminals.session(id: sessionId)?.screenSnapshot())
        }
        store.remove(id: sessionId)
        terminals.remove(sessionId)
        let settingsFile = settingsDir.appendingPathComponent("session-\(sessionId).json")
        try? FileManager.default.removeItem(at: settingsFile)
        statusLines.unwatch(sessionId: sessionId)
        notifications.forget(sessionId)
        screenSignatures.removeValue(forKey: sessionId)
        turnEndDebounce.forget(sessionId: sessionId)
        usageTracker?.unbind(sessionId: sessionId)
        injectedText.removeValue(forKey: sessionId)
        lastInjectionAt.removeValue(forKey: sessionId)
        limitSignatures.removeValue(forKey: sessionId)
        limitScans.removeValue(forKey: sessionId)
        limitHolds.removeValue(forKey: sessionId)
        limitHeldModelTasks.removeValue(forKey: sessionId)
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

    /// Last non-empty line of a screen snapshot's recent output.
    static func lastNonEmptyScreenLine(_ screen: ScreenSnapshot?) -> String {
        guard let screen else { return "" }
        let lines = screen.recentOutput(lines: 40)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last.map { String($0) } ?? ""
    }

    /// Queued model tasks for this worker's agent/model fail at once when the CLI exits at launch.
    func failModelTasksRejectedAtLaunch(session: Session, model: String, screen: ScreenSnapshot?) {
        let lastLine = Self.lastNonEmptyScreenLine(screen)
        let exited = "\(session.agentKind.displayName) exited at launch with model \(model)"
        let reason = lastLine.isEmpty ? "\(exited) (nothing on its screen)." : "\(exited): \(lastLine)"
        let inbox = InboxStore(workspaceRoot: session.cwd)
        let open: [TaskRecord]
        do {
            open = try inbox.openTasks(for: session.agentKind)
        } catch {
            NSLog("[linkC] launch rejection: could not read tasks for %@ — %@", session.cwd, String(describing: error))
            return
        }
        for task in open where task.state == .queued && task.model == model {
            do {
                try inbox.failTaskAndNotify(
                    taskId: task.id, reason: reason, notifyBody: "failed — \(reason)")
                NSLog("[linkC relay] task %@ failed — %@", task.shortId, reason)
            } catch {
                NSLog("[linkC] launch rejection: task %@ — %@", task.shortId, String(describing: error))
            }
        }
    }

    // MARK: - UI commands

    /// Spawns a teammate agent session in `workspacePath`, automatically synthesizing
    /// and writing a handoff memo to `<workspacePath>/.linkc/HANDOFF.md`.
    @discardableResult
    public func spawnTeammate(
        in workspacePath: String, agent: AgentKind = .claude, goal: String? = nil, tier: ModelTier? = nil,
        model: String? = nil,
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
        return try newSession(cwd: workspacePath, agent: agent, mode: .new, tier: tier, model: model,
                              select: false, asWorker: asWorker)
    }

    @discardableResult
    public func newSession(
        cwd: String, agent: AgentKind = .claude, mode: LaunchMode = .new, tier: ModelTier? = nil,
        model: String? = nil,
        select: Bool = true, asWorker: Bool = false
    ) throws -> Session {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return try launch(cwd: cwd, title: title, agent: agent, mode: mode, tier: tier, model: model,
                          asWorker: asWorker, select: select)
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

    /// The current tier → model mapping, read when asked.
    func liveModelSettings() -> AgentModelSettings {
        modelSettings()
    }

    /// `agent`'s default tier in Settings > Models: the tier a session opened without one gets.
    func defaultTier(for agent: AgentKind) -> ModelTier {
        modelSettings().defaultTier(for: agent)
    }

    /// Records that linkC just typed `text` into `sessionId`'s terminal. Every call the coordinator
    /// makes to inject text into a session must call this right alongside `terminals.sendInput`.
    /// `startsWork` is for text that hands the session something to do; see the batch overload.
    func recordInjection(sessionId: String, text: String, startsWork: Bool = false) {
        recordInjection(sessionId: sessionId, texts: [text], startsWork: startsWork)
    }

    /// A batch keeps each prompt in the echo history and stamps its one injection once.
    ///
    /// `startsWork` is true where the text is a task or a message delivered to the session: that is
    /// where its next stretch of work starts. The screen sample that would notice the screen move
    /// can be seconds away, and the watchdog reads the quiet clock in between: left alone, an idle
    /// session's old clock made the task just handed to it look like a stall, so it restarts.
    /// Other text (a model switch) is not work. Typed into a session that hung mid-turn it must
    /// leave the clock alone, or it would hide the hang for another quiet period.
    func recordInjection(sessionId: String, texts: [String], startsWork: Bool = false) {
        var entries = injectedText[sessionId] ?? []
        entries.append(contentsOf: texts)
        if entries.count > Self.injectedHistoryLimit {
            entries.removeFirst(entries.count - Self.injectedHistoryLimit)
        }
        injectedText[sessionId] = entries
        let injectedAt = now()
        lastInjectionAt[sessionId] = injectedAt
        if startsWork { screenSignatures[sessionId]?.since = injectedAt }
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
        model: String? = nil,
        asWorker: Bool = false,
        select: Bool
    ) throws -> Session {
        // A tier or model only ever pins a brand-new process. For Codex, `.continueLast`/`.resume`
        // argv starts with the `resume` subcommand (see AgentDescriptor), so appending `--model <id>`
        // after it — as this function does for `.new` — would land the flag after the subcommand
        // instead of before it. No caller pairs a tier with anything but `.new` today; refuse the
        // combination outright rather than ever build that argv.
        guard (tier == nil && model == nil) || mode == .new else {
            throw LinkCError.process("a tier can only pin a new session; \(mode) reuses an existing session's model")
        }
        // OpenCode and Kilo never resume a conversation: their own would keep whatever model they
        // last ran on, which linkC cannot see and which may not be free. Continue, Resume and a
        // restore all open a new conversation in the folder, on the default tier's model.
        let opensFresh = (agent == .opencode || agent == .kilo) && mode != .new
        let mode: LaunchMode = (agent == .opencode || agent == .kilo) ? .new : mode
        let resolved: (model: String?, tier: ModelTier?)
        if let model {
            resolved = (model, nil)
        } else {
            resolved = try launchModel(for: agent, tier: tier, mode: mode)
        }
        let model = resolved.model
        let modelTier = resolved.tier
        // OpenCode and Kilo run free models only, whichever way the model was chosen: the New menu,
        // a teammate, a worker, or a tier that was set to a paid model.
        if agent == .opencode, let model, !OpenCodeFreeModels.isFree(model) {
            throw LinkCError.process("\(model) is not a free OpenCode model")
        }
        if agent == .kilo, let model, !KiloFreeModels.isFree(model) {
            throw LinkCError.process("\(model) is not a free Kilo model")
        }
        let session = store.create(cwd: cwd, title: title, id: id ?? UUID().uuidString, agentKind: agent,
                                   model: model, modelTier: modelTier,
                                   claudeSessionId: resumeId, isWorker: asWorker)
        do {
            let terminal = terminals.makeSession(id: session.id, cwd: cwd, title: title, agentKind: agent, select: false)
            // A terminated child = an ended session: prune everything when the child exits.
            terminal.onTerminated = { [weak self] _ in
                self?.cleanup(sessionId: session.id, end: .processExited)
            }
            // A worker the user types into is theirs, on screen or not.
            terminal.onUserInput = { [weak self] in
                guard let self else { return }
                // Typing into the agent's composer makes it the user's: a `linkc` prompt still waiting is
                // not pasted after it. Keys pressed while the agent starts answer its own questions, so the
                // prompt waits.
                if let state = store.session(id: session.id)?.state, isIdle(state),
                   openingPrompts.removeValue(forKey: session.id) != nil {
                    NSLog("[linkC] the linkc prompt for %@ was dropped: the user typed first", session.id)
                    notifications.post(title: "linkC: your prompt was not typed",
                                       body: "You typed into \(session.agentKind.displayName) first. Paste it in yourself if you still want it.",
                                       project: session.cwd, tone: .info)
                }
                adoptWorker(session.id)
            }

            let executable: String
            let args: [String]
            var env: [String: String] = ["LINKC_SESSION": session.id]
            if agent == .grok {
                env.merge(try grokEnvironment()) { _, grok in grok }
            }
            if agent == .opencode {
                env.merge(try openCodeEnvironment(model: model)) { _, openCode in openCode }
            }
            if agent == .kilo {
                env.merge(try kiloEnvironment(model: model)) { _, kilo in kilo }
            }

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
            if opensFresh {
                if agent == .opencode { tellOpenCodeStartedFresh(title: title, folder: cwd) }
                if agent == .kilo { tellKiloStartedFresh(title: title, folder: cwd) }
            }
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
            // A starting session is sampled every second: don't let it wait out a slow sleep.
            sweepTicker?.wake()
            return session
        } catch {
            cleanup(sessionId: session.id, end: .launchFailed) // fail loud: no ghost session or orphaned settings file
            throw error
        }
    }

    /// The model a launch pins, and the tier it came from. A tier with no model leaves a session
    /// unpinned — except Grok and OpenCode, which always name their model: on a fresh `~/.cursor-grok`,
    /// Cursor's own default is Auto, not Grok. With no tier, Grok runs on its default tier's model but
    /// records no tier, so a Grok session the user opened is, like any other, never handed a
    /// delegated task (`Session.canCarry`). A tier with no model refuses the launch rather than
    /// run on whatever Cursor would pick. A session the user opens on agy also names its default
    /// tier's model, but opens without one when that tier has none.
    private func launchModel(for agent: AgentKind, tier: ModelTier?, mode: LaunchMode) throws -> (model: String?, tier: ModelTier?) {
        guard AgentKind.alwaysNamesModel.contains(agent) else {
            if agent == .agy, tier == nil, mode != .resume {
                // The user's own agy session opens on the default tier's model, so a limit it hits
                // is recorded for that model's pool (`ModelPool`), not for all of agy. With no model
                // for the tier it opens as it always did. It records no tier, like Grok's, so it is
                // never handed a delegated task. Resume passes no model: `--conversation` is the
                // last flag agy is given, and its conversation keeps the model it had.
                let settings = modelSettings()
                return (settings.model(for: .agy, tier: settings.defaultTier(for: .agy)), nil)
            }
            let model = tier.flatMap { resolvedModel(for: agent, tier: $0) }
            return (model, model == nil ? nil : tier)
        }
        let settings = modelSettings()
        let launchTier = tier ?? settings.defaultTier(for: agent)
        guard let model = settings.model(for: agent, tier: launchTier) else {
            throw LinkCError.process("no model configured for \(agent.rawValue) tier \(launchTier.rawValue) — set it in linkC settings")
        }
        return (model, tier)
    }

    /// What a Grok terminal adds to `LINKC_SESSION`: its own Cursor folder, made here if missing,
    /// and the mark linkC's tool server reads to tell it from Cursor. Fails loud — without its
    /// folder, Grok's `--model` would become the default of the user's own Cursor.
    private func grokEnvironment() throws -> [String: String] {
        guard let userHome else {
            throw LinkCError.process("Grok needs a home folder for its own Cursor settings, and linkC has none")
        }
        let folder = AgentDescriptor.grokConfigDirectory(home: userHome)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw LinkCError.process("could not create \(folder.path) for Grok's Cursor settings — \(error.localizedDescription)")
        }
        return AgentDescriptor.environment(for: .grok, home: userHome)
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
        // stays and the user can restore it individually later. OpenCode and Kilo never resume —
        // they open a new conversation — so they collide with nothing.
        let resumesById = targetAgent == .claude && !(r.claudeSessionId ?? "").isEmpty
        let folder = ProjectPath.canonical(r.cwd)
        if targetAgent != .opencode && targetAgent != .kilo, store.sessions.contains(where: { live in
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
    /// Board or screen that would otherwise stay on top of the newly-selected session, or showing
    /// the split that holds it. It runs even when `id` selected nothing (an ended session), so the
    /// UI compares `id` with the selection before acting on it.
    public var onSessionFocused: ((String) -> Void)?

    public func focusSession(_ id: String) {
        terminals.select(id)
        onSessionFocused?(id)
        acknowledgeSession(id)
    }

    /// Opens a session the way clicking its tab does, minus the selection: a torn-off window shows it
    /// while the panel keeps what it had open.
    public func acknowledgeSession(_ id: String) {
        NSApp?.activate(ignoringOtherApps: true)
        if let s = store.session(id: id), s.agentKind != .claude, s.state.bucket == .needsYou {
            store.updateState(id: id, to: .ready)
        }
    }

    /// Makes a worker the user's, in memory and in the manifest, so it is never closed for them. A
    /// no-op for any session that is not a worker.
    private func adoptWorker(_ id: String) {
        store.adopt(id: id)
        manifest.markAdopted(linkcId: id)
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

            // One read of the screen serves every check below.
            let screen = term.screenSnapshot()

            // The watchdog's progress signal. An unchanged screen has an unchanged signature.
            let previous = screenSignatures[session.id]
            if previous?.fingerprint != screen.fingerprint {
                let signature = screen.progressSignature()
                let since = previous?.signature == signature ? previous?.since : nil
                screenSignatures[session.id] = (screen.fingerprint, signature, since ?? now())
            }

            // Inspect terminal output for provider rate limits & auto-reroute
            checkLimitsAndReroute(for: session.id, screen: screen)

            // `.error` here means checkLimitsAndReroute found no capable peer (or none at all)
            // for this agent's last limit — not that the session itself is broken. Its own
            // recorded cooldown is the authority on whether that is still true; once the
            // cooldown has ended, recover on its own rather than waiting for a person to click
            // the tab or its torn-off window (`acknowledgeSession` is the only other place that
            // clears `.error`). This runs
            // for every agent kind, including Claude, whose own state otherwise comes from hook
            // events that never touch this mark.
            if let current = store.session(id: session.id), current.state == .error {
                let norm = session.cwd
                do {
                    if try InboxStore(workspaceRoot: norm)
                        .isAgentLimited(agent: session.agentKind, model: current.model, timeout: Self.relayLockTimeout) == nil {
                        store.updateState(id: session.id, to: .ready)
                    }
                } catch {
                    NSLog("[linkC relay] sampleAgentStates: %@ cooldown check — %@", session.agentKind.displayName, String(describing: error))
                }
            }
            resumeModelTaskAfterLimit(of: session.id)

            // Detect dynamic agent kind changes in child process tree. Only for sessions that
            // could change: a hook-driven launch's kind is known, and walking its tree tells
            // nothing. Decided by the launch, not the current kind: an agent that runs a `claude`
            // child reads as Claude until the child exits, and this walk is what turns it back.
            if !term.isHookDriven {
                let liveAgent = term.sampleForegroundAgent()
                if liveAgent != session.agentKind && liveAgent != .shell {
                    store.updateAgentKind(id: session.id, to: liveAgent)
                }
            }

            // Claude has its own hook server providing exact event transitions.
            guard session.agentKind != .claude else { continue }

            guard let currentSession = store.session(id: session.id), currentSession.state != .error else { continue }

            // A folder-trust dialog has no spinner, so it read as an idle session and the relay
            // typed briefs into it. Hold the session as needing the user until it is answered.
            if screen.showsTrustPrompt() {
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

            let liveActivity = screen.liveActivity(agent: currentSession.agentKind)
            let isWorking = liveActivity != nil && !liveActivity!.isEmpty

            if isWorking {
                if currentSession.state.bucket != .active {
                    store.updateState(id: session.id, to: .working)
                }
            } else {
                // A booting TUI is also silent. Promote only once the agent CLI is actually
                // running, or the relay types the next frame into a process that cannot read it.
                if currentSession.state == .starting, term.agentProcessIsRunning() {
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
                          session.agentKind.displayName, screen.recentRows(12).joined(separator: "\n"))
                }
            }
        }

        for path in activePaths {
            processPendingMessages(workspacePath: path)
        }
    }

    public func stopSession(_ id: String) {
        terminals.terminate(id)
        cleanup(sessionId: id, end: .stopped)
    }

    public var hookPort: UInt16 { hookServer.port }

    // MARK: - Swarm & Collision Tracking

    /// Computes active multi-agent project swarms and inspects file collisions. Each candidate
    /// workspace's blackboard is a flock-guarded file read, so the read runs off the main actor;
    /// `swarms` is only reassigned when the result actually changed, since this is called on every
    /// tick while the panel is visible, whether or not anything moved.
    public func sampleSwarms(additionalAgents: [String: [AgentKind]] = [:]) async {
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

        let candidates = agentsByPath.filter { $0.value.count >= 2 }
        let newSwarms = await Task.detached(priority: .utility) {
            Self.computeSwarms(candidates)
        }.value

        if newSwarms != swarms {
            swarms = newSwarms
        }
    }

    /// The off-main-actor half of `sampleSwarms`: reads each candidate workspace's blackboard and
    /// turns claimed-file overlaps into `CollisionWarning`s. `nonisolated` and static so it can run
    /// inside `Task.detached` without hopping back to the main actor for every file read; the
    /// result is sorted by workspace path (and each swarm's agents by raw value) so two samples of
    /// unchanged state compare equal regardless of dictionary/set iteration order.
    private nonisolated static func computeSwarms(_ candidates: [String: Set<AgentKind>]) -> [ProjectSwarm] {
        var newSwarms: [ProjectSwarm] = []
        for (path, agents) in candidates {
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
                    activeAgents: agents.sorted { $0.rawValue < $1.rawValue },
                    collisions: allCollisions
                )
            )
        }
        return newSwarms.sorted { $0.workspacePath < $1.workspacePath }
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
    /// With `sessionId`, that session is switched: it must be a live session of `agent` in the workspace.
    @discardableResult
    public func switchModel(in workspacePath: String, agent: AgentKind, to modelName: String, sessionId: String? = nil) throws -> String {
        guard agent != .shell else {
            throw LinkCError.process("Cannot switch model on shell session.")
        }
        let lists: [AgentKind: AgentModelList]
        do {
            lists = try modelLists()
        } catch {
            throw LinkCError.process("could not read the live model lists — \(error)")
        }
        let choosable = ModelListCache.choosable(for: agent, lists: lists, settings: modelSettings())
        // The CLI is told the listed spelling, whatever case the model was typed in.
        guard let listed = choosable.first(where: { $0.id.caseInsensitiveCompare(modelName) == .orderedSame }) else {
            let allowed = choosable.map(\.id).joined(separator: ", ")
            throw LinkCError.process("'\(modelName)' is not among the models \(agent.displayName) lists. Available: \(allowed)")
        }
        let modelName = listed.id
        let norm = ProjectPath.canonical(workspacePath)
        guard let session = store.sessions.first(where: {
            $0.cwd == norm && $0.agentKind == agent && $0.state != .ended && (sessionId == nil || $0.id == sessionId)
        }) else {
            if let sessionId {
                throw LinkCError.process("Session \(sessionId) is not a live \(agent.displayName) session in \(workspacePath).")
            }
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
            port: hookServer.port, token: hookToken, statusLineFile: statusLines.fileURL(sessionId: session.id))
        claudeStatusLineIsUsers = try SettingsComposer.definesStatusLine(
            user: user, project: project, projectLocal: projectLocal)
        // The status file must exist and be watched before Claude starts; with the user's own status
        // line there is nothing of linkC's to write it.
        if !claudeStatusLineIsUsers {
            try statusLines.watch(sessionId: session.id)
        }
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
