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

    func testDeliversReachabilityChangesOnTheMainActor() async {
        let fake = FakePath()
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(fake))
        XCTAssertTrue(monitor.isReachable, "optimistic until the path monitor says otherwise")

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

    /// Transport evidence is display-only: it flips `appearsOffline` but leaves
    /// `isReachable` and `revision` (what gates controls and invalidates tokens) alone.
    func testTransportEvidenceMakesTheMonitorAppearOfflineWithoutTouchingReachability() async {
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(FakePath()))
        let revision = monitor.revision

        monitor.report(.unreachable)
        await waitUntil { monitor.serverUnreachable }

        XCTAssertTrue(monitor.appearsOffline)
        XCTAssertTrue(monitor.isReachable)
        XCTAssertEqual(monitor.revision, revision)

        monitor.report(.reachedServer)
        await waitUntil { !monitor.serverUnreachable }
        XCTAssertFalse(monitor.appearsOffline)
        XCTAssertEqual(monitor.revision, revision)
    }

    func testAPathChangeClearsTransportEvidence() async {
        let fake = FakePath()
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(fake))

        monitor.report(.unreachable)
        await waitUntil { monitor.serverUnreachable }

        fake.onChange?(false)
        await waitUntil { !monitor.isReachable }
        XCTAssertFalse(monitor.serverUnreachable, "a new path deserves a fresh judgment")
        XCTAssertTrue(monitor.appearsOffline, "the path itself is down")

        fake.onChange?(true)
        await waitUntil { monitor.isReachable }
        XCTAssertFalse(monitor.appearsOffline)
    }

    /// Reports share the path stream's ordering: the last of a back-to-back burst wins, in
    /// each direction. Each half starts from the opposite state, so neither can pass by
    /// leaving the flag where it began.
    func testBufferedTransportReportsApplyInOrder() async {
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(FakePath()))
        let base = ContinuousClock.now

        monitor.report(.unreachable, startedAt: base)
        await waitUntil { monitor.serverUnreachable }

        // Order-sensitive: applied in reverse, this would end unreachable.
        monitor.report(.unreachable, startedAt: base + .seconds(2))
        monitor.report(.reachedServer, startedAt: base + .seconds(1))
        await waitUntil { !monitor.serverUnreachable }

        monitor.report(.reachedServer, startedAt: base + .seconds(3))
        monitor.report(.unreachable, startedAt: base + .seconds(4))
        await waitUntil { monitor.serverUnreachable }
    }

    /// A request issued while the link was dead reports `.unreachable` when its timeout
    /// fires — possibly after a newer request got through. That late report is about an
    /// older link, so it must not flip the flag; one from a later request still does.
    func testAnUnreachableReportFromBeforeAServerResponseIsStale() async {
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(FakePath()))
        let base = ContinuousClock.now

        monitor.report(.reachedServer, startedAt: base + .seconds(10))
        monitor.report(.unreachable, startedAt: base)  // started before the response
        monitor.report(.unreachable, startedAt: base + .seconds(11))
        await waitUntil { monitor.serverUnreachable }

        // The stale report alone, in isolation from the fresh one, never lands.
        monitor.report(.reachedServer, startedAt: base + .seconds(20))
        await waitUntil { !monitor.serverUnreachable }
        monitor.report(.unreachable, startedAt: base + .seconds(15))
        await waitAndConfirmNever { monitor.serverUnreachable }
    }

    func testAnUnreachableReportFromBeforeAPathCallbackIsStale() async {
        let fake = FakePath()
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(fake))
        let beforePath = ContinuousClock.now - .seconds(1)

        fake.onChange?(true)
        monitor.report(.unreachable, startedAt: beforePath)
        await waitAndConfirmNever { monitor.serverUnreachable }

        monitor.report(.unreachable, startedAt: .now)
        await waitUntil { monitor.serverUnreachable }
    }

    /// NWPath also fires for interface changes where both sides are satisfied (captive Wi-Fi →
    /// cellular). That is still a new path deserving a fresh judgment, but it is not a
    /// disconnect/reconnect, so tokens must not be invalidated.
    func testASameValuePathCallbackClearsEvidenceWithoutBumpingRevision() async {
        let fake = FakePath()
        let monitor = ConnectivityMonitor(monitoring: makeMonitoring(fake))
        let revision = monitor.revision

        monitor.report(.unreachable)
        await waitUntil { monitor.serverUnreachable }

        fake.onChange?(true)
        await waitUntil { !monitor.serverUnreachable }
        XCTAssertEqual(monitor.revision, revision)
        XCTAssertTrue(monitor.isReachable)
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
