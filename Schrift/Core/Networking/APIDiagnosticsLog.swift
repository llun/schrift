import Foundation

/// The last few non-2xx responses, kept in memory so a view model can quote the server's
/// own explanation alongside its friendly error message.
///
/// Recorded **synchronously** from inside `DocsAPIClient.performRequest`, before the error
/// is thrown, so the view model that catches that error is guaranteed to see it. An
/// `@Observable @MainActor` log would have to hop isolation domains to record, landing
/// after the `catch` had already read it — hence the lock rather than the Observation
/// framework this codebase otherwise uses for state.
///
/// Bounded, in-memory, never persisted. `RequestFailure` carries no credential by
/// construction; keep it that way.
final class APIDiagnosticsLog: @unchecked Sendable {
    /// Enough to see a failure next to the requests around it, small enough that a request
    /// storm cannot grow it without bound.
    static let capacity = 20

    private let lock = NSLock()
    private var failures: [RequestFailure] = []
    /// Total ever recorded — the value callers snapshot as a marker. Deliberately not
    /// `failures.count`, which the capacity cap would make non-monotonic.
    private var recorded = 0

    func record(_ failure: RequestFailure) {
        lock.lock()
        defer { lock.unlock() }
        failures.append(failure)
        recorded += 1
        if failures.count > Self.capacity {
            failures.removeFirst(failures.count - Self.capacity)
        }
    }

    /// Snapshot before issuing a request; pass it to `failure(after:)` in the catch.
    func marker() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The newest failure recorded since `marker`, or nil when none was. That nil is the
    /// point: a transport error (`.network`) or a decoding failure has no HTTP status, so
    /// without the marker the catch would quote an unrelated older response as its reason.
    func failure(after marker: Int) -> RequestFailure? {
        lock.lock()
        defer { lock.unlock() }
        return recorded > marker ? failures.last : nil
    }

    var recentFailures: [RequestFailure] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}

/// The one-line detail a view model shows beneath its friendly error message, or nil when the
/// request that just failed produced no HTTP response of its own — so an offline `.network`
/// failure never quotes an unrelated earlier one. Snapshot `log.marker()` before issuing the
/// request and pass it here from the `catch`.
func requestFailureDetail(after marker: Int?, in log: APIDiagnosticsLog?) -> String? {
    guard let marker, let failure = log?.failure(after: marker) else { return nil }
    return failure.displayText
}
