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

    /// The **first** failure recorded after `marker` — the one that caused the throw — or nil
    /// when none was.
    ///
    /// First, not last: a single call can issue more than one request, and the later ones are
    /// consequences, not causes. `formattedContent`'s confirmation probe is exactly this — it
    /// fires *after* the document's own 404 and records a 404 of its own, for a document id
    /// that does not exist. Quoting the newest failure would show the user a reason belonging
    /// to a request they never made.
    ///
    /// The nil is equally load-bearing: a transport error (`.network`) or a decoding failure
    /// has no HTTP response, so without the marker the catch would quote an unrelated older
    /// one as its reason.
    func failure(after marker: Int) -> RequestFailure? {
        lock.lock()
        defer { lock.unlock() }
        guard recorded > marker else { return nil }
        // `failures` holds only the last `capacity` of the `recorded` total, so index from the
        // end. If the causal failure has already been evicted, the oldest we still hold is the
        // closest thing to it.
        let offsetFromEnd = recorded - marker
        guard offsetFromEnd <= failures.count else { return failures.first }
        return failures[failures.count - offsetFromEnd]
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
