import Foundation

/// How long a silent re-login may run before the sheet takes over, however it is going.
let silentReauthenticationTimeout: Duration = .seconds(15)

/// How long the hidden login may sit on a page it stopped on (`WebLoginProgress.stopped`)
/// before the sheet takes over. Not zero, because an IdP answering with
/// `response_mode=form_post` finishes loading a page whose script then submits it back to the
/// server — a page that looks stopped and is not; the submission's `.navigating` cancels the
/// wait. A real login form never moves on by itself.
let silentReauthenticationStopGrace: Duration = .seconds(2)

/// Decides when a silent re-login has failed and must hand over to the sheet — the timing
/// half of `SilentReauthenticationView`, kept out of the view so it can be tested.
///
/// It escalates, exactly once, when: the login stays stopped for the grace period, the whole
/// attempt outlives the timeout, or the confirmation after the login fails. Once the web view
/// has reached the server (`.reachedServer`) neither timer can fire any more — the attempt is
/// then the confirmation's to win or lose — which is what keeps a slow `/users/me/` from
/// flashing the sheet up just before the silent sign-in closes it again.
@MainActor
@Observable
final class SilentReauthenticationAttempt {
    private(set) var hasReachedServer = false
    private(set) var didEscalate = false

    private let timeout: Duration
    private let stopGrace: Duration
    private let escalate: @MainActor () -> Void
    private var timeoutTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?

    init(
        timeout: Duration = silentReauthenticationTimeout,
        stopGrace: Duration = silentReauthenticationStopGrace,
        escalate: @escaping @MainActor () -> Void
    ) {
        self.timeout = timeout
        self.stopGrace = stopGrace
        self.escalate = escalate
    }

    /// Starts the overall timeout. Idempotent.
    func start() {
        guard timeoutTask == nil, !didEscalate else { return }
        let timeout = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.escalateUnlessArrived()
        }
    }

    /// The app came back to the foreground. The timeout's clock kept running while it was
    /// suspended, and so was the web view, so the time spent away is not the login stalling:
    /// give it a fresh timeout.
    func restartTimeout() {
        guard !didEscalate, !hasReachedServer else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        start()
    }

    func handle(_ progress: WebLoginProgress) {
        switch progress {
        case .navigating:
            graceTask?.cancel()
            graceTask = nil
        case .stopped:
            guard !hasReachedServer, !didEscalate else { return }
            graceTask?.cancel()
            let grace = stopGrace
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                self?.escalateUnlessArrived()
            }
        case .reachedServer:
            hasReachedServer = true
            cancelTimers()
        }
    }

    /// The confirming `/users/me/` has answered. Success needs nothing here — signing in ends
    /// the attempt — while failure means the user has to be asked.
    func confirmationFinished(succeeded: Bool) {
        guard !succeeded else { return }
        fire()
    }

    /// The attempt is over (the view went away); no timer may fire after it.
    func cancel() {
        cancelTimers()
    }

    private func escalateUnlessArrived() {
        guard !hasReachedServer else { return }
        fire()
    }

    private func fire() {
        guard !didEscalate else { return }
        didEscalate = true
        cancelTimers()
        escalate()
    }

    private func cancelTimers() {
        timeoutTask?.cancel()
        timeoutTask = nil
        graceTask?.cancel()
        graceTask = nil
    }
}
