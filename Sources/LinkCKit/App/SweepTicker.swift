import Foundation

/// A repeating pass whose spacing is chosen anew before every sleep, and which `wake()` can
/// cut short. The sleep passes a tolerance (a tenth of the interval) so macOS can coalesce its
/// wakeup with others. A `wake()` while a pass runs is not lost: the pass runs again straight
/// after it, because whatever prompted the wake may have landed after the pass read its inputs.
/// Several wakes before the loop gets back to the top make one pass.
@MainActor
public final class SweepTicker {
    private let clock: any Clock<Duration>
    private let interval: @MainActor () -> Duration
    private let pass: @MainActor () async -> Void
    private var loop: Task<Void, Never>?
    private var sleeping: Task<Bool, Never>?
    private var wakePending = false

    /// `clock` is injected so a test can move time by hand. `interval` is read before each sleep.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        interval: @escaping @MainActor () -> Duration,
        pass: @escaping @MainActor () async -> Void
    ) {
        self.clock = clock
        self.interval = interval
        self.pass = pass
    }

    /// Starts sleeping; the first pass runs when the first interval ends or on a `wake()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !wakePending {
                    // A sleep cut short by `reschedule()` ends with no pass: the interval is read anew.
                    guard await sleep() || wakePending else { continue }
                }
                guard !Task.isCancelled else { return }
                wakePending = false
                await pass()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        sleeping?.cancel()
        sleeping = nil
    }

    /// Ends the sleep at once, or, during a pass, asks for another straight after it.
    public func wake() {
        wakePending = true
        sleeping?.cancel()
    }

    /// Ends the sleep without a pass, so the next one is chosen with whatever `interval` returns
    /// now. For a change that shortens the interval but has nothing to sample yet.
    public func reschedule() {
        sleeping?.cancel()
    }

    /// Returns true when the interval has passed, false when `wake()`, `reschedule()` or `stop()`
    /// cancelled it. A cancelled sleep is the only error `Clock.sleep` throws, and here it is an
    /// expected exit.
    private func sleep() async -> Bool {
        let interval = interval()
        let tolerance = TickCadence.tolerance(for: interval)
        let task = Task<Bool, Never> { [clock] in
            (try? await clock.sleep(for: interval, tolerance: tolerance)) != nil
        }
        sleeping = task
        let ranOut = await task.value
        sleeping = nil
        return ranOut
    }
}
