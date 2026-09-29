import Foundation
import os

/// When each (blackboard file, pid) heartbeat next has to touch `blackboard.json`.
///
/// A heartbeat writes only when it inserts a record, refreshes one that has gone
/// `BlackboardStore.heartbeatRefreshInterval` without a beat, or prunes an agent past
/// `BlackboardStore.staleAgentAge`. The app calls it once a second per live session and
/// `linkc-mcp` on every tool call, so what each call has to know — "nothing is due yet" — lives in
/// memory, per process. `BlackboardStore` is built fresh for nearly every call, hence the shared
/// instance. Absent means unknown, which is due.
final class HeartbeatSchedule: Sendable {
    static let shared = HeartbeatSchedule()

    private struct Key: Hashable, Sendable {
        let path: String
        let pid: pid_t
    }

    private let dueDates = OSAllocatedUnfairLock<[Key: Date]>(initialState: [:])

    func isDue(path: String, pid: pid_t, now: Date) -> Bool {
        dueDates.withLock { dates in
            guard let due = dates[Key(path: path, pid: pid)] else { return true }
            return now >= due
        }
    }

    func schedule(path: String, pid: pid_t, due: Date) {
        dueDates.withLock { $0[Key(path: path, pid: pid)] = due }
    }

    /// Drops every pid's schedule for `path`. Called when this process saves the file for any
    /// reason other than a heartbeat: what the next heartbeat has to do is no longer known.
    func forget(path: String) {
        dueDates.withLock { dates in
            dates = dates.filter { $0.key.path != path }
        }
    }
}
