import Foundation

/// Narrow seam over `DocumentCollaborationManager` so `LiveEditingBridge` is
/// unit-testable without a real socket/replica. `DocumentCollaborationManager`
/// conforms via the plain extension below — its Task-2 methods already match
/// this shape exactly.
@MainActor
protocol LiveReplicaProviding: AnyObject {
    /// A monotonic counter that advances each time an inbound update integrates
    /// cleanly into the document's replica. The view observes this (not a
    /// push/delegate callback) and calls `replicaDidChange()` whenever it ticks.
    func replicaVersion(for documentID: UUID) -> Int
    /// The document's live replica projected into BlockNote-vocabulary blocks,
    /// or `nil` when there is nothing safe to project yet (no replica, not
    /// synced, fail-safed, or still holding unintegrated pending structs/deletes).
    func projectedReplica(for documentID: UUID, interlinkingOrigin: String?) -> ProjectedDocument?
    /// Fires synchronously with integration. The bridge invalidates its write baseline
    /// immediately, then coalesces projection/UI work until the next frame. Local mutations
    /// flush that pending frame before reading indices or forwarding an edit.
    func setReplicaObserver(_ observer: (() -> Void)?, for documentID: UUID)

    // MARK: - Write side (C2c)

    /// Includes abilities.update as well as replica health and initial sync.
    func canWriteReplica(for documentID: UUID) -> Bool

    /// Applies one local BlockNote edit to the replica and broadcasts the resulting
    /// incremental Yjs update; throws when the replica is not writable or malformed
    /// (which latches fail-safe). `old` must be the replica's current projection.
    func applyLocalEdit(old: [BlockNoteBlock], new: [BlockNoteBlock], for documentID: UUID) throws -> Data
    /// A full-state Yjs v1 snapshot for the classic save path, or `nil` when the
    /// replica is not writable (no replica / not initial-synced / pending structs /
    /// fail-safed). A `nil` return is the TOP SAFETY gate: never PATCH.
    func encodeSnapshotForSave(for documentID: UUID) -> Data?
    /// True once an inbound update failed to decode/apply — the replica must never
    /// drive the editor again.
    func replicaIsFailSafe(for documentID: UUID) -> Bool
    /// True when the replica has un-integrated pending structs/deletes, or there is
    /// no replica — nothing safe to write on top of.
    func hasPendingStructs(for documentID: UUID) -> Bool
}

/// C1's per-editor live-write coordinator: owns the BlockNote-id ⇄
/// `EditorBlock.id` identity map, decides whether a remote change may be
/// applied right now, diffs the projected replica against the editor's
/// current blocks, and drives `EditorViewModel.applyLiveRemoteChange`.
///
/// This is the read side of the C1 bridge — C2 adds the write path (local
/// edits -> outgoing Yjs updates). Nothing here touches a socket or a `YDoc`
/// directly; both are reached only through the injected `LiveReplicaProviding`
/// seam, which keeps this class testable with a scripted fake.
@MainActor
@Observable
final class LiveEditingBridge: EditorLiveWriteCoordinating {
    private let documentID: UUID
    private let viewModel: EditorViewModel
    private let collaboration: LiveReplicaProviding
    private let serverOrigin: String?
    private let remoteApplyScheduler: LiveRemoteApplyScheduling
    private var hasPendingRemoteApply = false
    private var remoteApplyGeneration = 0
    private var remoteAppliesStopped = false
    private var observesReplica = false
    private var appliedReplicaVersion: Int?
    private var projectionIsFullyModeled = false

    /// BlockNote id -> `EditorBlock.id`. Rebuilt (via `reseedMap`) whenever it
    /// no longer covers the editor's current blocks — checked fresh on every
    /// remote apply by comparing `map`'s value set against
    /// `viewModel.blocks`' id set, rather than tracked with a separate "is this
    /// stale" flag. In steady state after an engaged apply the two sets are
    /// equal (`applyLiveRemoteChange` leaves `blocks` holding exactly the ids
    /// `liveChangeSet` resolved into `map`), so the check is a no-op; it fires
    /// on first engage (`map` is empty), on resume after a pause during which a
    /// structural edit landed, and — the case a boolean `isSeeded` flag
    /// couldn't catch — when a pause-free `install(...)` (a pull-to-refresh or
    /// server-wins reconcile) re-identifies every changed block (only unchanged
    /// blocks keep their `EditorBlock.id`) while the doc stays clean, since
    /// that never flips `canEngageLiveEditing` false and so never reset a
    /// "seeded" flag either.
    private var map: [String: UUID] = [:]

