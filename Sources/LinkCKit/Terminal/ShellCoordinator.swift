import Foundation
import Observation

/// Drives dev terminals — plain login shells for running local servers. Deliberately a
/// sibling of `AppCoordinator`, not part of it: shells need none of the claude plumbing
/// (hooks, settings composition, manifest, notifications, usage). The two share exactly one
/// thing — the `TerminalSessionManager` — so both kinds of terminal live under the panel's
/// single selection cursor and render through the same hero.
@MainActor
@Observable
public final class ShellCoordinator {
    public let store = ShellTerminalStore()

    private let terminals: TerminalSessionManager
    private let shellPath: () -> String
    let manifest: ShellManifest?
    /// Shells remembered from a previous run — restorable rows, not live ones. Kept in
    /// sync with the manifest so the UI can observe one source.
    public private(set) var restorables: [RestorableShell] = []

    public init(
        terminals: TerminalSessionManager,
        manifestDir: URL? = nil,
        shellPath: @escaping () -> String = { ShellResolver.loginShell() }
    ) {
        self.terminals = terminals
        self.shellPath = shellPath
        self.manifest = manifestDir.map { ShellManifest(directory: $0) }
        // Everything the manifest already holds is from a previous run — nothing is live
        // yet, so all of it surfaces as restorable.
        self.restorables = manifest?.entries ?? []
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
            // Stamp it restorable: the shell is dead, so a later run can offer it back.
            self?.manifest?.markEnded(id: id, at: Date())
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
        manifest?.upsert(RestorableShell(id: id, cwd: cwd, title: title, command: command))
        let row = store.add(id: id, cwd: cwd, title: title, command: command)
        syncRestorables()   // after the row exists: a live shell is not restorable
        return row
    }

    /// Sample active foreground agents across all live shell terminals.
    public func sampleAgents() {
        for row in store.rows {
            if let terminal = terminals.session(id: row.id) {
                let agent = terminal.sampleForegroundAgent()
                store.updateDetectedAgent(id: row.id, agent: agent == .shell ? nil : agent)
            }
        }
    }

    /// Snapshot all running shells to the manifest before shutdown.
    public func prepareForShutdown() {
        for row in store.rows where row.state == .running {
            manifest?.upsert(RestorableShell(
                id: row.id,
                cwd: row.cwd,
                title: row.title,
                command: row.command,
                wasActiveOnQuit: true,
                detectedAgent: row.detectedAgent,
                endedAt: nil
            ))
        }
    }

    /// Re-open a shell remembered from a previous run: a fresh shell in its folder (and
    /// its command, for command-mode shells). The card is consumed either way — a failed
    /// launch rethrows, and the entry is already gone, matching session restore.
    @discardableResult
    public func restore(_ shell: RestorableShell) throws -> ShellRow {
        // Remove only after a successful launch: a throw (folder on an unmounted volume,
        // say) must leave the card recoverable rather than erasing it.
        let row = try launch(cwd: shell.cwd, command: shell.command, title: shell.title)
        manifest?.remove(id: shell.id)
        syncRestorables()
        return row
    }

    /// Drop a remembered shell without launching it (the user dismissed the card).
    public func forget(_ shell: RestorableShell) {
        manifest?.remove(id: shell.id)
        syncRestorables()
    }

    /// Restorables are the remembered shells that aren't currently live — the same
    /// live-minus-manifest split the session side uses. Without the filter, launching a
    /// shell would immediately also list it as restorable.
    private func syncRestorables() {
        let liveIds = Set(store.rows.map(\.id))
        let next = (manifest?.entries ?? []).filter { !liveIds.contains($0.id) }
        if next != restorables { restorables = next }
    }

    /// Re-open an exited terminal's folder in a fresh shell (dev servers "restore" by
    /// re-running, not resuming). The old row and scrollback are replaced.
    @discardableResult
    public func relaunch(_ row: ShellRow) throws -> ShellRow {
        dismiss(row.id)
        return try launch(cwd: row.cwd, command: row.command, title: row.title)
    }

    /// Kill a RUNNING terminal and drop it entirely.
    public func stop(_ id: String) {
        terminals.terminate(id)
        store.remove(id: id)
        // Deliberately stopping a shell drops it entirely (same as dismiss) — it must not
        // reappear as a relaunch card in the same run. Cross-run persistence comes from
        // the manifest's load-time stamping, not from this path.
        manifest?.remove(id: id)
        syncRestorables()
    }

    /// Drop an EXITED terminal (row + kept scrollback). No-op while it's still running —
    /// stopping a live shell is `stop`'s explicit job, never a side effect of dismissal.
    public func dismiss(_ id: String) {
        guard case .exited = store.row(id: id)?.state else { return }
        terminals.remove(id)
        store.remove(id: id)
        manifest?.remove(id: id)
        syncRestorables()
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
