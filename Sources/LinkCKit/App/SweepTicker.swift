import Foundation

/// A repeating pass whose spacing is chosen anew before every sleep, and which `wake()` can
/// cut short. The sleep passes a tolerance (a tenth of the interval) so macOS can coalesce its
/// wakeup with others. A `wake()` while a pass runs is not lost: the pass runs again straight
/// after it, because whatever prompted the wake may have landed after the pass read its inputs.
/// Several wakes before the loop gets back to the top make one pass.
///
/// A pass a wake asks for never starts sooner than `minimumGap` after the previous pass started.
/// A wake inside that window is held to its end, not dropped, and every wake that lands while it
/// is held is covered by the one pass that follows.
@MainActor
public final class SweepTicker {
    private let clock: any Clock<Duration>
    private let minimumGap: Duration
    private let interval: @MainActor () -> Duration
    private let pass: @MainActor () async -> Void
    private var loop: Task<Void, Never>?
    private var sleeping: Task<Bool, Never>?
    private var currentSleep: SleepStart?
    private var wakePending = false
    private var lastPassStart: PassStart?

    /// `clock` is injected so a test can move time by hand. `interval` is read before each sleep.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        minimumGap: Duration = TickCadence.minimumWakeGap,
        interval: @escaping @MainActor () -> Duration,
        pass: @escaping @MainActor () async -> Void
    ) {
        self.clock = clock
        self.minimumGap = minimumGap
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
                if wakePending { await waitOutTheGap() }
                guard !Task.isCancelled else { return }
                wakePending = false
                lastPassStart = PassStart.now(on: clock)
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

    /// Ends the sleep at once, or, during a pass, asks for another straight after it. Either way
    /// the pass waits out `minimumGap` since the last one started.
    public func wake() {
        wakePending = true
        sleeping?.cancel()
    }

    /// Ends the sleep without a pass when what `interval` returns now would end sooner than what
    /// is left of it, so the next sleep is chosen anew. For a change that shortens the interval but
    /// has nothing to sample yet. A sleep that already ends sooner is left alone: restarting it
    /// would push the next pass back, and repeated calls would keep pushing it.
    public func reschedule() {
        guard let currentSleep, interval() < currentSleep.remaining() else { return }
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
        currentSleep = SleepStart.now(on: clock, lasting: interval)
        let ranOut = await task.value
        sleeping = nil
        currentSleep = nil
        return ranOut
    }

    /// Returns once `minimumGap` has passed since the last pass started. Runs in the loop's own
    /// task, so `wake()` does not cut it short (more wakes only join the pass it ends in) and
    /// `stop()` does.
    private func waitOutTheGap() async {
        guard let lastPassStart else { return }
        // Cancellation is the only error a clock sleep throws; the loop checks for it next.
        try? await lastPassStart.sleepUntilGapEnds(minimumGap)
    }
}

/// A sleep in progress, measured in its clock's own instants like `PassStart`.
private struct SleepStart {
    let remaining: () -> Duration

    static func now(on clock: any Clock<Duration>, lasting length: Duration) -> SleepStart {
        func mark<C: Clock<Duration>>(_ clock: C) -> SleepStart {
            let start = clock.now
            return SleepStart { length - start.duration(to: clock.now) }
        }
        return mark(clock)
    }
}

/// When a pass began, in its clock's own instants. `any Clock` cannot hold its `Instant`, so the
/// instant stays inside the closure that measures from it.
private struct PassStart {
    let sleepUntilGapEnds: @Sendable (Duration) async throws -> Void

    static func now(on clock: any Clock<Duration>) -> PassStart {
        func mark<C: Clock<Duration>>(_ clock: C) -> PassStart {
            let start = clock.now
            return PassStart { gap in try await clock.sleep(until: start.advanced(by: gap), tolerance: nil) }
        }
        return mark(clock)
    }
}
