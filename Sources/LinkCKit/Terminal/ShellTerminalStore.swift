import Foundation
import Observation

public enum ShellState: Sendable, Equatable {
    case running
    case exited(Int32?)
}

/// One dev terminal, shown in the sidebar's Terminals section and on the Terminals screen.
public struct ShellRow: Sendable, Identifiable, Equatable {
    public let id: String
    public internal(set) var cwd: String
    public internal(set) var title: String
    /// Non-nil for command-mode shells (docker logs, a dev server) — relaunch re-runs it.
    public var command: String?
    public var state: ShellState
    public var detectedAgent: AgentKind?

    public init(
        id: String,
        cwd: String,
        title: String,
        command: String? = nil,
        state: ShellState,
        detectedAgent: AgentKind? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.command = command
        self.state = state
        self.detectedAgent = detectedAgent
    }
}

/// Bookkeeping for dev terminals — the shell analogue of `SessionStore`, minus the hook
/// state machine (shells have exactly two states). The load-bearing rule: `markExited`
/// KEEPS the row, so a crashed dev server stays visible (with its scrollback) until the
/// user dismisses it.
@MainActor
@Observable
public final class ShellTerminalStore {
    public private(set) var rows: [ShellRow] = []

    public init() {}

    @discardableResult
    public func add(id: String, cwd: String, title: String, command: String? = nil) -> ShellRow {
        let row = ShellRow(id: id, cwd: cwd, title: title, command: command, state: .running, detectedAgent: nil)
        rows.append(row)
        return row
    }

    public func row(id: String) -> ShellRow? {
        rows.first { $0.id == id }
    }

    /// Flip a row to exited. No-op for an unknown id (e.g. the exit callback of a shell the
    /// user already stopped and removed).
    public func markExited(id: String, code: Int32?) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = .exited(code)
    }

    /// Update the detected active agent running in this shell terminal. Writes only on a real
    /// change: sampling runs every second, and an unconditional write would invalidate every
    /// observer of `rows` each tick.
    public func updateDetectedAgent(id: String, agent: AgentKind?) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[index].detectedAgent != agent {
            rows[index].detectedAgent = agent
        }
    }

    /// Moves a row to the folder its shell is now in. A plain terminal (no command) is renamed
    /// after the folder; a command terminal keeps its title. Writes only on a real change,
    /// because the sweep runs every second, and returns the updated row, or nil when nothing
    /// changed.
    @discardableResult
    public func updateDirectory(id: String, to directory: String, home: String = NSHomeDirectory()) -> ShellRow? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        var row = rows[index]
        row.cwd = directory
        if row.command == nil {
            row.title = ShellTitle.name(forDirectory: directory, home: home)
        }
        guard row != rows[index] else { return nil }
        rows[index] = row
        return row
    }

    public func remove(id: String) {
        rows.removeAll { $0.id == id }
    }

    public var runningCount: Int {
        rows.count { $0.state == .running }
    }
}