    /// The replica's current projection expressed as `[BlockNoteBlock]` (the `old` for
    /// the next `applyLocalEdit`). Built from the editor's own blocks the moment they
    /// reflect the projection — captured on every successful remote frame and
    /// re-synced after every `applyLiveRemoteChange`. Invalidated synchronously on each
    /// remote notification (`nil` while a frame is pending or the bridge is disengaged),
    /// so no forward can read a pre-update baseline. Local mutations flush first.
    /// Editor ids are stable within a session, so a survivor keeps its id across
    /// forwards and reconciles in place instead of a whole-document rebuild.
    private var lastAppliedBlocks: [BlockNoteBlock]?

    /// The pending ~60 s snapshot debounce (cancel-and-reschedule on each forward).
    private var snapshotTask: Task<Void, Never>?
    /// True while un-snapshotted local forwards exist; `flushPendingLiveSnapshot` only
    /// fires when set.
    private var hasPendingSnapshot = false
    private let snapshotInterval: Duration

    /// Whether the last remote frame found a usable projection
    /// and (if engagement allowed it) is actively driving the editor. Exposed
    /// for the view to gate any "live" UI affordance and for tests.
    private(set) var isEngaged = false

    /// Suppresses stale REST installs while engaged or awaiting a remote frame. Fidelity
    /// is checked by the frame, not re-projected by every SwiftUI read of this gate. Unsafe
    /// replicas and local work release the gate immediately; unrenderable content releases
    /// it when the frame resolves and falls back to A5.
    var isApplyingLiveContent: Bool {
        // Never project from a SwiftUI gate: that would undo the frame coalescing.
        // While a frame is pending, reserve the screen for it; the frame re-checks fidelity.
        viewModel.canEngageLiveEditing && !remoteAppliesStopped
            && (isEngaged || hasPendingRemoteApply)
            && !collaboration.replicaIsFailSafe(for: documentID)
            && !collaboration.hasPendingStructs(for: documentID)
    }

    init(
        documentID: UUID, viewModel: EditorViewModel, collaboration: LiveReplicaProviding,
        serverOrigin: String?, remoteApplyScheduler: LiveRemoteApplyScheduling? = nil,
        snapshotInterval: Duration = .seconds(60)
    ) {
        self.documentID = documentID
        self.viewModel = viewModel
        self.collaboration = collaboration
        self.serverOrigin = serverOrigin
        self.snapshotInterval = snapshotInterval
        self.remoteApplyScheduler = remoteApplyScheduler ?? DisplayLinkRemoteApplyScheduler()
    }

    /// Registers on every live-session (re)acquisition, not at construction. The
    /// observer synchronously invalidates the writable baseline in the integrate turn;
    /// only projection, diffing and UI apply wait for a frame. A local mutation flushes
    /// that frame first (`prepareForLocalEdit`), before it can change the editor's blocks.
    /// The manager owns the per-document observer and drops it at linger teardown. This
    /// bridge can outlive that entry in SwiftUI @State, so reopening must register again.
    /// A weak capture avoids retaining the editor through the manager.
    func registerReplicaObserver() {
        remoteAppliesStopped = false
        observesReplica = true
        appliedReplicaVersion = nil
        collaboration.setReplicaObserver({ [weak self] in self?.replicaDidChange() }, for: documentID)
        // A lingered entry may already have a replica without another version edge
        // on reopening. Catch up before the retained bridge can forward local edits.
        if collaboration.replicaVersion(for: documentID) > 0 { replicaDidChange() }
    }

    /// Project/render once per remote frame. The result must be safe to round-trip
    /// through the editor before it can engage; only fully modeled content can write.
    private func resolvedLiveDocument() -> (blocks: [ProjectedEditorBlock], markdown: String)? {
        guard let projected = collaboration.projectedReplica(for: documentID, interlinkingOrigin: serverOrigin),
            projected.isFullyRenderable,
            let rendered = YBlockProjection.renderedEditorDocument(projected)
        else { return nil }
        projectionIsFullyModeled = projected.isFullyModeled
        return rendered
    }

    /// Called synchronously by the replica observer and again by SwiftUI's deferred
    /// version notification. Invalidate writes now; queue at most one latest-state apply.
    func replicaDidChange() {
        guard !remoteAppliesStopped else { return }
        // The observer and SwiftUI's later notification describe the same integration.
        if observesReplica, appliedReplicaVersion == collaboration.replicaVersion(for: documentID),
            isEngaged, lastAppliedBlocks != nil
        {
            return
        }
        // This bookkeeping MUST run synchronously with the integrate. The old baseline
        // is no longer writable, even though its projection/UI apply waits for a frame.
        lastAppliedBlocks = nil
        guard !hasPendingRemoteApply else { return }
        hasPendingRemoteApply = true
        remoteApplyGeneration += 1
        let generation = remoteApplyGeneration
        remoteApplyScheduler.schedule { [weak self] in
            guard let self, self.remoteApplyGeneration == generation else { return }
            self.applyPendingRemoteChange()
        }
    }

