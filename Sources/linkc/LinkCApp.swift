import SwiftUI
import AppKit
import LinkCKit

@main
struct LinkCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The status item and panel are built by the AppDelegate/StatusPanelController, not by
    // SwiftUI. This scene exists only to satisfy `App`; an accessory app never shows it.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panelController: StatusPanelController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        panelController = StatusPanelController(model: model)
        hotKey = GlobalHotKey { [weak self] in self?.panelController?.togglePanel() }
        applyHotKeyPreference()
        observeHotKeyPreference()
        Task { await model.start() }
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

    /// Guard against losing running sessions: quitting linkC ends the claude processes it hosts.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
    /// Whether the menu-bar panel is currently on screen. Feeds the coordinator's watch probe
    /// and gates the usage-refresh timer — no panel, no polling.
    var panelVisible = false {
        willSet {
            // Hiding the panel takes the open terminal off screen: record it as seen first.
            if !newValue { markOnScreenSeen() }
        }
        didSet {
            updateUsageTimer()
            if !panelVisible {
                flushStateToDisk()
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
    /// Samples which agent each dev terminal is running, once a second. Sampling writes
    /// observable rows, so it runs here and never inside a view body — a body that writes
    /// what it reads re-renders itself forever.
    @ObservationIgnored private var shellSweepTask: Task<Void, Never>?
    @ObservationIgnored private var cachedInboxes: [String: Inbox] = [:]
    @ObservationIgnored private var lastInboxFetch: [String: Date] = [:]

    public var globalDashboardData: GlobalDashboardData?
    public var projectDashboardData: [String: ProjectDashboardData] = [:]

    public func refreshDashboard(workspacePath: String? = nil) async {
        guard let coordinator = self.coordinator else { return }
        let global = await coordinator.fetchGlobalDashboardAsync()
        self.globalDashboardData = global
        if let ws = workspacePath {
            let norm = (ws as NSString).standardizingPath
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
                    guard let self else { return false }
                    return self.panelVisible && NSApp.isActive && terminals.selectedId == id
                }
            )
            // A notification click reaches `focusSession` directly — never through `focus(_:)`
            // below — so this is the one place both paths funnel through: whichever one focused
            // a session, drop whatever was covering it.
            coordinator.onSessionFocused = { [weak self] _ in
                self?.showSelection()
            }
            try coordinator.start()
            coordinator.usageTracker = usage
            self.coordinator = coordinator
            self.mcpServers = MCPServerService(claudePath: preflight.claudePath)
            self.skills = SkillsService(claudePath: preflight.claudePath)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let linkCSupport = support.appendingPathComponent("linkC", isDirectory: true)
            self.shells = ShellCoordinator(terminals: terminals, manifestDir: linkCSupport)
            self.shells?.restoreActiveShells()
            // A filing is dropped only when its terminal is truly dismissed — keep it for a live
            // terminal, and for one still offered back in Earlier, so a terminal that had exited by
            // quit time, or whose folder was missing and so was skipped above, doesn't lose it.
            let keptTerminals = Set(shellRows.map(\.id)).union(restorableShells.map(\.id))
            sidebarState.pruneTerminals(keeping: keptTerminals)
            startShellSweep()
            // Forget remembered folders with no live session, no Earlier entry, and no filing.
            let standardized: (String) -> String = { ($0 as NSString).standardizingPath }
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

    /// Same cadence as the coordinator's session sweep: shells and swarms sampled every second.
    private func startShellSweep() {
        guard shellSweepTask == nil else { return }
        shellSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.sampleShells()
                self?.sampleSidebar()
            }
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

    /// Re-read Codex's own rate-limit snapshot. File IO only, and off the main actor: the reader
    /// reads the tail of the few newest rollouts, and the result lands back here.
    private func refreshCodexUsage() {
        let reader = CodexUsageReader(
            sessionsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions"))
        Task.detached(priority: .utility) { [weak self] in
            let usage = reader.read()
            await MainActor.run { self?.codexUsage = usage }
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
        let norm = (cwd as NSString).standardizingPath
        return swarms.first { ($0.workspacePath as NSString).standardizingPath == norm }
    }

    /// Loads the inbox for a workspace root with a 1-second in-memory throttle
    /// to avoid redundant synchronous disk reads during SwiftUI view body evaluations.
    func inbox(for workspacePath: String) -> Inbox? {
        let norm = (workspacePath as NSString).standardizingPath
        let now = Date()
        if let last = lastInboxFetch[norm], now.timeIntervalSince(last) < 1.0 {
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

    /// Refreshes cached inboxes for all active workspaces.
    func refreshCachedInboxes() {
        var paths = Set<String>()
        for s in sessions {
            paths.insert((s.cwd as NSString).standardizingPath)
        }
        for r in shellRows {
            paths.insert((r.cwd as NSString).standardizingPath)
        }
        let now = Date()
        for norm in paths {
            cachedInboxes[norm] = readInboxFromDisk(norm: norm)
            lastInboxFetch[norm] = now
        }
    }

    func sampleShells() {
        shells?.sampleDirectories()
        shells?.sampleAgents()
        var shellAgents: [String: [AgentKind]] = [:]
        let projects = knownProjectPaths
        for row in shellRows {
            if let agent = row.detectedAgent {
                // The same resolution `currentProject` uses: a terminal that `cd`s into a
                // subfolder (e.g. `cd Sources`) must still count toward its project's swarm
                // check, not toward the subfolder as if it were a separate project.
                let key = TerminalFiling.project(
                    forTerminal: row.id, cwd: row.cwd, filed: sidebarState.terminalProjects, projects: projects
                ) ?? ProjectTabs.standardized(row.cwd)
                shellAgents[key, default: []].append(agent)
            }
        }
        coordinator?.sampleSwarms(additionalAgents: shellAgents)
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
        let folder = (workspacePath as NSString).standardizingPath
        var things: [DiscoveredThing] = []
        var seen: Set<String> = []

        for project in toolServers?.projects ?? [] {
            guard let dir = project.workingDir,
                  (dir as NSString).standardizingPath == folder else { continue }
            for container in project.containers where container.state == .running {
                let name = container.composeService ?? container.name
                guard seen.insert(name.lowercased()).inserted else { continue }
                things.append(DiscoveredThing(
                    name: name, image: container.image,
                    detail: "container \(container.name) · \(container.image)"))
            }
        }

        for stack in toolServers?.knownStacks.stacks ?? []
        where (stack.workingDir as NSString).standardizingPath == folder {
            for service in stack.services {
                guard seen.insert(service.lowercased()).inserted else { continue }
                things.append(DiscoveredThing(
                    name: service, image: nil, detail: "compose service in \(stack.name)"))
            }
        }
        return things
    }

    /// One board model per project for the life of the app, so undo and unwritten edits survive
    /// switching tabs and projects.
    @ObservationIgnored private var boards: [String: BoardModel] = [:]

    func board(for path: String) -> BoardModel {
        let key = (path as NSString).standardizingPath
        if let board = boards[key] { return board }
        let board = BoardModel(store: BoardMapStore(workspacePath: key))
        boards[key] = board
        return board
    }

    /// The project whose Board is showing, or nil when a terminal — or nothing — is.
    private(set) var boardProject: String?

    /// The project the tab strip belongs to: the Board's, or the open session's or terminal's folder.
    var currentProject: String? {
        if let boardProject { return boardProject }
        guard let id = selectedId else { return nil }
        if let session = sessions.first(where: { $0.id == id }) { return ProjectTabs.standardized(session.cwd) }
        if let shell = shellRows.first(where: { $0.id == id }) {
            return TerminalFiling.project(
                forTerminal: shell.id, cwd: shell.cwd, filed: sidebarState.terminalProjects, projects: knownProjectPaths
            ) ?? ProjectTabs.standardized(shell.cwd)
        }
        return nil
    }

    var projectTabs: [ProjectTab] {
        guard let project = currentProject else { return [] }
        var activities: [String: String] = [:]
        for session in sessions
        where ProjectTabs.standardized(session.cwd) == ProjectTabs.standardized(project)
            && ShownActivity.applies(to: session.state) {
            activities[session.id] = currentActivity(session)
        }
        return ProjectTabs.tabs(
            project: project, sessions: sessions, shells: shellRows, filed: sidebarState.terminalProjects, titles: sessionTitles,
            activities: activities)
    }

    /// Whether the current project has a session mid-turn — computed directly, without building
    /// every tab (and reading every tab's activity) just to test one Bool. Working only: a
    /// permission wait's line doesn't change without an observable state change, so it needs no
    /// timer either.
    var projectHasWorkingSession: Bool {
        guard let project = currentProject else { return false }
        return sessions.contains { $0.state == .working && ProjectTabs.standardized($0.cwd) == project }
    }

    /// The tab showing: the project's Board, or the selected session or terminal.
    var selectedTabID: String? {
        if let boardProject { return ProjectTabs.boardID(boardProject) }
        return selectedId
    }

    func showBoard(_ path: String) {
        boardProject = ProjectTabs.standardized(path)
        activeScreen = nil
    }

    /// A session or terminal was just selected — show it. Clears both what could cover it: an
    /// open screen, and another project's Board (else the new one opens hidden underneath it).
    private func showSelection() {
        boardProject = nil
        activeScreen = nil
    }

    func select(_ tab: ProjectTab) {
        switch tab.kind {
        case .board:
            if let project = currentProject { showBoard(project) }
        case .agent, .terminal:
            focus(tab.id)
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
        case .agent: stop(tab.id)
        case .terminal: stopShell(tab.id)
        }
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
        healthTimer?.invalidate()
        healthTimer = nil
        shellSweepTask?.cancel()
        shellSweepTask = nil
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
        } else {
            coordinator?.terminals.deselect()
        }
    }

    /// Focusing a session always wins over an open screen. Select first, then close the screen:
    /// the session being left is judged by what was really on screen (a screen covered it).
    /// `focusSession`'s `onSessionFocused` callback (wired in `start()`) does the clearing, so
    /// a notification click gets the same treatment without going through this method at all.
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
