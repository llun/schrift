@testable import Schrift

/// Keeps existing bridge tests synchronous; frame batching tests use a manual scheduler.
@MainActor
final class ImmediateLiveRemoteApplyScheduler: LiveRemoteApplyScheduling {
    func schedule(_ apply: @escaping @MainActor () -> Void) { apply() }
    func cancel() {}
}

@MainActor
final class ManualLiveRemoteApplyScheduler: LiveRemoteApplyScheduling {
    private(set) var pending: (@MainActor () -> Void)?
    private(set) var scheduleCount = 0

    func schedule(_ apply: @escaping @MainActor () -> Void) {
        scheduleCount += 1
        pending = apply
    }

    func cancel() { pending = nil }

    func advanceFrame() {
        let apply = pending
        pending = nil
        apply?()
    }
}