    /// Runs before any editor mutation, never from the post-mutation forward. A local
    /// action is the sole exception to waiting for the next display frame.
    func prepareForLocalEdit() {
        guard hasPendingRemoteApply else { return }
        remoteApplyScheduler.cancel()
        applyPendingRemoteChange()
    }

    /// Navigation teardown cancels both the frame and its observer. Reacquisition
    /// re-registers the observer on the existing bridge and re-enables frame delivery.
    func stopRemoteApplies() {
        remoteApplyScheduler.cancel()
        remoteApplyGeneration += 1
        hasPendingRemoteApply = false
        remoteAppliesStopped = true
        observesReplica = false
        collaboration.setReplicaObserver(nil, for: documentID)
        isEngaged = false
        lastAppliedBlocks = nil
        appliedReplicaVersion = nil
    }

    private func applyPendingRemoteChange() {
        guard hasPendingRemoteApply, !remoteAppliesStopped else { return }
        hasPendingRemoteApply = false
        remoteApplyGeneration += 1
        projectionIsFullyModeled = false
        // The user's own local work always wins — a live apply must never
        // race or clobber it (see `canEngageLiveEditing`'s doc comment for the
        // exhaustive list of what "local work" covers). On pause the map is
        // left as-is: whatever happens while paused (a local edit, a save, a
        // conflict) may leave the editor's blocks no longer matching what the
        // map remembers, but the staleness check below re-evaluates that fresh
        // on the next engage rather than needing a flag reset here. The editor
        // itself is left untouched — dropping engagement is not the same as
        // clearing content.
        guard viewModel.canEngageLiveEditing else {
            isEngaged = false
            lastAppliedBlocks = nil  // writes must not flow while disengaged
            return
        }

        // Not synced yet / opaque / can't self-verify as markdown: leave the
        // document exactly as it is and fall back to the signal-only refresh
        // path (A5) — there is nothing safe to diff against.
        guard let (rendered, markdown) = resolvedLiveDocument() else {
            isEngaged = false
            lastAppliedBlocks = nil
            // The remote-change signal may have suppressed A5 while this frame was
            // pending. Re-open that path if the latest projection cannot drive the UI.
            if observesReplica { viewModel.noteRemoteChange() }
            return
        }

        isEngaged = true
        appliedReplicaVersion = collaboration.replicaVersion(for: documentID)

        // Re-seed when the identity map no longer matches the editor's current
        // blocks — e.g. `install(...)` (a pull-to-refresh / server-wins
        // reconcile) gave every changed block a fresh `EditorBlock.id`
        // underneath us while the doc stayed clean, so part of the
        // carried-forward map is keyed to dead ids. (Any content change
        // re-identifies or drops at least one block, so the id sets differ;
        // an install that changed nothing leaves every id, and the map, valid.) In
        // steady state after an engaged apply the two sets are equal, so this
        // is a no-op; it fires exactly when the editor's block identities were
        // replaced out from under the map. This subsumes first-engage (empty
        // map) and pause -> resume-after-edit, which is why there is no
        // separate "seeded" flag to track.
        if Set(viewModel.blocks.map(\.id)) != Set(map.values) {
            reseedMap(against: rendered)
        }

        let (change, newMap) = liveChangeSet(current: viewModel.publishableBlocks, projected: rendered, map: map)
        map = newMap

        // An empty diff means the editor already shows exactly what the
        // replica projects to (the common case right after first engaging
        // with matching content) — applying it would be a needless no-op
        // write to the save baseline, so it's skipped outright.
        if !change.changes.isEmpty {
            viewModel.applyLiveRemoteChange(change, projectedMarkdown: markdown, projectedTitle: nil)
        }

        // Capture the write baseline once the editor reflects the projection — the `old`
        // for the next forward. Done on every engage (including an empty diff) and after
        // every remote apply, so `old` always describes the replica's current projection.
        // A local forward advances this itself. Remote notifications invalidate it in the
        // integrate turn, and a pre-mutation flush restores it before the next local diff.
        lastAppliedBlocks = MarkdownYjs.blockNoteBlocks(from: viewModel.publishableBlocks)
    }

    // MARK: - Live write path (C2c)

