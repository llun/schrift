import Darwin

/// The calling thread's CPU time, for per-step budgets in the scale tests.
///
/// A wall-clock step also counts every moment the OS left the simulator unscheduled; on a
/// shared CI machine one such pause of a few hundred milliseconds lands in a single step and
/// fails a budget the code meets by two orders of magnitude. CPU time counts only the work
/// the step did on its thread, so a real slowdown in layout or typing still fails it.
enum ThreadCPUClock {
    static var now: Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }
}
