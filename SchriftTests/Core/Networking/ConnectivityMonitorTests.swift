import XCTest

@testable import Schrift

@MainActor
final class ConnectivityMonitorTests: XCTestCase {
    /// Captures the path-monitor's `onChange` so the test can drive reachability,
    /// and records cancellation. `@unchecked Sendable`: `onChange` is written once
    /// synchronously in `ConnectivityMonitor.init` (main actor) and read only from
    /// the main-actor test body; `cancelled` likewise.
    private final class FakePath: @unchecked Sendable {
        var onChange: (@Sendable (Bool) -> Void)?
        var cancelled = false
    }

    private func makeMonitoring(_ fake: FakePath) -> NetworkPathMonitoring {
        NetworkPathMonitoring { onChange in
            fake.onChange = onChange
            return { fake.cancelled = true }
        }
    }

    func testStartsOptimisticallyReachable() {
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(FakePath()))
        XCTAssertTrue(monitor.isReachable)
    }

    func testDeliversReachabilityChangesOnTheMainActor() async {
        let fake = FakePath()
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(fake))

        fake.onChange?(false)
        await waitUntil { monitor.isReachable == false }

        fake.onChange?(true)
        await waitUntil { monitor.isReachable == true }
    }

    /// The whole reason for the AsyncStream drain: several changes buffered
    /// back-to-back (no await between) are applied in order, so reachability
    /// settles on the LAST value — an earlier one never wins late.
    func testDeliversBufferedChangesInOrder() async {
        let fake = FakePath()
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(fake))

        fake.onChange?(false)
        fake.onChange?(true)
        fake.onChange?(false)
        fake.onChange?(true)
        await waitUntil { monitor.isReachable == true }
        await waitAndConfirmNever { monitor.isReachable == false }

        // A burst ending in `false` settles on `false`.
        fake.onChange?(true)
        fake.onChange?(false)
        await waitUntil { monitor.isReachable == false }
    }

    func testCancelsMonitoringOnDeinit() {
        let fake = FakePath()
        var monitor: ConnectivityMonitor? = ConnectivityMonitor(monitoring: makeMonitoring(fake))
        _ = monitor
        XCTAssertFalse(fake.cancelled)

        monitor = nil  // drops the last reference → the canceller box fires

        XCTAssertTrue(fake.cancelled)
    }
}
