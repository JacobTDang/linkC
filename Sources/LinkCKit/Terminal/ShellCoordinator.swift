import Foundation

/// Drives dev terminals — plain login shells for running local servers. Deliberately a
/// sibling of `AppCoordinator`, not part of it: shells need none of the claude plumbing
/// (hooks, settings composition, manifest, notifications, usage). The two share exactly one
/// thing — the `TerminalSessionManager` — so both kinds of terminal live under the panel's
/// single selection cursor and render through the same hero.
@MainActor
public final class ShellCoordinator {
    public let store = ShellTerminalStore()

    private let terminals: TerminalSessionManager
    private let shellPath: () -> String

    public init(
        terminals: TerminalSessionManager,
        shellPath: @escaping () -> String = { ShellResolver.loginShell() }
    ) {
        self.terminals = terminals
        self.shellPath = shellPath
    }

    /// Open the user's login shell in `cwd` — interactive when `command` is nil, otherwise
    /// running `command` through `-l -c` (PATH/dotfiles still load; the terminal becomes a
    /// normal exited card when the command ends — this is how "view logs" rides on dev
    /// terminals). Selected on creation, same UX as a new claude session. Fail loud: a
    /// failed spawn removes the terminal and rethrows.
    @discardableResult
    public func launch(cwd: String, command: String? = nil, title: String? = nil) throws -> ShellRow {
        let id = UUID().uuidString
        let title = title ?? URL(fileURLWithPath: cwd).lastPathComponent
        let shell = shellPath()

        let terminal = terminals.makeSession(id: id, cwd: cwd, title: title)
        terminal.onTerminated = { [weak self] rawStatus in
            // Keeps the row (and the terminal's scrollback): a dead dev server stays
            // visible and inspectable until the user dismisses it.
            self?.store.markExited(id: id, code: Self.decodeWaitStatus(rawStatus))
        }
        do {
            try terminal.start(
                executable: shell,
                args: command.map { ["-l", "-c", $0] } ?? [],
                env: [:],
                execName: command == nil ? ShellResolver.loginArgv0(for: shell) : nil
            )
        } catch {
            terminals.remove(id)
            throw error
        }
        return store.add(id: id, cwd: cwd, title: title)
    }

    /// Re-open an exited terminal's folder in a fresh shell (dev servers "restore" by
    /// re-running, not resuming). The old row and scrollback are replaced.
    @discardableResult
    public func relaunch(_ row: ShellRow) throws -> ShellRow {
        dismiss(row.id)
        return try launch(cwd: row.cwd)
    }

    /// Kill a RUNNING terminal and drop it entirely.
    public func stop(_ id: String) {
        terminals.terminate(id)
        store.remove(id: id)
    }

    /// Drop an EXITED terminal (row + kept scrollback). No-op while it's still running —
    /// stopping a live shell is `stop`'s explicit job, never a side effect of dismissal.
    public func dismiss(_ id: String) {
        guard case .exited = store.row(id: id)?.state else { return }
        terminals.remove(id)
        store.remove(id: id)
    }

    /// SwiftTerm's forkpty path reports the RAW waitpid status (exit 1 arrives as 256).
    /// Decode: a normal exit (low bits clear) yields WEXITSTATUS; a signal death yields nil —
    /// the UI only distinguishes clean (0) from not (non-zero or nil), and a signal has no
    /// meaningful exit code anyway.
    static func decodeWaitStatus(_ raw: Int32?) -> Int32? {
        guard let raw else { return nil }
        guard raw & 0x7f == 0 else { return nil }
        return (raw >> 8) & 0xff
    }
}
