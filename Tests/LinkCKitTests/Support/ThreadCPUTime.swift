import Foundation

/// The calling thread's own CPU time, for speed-budget tests. `Date()`-based elapsed time
/// counts whatever else the machine was doing too, so a loaded box can fail a test that ran
/// perfectly fine on its own thread; CPU time can't be inflated by other processes or threads,
/// only by the measured work actually taking longer.
enum ThreadCPUTime {
    private static func now() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }

    /// Runs `body` and returns the CPU time it consumed on the calling thread, in seconds.
    static func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = now()
        body()
        return now() - start
    }
}
