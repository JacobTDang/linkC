import SwiftUI
import AppKit
import WebKit
import LinkCKit

@main
struct LinkCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The status item and panel are built by the AppDelegate/StatusPanelController, not by
    // SwiftUI. This scene exists only to satisfy `App`; an accessory app never shows it. While a
    // torn-off window makes linkC a regular app, its App menu would offer "Settings…" (⌘,) and open
    // this empty scene: the command group removes the item and its shortcut.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panelController: StatusPanelController?
    private var tornOffWindows: TornOffWindows?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        panelController = StatusPanelController(model: model)
        hotKey = GlobalHotKey { [weak self] in self?.panelController?.togglePanel() }
        applyHotKeyPreference()
        observeHotKeyPreference()
        Task {
            await model.start()
            // A failed start-up leaves nothing live, and the panel shows why: no windows to open.
            guard model.setupError == nil else { return }
            // Start-up has restored the terminals and pruned the windows whose terminal or split did
            // not come back, so only live ones open.
            tornOffWindows = TornOffWindows(model: model)
        }
    }

    /// Re-registers the global shortcut whenever the preference changes — the same
    /// `withObservationTracking` re-arm loop StatusPanelController uses.
    private func observeHotKeyPreference() {
        withObservationTracking {
            _ = model.preferences.hotKeyPreset
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyHotKeyPreference()
                self.observeHotKeyPreference()
            }
        }
    }

    private func applyHotKeyPreference() {
        guard let hotKey else { return }
        let preset = model.preferences.hotKeyPreset
        guard let keyCode = preset.keyCode, let modifiers = preset.carbonModifiers else {
            hotKey.unregister()
            return
        }
        do {
            try hotKey.register(keyCode: keyCode, modifiers: modifiers)
        } catch {
            model.surface(error: "Global shortcut unavailable: \(error.localizedDescription)")
        }
    }

    /// Closing the last torn-off window must not quit the menu-bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = terminateReply()
        // Quitting is not the user closing the windows: they stay saved and reopen on the next launch.
        if reply == .terminateNow { tornOffWindows?.prepareForQuit() }
        return reply
    }

    /// Guard against losing running sessions: quitting linkC ends the claude processes it hosts.
    private func terminateReply() -> NSApplication.TerminateReply {
        // Tapping "Install & restart" already consented to exactly this quit — the swap
        // helper is waiting on our exit, so the warning would only stall it.
        if model.updateInProgress { return .terminateNow }
        // Running dev terminals count too — quitting kills them, and they come back as
        // relaunchable rows (a fresh shell, no scrollback), which the copy says plainly.
        // Exited terminals have nothing to kill.
        guard let warning = QuitWarningBuilder.build(
            sessionCount: model.sessions.count,
            runningTerminalCount: model.shellRows.count { $0.state == .running }
        ) else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.flushStateToDisk()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

/// Observable app state backing the panel. Holds the coordinator once preflight succeeds, or
/// a setup error to show the user. Owns the terminal manager so the coordinator's watch probe
/// and the panel's terminal view share one source of truth.
@MainActor
@Observable
final class AppModel {
    private(set) var coordinator: AppCoordinator?
    private(set) var setupError: String?
    /// The error strip's message: shown for a few seconds, then cleared, so a one-off failure is
    /// loud without lingering. Empty messages never show.
    let errorFlash = FlashMessage()
    /// Surfaced when a one-off action (e.g. launching a session) fails — shown inline without
    /// tearing down the whole panel. Failing loud, not silent. Setting it shows a new flash;
    /// setting nil clears the strip at once.
    private(set) var lastError: String? {
        get { errorFlash.text }
        set { errorFlash.show(newValue) }
    }
    /// An update notice waiting for the panel to open (see `start()`).
    private var pendingUpdateNotice: String?
    /// Whether the menu-bar panel itself is currently on screen — not a torn-off window. Feeds
    /// `onScreenSessionId` and the coordinator's watch probe, and gates the usage-refresh timer — no
    /// panel, no polling. The coordinator's sweep follows the panel or any window: `syncSweepVisibility()`.
    var panelVisible = false {
        willSet {
            // Hiding the panel takes the open terminal off screen: record it as seen first.
            if !newValue { markOnScreenSeen() }
        }
        didSet {
            syncSweepVisibility()
            updateUsageTimer()
            if !panelVisible {
                flushStateToDisk()
            } else if !oldValue {
                if let notice = pendingUpdateNotice {
                    pendingUpdateNotice = nil
                    lastError = notice
                }
                // Not a sweep tick behind: sample what changed while the panel was hidden.
                sampleSidebar()
            }
        }
    }

    /// Flush all session, shell, and selection state to disk in real-time.
    public func flushStateToDisk() {
        for board in boards.values { board.saveNow() }
        shells?.prepareForShutdown()
        coordinator?.prepareForShutdown(selectedId: selectedId)
        if let selectedId {
            UserDefaults.standard.set(selectedId, forKey: "LinkCLastSelectedSessionId")
        }
        UserDefaults.standard.set(boardProject, forKey: "LinkCLastBoardProject")
    }

    /// Live usage state: per-session context/tokens/cost, plus the global plan window.
    let usage = UsageTracker()
    /// linkC's own settings (hotkey preset, panel toggles) — UserDefaults-backed.
    let preferences = AppPreferences()
    /// When each session was last on screen — decides whether a finished turn still reads coral.
    let attention = SessionAttention()
    /// The sidebar's remembered project order, expansion, and open sections.
    let sidebarState = SidebarState()
    /// Codex's own rate-limit snapshot, re-read off the main thread. nil until the first read lands.
    private(set) var codexUsage: AgentUsage?
    /// The sidebar's non-observable inputs, published by `sampleSidebar()` only when they change.
    let sidebarSignal = SidebarSignalFeed()

    /// Surface a one-off failure in the panel's error bar (fail loud, stay standing).
    func surface(error message: String) { lastError = message }
    /// Refreshes usage while the panel is visible; hook events cover the rest of the time.
    @ObservationIgnored private var usageTimer: Timer?
    @ObservationIgnored private var usageTicks = 0
    /// Health checks run on their OWN timer, deliberately independent of `panelVisible`:
    /// an outage that starts and ends while the panel is closed would otherwise never
    /// notify, making the alert only ever restate a row the user is already looking at.
    /// The cost is a few HTTP HEADs a minute — nothing like a polling loop.
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var cachedInboxes: [String: Inbox] = [:]
    @ObservationIgnored private var lastInboxFetch: [String: Date] = [:]

    public var globalDashboardData: GlobalDashboardData?
    public var projectDashboardData: [String: ProjectDashboardData] = [:]

    public func refreshDashboard(workspacePath: String? = nil) async {
        guard let coordinator = self.coordinator else { return }
        let global = await coordinator.fetchGlobalDashboardAsync()
        self.globalDashboardData = global
        if let ws = workspacePath {
            let norm = ProjectPath.canonical(ws)
            let project = await coordinator.fetchProjectDashboardAsync(workspacePath: norm)
            self.projectDashboardData[norm] = project
        }
    }

    var sessions: [Session] { coordinator?.store.sessions ?? [] }
    /// Previous sessions no longer live — shown as dimmed restorable rows in the sidebar's
    /// Earlier section.
    var restorables: [RestorableSession] { coordinator?.restorableStore.restorables ?? [] }
    var selectedId: String? { coordinator?.terminals.selectedId }

    var selectedTerminal: TerminalSession? {
        guard let id = selectedId else { return nil }
        return coordinator?.terminals.session(id: id)
    }

    func start() async {
        do {
            let preflight = try Preflight.resolve()
            let terminals = TerminalSessionManager()
            // Whatever moves the selection — a click, a restore, a notification, a terminal
            // exiting — the session leaving the screen is marked seen first.
            terminals.onSelectionWillChange = { [weak self] in self?.markOnScreenSeen() }
            let prefs = preferences
            let coordinator = AppCoordinator(
                claudePath: preflight.claudePath,
                terminals: terminals,
                modelSettings: { prefs.agentModels },
                isWatching: { [weak self] id in
                    guard let self, NSApp.isActive else { return false }
                    // The panel watches what it shows: a terminal that lives in a window is watched only
                    // while that window is the key one.
                    let inPanel = self.panelVisible && terminals.selectedId == id && self.host(of: id) == nil
                    return inPanel || self.keyWindowSessionId == id
                }
            )
            // A notification click reaches `focusSession` directly — never through `focus(_:)`
            // below — so this is the one place both paths funnel through: whichever one focused
            // a session, drop whatever was covering it.
            coordinator.onSessionFocused = { [weak self] id in
                self?.showSelection(opening: id)
            }
            try coordinator.start()
            coordinator.usageTracker = usage
            coordinator.panelSweep = { [weak self] in
                await self?.sampleShells()
                self?.sampleSidebar()
            }
            self.coordinator = coordinator
            self.mcpServers = MCPServerService(claudePath: preflight.claudePath)
            self.skills = SkillsService(claudePath: preflight.claudePath)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let linkCSupport = support.appendingPathComponent("linkC", isDirectory: true)
            self.shells = ShellCoordinator(terminals: terminals, manifestDir: linkCSupport)
            // A crash or force quit of a previous launch can leave app groups running with
            // nothing left to stop them — catch those before anything else starts.
            appGroupLedger.stopLeftovers()
            self.shells?.restoreActiveShells()
            // Restore has run: a window whose terminal or split did not come back must not open.
            pruneTornOff()
            // Windows restored and kept, or a panel open already, keep the sweep running.
            syncSweepVisibility()
            // A filing is dropped only when its terminal is truly dismissed — keep it for a live
            // terminal, and for one still offered back in Earlier, so a terminal that had exited by
            // quit time, or whose folder was missing and so was skipped above, doesn't lose it.
            let keptTerminals = Set(shellRows.map(\.id)).union(restorableShells.map(\.id))
            sidebarState.pruneTerminals(keeping: keptTerminals)
            // Forget remembered folders with no live session, no Earlier entry, and no filing.
            let standardized: (String) -> String = { ProjectPath.canonical($0) }
            var inUse = Set(sessions.map { standardized($0.cwd) })
            inUse.formUnion(restorables.map { standardized($0.cwd) })
            inUse = SidebarState.inUseProjects(sessionPaths: inUse, filed: sidebarState.terminalProjects)
            sidebarState.prune(keeping: inUse)
            if let lastId = UserDefaults.standard.string(forKey: "LinkCLastSelectedSessionId"),
               terminals.sessions.contains(where: { $0.id == lastId }) {
                terminals.select(lastId)
            }
            if let path = UserDefaults.standard.string(forKey: "LinkCLastBoardProject"),
               FileManager.default.fileExists(atPath: path) {
                showBoard(path)
            }
            if coordinator.terminals.selectedId != nil {
                self.activeScreen = nil
            }
            self.toolServers = ToolServerService()
            self.recents = RecentFoldersStore(directory: linkCSupport)
            self.oracle = OracleService()
            self.supabase = SupabaseService()
            self.watchedEndpointsStore = WatchedEndpointsStore(directory: linkCSupport)
            reloadConfiguredEndpoints()
            startHealthTimer()
            // The swap that installed this build ran with no app to tell: what it left for the
            // user (a failed install, or grants about to be lost) is posted now, and shown again
            // in the error bar the next time the panel opens — the panel is hidden at launch.
            if let notice = UpdateSwap.takeNotice() {
                coordinator.notify(id: "update", title: "linkC update", body: notice)
                if panelVisible { lastError = notice } else { pendingUpdateNotice = notice }
            }
        } catch {
            setupError = error.localizedDescription
        }
    }

    /// MCP config + live health for the MCP Servers screen. Built in `start()` (needs the
    /// resolved claude path); does no I/O until the screen asks.
    private(set) var mcpServers: MCPServerService?
    /// The unified skills catalog + plugin toggles for the Skills screen. Same lifecycle.
    private(set) var skills: SkillsService?
    /// Dev terminals — plain login shells sharing the sessions' terminal manager, so both
    /// kinds live under the panel's single selection cursor.
    private(set) var shells: ShellCoordinator?
    /// The services his tools depend on — compose projects + standalone containers.
    private(set) var toolServers: ToolServerService?
    /// Folders sessions/terminals were launched in — backs the empty state's one-tap chips.
    private(set) var recents: RecentFoldersStore?
    /// Oracle compute through the user's own `oci` CLI — a permanent quiet no-op when
    /// the CLI or its config is absent.
    private(set) var oracle: OracleService?
    /// Supabase projects through the user's own CLI — the second CLOUD provider.
    private(set) var supabase: SupabaseService?
    /// Liveness of the services worth watching — a VM being RUNNING says nothing about
    /// whether the thing on it is answering.
    let health = HealthMonitor()
    private var watchedEndpointsStore: WatchedEndpointsStore?

    var cloudInstances: [OracleInstance] { oracle?.instances ?? [] }
    var cloudRegion: String? { oracle?.region }
    var supabaseProjects: [SupabaseProject] { supabase?.projects ?? [] }

    /// Everything being health-checked: each live Supabase project (URL derived from its
    /// ref — no configuration) plus whatever the user listed in endpoints.json. A paused
    /// project is skipped; the row already explains that state.
    ///
    /// The rule lives in WatchList (and is tested there): a Supabase listing too old to
    /// trust stops driving probes, but never takes the user's own endpoints with it.
    var watchedEndpoints: [WatchedEndpoint] {
        // configuredEndpoints is the cache, not another disk read —
        // reloadConfiguredEndpoints() is what refreshes it, once per health beat.
        WatchList.endpoints(
            supabaseProjects: supabaseProjects,
            lastListedAt: supabase?.lastListedAt,
            configured: configuredEndpoints
        )
    }

    func serviceHealth(_ endpointId: String) -> HealthStatus? { health.status(of: endpointId) }
    func supabaseHealth(_ project: SupabaseProject) -> HealthStatus? {
        health.status(of: WatchList.supabaseEndpointId(project))
    }
    /// Endpoints from endpoints.json that aren't tied to a provider row — the mp3 server
    /// and anything else the user named. Cached: this is read by the sidebar's body, and
    /// re-parsing the file on every re-render (expand, hover, each 5s tick) would put a
    /// synchronous disk read on the main thread. Refreshed on the health beat.
    private(set) var configuredEndpoints: [WatchedEndpoint] = []

    private func reloadConfiguredEndpoints() {
        let next = watchedEndpointsStore?.load() ?? []
        if next != configuredEndpoints { configuredEndpoints = next }
    }
    var endpointsConfigPath: String? { watchedEndpointsStore?.path }
    /// Create the file on demand so "reveal" in Settings always lands somewhere real.
    func revealEndpointsConfig() -> String? {
        guard let store = watchedEndpointsStore else { return nil }
        do {
            let path = try store.ensureExists()
            reloadConfiguredEndpoints()
            lastError = nil
            return path
        } catch {
            // Fail loud rather than send Finder to a path that was never written.
            lastError = "Couldn't create endpoints.json: \(error.localizedDescription)"
            return nil
        }
    }

    /// The background health beat. Runs for the app's lifetime, not the panel's.
    private func startHealthTimer() {
        guard healthTimer == nil else { return }
        checkHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkHealth() }
        }
    }

    /// Probe the watched services and announce anything that CHANGED.
    private func checkHealth() {
        reloadConfiguredEndpoints()
        // The Supabase half of the watch list comes from the project listing, which the
        // panel-gated refresh populates — with the panel closed the background beat would
        // otherwise check nothing at all, which is exactly the outage window this timer
        // exists to cover. refreshIfStale keeps it current on its own cadence.
        if let supabase { Task { await supabase.refreshIfStale() } }
        let endpoints = watchedEndpoints
        // Emptying the watch list must clear stale readings rather than freeze them for
        // the life of the process.
        guard !endpoints.isEmpty else {
            health.prune(to: [])
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // check() prunes internally, against the list it actually probed.
            let changes = await self.health.check(endpoints)
            for change in changes {
                self.coordinator?.notify(
                    id: "health:\(change.endpointId)", title: change.title, body: change.body
                )
            }
        }
    }
    /// The CLI is installed but not authenticated — an invitation, not a failure.
    var supabaseNeedsLogin: Bool { supabase?.needsLogin ?? false }
    /// Real cloud failures worth showing. Both providers can fail at once, so neither
    /// hides behind the other.
    var cloudErrors: [String] {
        [oracle?.lastError, supabase?.lastError].compactMap { $0 }
    }

    /// A cloud instance's drill-in (IP, CPU), once its row has been expanded.
    func cloudDetail(_ id: String) -> OracleDetail? { oracle?.detail(for: id) }

    /// Fetch a drill-in on expand — never on the poll path. `force` is the row's own
    /// refresh action; a plain expand reuses the cached figures.
    func loadCloudDetail(_ id: String, force: Bool = false) {
        guard let oracle else { return }
        Task { await oracle.loadDetail(for: id, force: force) }
    }

    /// Cloud calls are slow and rate-limited — refresh on panel open + every ~120s,
    /// never the local 15s loop.
    private func refreshCloud() {
        if let oracle, oracle.ociPath != nil {
            Task { await oracle.refresh() }
        }
        if let supabase, supabase.cliPath != nil {
            Task { await supabase.refresh() }
        }
    }

    /// Guards `refreshCodexUsage` against overlapping reads — the panel-open trigger and the
    /// 5-minute timer tick can otherwise land close enough together that a slow read (a large
    /// `.codex/sessions`) is still in flight when the next one starts.
    private var codexUsageRefreshInFlight = false

    /// Re-read Codex's own rate-limit snapshot. File IO only, and off the main actor: the reader
    /// reads the tail of the few newest rollouts, and the result lands back here.
    private func refreshCodexUsage() {
        guard !codexUsageRefreshInFlight else { return }
        codexUsageRefreshInFlight = true
        let reader = CodexUsageReader(
            sessionsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions"))
        Task.detached(priority: .utility) { [weak self] in
            let usage = reader.read()
            await MainActor.run {
                self?.codexUsage = usage
                self?.codexUsageRefreshInFlight = false
            }
        }
    }

    /// The empty state shows up to three recent launch folders as chips.
    var recentFolders: [String] { Array((recents?.paths ?? []).prefix(3)) }

    /// The chips' launch path: a new session in a known folder, no picker in the way.
    func startSession(in cwd: String, agent: AgentKind = .claude) {
        guard let coordinator else { return }
        do {
            lastError = nil
            try coordinator.newSession(cwd: cwd, agent: agent, mode: .new)
            showSelection()  // the new session is selected — show it
            recents?.record(cwd)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Spawns a teammate agent session in `cwd`, synthesizing and writing a handoff memo.
    func spawnTeammate(in cwd: String, agent: AgentKind) {
        guard let coordinator else { return }
        Task { @MainActor in
            do {
                lastError = nil
                try coordinator.spawnTeammate(in: cwd, agent: agent)
                recents?.record(cwd)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// "View logs" rides on dev terminals: a shell running `docker logs -f`, which becomes
    /// a normal exited row when the follow ends.
    func openContainerLogs(_ container: ContainerInfo) {
        openContainerCommand(
            "logs --tail 200 -f", container: container,
            title: "logs: \(container.composeService ?? container.name)"
        )
    }

    /// A shell INSIDE the container — sh, which every image has; bash is one keystroke away
    /// when the image ships it.
    func openContainerExec(_ container: ContainerInfo) {
        openContainerCommand(
            "exec -it", container: container, suffix: "/bin/sh",
            title: "exec: \(container.composeService ?? container.name)"
        )
    }

    private func openContainerCommand(
        _ subcommand: String, container: ContainerInfo, suffix: String = "", title: String
    ) {
        guard let shells, let dockerPath = toolServers?.dockerPath else { return }
        do {
            lastError = nil
            try shells.launch(
                cwd: NSHomeDirectory(),
                command: "\(dockerPath) \(subcommand) \(container.name) \(suffix)"
                    .trimmingCharacters(in: .whitespaces),
                title: title
            )
            showSelection()  // the new terminal is selected — show it
        } catch {
            lastError = error.localizedDescription
        }
    }

    var shellRows: [ShellRow] { shells?.store.rows ?? [] }

    var swarms: [ProjectSwarm] { coordinator?.swarms ?? [] }

    func swarm(for cwd: String) -> ProjectSwarm? {
        let norm = ProjectPath.canonical(cwd)
        return swarms.first { $0.workspacePath == norm }
    }

    /// How long a read of a workspace's inbox is reused.
    private static let inboxCacheWindow: TimeInterval = 1.0

    /// Loads the inbox for a workspace root with a 1-second in-memory throttle
    /// to avoid redundant synchronous disk reads during SwiftUI view body evaluations.
    func inbox(for workspacePath: String) -> Inbox? {
        let norm = ProjectPath.canonical(workspacePath)
        let now = Date()
        if let last = lastInboxFetch[norm], now.timeIntervalSince(last) < Self.inboxCacheWindow {
            return cachedInboxes[norm]
        }
        let loaded = readInboxFromDisk(norm: norm)
        cachedInboxes[norm] = loaded
        lastInboxFetch[norm] = now
        return loaded
    }

    private func readInboxFromDisk(norm: String) -> Inbox? {
        let inboxURL = URL(fileURLWithPath: (norm as NSString).appendingPathComponent(".linkc/inbox.json"))
        guard FileManager.default.fileExists(atPath: inboxURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: inboxURL)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try dec.decode(Inbox.self, from: data)
        } catch {
            NSLog("[linkC] inbox for %@ could not be read — %@", norm, String(describing: error))
            return nil
        }
    }

    /// Loads the inbox of every active workspace ahead of the views, through the same throttle
    /// `inbox(for:)` applies: one whose read is still fresh is not read again.
    func refreshCachedInboxes() {
        var paths = Set<String>()
        for s in sessions {
            paths.insert(s.cwd)
        }
        for r in shellRows {
            paths.insert(ProjectPath.canonical(r.cwd))
        }
        for norm in paths {
            _ = inbox(for: norm)
        }
    }

    func sampleShells() async {
        shells?.sampleDirectories()
        shells?.sampleAgents()
        var shellAgents: [String: [AgentKind]] = [:]
        let projects = knownProjectPaths
        for row in shellRows {
            if let agent = row.detectedAgent {
                // The same resolution `currentProject` uses: a filed terminal counts toward the
                // project it is filed under, wherever its shell has `cd`'d to.
                let key = TerminalFiling.project(
                    forTerminal: row.id, cwd: row.cwd, filed: sidebarState.terminalProjects, projects: projects
                ) ?? ProjectTabs.standardized(row.cwd)
                shellAgents[key, default: []].append(agent)
            }
        }
        await coordinator?.sampleSwarms(additionalAgents: shellAgents)
        refreshCachedInboxes()
    }

    /// Dev terminals remembered from a previous run — relaunchable, never auto-started.
    var restorableShells: [RestorableShell] { shells?.restorables ?? [] }

    func restoreShell(_ shell: RestorableShell) {
        guard let shells else { return }
        do {
            lastError = nil
            let newRow = try shells.restore(shell)
            if let filedProject = sidebarState.terminalProjects[shell.id] {
                sidebarState.unfile(terminal: shell.id)
                sidebarState.file(terminal: newRow.id, under: filedProject)
            }
            recents?.record(shell.cwd)
            showSelection()  // the new terminal is selected — show it
        } catch {
            lastError = error.localizedDescription
        }
    }

    func forgetShell(_ shell: RestorableShell) { shells?.forget(shell) }

    /// The sidebar's SERVERS section: compose projects with at least one live container,
    /// then standalone running containers. Empty (and the section hidden) without docker.
    var runningProjects: [ToolServerProject] {
        toolServers?.projects.filter { $0.runningCount > 0 } ?? []
    }
    var runningStandalone: [ContainerInfo] {
        toolServers?.standalone.filter { $0.state == .running } ?? []
    }

    /// What linkC can see running for a project, reduced to what the system map is compared
    /// against: the containers of a compose project rooted at this folder, and the services of a
    /// stack linkC already knows for it. Nothing here runs a process — it reads what the tool
    /// server service last found.
    func discoveredThings(in workspacePath: String) -> [DiscoveredThing] {
        let folder = ProjectPath.canonical(workspacePath)
        var things: [DiscoveredThing] = []
        var seen: Set<String> = []

        for project in toolServers?.projects ?? [] {
            guard let dir = project.workingDir,
                  ProjectPath.canonical(dir) == folder else { continue }
            for container in project.containers where container.state == .running {
                let name = container.composeService ?? container.name
                guard seen.insert(name.lowercased()).inserted else { continue }
                things.append(DiscoveredThing(
                    name: name, image: container.image,
                    detail: "container \(container.name) · \(container.image)"))
            }
        }

        for stack in toolServers?.knownStacks.stacks ?? []
        where ProjectPath.canonical(stack.workingDir) == folder {
            for service in stack.services {
                guard seen.insert(service.lowercased()).inserted else { continue }
                things.append(DiscoveredThing(
                    name: service, image: nil, detail: "compose service in \(stack.name)"))
            }
        }
        return things
    }

    /// One board model per board for the life of the app, so undo and unwritten edits survive
    /// switching tabs and projects.
    @ObservationIgnored private var boards: [BoardAddress: BoardModel] = [:]

    /// The model for `address`, made on first use. A detail board's ghosts are synced by its
    /// pane each time it appears, not here, since SwiftUI can call this for a view many times.
    func board(for address: BoardAddress) -> BoardModel {
        if let board = boards[address] { return board }
        let board = BoardModel(store: BoardMapStore(workspacePath: address.projectPath, board: address.slug))
        boards[address] = board
        return board
    }

    /// The project whose Board is showing, or nil when a terminal — or nothing — is.
    private(set) var boardProject: String?

    /// The project whose Split tab is showing, or nil. Written only by `showSplit`, `showSelection`,
    /// `showBoard`, `showApp`, `select(_:)`, `removeFromSplit`, `dissolveSplit`, `repairSplitSelection`
    /// and `goBack` — never by a view.
    private(set) var splitProject: String?
    /// The terminal whose own tab chip is being opened: it shows full-size, not in its split. Set
    /// only for the length of `select(_:)`'s focus.
    @ObservationIgnored private var fullSizeRequest: String?

    /// The torn-off window that is key, or nil when none is. Written only by `setKeyWindowItem(_:)`; see
    /// `keyWindowSessionId`.
    private(set) var keyWindowItem: TornOffItem?

    /// The window controller reports the key torn-off window from became-key, and nil from resign-key. The
    /// window that stops being key was on screen until now, so its terminal is marked seen first —
    /// straight away, not through `markOnScreenSeen()`'s `NSApp.isActive` gate: resign-key can arrive after
    /// the app has already deactivated.
    func setKeyWindowItem(_ item: TornOffItem?) {
        guard item != keyWindowItem else { return }
        markSeen(keyWindowSessionId, at: Date())
        keyWindowItem = item
    }

    /// Brings a torn-off window forward. Set by the window controller.
    @ObservationIgnored var onRaiseWindow: ((TornOffItem) -> Void)?
    /// The menu-bar panel's frame in screen points, where a window opens beside it. Set by the panel's
    /// controller; nil when there is no panel to be beside.
    @ObservationIgnored var panelFrame: () -> CGRect? = { nil }

    /// The apps each project can open: its own `.linkc/app.json`, then the ones registered in
    /// Settings. Reads the manifest fresh (on a short TTL) each time it's asked, so an edit to
    /// app.json takes effect without a restart.
    let appCatalog = LinkCAppCatalog()
    /// Where every app process group linkC starts is recorded, so a crash or force quit of linkC
    /// itself doesn't leave one running forever — `stopLeftovers()` (called at start-up) is what
    /// cleans up after a previous run that never got to stop them normally.
    let appGroupLedger = LinkCAppGroupLedger.applicationSupport
    /// The app tab showing, or nil. Written only by `showApp` and `clearAppTab` below, and by
    /// `showBoard`/`showSelection` — never by a view.
    private(set) var appTab: AppTabRef?
    /// Each open app tab's live process, keyed by the tab id — created and torn down by
    /// `AppModel+Apps.swift`.
    var appProcesses: [String: LinkCAppProcess] = [:]
    /// Cached `WKWebView`s for running apps, keyed by tab id. Never observed: written only by
    /// `AppWebView.makeNSView`/`updateNSView`, which are `@ObservationIgnored` for exactly that
    /// reason.
    @ObservationIgnored var appWebViews: [String: CachedAppWebView] = [:]

    /// The project the tab strip belongs to: the Board's, or the open session's or terminal's folder.
    var currentProject: String? {
        if let boardProject { return boardProject }
        if let splitProject { return splitProject }
        if let appTab { return appTab.project }
        guard let id = selectedId else { return nil }
        if let session = sessions.first(where: { $0.id == id }) { return session.cwd }
        if let shell = shellRows.first(where: { $0.id == id }) {
            return TerminalFiling.project(
                forTerminal: shell.id, cwd: shell.cwd, filed: sidebarState.terminalProjects, projects: knownProjectPaths
            ) ?? ProjectTabs.standardized(shell.cwd)
        }
        return nil
    }

    var projectTabs: [ProjectTab] {
        guard let project = currentProject else { return [] }
        let canonicalProject = ProjectTabs.standardized(project)
        var activities: [String: String] = [:]
        for session in sessions
        where session.cwd == canonicalProject
            && ShownActivity.applies(to: session.state) {
            activities[session.id] = currentActivity(session)
        }
        return ProjectTabs.tabs(
            project: canonicalProject, sessions: sessions, shells: shellRows, filed: sidebarState.terminalProjects, titles: sessionTitles,
            activities: activities, openApps: sidebarState.openApps(in: canonicalProject),
            split: sidebarState.split(for: canonicalProject))
    }

    /// Whether the current project has a session mid-turn — computed directly, without building
    /// every tab (and reading every tab's activity) just to test one Bool. Working only: a
    /// permission wait's line doesn't change without an observable state change, so it needs no
    /// timer either.
    var projectHasWorkingSession: Bool {
        guard let project = currentProject else { return false }
        let canonicalProject = ProjectTabs.standardized(project)
        return sessions.contains { $0.state == .working && $0.cwd == canonicalProject }
    }

    /// The tab showing: the project's Board or Split, an app tab, or the selected session or terminal.
    var selectedTabID: String? {
        if let boardProject { return ProjectTabs.boardID(boardProject) }
        if let splitProject { return ProjectTabs.splitID(canonical: splitProject) }
        if let appTab { return appTab.id }
        return selectedId
    }

    /// The current board of each project: project path -> slug. A missing entry means the overview.
    var currentBoard: [String: String] = [:]

    func currentAddress(for path: String) -> BoardAddress {
        let key = ProjectTabs.standardized(path)
        return BoardAddress(projectPath: key, slug: currentBoard[key])
    }

    func showBoard(_ address: BoardAddress) {
        let project = ProjectTabs.standardized(address.projectPath)
        if let slug = address.slug {
            currentBoard[project] = slug
        } else {
            currentBoard.removeValue(forKey: project)
        }
        showBoard(project)
    }

    func showBoard(_ path: String) {
        boardProject = ProjectTabs.standardized(path)
        splitProject = nil
        appTab = nil
        activeScreen = nil
    }

    /// Shows an app tab: picked from the strip's + menu, or a restored tab the user selected.
    /// Never starts it — starting only ever happens from a menu pick or a Start/Retry button.
    func showApp(_ ref: AppTabRef) {
        appTab = ref
        boardProject = nil
        splitProject = nil
        activeScreen = nil
    }

    /// `closeApp` (AppModel+Apps.swift) can't write `appTab` itself — its setter is private to
    /// this file — so it calls here to clear it when the tab it just closed was the one showing.
    func clearAppTab(matching id: String) {
        if appTab?.id == id { appTab = nil }
    }

    /// A session or terminal was just selected — show it. Clears everything that could cover it:
    /// an open screen, another project's Board, or an open app tab (else the new one opens
    /// hidden underneath it). `opened` is what the user opened (a sidebar row, a notification, a
    /// screen's Open): a live member of an active split shows in that split, focused, unless its own
    /// tab chip asked for it full-size (`fullSizeRequest`). See `ProjectSplit.showing`.
    private func showSelection(opening opened: String? = nil) {
        let splits = storedSplits()
        let showing = ProjectSplit.showing(
            selected: selectedId, opened: opened, current: splitProject,
            fullSize: selectedId != nil && fullSizeRequest == selectedId,
            splits: splits, liveIDs: { self.splittableIDs(in: $0) })
        if let showing, let id = selectedId, let split = splits[showing] {
            // The split's focus follows whatever was selected.
            if split.focusing(id) != split { markOnScreenSeen() }
            sidebarState.setSplit(split.focusing(id), for: showing)
        }
        if splitProject != showing { splitProject = showing }
        boardProject = nil
        appTab = nil
        activeScreen = nil
        // What was opened lives in a window: the panel shows its note, and the window comes forward.
        if let opened, opened == selectedId, let window = host(of: opened) {
            raise(window, focusing: opened)
        }
    }

    /// The terminals that may sit in `project`'s split: its sessions and the shell terminals filed
    /// under it — exactly what its tab strip lists.
    func splittableIDs(in project: String) -> Set<String> {
        let tabs = ProjectTabs.tabs(project: project, sessions: sessions, shells: shellRows,
                                    filed: sidebarState.terminalProjects, titles: [:])
        return Set(ProjectTabs.terminalIDs(tabs))
    }

    /// Every project's stored split, by canonical project path.
    func storedSplits() -> [String: ProjectSplit] {
        Dictionary(uniqueKeysWithValues: sidebarState.projectsWithSplits.compactMap { project in
            sidebarState.split(for: project).map { (project, $0) }
        })
    }

    func liveSplitMembers(in project: String) -> [String] {
        sidebarState.split(for: project)?.liveMembers(in: splittableIDs(in: project)) ?? []
    }

    /// What the Split tab renders: the live members in grid order, the one with the keyboard, and the
    /// live titles. One tab-list build and one title resolve, however many panes there are.
    func splitPaneState(in project: String) -> (members: [String], focused: String?, titles: [String: String]) {
        guard let split = sidebarState.split(for: project) else { return ([], nil, [:]) }
        let live = splittableIDs(in: project)
        return (split.liveMembers(in: live), split.focusedLive(in: live), sessionTitles)
    }

    func focusedSplitMember(in project: String) -> String? {
        sidebarState.split(for: project)?.focusedLive(in: splittableIDs(in: project))
    }

    func terminalSession(_ id: String) -> TerminalSession? {
        coordinator?.terminals.session(id: id)
    }

    /// A split pane's title: the tab strip's own, so the two never disagree. The live title (from
    /// `titles`, the live titles) first, then the session's stored one, then a shell terminal's, then the id.
    func splitPaneTitle(_ id: String, titles: [String: String]) -> String {
        titles[id] ?? sessions.first { $0.id == id }?.title ?? shellRows.first { $0.id == id }?.title ?? id
    }

    /// The state dot beside the pane's title, by the rule the sidebar's dots follow. nil for a shell
    /// terminal, which has no state to show.
    func splitPaneDot(_ id: String) -> ProjectDot? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        return SidebarModel.dot(
            status: rowStatus(session),
            hasRunningSubagents: usage.sessionAgents(id).contains(where: \.isRunning))
    }

    /// Shows `project`'s Split tab, its focused live member selected. Does nothing when the project
    /// has no active split.
    func showSplit(_ project: String) {
        let key = ProjectTabs.standardized(project)
        guard let target = focusedSplitMember(in: key), liveSplitMembers(in: key).count >= 2 else { return }
        markOnScreenSeen()   // what was on screen, a non-member perhaps, is about to leave it
        splitProject = key   // before the focus below, so the selection callback keeps it
        focus(target)
        boardProject = nil
        appTab = nil
        activeScreen = nil
    }

    /// A pane in `project`'s split got the keyboard (a click inside it, or a pane taking it over
    /// when the focused one ended): remember it as the split's focus. In the split the panel is showing,
    /// it is also selected, keeping the grid on screen. Only the selection moves, as
    /// `repairSplitSelection()` moves it: this also runs for a pane that took the keyboard by itself, so
    /// it never activates the app or adopts a worker. The user's own click goes on to `pickSplitPane(_:in:)`.
    /// A split in a torn-off window leaves the panel's selection alone. `project` is standardized here,
    /// like in every split operation below, so it compares with `splitProject` and the windows' keys.
    func focusInSplit(_ id: String, in project: String) {
        let key = ProjectTabs.standardized(project)
        guard let split = sidebarState.split(for: key), split.members.contains(id) else { return }
        let next = split.focusing(id)
        // The pane a key window shows is about to change; the panel's own change is marked by the selection.
        if next != split { markOnScreenSeen() }
        if key == splitProject, selectedId != id { coordinator?.terminals.select(id) }
        sidebarState.setSplit(next, for: key)
    }

    /// The user clicked a pane: it is opened as a tab is (`focus(_:)`), so a worker becomes theirs and
    /// an agent waiting on them reads as seen. `showSelection()` keeps the grid and moves its focus.
    /// In a torn-off window the panel's selection stays: the pane takes the split's focus and is
    /// acknowledged, nothing more.
    func pickSplitPane(_ id: String, in project: String) {
        let key = ProjectTabs.standardized(project)
        guard sidebarState.split(for: key)?.members.contains(id) == true else { return }
        if key == splitProject {
            focus(id)
        } else {
            focusInSplit(id, in: key)
            coordinator?.acknowledgeSession(id)
        }
    }

    /// A click on a pane's title row, in the grid `grid` draws (a torn-off window's item, nil for the
    /// panel): the pane gets the keyboard, as a click inside its terminal gives it. A pane whose terminal
    /// lives in another host shows a note in this grid, and its live view is not here to take the keyboard.
    func clickSplitPane(_ id: String, in project: String, grid: TornOffItem?) {
        pickSplitPane(id, in: project)
        guard host(of: id) == grid, let view = terminalSession(id)?.terminalView else { return }
        view.window?.makeFirstResponder(view)
    }

    /// Takes `id` out of `project`'s split; the session keeps running. Fewer than two
    /// panes left forgets the split; fewer than two live ones (one just ended) only ends the grid
    /// until the next prune forgets it. Whatever pane is left shows on its own. A split in a torn-off
    /// window changes only the stored split: the panel's selection stays, and the window closes if the
    /// split is no longer active.
    func removeFromSplit(_ id: String, in project: String) {
        let key = ProjectTabs.standardized(project)
        guard let split = sidebarState.split(for: key) else { return }
        markOnScreenSeen()   // the pane leaving the grid was on screen until now
        let next = split.removing(id)
        if next.isViable {
            sidebarState.setSplit(next, for: key)
        } else {
            sidebarState.clearSplit(for: key)
        }
        defer { pruneTornOff() }
        guard key == splitProject else { return }
        let repair = next.repair(selected: selectedId, liveIDs: splittableIDs(in: key))
        // Focus first, while the grid still covers whatever the selection fell back to: cleared first,
        // the fallback would read as on screen and be marked seen as the selection leaves it.
        if let target = repair.select { focus(target) }
        if !repair.keepsGrid { splitProject = nil }
    }

    /// `id` dragged onto `edge` of the terminal `target` in `project`: starts the project's
    /// split if `target` isn't in one, else adds `id` to it or moves it within, then shows the split.
    /// A terminal that isn't one of the project's, a ninth pane, or a drop outside a split that is showing is
    /// refused and the error bar says why.
    /// A terminal dropped on itself does nothing. A split in a torn-off window is stored but not
    /// shown: the window already shows it, and the panel's selection stays.
    func dropTerminal(_ id: String, onto target: String, edge: SplitEdge, in project: String) {
        let key = ProjectTabs.standardized(project)
        do {
            let next = try ProjectSplit.dropping(
                id, onto: target, edge: edge, into: sidebarState.split(for: key), splittable: splittableIDs(in: key))
            lastError = nil
            // The drop can move the dropped terminal into a window and change the pane a key window
            // shows: whatever is on screen now was seen until this store.
            markOnScreenSeen()
            sidebarState.setSplit(next, for: key)
            if key == splitProject || !tornOff.contains(.split(key)) { showSplit(key) }
        } catch ProjectSplit.Refusal.onItself {
            return
        } catch ProjectSplit.Refusal.notSplittable {
            lastError = "That terminal isn't one of this project's running terminals, so it can't join this split."
        } catch ProjectSplit.Refusal.splitAlreadyShowing {
            lastError = "This project already has a split — drop onto one of its panes, or close the Split tab first."
        } catch ProjectSplit.Refusal.full {
            lastError = "The split is full — it holds at most \(SplitLayout.maxPanes) terminals."
        } catch {
            lastError = "Couldn't split: \(error)"
        }
    }

    /// Forgets `project`'s split — the user closed its tab. The selected pane stays, shown on its own.
    func dissolveSplit(_ project: String) {
        let key = ProjectTabs.standardized(project)
        let split = sidebarState.split(for: key)
        markOnScreenSeen()   // a window showing the split closes with it
        sidebarState.clearSplit(for: key)
        pruneTornOff()
        guard splitProject == key else { return }
        // Focus first, while the grid still covers a fallback selection, so it isn't marked seen.
        if let target = split?.repair(selected: selectedId, liveIDs: splittableIDs(in: key)).select { focus(target) }
        splitProject = nil
    }

    /// Keeps a showing split's selection on its own panes. A pane that ends hands the selection to
    /// whatever terminal the manager falls back on, which the grid does not show: select a live pane
    /// instead, and end the grid once fewer than two are live. The stored split stays until
    /// `sampleSidebar()`'s pruning forgets the member (or the split). Runs from the 1 Hz tick
    /// and after a close, never on a user's behalf, so it moves the selection without `focus(_:)`'s
    /// side effects (activating the app, adopting a worker).
    func repairSplitSelection() {
        guard let project = splitProject else { return }
        let split = sidebarState.split(for: project) ?? ProjectSplit()
        let repair = split.repair(selected: selectedId, liveIDs: splittableIDs(in: project))
        // Select before the grid goes, so the terminal being left is judged as hidden, not seen.
        if let target = repair.select {
            coordinator?.terminals.select(target)
            if repair.keepsGrid { sidebarState.setSplit(split.focusing(target), for: project) }
        }
        if !repair.keepsGrid { splitProject = nil }
    }

    func select(_ tab: ProjectTab) {
        switch tab.kind {
        case .board:
            if let project = currentProject { showBoard(project) }
        case .split:
            if let project = currentProject { showSplit(project) }
        case .agent, .terminal:
            // A member's own tab shows it full-size: say so, or the selection would open its split.
            splitProject = nil
            fullSizeRequest = tab.id
            defer { fullSizeRequest = nil }
            focus(tab.id)
        case .app:
            guard let ref = openAppRef(forTab: tab.id) else { return }
            showApp(ref)
        }
    }

    /// Stops the tab's session. When that leaves this project showing nothing — including when
    /// the session manager's fallback jumped to a different project's terminal — this project's
    /// Board shows instead, so the strip does not vanish, or jump elsewhere, from under the
    /// pointer.
    func close(_ tab: ProjectTab) {
        let project = currentProject
        switch tab.kind {
        case .board: return
        case .split: if let project { dissolveSplit(project) }
        case .agent: stop(tab.id)
        case .terminal: stopShell(tab.id)
        case .app: closeApp(tab)
        }
        repairSplitSelection()
        if let project, currentProject != project { showBoard(project) }
    }

    /// Keep the SERVERS section honest while the panel shows: docker state changes
    /// out-of-band, so poll gently — and only when docker exists at all.
    private func refreshServers() {
        guard let toolServers, toolServers.dockerPath != nil else { return }
        Task { await toolServers.refresh() }
    }

    /// A fresh build waiting in dist — nil when current, or when running straight from
    /// dist (no `LinkCSourceDist` stamp, so dev runs never nag).
    private(set) var updateAvailable: UpdateInfo?
    /// Set the moment Install & restart is tapped: the quit warning steps aside (the tap
    /// IS the consent) and the detached swap helper takes over.
    private(set) var updateInProgress = false

    private func checkForUpdate() {
        guard let dist = Bundle.main.object(forInfoDictionaryKey: "LinkCSourceDist") as? String,
              let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return }
        updateAvailable = UpdateCheck.available(ownBuild: own, distBundle: URL(fileURLWithPath: dist))
    }

    /// Swap in the fresh build: a detached helper waits for this process to exit, copies
    /// the dist bundle over the installed one, and relaunches it. Sessions land in
    /// EARLIER for manual restore — same as any quit.
    func installUpdate() {
        guard let dist = Bundle.main.object(forInfoDictionaryKey: "LinkCSourceDist") as? String else { return }
        shells?.prepareForShutdown()
        coordinator?.prepareForShutdown(selectedId: selectedId)
        let script = UpdateSwap.script(
            pid: ProcessInfo.processInfo.processIdentifier,
            distPath: dist,
            installPath: Bundle.main.bundlePath
        )
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-update-\(UUID().uuidString).sh")
        do {
            lastError = nil
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            try process.run()
            updateInProgress = true
            NSApplication.shared.terminate(nil)
        } catch {
            lastError = "Couldn't start the update: \(error.localizedDescription)"
        }
    }

    /// The Docker VM's host CPU — the tax no per-container stat can show.
    var dockerVmCpu: Double? { toolServers?.vmCpu }

    /// A container's last stats sample; nil before the first sweep lands.
    func containerStats(_ id: String) -> ContainerStats? { toolServers?.statsById[id] }

    /// A compose project's summed live CPU — the stack's total draw, for display.
    func projectCpu(_ project: ToolServerProject) -> Double {
        project.containers.reduce(0) { $0 + (containerStats($1.id)?.cpuValue ?? 0) }
    }

    /// A project's single hottest container — the warning signal. A four-container stack
    /// idling at 30% each totals 120% without anything being hot; gold means one container
    /// actually crossed a full core.
    func projectHottest(_ project: ToolServerProject) -> Double {
        project.containers.map { containerStats($0.id)?.cpuValue ?? 0 }.max() ?? 0
    }

    /// The SERVERS rows, hottest first — ranked here so every surface orders the same way
    /// and the sort never re-derives a stack's total per comparison.
    var runningProjectsByPower: [ToolServerProject] {
        let cpu = Dictionary(uniqueKeysWithValues: runningProjects.map { ($0.id, projectCpu($0)) })
        return runningProjects.sorted { (cpu[$0.id] ?? 0) > (cpu[$1.id] ?? 0) }
    }
    var runningStandaloneByPower: [ContainerInfo] {
        runningStandalone.sorted {
            (containerStats($0.id)?.cpuValue ?? 0) > (containerStats($1.id)?.cpuValue ?? 0)
        }
    }

    func newTerminal(in project: String) {
        guard let shells else { return }
        do {
            lastError = nil
            let row = try shells.launch(cwd: project)
            sidebarState.file(terminal: row.id, under: project)
            showSelection() // the new terminal is selected by launch — show it
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Open a new dev terminal: pick a folder, get your login shell there.
    func newShellTerminal() {
        guard let shells else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal"
        panel.message = "Choose a folder to open a terminal in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            lastError = nil
            try shells.launch(cwd: url.path)
            recents?.record(url.path)
            showSelection()  // the new terminal is selected — show it
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopShell(_ id: String) { shells?.stop(id) }
    func dismissShell(_ id: String) {
        shells?.dismiss(id)
        sidebarState.unfile(terminal: id)
    }

    func relaunchShell(_ row: ShellRow) {
        guard let shells else { return }
        do {
            lastError = nil
            let newRow = try shells.relaunch(row)
            if let filedProject = sidebarState.terminalProjects[row.id] {
                sidebarState.unfile(terminal: row.id)
                sidebarState.file(terminal: newRow.id, under: filedProject)
            }
            recents?.record(row.cwd)
            showSelection()  // the new terminal is selected — show it
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Usage

    /// 0…1 context fill for a session's hairline bar; nil until its transcript has data.
    func contextFill(_ id: String) -> Double? {
        usage.sessionUsage(id)?.contextFill
    }

    /// The session's agents worth showing: everything running, plus completions from the
    /// last minute — finished work lingers briefly, then folds away. Swept runs stay hidden
    /// (they are phantoms) unless a later real completion clears the flag and re-surfaces them.
    func visibleAgents(_ id: String, now: Date = Date()) -> [AgentRun] {
        usage.sessionAgents(id).filter { agent in
            agent.isRunning || (!agent.endedBySweep
                && (agent.endedAt.map { now.timeIntervalSince($0) < 60 } ?? false))
        }
    }

    /// "142k · ~$1.87" for the open session's chrome; dollars dropped when any of the
    /// session's models is missing from the pricing table (never guess).
    var selectedUsageLabel: String? {
        guard let id = selectedId, let s = usage.sessionUsage(id) else { return nil }
        let tokens = UsageFormat.tokens(s.totalTokens)
        guard !s.hasUnpricedTokens else { return tokens }
        return "\(tokens) · \(UsageFormat.dollars(s.cost))"
    }

    /// The sidebar's footer: `5h · 3.1M tok · resets ~2am · 7d · 41M`. Nil until the first scan.
    var windowUsageLabel: String? {
        guard let w = usage.window else { return nil }
        var parts: [String] = []
        if let reset = w.blockResetAt {
            parts.append("5h · \(UsageFormat.tokens(w.blockTokens)) tok · resets \(UsageFormat.resetTime(reset))")
        }
        if w.weekTokens > 0 {
            parts.append("7d · \(UsageFormat.tokens(w.weekTokens))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func updateUsageTimer() {
        if panelVisible, usageTimer == nil {
            // First tick immediately so the panel never opens on stale zeros.
            usage.refreshAllSessions()
            usage.refreshWindow()
            refreshServers()
            refreshCodexUsage()
            checkForUpdate()
            refreshCloud()
            checkHealth()
            usageTicks = 0
            usageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.usage.refreshAllSessions()
                    self.usageTicks += 1
                    // The global sweep is heavier — every 30s is live enough for a footer,
                    // and enough for noticing a fresh build too.
                    if self.usageTicks % 6 == 0 {
                        self.usage.refreshWindow()
                        self.checkForUpdate()
                    }
                    // Cloud is slowest and rate-limited: every 120s is plenty.
                    if self.usageTicks % 24 == 0 { self.refreshCloud() }
                    // Docker state drifts slowly; every 15s keeps SERVERS honest cheaply.
                    if self.usageTicks % 3 == 0 { self.refreshServers() }
                    // Codex writes its snapshot every turn; five minutes is live enough to read it.
                    if self.usageTicks % 60 == 0 { self.refreshCodexUsage() }
                }
            }
        } else if !panelVisible {
            usageTimer?.invalidate()
            usageTimer = nil
        }
    }

    func shutdown() {
        LinkCAppProcess.stopAll(Array(appProcesses.values))
        appProcesses = [:]
        healthTimer?.invalidate()
        healthTimer = nil
        // Terminals are only sampled while the panel is visible or a torn-off window is open, so one that
        // changed folder or agent since then would be remembered as it was. Take the last look before
        // the snapshot below.
        shells?.sampleDirectories()
        shells?.sampleAgents()
        // Boards, sessions and shells all flush together — a quit within the Board's 600 ms
        // settle must not lose the edit, and the restore keys must not go stale. Safe to run
        // again on top of `applicationDidResignActive`'s own flush: every part of it is a
        // re-writable snapshot, not a one-shot.
        flushStateToDisk()
        coordinator?.shutdown()
    }

    func newSession(agent: AgentKind = .claude, mode: LaunchMode = .new) {
        guard let coordinator else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let name = agent.displayName
        switch mode {
        case .new:
            panel.prompt = "Start"
            panel.message = "Choose a folder to start a new \(name) session in"
        case .continueLast:
            panel.prompt = "Continue"
            panel.message = "Choose a folder — continues its most recent \(name) session"
        case .resume:
            panel.prompt = "Resume"
            panel.message = "Choose a folder — then pick a past \(name) session to resume in the terminal"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            lastError = nil
            try coordinator.newSession(cwd: url.path, agent: agent, mode: mode)
            showSelection()  // the new session is selected — show it
            recents?.record(url.path)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Which screen is open over the right pane, if any. While set, it is what the right pane
    /// shows, layered over any selected terminal. Anything that selects a session selects first
    /// and clears this second, so the session being left is judged by what was really on screen.
    var activeScreen: PanelScreen? {
        willSet {
            // A screen opening over the terminal (or closing) moves what is on screen.
            if newValue != activeScreen { markOnScreenSeen() }
        }
    }

    /// Open a screen from the sidebar. The selection stays put — screens layer over an open
    /// terminal, so closing the screen lands the user exactly where they were.
    func open(_ screen: PanelScreen) {
        activeScreen = screen
    }

    /// Back peels one layer: closes onto whatever was under it (the open terminal, or the
    /// launcher); the terminal closes onto the launcher, or onto the sidebar in a narrow panel.
    func goBack() {
        if activeScreen != nil {
            activeScreen = nil
        } else if boardProject != nil {
            boardProject = nil
            coordinator?.terminals.deselect()
        } else if appTab != nil {
            appTab = nil
            coordinator?.terminals.deselect()
        } else if splitProject != nil {
            splitProject = nil
            coordinator?.terminals.deselect()
        } else {
            coordinator?.terminals.deselect()
        }
    }

    /// Focusing a session always wins over an open screen. Select first, then close the screen:
    /// the session being left is judged by what was really on screen (a screen covered it).
    /// `focusSession`'s `onSessionFocused` callback (wired in `start()`) does the clearing — and
    /// opens the split holding `id`, when there is one — so a notification click gets the same
    /// treatment without going through this method at all.
    func focus(_ id: String) {
        coordinator?.focusSession(id)
    }
    func stop(_ id: String) { coordinator?.stopSession(id) }

    /// Resume a previous session as a fresh live one. Surfaces failures inline (fail loud).
    func restore(_ r: RestorableSession, as agent: AgentKind? = nil) {
        guard let coordinator else { return }
        do {
            lastError = nil
            try coordinator.restore(r, as: agent)
            showSelection()  // the new session is selected — show it
            recents?.record(r.cwd)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Restore every previous session. Any failures are collected and surfaced inline.
    func restoreAll() {
        guard let coordinator else { return }
        do {
            lastError = nil
            try coordinator.restoreAll()
            showSelection()  // the new session is selected — show it
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Forget a previous session (the user dismissed its row).
    func dismiss(_ r: RestorableSession) { coordinator?.dismiss(r) }

    /// The last `lines` rows of `id`'s live terminal output, for the Terminals screen's preview.
    /// "" when the session has no terminal yet (never started).
    func recentOutput(_ id: String, lines: Int) -> String {
        coordinator?.terminals.session(id: id)?.recentOutput(lines: lines) ?? ""
    }
}
