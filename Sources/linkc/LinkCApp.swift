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

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

/// The rail's destinations — full screens the panel can show in place of home.
enum PanelScreen: String, CaseIterable, Identifiable, Equatable {
    case mcpServers, skills, terminals, toolServers, settings
    var id: String { rawValue }
}

/// Observable app state backing the panel. Holds the coordinator once preflight succeeds, or
/// a setup error to show the user. Owns the terminal manager so the coordinator's watch probe
/// and the panel's terminal view share one source of truth.
@MainActor
@Observable
final class AppModel {
    private(set) var coordinator: AppCoordinator?
    private(set) var setupError: String?
    /// Surfaced when a one-off action (e.g. launching a session) fails — shown inline without
    /// tearing down the whole panel. Failing loud, not silent.
    private(set) var lastError: String?
    /// Whether the menu-bar panel is currently on screen. Feeds the coordinator's watch probe
    /// and gates the usage-refresh timer — no panel, no polling.
    var panelVisible = false {
        didSet { updateUsageTimer() }
    }

    /// Live usage state: per-session context/tokens/cost, plus the global plan window.
    let usage = UsageTracker()
    /// linkC's own settings (hotkey preset, panel toggles) — UserDefaults-backed.
    let preferences = AppPreferences()

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

    var sessions: [Session] { coordinator?.store.sessions ?? [] }
    /// Previous sessions no longer live — shown as dimmed restorable cards on the home overview.
    var restorables: [RestorableSession] { coordinator?.restorableStore.restorables ?? [] }
    var activeCount: Int { coordinator?.store.activeCount ?? 0 }
    var needsYouCount: Int { coordinator?.store.needsYouCount ?? 0 }
    var selectedId: String? { coordinator?.terminals.selectedId }

    var selectedTerminal: TerminalSession? {
        guard let id = selectedId else { return nil }
        return coordinator?.terminals.session(id: id)
    }

    func start() async {
        do {
            let preflight = try Preflight.resolve()
            let terminals = TerminalSessionManager()
            let coordinator = AppCoordinator(
                claudePath: preflight.claudePath,
                terminals: terminals,
                isWatching: { [weak self] id in
                    guard let self else { return false }
                    return self.panelVisible && NSApp.isActive && terminals.selectedId == id
                }
            )
            try coordinator.start()
            coordinator.usageTracker = usage
            self.coordinator = coordinator
            self.mcpServers = MCPServerService(claudePath: preflight.claudePath)
            self.skills = SkillsService(claudePath: preflight.claudePath)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let linkCSupport = support.appendingPathComponent("linkC", isDirectory: true)
            self.shells = ShellCoordinator(terminals: terminals, manifestDir: linkCSupport)
            self.shells?.restoreActiveShells()
            if let lastId = UserDefaults.standard.string(forKey: "LinkCLastSelectedSessionId"),
               terminals.sessions.contains(where: { $0.id == lastId }) {
                terminals.select(lastId)
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

    /// The empty state shows up to three recent launch folders as chips.
    var recentFolders: [String] { Array((recents?.paths ?? []).prefix(3)) }

    /// The chips' launch path: a new session in a known folder, no picker in the way.
    func startSession(in cwd: String, agent: AgentKind = .claude) {
        guard let coordinator else { return }
        do {
            lastError = nil
            try coordinator.newSession(cwd: cwd, agent: agent, mode: .new)
            recents?.record(cwd)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "View logs" rides on dev terminals: a shell running `docker logs -f`, which becomes
    /// a normal exited card when the follow ends.
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
            activeScreen = nil  // the new terminal is selected — show it
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

    func sampleShellAgents() {
        shells?.sampleAgents()
        var shellAgents: [String: [AgentKind]] = [:]
        for row in shellRows {
            if let agent = row.detectedAgent {
                shellAgents[row.cwd, default: []].append(agent)
            }
        }
        coordinator?.sampleSwarms(additionalAgents: shellAgents)
    }
    /// Dev terminals remembered from a previous run — relaunchable, never auto-started.
    var restorableShells: [RestorableShell] { shells?.restorables ?? [] }

    func restoreShell(_ shell: RestorableShell) {
        guard let shells else { return }
        do {
            lastError = nil
            try shells.restore(shell)
            recents?.record(shell.cwd)
            activeScreen = nil   // the new terminal is selected — show it
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

    /// The session's current action ("$ swift test") — while it's working, and while it's
    /// blocked on a permission prompt (that's exactly when "which command is waiting?"
    /// matters most). Idle rows never state an absence.
    func currentActivity(_ session: Session) -> String? {
        guard session.state.bucket == .active || session.state == .waitingPermission else {
            return nil
        }
        return usage.sessionActivity(session.id)
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

    /// The empty-state gate, centralized: dev terminals count as content too.
    var isEmptyOverview: Bool {
        sessions.isEmpty && restorables.isEmpty && shellRows.isEmpty && restorableShells.isEmpty
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
            activeScreen = nil  // the new terminal is selected — show it
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopShell(_ id: String) { shells?.stop(id) }
    func dismissShell(_ id: String) { shells?.dismiss(id) }

    func relaunchShell(_ row: ShellRow) {
        guard let shells else { return }
        do {
            lastError = nil
            try shells.relaunch(row)
            recents?.record(row.cwd)
            activeScreen = nil
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

    /// The home footer: `5h · 3.1M tok · resets ~2am · 7d · 41M`. Nil until the first scan.
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
        shells?.prepareForShutdown()
        coordinator?.prepareForShutdown(selectedId: selectedId)
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
            recents?.record(url.path)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Which rail screen is open, if any. Orthogonal to `selectedId`; the terminal wins when
    /// both are set (a session needing attention outranks a static screen).
    var activeScreen: PanelScreen?

    /// Open a rail screen. The selection stays put — screens layer over an open terminal,
    /// so closing the screen lands the user exactly where they were.
    func open(_ screen: PanelScreen) {
        activeScreen = screen
    }

    /// Back peels one layer: a screen closes onto whatever was under it (the open
    /// terminal, or home); the terminal closes onto home.
    func goBack() {
        if activeScreen != nil {
            activeScreen = nil
        } else {
            coordinator?.terminals.deselect()
        }
    }

    /// The terminal hero shows the session strip only when it offers a real switch —
    /// another live session to go to (which includes one session while a dev shell is open).
    var showsSessionStrip: Bool {
        guard let selectedId else { return false }
        return sessions.contains { $0.id != selectedId }
    }

    /// Focusing a session always wins over an open screen (notification clicks included).
    func focus(_ id: String) {
        activeScreen = nil
        coordinator?.focusSession(id)
    }
    func stop(_ id: String) { coordinator?.stopSession(id) }

    /// Resume a previous session as a fresh live one. Surfaces failures inline (fail loud).
    func restore(_ r: RestorableSession) {
        guard let coordinator else { return }
        do {
            lastError = nil
            try coordinator.restore(r)
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Forget a previous session (the user dismissed its card).
    func dismiss(_ r: RestorableSession) { coordinator?.dismiss(r) }

    /// Return to the home overview (no session selected). Keeps every terminal alive.
    func goHome() {
        coordinator?.terminals.deselect()
        activeScreen = nil
    }

    /// The last `lines` rows of `id`'s live terminal output, for the home overview's preview.
    /// "" when the session has no terminal yet (never started).
    func recentOutput(_ id: String, lines: Int) -> String {
        coordinator?.terminals.session(id: id)?.recentOutput(lines: lines) ?? ""
    }
}
