import SwiftUI
import AppKit
import LinkCKit

@main
struct LinkCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            LinkCMenu(model: appDelegate.model)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        Task { await model.start() }
    }
}

/// Observable app state backing the menu. Holds the coordinator once preflight succeeds,
/// or a setup error to show the user.
@MainActor
@Observable
final class AppModel {
    private(set) var coordinator: AppCoordinator?
    private(set) var setupError: String?

    var sessions: [Session] { coordinator?.store.sessions ?? [] }
    var activeCount: Int { coordinator?.store.activeCount ?? 0 }
    var needsYouCount: Int { coordinator?.store.needsYouCount ?? 0 }

    func start() async {
        do {
            let preflight = try Preflight.resolve()
            let coordinator = AppCoordinator(
                kittyPath: preflight.kittyPath,
                kittenPath: preflight.kittenPath,
                socketPath: preflight.socketPath,
                claudePath: preflight.claudePath
            )
            try coordinator.start()
            self.coordinator = coordinator
        } catch {
            setupError = error.localizedDescription
        }
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
            panel.message = "Choose a folder — then pick a past session to resume in the tab"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await coordinator.newSession(cwd: url.path, mode: mode) }
    }

    func focus(_ id: String) { Task { await coordinator?.focusSession(id) } }
    func stop(_ id: String) { Task { await coordinator?.stopSession(id) } }
}

struct LinkCMenu: View {
    let model: AppModel

    var body: some View {
        if let error = model.setupError {
            Text("Setup needed").font(.headline)
            Text(error).font(.caption)
            Divider()
        } else {
            Text("\(model.activeCount) running · \(model.needsYouCount) waiting")
                .font(.caption)
            Divider()
            if model.sessions.isEmpty {
                Text("No sessions yet — start one below").foregroundStyle(.secondary)
            } else {
                ForEach(model.sessions) { session in
                    Menu("\(statusDot(session.state)) \(session.title) — \(label(session.state))") {
                        Button("Focus") { model.focus(session.id) }
                        Button("Stop") { model.stop(session.id) }
                    }
                }
            }
            Divider()
            Button("New session…") { model.newSession(mode: .new) }
            Button("Continue last…") { model.newSession(mode: .continueLast) }
            Button("Resume…") { model.newSession(mode: .resume) }
        }
        Button("Quit linkC") { NSApplication.shared.terminate(nil) }
    }

    private func statusDot(_ state: SessionState) -> String {
        switch state.bucket {
        case .active: return "🟢"
        case .needsYou: return "🟠"
        case .idle: return "⚪️"
        }
    }

    private func label(_ state: SessionState) -> String {
        switch state {
        case .starting: return "starting"
        case .ready: return "ready"
        case .working: return "working"
        case .waitingPermission: return "needs permission"
        case .waitingIdle: return "waiting for input"
        case .finished: return "finished"
        case .error: return "error"
        case .ended: return "ended"
        }
    }
}