    /// The last applied projection's modeled flag is valid until the next synchronous
    /// remote notification invalidates the baseline. Local forwards do not change inbound
    /// versions (echo suppression); fail-safe/pending-struct gates are always read fresh.
    /// The photo-insert path asks this before acting, without projecting or mutating.
    var isHandlingLocalEditsLive: Bool {
        viewModel.canEngageLiveEditing && projectionIsFullyModeled
            && !hasPendingRemoteApply && lastAppliedBlocks != nil
            && collaboration.canWriteReplica(for: documentID)
            && !collaboration.replicaIsFailSafe(for: documentID)
            && !collaboration.hasPendingStructs(for: documentID)
    }

    func forwardLocalEdit() -> Bool {
        guard isHandlingLocalEditsLive, let old = lastAppliedBlocks else { return false }

        // `new` is built from the editor's own id-stable blocks (Task 1) — NOT re-parsed
        // markdown, which would mint fresh ids and force a whole-document rebuild each edit.
        let new = MarkdownYjs.blockNoteBlocks(from: viewModel.publishableBlocks)
        guard (try? collaboration.applyLocalEdit(old: old, new: new, for: documentID)) != nil else {
            // notWritable, or a malformed replica that just fail-safed. Downgrade to
            // classic for this edit; the classic save persists the current content, and
            // the fail-safed replica keeps every later edit downgrading too.
            return false
        }
        // Advance the baseline. A local forward does NOT bump the inbound `replicaVersion`
        // (C2a echo suppression), so `replicaDidChange`/`applyLiveRemoteChange` never re-fire
        // on our own edit — no self-echo loop, and this is the only place that advances it
        // between remote applies.
        lastAppliedBlocks = new
        hasPendingSnapshot = true
        scheduleSnapshot()
        return true
    }

    /// Fire any pending debounced live snapshot immediately (Done / background /
    /// disappear). A no-op when nothing is pending.
    func flushPendingLiveSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = nil
        guard hasPendingSnapshot else { return }
        fireSnapshot()
    }

    /// Cancel-and-reschedule the ~60 s debounce. Uses the injected `snapshotInterval`
    /// (short in tests) and `Task.sleep` — never a wall clock — so the fire is
    /// deterministic and cancels cleanly.
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        let interval = snapshotInterval
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.fireSnapshot()
        }
    }

    private func fireSnapshot() {
        hasPendingSnapshot = false
        snapshotTask = nil
        // TOP SAFETY: a nil snapshot (un-synced / pending structs / fail-safed) means there
        // is no trustworthy full state — never PATCH, or a half-synced replica would wipe the
        // document. Re-check `isFullyModeled` here too: the projection can have gone lossy
        // between the forward and this fire. `snapshot` and `markdown` are both read from the
        // replica (not the editor), so the persisted body is exactly our replica's render
        // of the bytes. If either fails, skip — the un-snapshotted work is still on screen
        // and a later classic downgrade save persists it.
        guard let snapshot = collaboration.encodeSnapshotForSave(for: documentID),
            let projection = collaboration.projectedReplica(for: documentID, interlinkingOrigin: serverOrigin),
            projection.isFullyModeled,
            let markdown = YBlockProjection.projectedMarkdown(projection)
        else { return }
        viewModel.persistLiveSnapshot(snapshot, projectedMarkdown: markdown)
    }

    /// Seeds `map` by pairing the editor's *current* blocks to the freshly
    /// rendered projection by position. This is safe exactly when the editor
    /// was last clean against replica-equivalent content — `canEngageLiveEditing`
    /// guarantees there is no local work in flight, and the two block lists
    /// were built from the same underlying document whenever they agree in
    /// count, so pairing by index recovers the same identity a full diff
    /// would have produced, without minting fresh ids for blocks the editor
    /// already knows. When the counts differ (the replica moved while this
    /// bridge wasn't engaged, or this is a genuinely first sync), position
    /// pairing can't be trusted, so seeding starts from an empty map instead:
    /// `liveChangeSet` then mints a fresh id for every projected block and the
    /// resulting diff reconverges the editor to the replica on its own,
    /// exactly as it would for a first engage with completely new content.
    private func reseedMap(against rendered: [ProjectedEditorBlock]) {
        let current = viewModel.blocks
        guard current.count == rendered.count else {
            map = [:]
            return
        }
        var seeded: [String: UUID] = [:]
        seeded.reserveCapacity(rendered.count)
        for (index, block) in rendered.enumerated() {
            seeded[block.blockNoteID] = current[index].id
        }
        map = seeded
    }
}

/// `DocumentCollaborationManager`'s Task-2 accessors already match
/// `LiveReplicaProviding` exactly, so no adapter code is needed.
extension DocumentCollaborationManager: LiveReplicaProviding {}
