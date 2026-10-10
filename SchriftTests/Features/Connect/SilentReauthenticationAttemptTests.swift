import XCTest

@testable import Schrift

/// Timing is real but tiny: a long duration stands for "never within this test", a short one
/// for "soon". `waitAndConfirmNever` outlasts every short duration used here.
@MainActor
final class SilentReauthenticationAttemptTests: XCTestCase {
    private var escalations = 0

    override func setUp() {
        super.setUp()
        escalations = 0
    }

    private func makeAttempt(
        timeout: Duration = .seconds(60), stopGrace: Duration = .seconds(60)
    ) -> SilentReauthenticationAttempt {
        SilentReauthenticationAttempt(timeout: timeout, stopGrace: stopGrace) { [weak self] in
            self?.escalations += 1
        }
    }

    func testStayingStoppedPastTheGraceEscalates() async {
        let attempt = makeAttempt(stopGrace: .milliseconds(50))
        attempt.start()

        attempt.handle(.stopped)

        await waitUntil { self.escalations == 1 }
    }

    /// A `form_post` page finishes, then submits itself: the submission is progress.
    func testANewLoadWithinTheGraceCancelsIt() async {
        let attempt = makeAttempt(stopGrace: .milliseconds(100))
        attempt.start()

        attempt.handle(.stopped)
        attempt.handle(.navigating)

        await waitAndConfirmNever { self.escalations > 0 }
    }

    func testRunningOutOfTimeEscalates() async {
        let attempt = makeAttempt(timeout: .milliseconds(50))

        attempt.start()

        await waitUntil { self.escalations == 1 }
    }

    /// The gap between arriving back on the server and the confirmation answering must not be
    /// read as a stall — that is what flashed the sheet just before a silent sign-in closed it.
    func testReachingTheServerStopsBothTimers() async {
        let attempt = makeAttempt(timeout: .milliseconds(50), stopGrace: .milliseconds(50))
        attempt.start()
        attempt.handle(.stopped)

        attempt.handle(.reachedServer)

        await waitAndConfirmNever { self.escalations > 0 }
    }

    func testAStopAfterReachingTheServerIsIgnored() async {
        let attempt = makeAttempt(stopGrace: .milliseconds(50))
        attempt.start()
        attempt.handle(.reachedServer)

        attempt.handle(.stopped)

        await waitAndConfirmNever { self.escalations > 0 }
    }

    func testAFailedConfirmationEscalates() {
        let attempt = makeAttempt()
        attempt.start()
        attempt.handle(.reachedServer)

        attempt.confirmationFinished(succeeded: false)

        XCTAssertEqual(escalations, 1)
    }

    func testASuccessfulConfirmationDoesNotEscalate() async {
        let attempt = makeAttempt(timeout: .milliseconds(50))
        attempt.start()
        attempt.handle(.reachedServer)

        attempt.confirmationFinished(succeeded: true)

        await waitAndConfirmNever { self.escalations > 0 }
    }

    func testEscalatesAtMostOnce() async {
        let attempt = makeAttempt(timeout: .milliseconds(50), stopGrace: .milliseconds(10))
        attempt.start()
        attempt.handle(.stopped)
        await waitUntil { self.escalations == 1 }

        attempt.confirmationFinished(succeeded: false)
        attempt.handle(.stopped)

        await waitAndConfirmNever { self.escalations > 1 }
    }

    func testCancellingStopsEveryTimer() async {
        let attempt = makeAttempt(timeout: .milliseconds(50), stopGrace: .milliseconds(50))
        attempt.start()
        attempt.handle(.stopped)

        attempt.cancel()

        await waitAndConfirmNever { self.escalations > 0 }
    }

    /// Time spent suspended in the background is not the login stalling.
    func testPausingStopsTheTimersUntilResumed() async {
        let attempt = makeAttempt(timeout: .milliseconds(100), stopGrace: .milliseconds(50))
        attempt.start()
        attempt.handle(.stopped)

        attempt.pause()
        await waitAndConfirmNever(timeout: 0.4) { self.escalations > 0 }

        attempt.resume()
        await waitUntil { self.escalations == 1 }
    }

    func testResumingGivesAFreshTimeout() async {
        let attempt = makeAttempt(timeout: .seconds(1))
        attempt.start()
        try? await Task.sleep(for: .milliseconds(500))

        attempt.resume()

        // Well past the original deadline, short of the fresh one.
        await waitAndConfirmNever(timeout: 0.8) { self.escalations > 0 }
        await waitUntil { self.escalations == 1 }
    }

    /// A login form the app left on is still a stop when it comes back, and nothing will report
    /// it again — the grace, not the whole timeout, must decide.
    func testResumingRearmsTheGraceForALoginLeftAtRest() async {
        let attempt = makeAttempt(stopGrace: .milliseconds(50))
        attempt.start()
        attempt.handle(.stopped)
        attempt.pause()

        attempt.resume()

        await waitUntil(timeout: 1) { self.escalations == 1 }
    }

    /// A page that finishes just as the app leaves must not start a grace that runs while the
    /// web view is asleep.
    func testAStopReportedWhilePausedWaitsForResume() async {
        let attempt = makeAttempt(stopGrace: .milliseconds(50))
        attempt.start()
        attempt.pause()

        attempt.handle(.stopped)

        await waitAndConfirmNever { self.escalations > 0 }
        attempt.resume()
        await waitUntil(timeout: 1) { self.escalations == 1 }
    }

    func testAnAttemptPausedBeforeItStartsDoesNotTimeOut() async {
        let attempt = makeAttempt(timeout: .milliseconds(50))
        attempt.pause()

        attempt.start()

        await waitAndConfirmNever { self.escalations > 0 }
    }
}
