import Foundation
import Observation

/// Debounces a native replica save the way the classic editor debounces its
/// flush: a trailing interval, capped by a total deferral so a long burst still
/// persists periodically. The journal is already durable per keystroke; this
/// only decides when to hand the captured outbox to the coordinator.
///
/// A capture that cannot be prepared is not retried: the journal bytes stay on
/// disk, but nothing can send them until the refusal clears, so authoring is
/// frozen and the caller reports a truthful failure.
@MainActor @Observable
final class NativeReplicaSaveScheduler {
    /// Continuous typing keeps restarting the trailing debounce; cap the total
    /// deferral so a long burst still persists periodically.
    static let maxDeferral: TimeInterval = 30

    private let interval: Duration
    private let enqueue: () throws -> Void
    private let onFailure: () -> Void
    private var task: Task<Void, Never>?
    private var dirtySince: Date?
    /// Durable journal bytes the coordinator has not been handed yet. The view
    /// reports them as saved on this device, never as synced.
    private(set) var hasPendingSave = false
    private(set) var isFrozen = false

    init(
        interval: Duration = .seconds(10),
        enqueue: @escaping () throws -> Void,
        onFailure: @escaping () -> Void
    ) {
        self.interval = interval
        self.enqueue = enqueue
        self.onFailure = onFailure
    }

    /// Called after a command's bytes are durable. Never throws or enqueues
    /// synchronously: it runs inside the engine's durability callback, and a
    /// scheduling failure must not undo a persisted keystroke.
    func schedule() {
        guard !isFrozen else { return }
        hasPendingSave = true
        let now = Date()
        if dirtySince == nil { dirtySince = now }
        let overdue = dirtySince.map { now.timeIntervalSince($0) >= Self.maxDeferral } ?? false
        let delay: Duration = overdue ? .zero : interval
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Hand the captured outbox to the coordinator now. A no-op when nothing
    /// has been scheduled since the last flush, so a close with no edits never
    /// enqueues an empty save.
    func flush() {
        task?.cancel()
        task = nil
        dirtySince = nil
        guard hasPendingSave, !isFrozen else { return }
        hasPendingSave = false
        do {
            try enqueue()
        } catch {
            isFrozen = true
            onFailure()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        dirtySince = nil
        hasPendingSave = false
    }
}
