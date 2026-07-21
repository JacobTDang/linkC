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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        panelController = StatusPanelController(model: model)
        Task { await model.start() }
    }

    /// Guard against losing running sessions: quitting linkC ends the claude processes it hosts.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = model.sessions.count
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Quit linkC and end 1 session?" : "Quit linkC and end \(count) sessions?"
        alert.informativeText = "Quitting ends the Claude Code \(count == 1 ? "session" : "sessions") running in linkC. "
            + "You can reopen \(count == 1 ? "it" : "them") later with Continue or Resume."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
    /// Surfaced when a one-off action (e.g. launching a session) fails — shown inline without
    /// tearing down the whole panel. Failing loud, not silent.
    private(set) var lastError: String?
    /// Whether the menu-bar panel is currently on screen. Feeds the coordinator's watch probe.
    var panelVisible = false

    var sessions: [Session] { coordinator?.store.sessions ?? [] }
    var activeCount: Int { coordinator?.store.activeCount ?? 0 }
    var needsYouCount: Int { coordinator?.store.needsYouCount ?? 0 }
    var selectedId: String? { coordinator?.terminals.selectedId }

    var selectedSession: Session? {
        guard let id = selectedId else { return nil }
        return coordinator?.store.session(id: id)
    }

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
            self.coordinator = coordinator
        } catch {
            setupError = error.localizedDescription
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

    func focus(_ id: String) { coordinator?.focusSession(id) }
    func stop(_ id: String) { coordinator?.stopSession(id) }
}
