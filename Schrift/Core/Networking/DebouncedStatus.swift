import Foundation

/// A two-sided debounce for a **display-only** flag, so status chrome (the offline banner)
/// does not flash on and off, pushing content down and back up, while the underlying signal
/// pulses — a transient transport failure on one slow request, a path flapping between
/// satisfied and unsatisfied.
///
/// The flag turns on only after the raw signal has been continuously true for `showDelay`,
/// and off only after it has been continuously false for `hideDelay`. A raw flip back before
/// the delay elapses cancels the pending change. Initial state is the raw value passed to the
/// first `update`, applied immediately: a screen that opens already offline should say so
/// rather than wait out the delay.
///
/// **Never feed this into anything that gates a control, a response (`permitsResponse`) or a
/// save.** Those keep their own signals; `OnlineAvailability.showsOfflineStatus` is likewise
/// status-only. The Work Offline preference is a deliberate user choice rather than evidence,
/// so callers show it immediately (`OnlineAvailability.isWorkOffline`) and debounce only the
/// path/transport evidence.
@MainActor
@Observable
final class DebouncedStatus {
    /// The debounced value the view draws.
    private(set) var value: Bool = false

    @ObservationIgnored private let showDelay: Duration
    @ObservationIgnored private let hideDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var hasReceivedInput = false
    @ObservationIgnored private var latestRaw = false
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(
        showDelay: Duration = .milliseconds(1500),
        hideDelay: Duration = .milliseconds(1000),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.showDelay = showDelay
        self.hideDelay = hideDelay
        self.sleep = sleep
    }

    /// Feeds the live raw signal. Idempotent for an unchanged input, so a view can call it
    /// from `onChange(of:initial:)` without churn.
    func update(_ raw: Bool) {
        if !hasReceivedInput {
            hasReceivedInput = true
            latestRaw = raw
            value = raw
            return
        }
        guard raw != latestRaw else { return }
        latestRaw = raw
        pending?.cancel()
        pending = nil
        // Already showing what the raw signal now says: nothing to wait for.
        guard raw != value else { return }
        let delay = raw ? showDelay : hideDelay
        let sleep = self.sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.value = raw
            self.pending = nil
        }
    }
}
