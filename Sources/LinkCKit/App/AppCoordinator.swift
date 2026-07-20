import Foundation
import AppKit

/// How to start `claude` in a new tab: fresh, continue the most recent conversation in the
/// folder, or resume (claude shows its own session picker in the tab). `--continue`/`--resume`
/// use claude's own per-directory history, so they also work for sessions started outside linkC.
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
/// UI commands create / focus / stop sessions through kitty. The pure logic it orchestrates
/// (state machine, focus policy, settings merge, ls parsing) is unit-tested; this glue is
/// covered by AppCoordinatorIntegrationTests via injected doubles.
@MainActor
public final class AppCoordinator {
    public let store = SessionStore()

    private let kitty: KittyController
    private let hookServer: HookServer
    private let notifications: NotificationManager
    private let claudePath: String
    private let settingsDir: URL
    private let userSettingsURL: URL
    private let frontmostBundleID: @Sendable () -> String?

    public static let kittyBundleID = "net.kovidgoyal.kitty"

    /// Designated initializer — all collaborators injected (used by tests).
    public init(
        kitty: KittyController,
        hookServer: HookServer,
        notifications: NotificationManager,
        claudePath: String,
        settingsDir: URL,
        userSettingsURL: URL,
        frontmostBundleID: @escaping @Sendable () -> String?
    ) {
        self.kitty = kitty
        self.hookServer = hookServer
        self.notifications = notifications
        self.claudePath = claudePath
        self.settingsDir = settingsDir
        self.userSettingsURL = userSettingsURL
        self.frontmostBundleID = frontmostBundleID
    }

    /// Production initializer — builds real collaborators from resolved binary paths.
    public convenience init(kittyPath: String, kittenPath: String, socketPath: String, claudePath: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            kitty: KittyController(kittyPath: kittyPath, kittenPath: kittenPath, socketPath: socketPath, runner: ProcessCommandRunner()),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(),
            claudePath: claudePath,
            settingsDir: support.appendingPathComponent("linkC", isDirectory: true),
            userSettingsURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json"),
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        )
    }

    public func start() throws {
        notifications.onActivate = { [weak self] id in
            Task { @MainActor in await self?.focusSession(id) }
        }
        hookServer.onEvent = { [weak self] event in
            Task { @MainActor in await self?.handle(event) }
        }
        // Start receiving hooks immediately — do NOT gate this on the notification
        // permission dialog, which can block indefinitely on first launch.
        try hookServer.start()
        Task { await notifications.requestAuthorization() }
    }

    /// Stops the hook server. Called at app termination (and by tests).
    public func shutdown() {
        hookServer.stop()
    }

    // MARK: - Hook events → store → focus-aware notification

    func handle(_ event: HookEvent) async {
        let outcome = store.apply(event)
        guard outcome.shouldConsiderNotifying, let session = outcome.session else { return }
        let kittyFrontmost = frontmostBundleID() == Self.kittyBundleID
        let focused = (try? await kitty.focusedLinkcSession()) ?? nil
        if FocusPolicy.shouldNotify(
            session: session,
            enteredNotifiable: true,
            kittyIsFrontmost: kittyFrontmost,
            focusedLinkcSession: focused
        ) {
            notifications.post(session: session)
        }
    }

    // MARK: - UI commands

    @discardableResult
    public func newSession(cwd: String, mode: LaunchMode = .new) async throws -> Session {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        let session = store.create(cwd: cwd, title: title)
        do {
            try await kitty.ensureWorkspaceRunning()
            let settingsPath = try writeSettings(for: session)
            let windowId = try await kitty.launchSession(
                command: [claudePath] + mode.claudeArgs + ["--settings", settingsPath],
                cwd: cwd,
                title: title,
                linkcSessionId: session.id,
                extraEnv: [:]
            )
            store.setKittyWindow(windowId, for: session.id)
            activateKitty()
            return session
        } catch {
            store.remove(id: session.id) // fail loud: no ghost session
            throw error
        }
    }

    public func focusSession(_ id: String) async {
        try? await kitty.focus(linkcSessionId: id)
        activateKitty()
    }

    public func stopSession(_ id: String) async {
        try? await kitty.close(linkcSessionId: id)
        store.remove(id: id)
    }

    public var hookPort: UInt16 { hookServer.port }

    // MARK: - Helpers

    private func writeSettings(for session: Session) throws -> String {
        let user = try? Data(contentsOf: userSettingsURL)
        let projectURL = URL(fileURLWithPath: session.cwd).appendingPathComponent(".claude/settings.json")
        let project = try? Data(contentsOf: projectURL)
        let data = try SettingsComposer.compose(userSettings: user, projectSettings: project, port: hookServer.port)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let path = settingsDir.appendingPathComponent("session-\(session.id).json")
        try data.write(to: path)
        return path.path
    }

    private func activateKitty() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.kittyBundleID)
            .first?
            .activate()
    }
}
