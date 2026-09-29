import Foundation
import os

/// A clock a test moves by hand: a sleep ends only when `advance(by:)` passes its deadline, or
/// when the sleeping task is cancelled. It also records what each sleep asked for, so a test can
/// assert the interval and tolerance the code under test requested.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    /// A sleep that has not ended yet.
    struct PendingSleep {
        let id: UUID
        let deadline: Instant
        let requested: Duration
        let tolerance: Duration?
        fileprivate let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var pending: [PendingSleep] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// The sleeps still waiting, oldest first.
    var pendingSleeps: [PendingSleep] { state.withLock { $0.pending } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome: Result<Void, Error>? = state.withLock { state in
                    if deadline <= state.now { return .success(()) }
                    // A cancel that landed before this point found nothing to remove.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.pending.append(PendingSleep(
                        id: id, deadline: deadline, requested: state.now.duration(to: deadline),
                        tolerance: tolerance, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> PendingSleep? in
                guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return nil }
                return state.pending.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and ends every sleep whose deadline it reaches.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [PendingSleep] in
            state.now = state.now.advanced(by: duration)
            let due = state.pending.filter { $0.deadline <= state.now }
            state.pending.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleep in due { sleep.continuation.resume() }
    }
}
