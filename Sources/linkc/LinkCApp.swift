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
        // Running dev terminals count too — quitting kills them, and unlike sessions they
        // aren't restored, which the copy says plainly. Exited terminals have nothing to kill.
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
            self.shells = ShellCoordinator(terminals: terminals)
            self.toolServers = ToolServerService()
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

    /// The empty-state gate, centralized: dev terminals count as content too.
    var isEmptyOverview: Bool {
        sessions.isEmpty && restorables.isEmpty && shellRows.isEmpty
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
    /// last minute — finished work lingers briefly, then folds away.
    func visibleAgents(_ id: String, now: Date = Date()) -> [AgentRun] {
        usage.sessionAgents(id).filter { agent in
            agent.isRunning || (agent.endedAt.map { now.timeIntervalSince($0) < 60 } ?? false)
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
            usageTicks = 0
            usageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.usage.refreshAllSessions()
                    self.usageTicks += 1
                    // The global sweep is heavier — every 30s is live enough for a footer.
                    if self.usageTicks % 6 == 0 { self.usage.refreshWindow() }
                }
            }
        } else if !panelVisible {
            usageTimer?.invalidate()
            usageTimer = nil
        }
    }

    func shutdown() {
        coordinator?.shutdown()
    }

    func newSession(mode: LaunchMode = .new) {
        guard let coordinator else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        switch mode {
        case .new:
            panel.prompt = "Start"
            panel.message = "Choose a folder to start a new Claude Code session in"
        case .continueLast:
            panel.prompt = "Continue"
            panel.message = "Choose a folder — continues its most recent Claude Code session"
        case .resume:
            panel.prompt = "Resume"
            panel.message = "Choose a folder — then pick a past session to resume in the terminal"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            lastError = nil
            try coordinator.newSession(cwd: url.path, mode: mode)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Which rail screen is open, if any. Orthogonal to `selectedId`; the terminal wins when
    /// both are set (a session needing attention outranks a static screen).
    var activeScreen: PanelScreen?

    /// Open a rail screen — deselects any terminal so the screen actually shows.
    func open(_ screen: PanelScreen) {
        coordinator?.terminals.deselect()
        activeScreen = screen
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
