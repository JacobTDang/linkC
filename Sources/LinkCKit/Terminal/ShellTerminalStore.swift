import Foundation
import Observation

public enum ShellState: Sendable, Equatable {
    case running
    case exited(Int32?)
}

/// One dev terminal on the home overview / Terminals screen.
public struct ShellRow: Sendable, Identifiable, Equatable {
    public let id: String
    public let cwd: String
    public let title: String
    public var state: ShellState
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
    public func add(id: String, cwd: String, title: String) -> ShellRow {
        let row = ShellRow(id: id, cwd: cwd, title: title, state: .running)
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

    public func remove(id: String) {
        rows.removeAll { $0.id == id }
    }

    public var runningCount: Int {
        rows.count { $0.state == .running }
    }
}
