import XCTest

@testable import Schrift

@MainActor
final class NativeReplicaSaveSchedulerTests: XCTestCase {
    func testFailedHandoverRearmsOneTimerAndEnqueuesWithoutNewKeystroke() async {
        let gate = SleepGate()
        var attempts = 0
        var failures: [Error] = []
        let scheduler = NativeReplicaSaveScheduler(
            interval: .seconds(10),
            sleep: { try await gate.sleep($0) },
            enqueue: {
                attempts += 1
                return attempts >= 2
            },
            onFailure: { failures.append($0) }
        )
        defer { scheduler.cancel() }

        scheduler.schedule()
        await waitUntil { gate.pendingCount == 1 }
        XCTAssertEqual(gate.durations, [.seconds(10)])
        XCTAssertTrue(scheduler.hasPendingSave)

        // First flush returns false (e.g. account unknown): stays pending and re-arms one interval.
        gate.releaseNext()
        await waitUntil { attempts == 1 && gate.pendingCount == 1 }
        XCTAssertTrue(scheduler.hasPendingSave)
        XCTAssertEqual(gate.durations, [.seconds(10), .seconds(10)], "must re-arm normal interval, no busy loop")
        XCTAssertEqual(gate.pendingCount, 1)

        // Second flush succeeds with no new keystroke.
        gate.releaseNext()
        await waitUntil { attempts == 2 && !scheduler.hasPendingSave }
        XCTAssertEqual(gate.pendingCount, 0)
        XCTAssertEqual(gate.durations.count, 2)
        XCTAssertTrue(failures.isEmpty)
    }

    func testManualFlushFailureRearmsIntervalAndCancelClearsIt() async {
        let gate = SleepGate()
        var attempts = 0
        let scheduler = NativeReplicaSaveScheduler(
            interval: .seconds(10),
            sleep: { try await gate.sleep($0) },
            enqueue: {
                attempts += 1
                return false
            },
            onFailure: { XCTFail("unexpected failure: \($0)") }
        )
        defer { scheduler.cancel() }

        scheduler.schedule()
        await waitUntil { gate.pendingCount == 1 }

        scheduler.flush()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(scheduler.hasPendingSave)
        await waitUntil { gate.durations.count == 2 && gate.pendingCount == 1 }
        XCTAssertEqual(gate.durations, [.seconds(10), .seconds(10)])

        scheduler.cancel()
        await waitUntil { gate.pendingCount == 0 }
        XCTAssertFalse(scheduler.hasPendingSave)
        gate.releaseAll()
        XCTAssertEqual(attempts, 1)
    }
}
