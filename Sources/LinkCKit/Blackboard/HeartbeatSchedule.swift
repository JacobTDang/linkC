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
///
/// Due times are instants on the continuous (monotonic) clock: they are in-memory promises about
/// how much real time has to pass, so setting the date back or forward must not move them. The
/// timestamps persisted in the file stay wall-clock; `BlackboardStore` turns one into a delay
/// when it schedules.
final class HeartbeatSchedule: Sendable {
    static let shared = HeartbeatSchedule()

    private struct Key: Hashable, Sendable {
        let path: String
        let pid: pid_t
    }

    private let dueInstants = OSAllocatedUnfairLock<[Key: ContinuousClock.Instant]>(initialState: [:])

    func isDue(path: String, pid: pid_t, now: ContinuousClock.Instant) -> Bool {
        dueInstants.withLock { instants in
            guard let due = instants[Key(path: path, pid: pid)] else { return true }
            return now >= due
        }
    }

    /// The next heartbeat for `pid` has nothing to do until `delay` seconds after `now`.
    func schedule(path: String, pid: pid_t, after delay: TimeInterval, now: ContinuousClock.Instant) {
        dueInstants.withLock { $0[Key(path: path, pid: pid)] = now.advanced(by: .seconds(delay)) }
    }

    /// Drops every pid's schedule for `path`. Called when this process saves the file for any
    /// reason other than a heartbeat: what the next heartbeat has to do is no longer known.
    func forget(path: String) {
        dueInstants.withLock { instants in
            instants = instants.filter { $0.key.path != path }
        }
    }
}
