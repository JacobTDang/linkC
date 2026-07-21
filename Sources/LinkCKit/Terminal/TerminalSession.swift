import AppKit
import Foundation
import SwiftTerm
import os

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
    public let title: String

    /// Fired on the main actor when the child process exits — for ANY reason, including being
    /// killed by `terminate()`. Carries the exit code (nil when the exit was an IO error).
    public var onTerminated: ((Int32?) -> Void)?

    /// Held strongly: `LocalProcessTerminalView.processDelegate` is a `weak` reference.
    private let processDelegate = ProcessDelegate()

    /// Backing store for the lazily-created view. Kept as an optional (rather than a `lazy
    /// var`) so `terminate()` can ask "was a process ever started?" without forcing the view
    /// — and a live PTY — into existence.
    private var _terminalView: LocalProcessTerminalView?

    /// Child liveness, flipped to false SYNCHRONOUSLY inside SwiftTerm's exit delegate — on
    /// whichever thread it fires, in the same call chain that reaps the pid — so a signal can
    /// never target a pid that was reaped a runloop ago and recycled by the OS. (A microscopic
    /// window between SwiftTerm's waitpid and this flip is unavoidable without owning the reap;
    /// it is instructions wide, not runloop wide.) A lock, not a main-actor var: the exit
    /// delegate may arrive off-main, and reading SwiftTerm's own `process.running` races its IO
    /// queue (TSan-confirmed).
    private let liveness = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Set once at spawn on the main actor; never reused across restarts (sessions start once).
    private var childPid: pid_t = -1
    /// Idempotence for `terminate()` (main-actor only).
    private var terminationRequested = false

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

        processDelegate.onExit = { [weak self, liveness] code in
            // Flip liveness in the SAME synchronous call chain as SwiftTerm's reap (see the
            // property doc) — the main-queue hop below is only for the cleanup callback.
            liveness.withLock { $0 = false }
            DispatchQueue.main.async { self?.handleTerminated(code) }
        }

        _terminalView = view
        return view
    }

    /// Launch `executable` in the PTY. Inherits the app's environment, overlays `env`, forces
    /// `TERM=xterm-256color`, and guarantees Homebrew is on `PATH` (a Finder-launched GUI app
    /// otherwise inherits a minimal PATH that lacks node and claude's other dependencies).
    public func start(executable: String, args: [String], env: [String: String]) throws {
        // Fail loud BEFORE forking: SwiftTerm forks even for a nonexistent executable (the exec
        // failure happens asynchronously inside the child), which would manufacture a session
        // that dies instantly with no surfaced error. Validate the deterministic
        // preconditions here instead.
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw LinkCError.process("cannot start session: \(executable) is missing or not executable")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LinkCError.process("cannot start session: folder \(cwd) no longer exists")
        }
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
        // Capture once, on the spawning thread, before any concurrent activity — the only
        // data-race-free moment to read these from SwiftTerm.
        childPid = terminalView.process.shellPid
        // Fail loud on a spawn that never happened (missing/non-executable binary, fork
        // failure): SwiftTerm leaves shellPid at 0 and would otherwise report nothing useful.
        guard childPid > 0 else {
            throw LinkCError.process("failed to start \(executable) in \(cwd) — the process never spawned")
        }
        liveness.withLock { $0 = true }
    }

    /// Kill the child process. A no-op if it was never started or has already exited. Fails
    /// loud (logs the errno) only when signalling a still-living child genuinely fails.
    public func terminate() {
        guard _terminalView != nil, childPid > 0, !terminationRequested else { return }
        guard liveness.withLock({ $0 }) else { return } // already exited and reaped
        terminationRequested = true
        // Signal the child directly instead of calling SwiftTerm's `view.terminate()`: that
        // method races its own childStopped handler on the IO queue (TSan-confirmed upstream
        // bug). A plain signal lets the exit flow through SwiftTerm's normal process monitor —
        // the same clean path as a natural exit — which also fires our onTerminated.
        kill(childPid, SIGTERM)
        // Give SIGTERM a real grace window (claude flushes and tears down MCP children), then
        // escalate to SIGKILL — but ONLY if the child hasn't exited-and-been-reaped meanwhile
        // (the liveness gate is what makes signalling here safe against pid recycling).
        // Capture the lock, pid, and id DIRECTLY — not via self: stopSession drops this
        // session's last strong reference right after terminate(), and a weak-self escalation
        // would die with it, leaving a SIGTERM-ignoring child alive as an invisible orphan.
        let pid = childPid
        let sessionId = id
        Task { [liveness] in
            try? await Task.sleep(for: .milliseconds(400))
            guard liveness.withLock({ $0 }) else { return }
            if kill(pid, SIGKILL) != 0, errno != ESRCH {
                NSLog("linkC: failed to kill terminal child pid %d for session %@: %s", pid, sessionId, strerror(errno))
            }
        }
    }

    /// The last `lines` content rows of the terminal's visible screen, as plain text — for the
    /// home overview's live preview. `TerminalPreview` drops chrome-only rows (frames, rules,
    /// bare prompts) so the preview shows output, not furniture. Returns "" when the PTY was
    /// never started. Reads the private backing store (not `terminalView`) so a never-shown
    /// session is never forced to spawn a view.
    public func recentOutput(lines: Int) -> String {
        guard let view = _terminalView else { return "" }
        let terminal = view.getTerminal()
        var rows: [String] = []
        for row in 0..<terminal.rows {
            rows.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        return TerminalPreview.excerpt(rows: rows, lines: lines)
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

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
}
