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
/// It is a **sync trigger only** — it deliberately does *not* replace the inferred
/// `isOffline` state or the `workOffline` toggle. Those also catch server-down /
/// HTTP-3-stall states that a satisfied `NWPath` misses (the documented Simulator
/// quirk in CLAUDE.md), so reachability here answers "can the OS see a network",
/// not "is the server usable". Reachability starts optimistic (`true`) so nothing
/// reads offline before the first path update, and every change is delivered on
/// the main actor.
@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isReachable = true
    // The cancel closure lives in a box whose own `deinit` fires it. The box is
    // initialized at declaration (before the `[weak self]` capture below), which
    // both satisfies definite-initialization and keeps the teardown off
    // ConnectivityMonitor's own `deinit` — a MainActor-isolated `deinit` can't
    // touch isolated state under Swift 6 strict concurrency.
    private let canceller = MonitorCanceller()

    init(monitoring: NetworkPathMonitoring = .nwPath) {
        canceller.cancel = monitoring.start { [weak self] reachable in
            Task { @MainActor in
                self?.isReachable = reachable
            }
        }
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
