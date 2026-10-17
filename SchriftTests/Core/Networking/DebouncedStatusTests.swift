import XCTest

@testable import Schrift

/// The offline banner's anti-flash rule: show after sustained evidence, hide after sustained
/// recovery, and let a flip back before the delay cancel the change. Short real delays, since
/// the type is about elapsed time; ordering assertions use `waitUntil` / `waitAndConfirmNever`.
@MainActor
final class DebouncedStatusTests: XCTestCase {
    private func makeStatus() -> DebouncedStatus {
        DebouncedStatus(showDelay: .milliseconds(150), hideDelay: .milliseconds(100))
    }

    func testFirstInputAppliesImmediately() {
        let offlineAtOpen = makeStatus()
        offlineAtOpen.update(true)
        XCTAssertTrue(offlineAtOpen.value, "a screen that opens offline says so without waiting")

        let onlineAtOpen = makeStatus()
        onlineAtOpen.update(false)
        XCTAssertFalse(onlineAtOpen.value)
    }

    func testSustainedEvidenceShowsAfterTheDelayNotBefore() async {
        let status = makeStatus()
        status.update(false)

        status.update(true)

        XCTAssertFalse(status.value)
        await waitUntil { status.value }
    }

    func testBriefEvidenceNeverShows() async {
        let status = makeStatus()
        status.update(false)

        status.update(true)
        status.update(false)

        await waitAndConfirmNever(timeout: 0.4) { status.value }
    }

    func testSustainedRecoveryHidesAfterTheDelay() async {
        let status = makeStatus()
        status.update(true)

        status.update(false)

        XCTAssertTrue(status.value, "does not hide on the first clear")
        await waitUntil { !status.value }
    }

    func testABriefRecoveryDoesNotHide() async {
        let status = makeStatus()
        status.update(true)

        status.update(false)
        status.update(true)

        await waitAndConfirmNever(timeout: 0.4) { !status.value }
    }

    func testRepeatedIdenticalInputDoesNotRestartTheTimer() async {
        let status = makeStatus()
        status.update(false)
        status.update(true)

        // A view re-evaluating with the same signal must not push the deadline out forever.
        for _ in 0..<5 {
            status.update(true)
            try? await Task.sleep(for: .milliseconds(20))
        }

        await waitUntil { status.value }
    }
}
