import Foundation
import Network

/// A minimal seam over the platform network-path monitor, mirroring
/// `BackgroundTaskProvider`: production wraps `NWPathMonitor`; tests inject a fake
/// that drives reachability by hand (`MockURLProtocol` can't model a live path).
struct NetworkPathMonitoring: Sendable {
    /// Starts monitoring and calls `onChange` with the current reachability
    /// whenever the path changes; returns a cancel closure. Both closures are
    /// `@Sendable` because `NWPathMonitor` reports on a background queue.
    let start: @Sendable (_ onChange: @escaping @Sendable (Bool) -> Void) -> @Sendable () -> Void

    /// Production: `NWPathMonitor` on a private queue. A path counts as reachable
    /// when its status is `.satisfied`.
    static let nwPath = NetworkPathMonitoring { onChange in
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "dev.llun.Schrift.connectivity")
        monitor.pathUpdateHandler = { path in
            onChange(path.status == .satisfied)
        }
        monitor.start(queue: queue)
        return { monitor.cancel() }
    }
}

/// Observes network reachability for the app.
///
/// Reachability drives reconnect sync and `OnlineAvailability` for server-read
/// controls. A satisfied path does not establish server health: HTTP errors and
/// save decisions still come from their actual requests. Reachability starts
/// optimistic until the first OS callback; changes arrive on the main actor in order.
///
/// Path status cannot see "connected to Wi-Fi without internet" (plane Wi-Fi without a
/// purchase, a captive portal): the path stays `.satisfied` while every request hangs.
/// `DocsAPIClient` therefore reports transport evidence through `report(_:)`, which
/// drives `serverUnreachable` / `appearsOffline`. That evidence is **display-only**:
/// `isReachable` (and so `OnlineAvailability.isOffline`, which gates controls and
/// response tokens) is unchanged, because a control disabled on failure evidence would
/// make no request and so could never observe the server coming back. Path updates and
/// transport reports share one ordered stream, so they apply in the order they arrived.
@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isReachable = true
    /// True after a connectivity-class transport failure, until any HTTP response
    /// arrives or the path changes. Display evidence only; never a control gate.
    private(set) var serverUnreachable = false
    /// What status chrome (banner, save status, sync caption) should treat as offline.
    var appearsOffline: Bool { !isReachable || serverUnreachable }
    /// Invalidates requests across a disconnect/reconnect, even when the final path
    /// is reachable again by the time their old response arrives. Transport reports
    /// never bump it.
    private(set) var revision = 0

    private enum Event: Sendable {
        case path(Bool)
        case transport(TransportOutcome)
    }

    // `Continuation` is Sendable, so `report(_:)` may yield from any isolation (the
    // API client is an actor). A `let` is not tracked by `@Observable`.
    private nonisolated let continuation: AsyncStream<Event>.Continuation
    // The cancel closure lives in a box whose own `deinit` fires it. The box is
    // initialized at declaration (before the `[weak self]` capture below), which
    // both satisfies definite-initialization and keeps the teardown off
    // ConnectivityMonitor's own `deinit` — a MainActor-isolated `deinit` can't
    // touch isolated state under Swift 6 strict concurrency.
    private let canceller = MonitorCanceller()

    init(monitoring: NetworkPathMonitoring = .nwPath) {
        // NWPathMonitor delivers updates in order on its serial queue, but a fresh
        // `Task { @MainActor }` per callback carries no ordering guarantee — a fast
        // false→true flap could land true-then-false and strand `isReachable` at a
        // stale value on a link that is actually up. Funnel the ordered callbacks
        // through an AsyncStream drained by a single Task, so the main-actor updates
        // stay in order.
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        let stopMonitoring = monitoring.start { reachable in
            continuation.yield(.path(reachable))
        }
        // The box's deinit ends both the OS monitor and the drain loop when the
        // owner is released.
        canceller.cancel = {
            stopMonitoring()
            continuation.finish()
        }
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .path(let reachable):
                    if self.isReachable != reachable {
                        self.isReachable = reachable
                        self.revision += 1
                        // A new path deserves a fresh judgment of the server.
                        if self.serverUnreachable { self.serverUnreachable = false }
                    }
                case .transport(let outcome):
                    let unreachable = outcome == .unreachable
                    if self.serverUnreachable != unreachable { self.serverUnreachable = unreachable }
                }
            }
        }
    }

    /// Records what a request learned about the server. Callable from any isolation;
    /// ordered with path updates through the same stream.
    nonisolated func report(_ outcome: TransportOutcome) {
        continuation.yield(.transport(outcome))
    }
}

/// Holds a path-monitor cancel closure and invokes it on dealloc. `@unchecked
/// Sendable`: `cancel` is written exactly once (in `ConnectivityMonitor.init`, on
/// the main actor) and read exactly once (in this nonisolated `deinit`, after the
/// owner's last reference drops), so there is no concurrent access.
private final class MonitorCanceller: @unchecked Sendable {
    var cancel: (@Sendable () -> Void)?
    deinit { cancel?() }
}
