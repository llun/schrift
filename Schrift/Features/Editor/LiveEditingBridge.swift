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
final class LiveEditingBridge {
    private let documentID: UUID
    private let viewModel: EditorViewModel
    private let collaboration: LiveReplicaProviding
    private let serverOrigin: String?

    /// BlockNote id -> `EditorBlock.id`. Rebuilt (via `reseedMap`) whenever it
    /// no longer covers the editor's current blocks — checked fresh on every
    /// `replicaDidChange()` by comparing `map`'s value set against
    /// `viewModel.blocks`' id set, rather than tracked with a separate "is this
    /// stale" flag. In steady state after an engaged apply the two sets are
    /// equal (`applyLiveRemoteChange` leaves `blocks` holding exactly the ids
    /// `liveChangeSet` resolved into `map`), so the check is a no-op; it fires
    /// on first engage (`map` is empty), on resume after a pause during which a
    /// structural edit landed, and — the case a boolean `isSeeded` flag
    /// couldn't catch — when a pause-free `install(...)` (a pull-to-refresh or
    /// server-wins reconcile) re-mints every `EditorBlock.id` while the doc
    /// stays clean, since that never flips `canEngageLiveEditing` false and so
    /// never reset a "seeded" flag either.
    private var map: [String: UUID] = [:]

    /// Whether the last `replicaDidChange()` call found a usable projection
    /// and (if engagement allowed it) is actively driving the editor. Exposed
    /// for the view to gate any "live" UI affordance and for tests.
    private(set) var isEngaged = false

    /// Whether this document is currently being driven by the live stream — the
    /// engagement condition evaluated FRESH (not the last-apply flag). The view gates
    /// the A5 fallback refetch on this so a stale REST body can't install over (and
    /// reset the caret of) content the bridge is keeping live.
    var isApplyingLiveContent: Bool {
        viewModel.canEngageLiveEditing && resolvedLiveDocument() != nil
    }

    init(documentID: UUID, viewModel: EditorViewModel, collaboration: LiveReplicaProviding, serverOrigin: String?) {
        self.documentID = documentID
        self.viewModel = viewModel
        self.collaboration = collaboration
        self.serverOrigin = serverOrigin
    }

    /// The current replica projected + rendered to editor blocks and markdown, or nil
    /// if the document isn't live-appliable right now (no replica / not synced / opaque /
    /// not round-trippable). The SINGLE engagement condition — `replicaDidChange` applies
    /// exactly this, and `isApplyingLiveContent` reports whether it exists, so the A5
    /// suppression gate can never disagree with what the bridge actually does.
    private func resolvedLiveDocument() -> (blocks: [ProjectedEditorBlock], markdown: String)? {
        guard let projected = collaboration.projectedReplica(for: documentID, interlinkingOrigin: serverOrigin),
            projected.isFullyRenderable,
            let rendered = YBlockProjection.renderedEditorDocument(projected)
        else { return nil }
        return rendered
    }

    /// Called by the view whenever `collaboration.replicaVersion(for:)`
    /// changes. Pulls the current projection and, only if engagement is
    /// allowed and the projection is safe to show, diffs it against the
    /// editor's current blocks and applies the result.
    func replicaDidChange() {
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
            return
        }

        // Not synced yet / opaque / can't self-verify as markdown: leave the
        // document exactly as it is and fall back to the signal-only refresh
        // path (A5) — there is nothing safe to diff against.
        guard let (rendered, markdown) = resolvedLiveDocument() else {
            isEngaged = false
            return
        }

        isEngaged = true

        // Re-seed when the identity map no longer matches the editor's current
        // blocks — e.g. `install(...)` (a pull-to-refresh / server-wins
        // reconcile) re-minted every `EditorBlock.id` underneath us while the
        // doc stayed clean, so the carried-forward map is keyed to dead ids. In
        // steady state after an engaged apply the two sets are equal, so this
        // is a no-op; it fires exactly when the editor's block identities were
        // replaced out from under the map. This subsumes first-engage (empty
        // map) and pause -> resume-after-edit, which is why there is no
        // separate "seeded" flag to track.
        if Set(viewModel.blocks.map(\.id)) != Set(map.values) {
            reseedMap(against: rendered)
        }

        let (change, newMap) = liveChangeSet(current: viewModel.blocks, projected: rendered, map: map)
        map = newMap

        // An empty diff means the editor already shows exactly what the
        // replica projects to (the common case right after first engaging
        // with matching content) — applying it would be a needless no-op
        // write to the save baseline, so it's skipped outright.
        if !change.changes.isEmpty {
            viewModel.applyLiveRemoteChange(change, projectedMarkdown: markdown, projectedTitle: nil)
        }
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
