import XCTest

@testable import Schrift

/// The offline banner's anti-flash rule: show after sustained evidence, hide after sustained
/// recovery, and let a flip back before the delay cancel the change. The sleep seam is replaced
/// by a gate the test releases, so the assertions are about *which delay was requested* and
/// *what happens when it elapses*, not about wall-clock timing.
@MainActor
final class DebouncedStatusTests: XCTestCase {
    private let showDelay = Duration.milliseconds(1500)
    private let hideDelay = Duration.milliseconds(1000)

    /// A fake `sleep`: records each requested duration and suspends until the test releases it.
    /// Cancellation resumes the waiter by throwing, like `Task.sleep`.
    private final class SleepGate: @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [Duration] = []
        private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
        private var nextID = 0
        private var cancelledIDs: Set<Int> = []

        var durations: [Duration] {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        func sleep(_ duration: Duration) async throws {
            let id: Int = {
                lock.lock()
                defer { lock.unlock() }
                requested.append(duration)
                nextID += 1
                return nextID
            }()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if cancelledIDs.contains(id) {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append((id, continuation))
                        lock.unlock()
                    }
                }
            } onCancel: {
                lock.lock()
                let match = waiters.first { $0.id == id }
                waiters.removeAll { $0.id == id }
                if match == nil { cancelledIDs.insert(id) }
                lock.unlock()
                match?.continuation.resume(throwing: CancellationError())
            }
        }

        /// Lets every sleep currently suspended run to completion.
        func releaseAll() {
            lock.lock()
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.continuation.resume() }
        }
    }

    private func makeStatus(_ gate: SleepGate) -> DebouncedStatus {
        DebouncedStatus(showDelay: showDelay, hideDelay: hideDelay, sleep: { try await gate.sleep($0) })
    }

    func testFirstInputAppliesImmediately() {
        let gate = SleepGate()
        let offlineAtOpen = makeStatus(gate)
        offlineAtOpen.update(true)
        XCTAssertTrue(offlineAtOpen.value, "a screen that opens offline says so without waiting")

        let onlineAtOpen = makeStatus(gate)
        onlineAtOpen.update(false)
        XCTAssertFalse(onlineAtOpen.value)
        XCTAssertTrue(gate.durations.isEmpty, "the initial input never waits")
    }

    func testEvidenceShowsOnlyOnceTheShowDelayElapses() async {
        let gate = SleepGate()
        let status = makeStatus(gate)
        status.update(false)

        status.update(true)
        await waitUntil { gate.durations.count == 1 }

        XCTAssertEqual(gate.durations, [showDelay])
        XCTAssertFalse(status.value, "nothing shows before the delay elapses")

        gate.releaseAll()
        await waitUntil { status.value }
    }

    func testRepeatedIdenticalInputRequestsOneSleepNotARestart() async {
        let gate = SleepGate()
        let status = makeStatus(gate)
        status.update(false)
        status.update(true)
        await waitUntil { gate.durations.count == 1 }

        // A view re-evaluating with the same signal must not push the deadline out.
        for _ in 0..<5 { status.update(true) }

        await waitAndConfirmNever { gate.durations.count > 1 }
        XCTAssertFalse(status.value)
        gate.releaseAll()
        await waitUntil { status.value }
        XCTAssertEqual(gate.durations, [showDelay])
    }

    func testRecoveryHidesOnlyOnceTheHideDelayElapses() async {
        let gate = SleepGate()
        let status = makeStatus(gate)
        status.update(true)

        status.update(false)
        await waitUntil { gate.durations.count == 1 }

        XCTAssertEqual(gate.durations, [hideDelay])
        XCTAssertTrue(status.value, "does not hide on the first clear")

        gate.releaseAll()
        await waitUntil { !status.value }
    }

    func testBriefEvidenceNeverShowsEvenIfTheSupersededSleepElapses() async {
        let gate = SleepGate()
        let status = makeStatus(gate)
        status.update(false)

        status.update(true)
        await waitUntil { gate.durations.count == 1 }
        status.update(false)
        gate.releaseAll()

        await waitAndConfirmNever { status.value }
    }

    func testABriefRecoveryDoesNotHideEvenIfTheSupersededSleepElapses() async {
        let gate = SleepGate()
        let status = makeStatus(gate)
        status.update(true)

        status.update(false)
        await waitUntil { gate.durations.count == 1 }
        status.update(true)
        gate.releaseAll()

        await waitAndConfirmNever { !status.value }
        XCTAssertEqual(gate.durations, [hideDelay], "flipping back to the shown value needs no new wait")
    }

    /// The one real-time check: the default `Task.sleep` seam is wired and does elapse.
    func testDefaultSleepSeamEventuallyShows() async {
        let status = DebouncedStatus(showDelay: .milliseconds(50), hideDelay: .milliseconds(50))
        status.update(false)

        status.update(true)

        await waitUntil { status.value }
    }
}
