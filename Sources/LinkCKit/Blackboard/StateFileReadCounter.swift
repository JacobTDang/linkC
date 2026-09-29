import Foundation
import os

/// Counts how many times a store went to disk (open, read and decode) for a state file, keyed by
/// the file's path. `InboxStore` and `BlackboardStore` are constructed fresh for nearly every
/// call, so the count lives process-wide, not per instance. It is what lets a test say "this
/// relay pass read `inbox.json` once" instead of inferring it from timing.
final class StateFileReadCounter: Sendable {
    static let shared = StateFileReadCounter()

    private let counts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    func record(path: String) {
        counts.withLock { $0[path, default: 0] += 1 }
    }

    func count(path: String) -> Int {
        counts.withLock { $0[path] ?? 0 }
    }
}
