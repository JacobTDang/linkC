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

    /// ThreadSanitizer (`scripts/tsan.sh`) makes instrumented code run several times slower, so a
    /// budget sized for a plain debug build fails there with no real regression. Detected from the
    /// TSan runtime being loaded, so it holds however the suite was launched.
    static let budgetScale: Double = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil ? 5 : 1

    /// `seconds` as a CPU-time budget for this run: unchanged normally, scaled up under TSan.
    static func budget(_ seconds: TimeInterval) -> TimeInterval {
        seconds * budgetScale
    }

    /// Runs `body` and returns the CPU time it consumed on the calling thread, in seconds.
    static func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = now()
        body()
        return now() - start
    }
}
