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

    private let hookServer: HookServer
    private let notifications: NotificationManager
    private let claudePath: String
    private let settingsDir: URL
    private let userSettingsURL: URL
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
        isWatching: @escaping @MainActor @Sendable (String) -> Bool
    ) {
        self.terminals = terminals
        self.hookServer = hookServer
        self.notifications = notifications
        self.claudePath = claudePath
        self.settingsDir = settingsDir
        self.userSettingsURL = userSettingsURL
        self.isWatching = isWatching
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: HookEvent.self)
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
        self.init(
            terminals: terminals,
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(),
            claudePath: claudePath,
            settingsDir: support.appendingPathComponent("linkC", isDirectory: true),
            userSettingsURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json"),
            isWatching: isWatching
        )
    }

    public func start() throws {
        notifications.onActivate = { [weak self] id in
            Task { @MainActor in self?.focusSession(id) }
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

    /// Remove a session everywhere it leaves state behind: the store, its terminal (dropped,
    /// not killed — the process is already dead here), its per-session settings file, and its
    /// notification dedupe entry. Idempotent.
    private func cleanup(sessionId: String) {
        store.remove(id: sessionId)
        terminals.remove(sessionId)
        let settingsFile = settingsDir.appendingPathComponent("session-\(sessionId).json")
        try? FileManager.default.removeItem(at: settingsFile)
        notifications.forget(sessionId)
    }

    // MARK: - UI commands

    @discardableResult
    public func newSession(cwd: String, mode: LaunchMode = .new) throws -> Session {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        let session = store.create(cwd: cwd, title: title)
        do {
            let settingsPath = try writeSettings(for: session)
            let terminal = terminals.makeSession(id: session.id, cwd: cwd, title: title)
            // A terminated claude = an ended session: prune everything when the child exits.
            terminal.onTerminated = { [weak self] _ in
                self?.cleanup(sessionId: session.id)
            }
            terminal.start(
                executable: claudePath,
                args: mode.claudeArgs + ["--settings", settingsPath],
                env: ["LINKC_SESSION": session.id]
            )
            terminals.select(session.id)
            return session
        } catch {
            cleanup(sessionId: session.id) // fail loud: no ghost session or orphaned settings file
            throw error
        }
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
}
