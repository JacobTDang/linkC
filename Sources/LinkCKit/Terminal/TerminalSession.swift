import AppKit
import Foundation
import SwiftTerm

/// One embedded terminal running a `claude` process for a linkC session.
///
/// Wraps a SwiftTerm `LocalProcessTerminalView` — an AppKit NSView hosting a real PTY. The
/// view is created lazily so a session that is made but never shown/started never spins up a
/// view or a process. All access is on the main actor.
@MainActor
public final class TerminalSession {
    /// linkC's own session id — the correlation key shared with the store and hook events.
    public let id: String
    public let cwd: String
    /// The terminal's self-reported (OSC) title. Best-effort/informational: the tab UI uses
    /// the store's folder-derived title, which is stable.
    public private(set) var title: String

    /// Fired on the main actor when the child process exits — for ANY reason, including being
    /// killed by `terminate()`. Carries the exit code (nil when the exit was an IO error).
    public var onTerminated: ((Int32?) -> Void)?

    /// Held strongly: `LocalProcessTerminalView.processDelegate` is a `weak` reference.
    private let processDelegate = ProcessDelegate()

    /// Backing store for the lazily-created view. Kept as an optional (rather than a `lazy
    /// var`) so `terminate()` can ask "was a process ever started?" without forcing the view
    /// — and a live PTY — into existence.
    private var _terminalView: LocalProcessTerminalView?

    public init(id: String, cwd: String, title: String) {
        self.id = id
        self.cwd = cwd
        self.title = title
    }

    /// The AppKit view to embed. Created on first access; retains the process delegate and
    /// marshals its callbacks (delivered on SwiftTerm's private queue) onto the main actor.
    public var terminalView: LocalProcessTerminalView {
        if let existing = _terminalView { return existing }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        view.processDelegate = processDelegate
        view.nativeBackgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)

        processDelegate.onExit = { [weak self] code in
            DispatchQueue.main.async { self?.handleTerminated(code) }
        }
        processDelegate.onTitle = { [weak self] title in
            DispatchQueue.main.async { self?.title = title }
        }

        _terminalView = view
        return view
    }

    /// Launch `executable` in the PTY. Inherits the app's environment, overlays `env`, forces
    /// `TERM=xterm-256color`, and guarantees Homebrew is on `PATH` (a Finder-launched GUI app
    /// otherwise inherits a minimal PATH that lacks node and claude's other dependencies).
    public func start(executable: String, args: [String], env: [String: String]) {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = Self.pathEnsuringHomebrew(environment["PATH"])

        let environmentArray = environment.map { "\($0.key)=\($0.value)" }
        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: environmentArray,
            execName: nil,
            currentDirectory: cwd
        )
    }

    /// Kill the child process. A no-op if it was never started or has already exited. Fails
    /// loud (logs the errno) only when signalling a still-living child genuinely fails.
    public func terminate() {
        guard let view = _terminalView, view.process.running else { return }
        let pid = view.process.shellPid
        view.terminate() // SwiftTerm: tears down the PTY IO and SIGTERMs the child.
        guard pid > 0 else { return }
        // Escalate to SIGKILL only if it is still alive right after. ESRCH means the child is
        // already gone — the goal is met, not a failure.
        if kill(pid, 0) == 0, kill(pid, SIGKILL) != 0, errno != ESRCH {
            NSLog("linkC: failed to kill terminal child pid %d for session %@: %s", pid, id, strerror(errno))
        }
    }

    /// The last `lines` non-blank rows of the terminal's visible screen, as plain text — for the
    /// home overview's live preview. Returns "" when the PTY was never started. Reads the private
    /// backing store (not `terminalView`) so a never-shown session is never forced to spawn a view.
    public func recentOutput(lines: Int) -> String {
        guard let view = _terminalView else { return "" }
        let terminal = view.getTerminal()
        var rows: [String] = []
        for row in 0..<terminal.rows {
            rows.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }

    private func handleTerminated(_ code: Int32?) {
        onTerminated?(code)
    }

    /// Prepend Homebrew's bin dirs to `PATH` if absent, preserving everything else in order.
    private static func pathEnsuringHomebrew(_ current: String?) -> String {
        let homebrew = ["/opt/homebrew/bin", "/usr/local/bin"]
        var entries = (current ?? "").split(separator: ":").map(String.init)
        for dir in homebrew.reversed() where !entries.contains(dir) {
            entries.insert(dir, at: 0)
        }
        return entries.joined(separator: ":")
    }
}

/// Bridges SwiftTerm's class-bound `LocalProcessTerminalViewDelegate` (whose callbacks arrive
/// on a private background queue) into plain closures the owning `TerminalSession` marshals to
/// the main actor.
private final class ProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onExit: (@Sendable (Int32?) -> Void)?
    var onTitle: (@Sendable (String) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
}
