import Foundation
import Observation

/// Whether the "Back to top" offer should remove itself after a few seconds. It must not while
/// VoiceOver is running: the user may not have reached the pill before it would vanish.
func backToTopAutoDismisses(voiceOverEnabled: Bool) -> Bool { !voiceOverEnabled }

/// What to do with a decided restore, given which reading rows have reported a laid-out frame.
enum ReadingRestoreScrollStep: Equatable {
    /// No row has been laid out yet: content that has only just arrived is in the hierarchy but
    /// not measured, and a `scrollTo` now has no frame to scroll to. Keep the restore pending.
    case wait
    /// The target row is laid out: scroll now.
    case scroll
    /// Rows are laid out but the target is not among them (a completed checklist item that
    /// "Hide completed" leaves out). The reading surface is a plain `VStack`, laid out in full,
    /// so it is not coming: drop the restore rather than offer "Back to top" from the top.
    case abandon
}

/// When a decided restore may scroll. See `ReadingRestoreScrollStep`.
func readingRestoreScrollStep(target: UUID, laidOutBlockIDs: Set<UUID>) -> ReadingRestoreScrollStep {
    guard !laidOutBlockIDs.isEmpty else { return .wait }
    return laidOutBlockIDs.contains(target) ? .scroll : .abandon
}

/// One open document's "continue reading" state: restores the saved position once when the
/// content first appears, remembers where the reader is when they leave, and owns the
/// short-lived "Back to top" offer that follows a restore.
///
/// A plain reference held in `@State` by `EditorView`, like `EditorScrollAnchorStore`. Only
/// `offersBackToTop` is observed — everything else is `@ObservationIgnored`, so the editor is
/// not invalidated by bookkeeping the screen never draws.
///
/// **Nothing is written until the restore has been decided.** Between the screen appearing and
/// the content arriving the viewport sits at the top; persisting then would replace the very
/// position about to be restored with "the top". `persist` is a no-op until `beginRestore` has
/// seen real content.
///
/// **Deciding and scrolling are two steps.** A document opened from its cache gets its body
/// from `load()`, which `.task` runs *after* the reading surface has appeared over an empty
/// page, so the restore is decided in the same update that inserts the rows. Scrolling there
/// found nothing laid out to scroll to and the page stayed at the top; only a body fetched from
/// the network, which arrives behind the loading placeholder and so brings a fresh reading
/// surface with it, scrolled. `beginRestore` therefore only decides; `takeRestoreScroll` hands
/// the target over once its row reports a frame, and raises the offer at that moment, when the
/// reader actually lands.
@MainActor @Observable final class ReadingPositionSession {
    /// Whether the "Back to top" pill is on screen.
    private(set) var offersBackToTop = false

    @ObservationIgnored private let store: ReadingPositionStore
    @ObservationIgnored private let serverOrigin: String
    @ObservationIgnored private let documentID: UUID
    @ObservationIgnored private let offerDuration: Duration
    @ObservationIgnored private var hasDecidedRestore = false
    /// The block a decided restore will scroll to once its row is laid out.
    @ObservationIgnored private var pendingScrollBlockID: UUID?
    @ObservationIgnored private var offerTask: Task<Void, Never>?

    init(
        store: ReadingPositionStore = ReadingPositionStore(), serverOrigin: String, documentID: UUID,
        offerDuration: Duration = .seconds(6)
    ) {
        self.store = store
        self.serverOrigin = serverOrigin
        self.documentID = documentID
        self.offerDuration = offerDuration
    }

    /// The block to scroll to, decided once per open. Call when the reading surface has
    /// content; returns nil (and does not spend the one decision) while `blocks` is empty.
    ///
    /// `userHasScrolled` spends the decision without restoring: content that arrives after the
    /// reader has already started scrolling must not yank the page out from under them.
    ///
    /// Only decides: the returned block is held as the pending scroll, which
    /// `takeRestoreScroll` releases once the row is laid out.
    @discardableResult
    func beginRestore(blocks: [EditorBlock], userHasScrolled: Bool) -> UUID? {
        guard !hasDecidedRestore, !blocks.isEmpty else { return nil }
        hasDecidedRestore = true
        guard !userHasScrolled else { return nil }
        let saved = store.position(serverOrigin: serverOrigin, documentID: documentID)
        guard case .restore(let blockID) = readingPositionRestore(saved: saved, blocks: blocks) else { return nil }
        pendingScrollBlockID = blockID
        return blockID
    }

    /// Whether a decided restore is still waiting for its row to be laid out.
    var hasPendingRestoreScroll: Bool { pendingScrollBlockID != nil }

    /// The block to scroll to now, once, if a restore is pending and its row has been laid out
    /// (`laidOutBlockIDs`: the rows that have reported a frame). Raises the "Back to top" offer,
    /// which dismisses itself after `offerDuration`.
    ///
    /// With VoiceOver running the offer does not time out (`backToTopAutoDismisses`): a
    /// screen-reader user needs longer than six seconds to find it, so it stays until they
    /// scroll, activate it or leave.
    func takeRestoreScroll(laidOutBlockIDs: Set<UUID>, voiceOverEnabled: Bool = false) -> UUID? {
        guard let blockID = pendingScrollBlockID else { return nil }
        switch readingRestoreScrollStep(target: blockID, laidOutBlockIDs: laidOutBlockIDs) {
        case .wait:
            return nil
        case .abandon:
            pendingScrollBlockID = nil
            return nil
        case .scroll:
            pendingScrollBlockID = nil
        }
        offersBackToTop = true
        offerTask?.cancel()
        offerTask = nil
        guard backToTopAutoDismisses(voiceOverEnabled: voiceOverEnabled) else { return blockID }
        offerTask = Task { [offerDuration] in
            try? await Task.sleep(for: offerDuration)
            guard !Task.isCancelled else { return }
            self.offersBackToTop = false
        }
        return blockID
    }

    /// Drops a restore that has not scrolled yet: the reader took hold of the page, switched to
    /// editing, or left. The decision stays spent.
    func cancelPendingRestore() {
        pendingScrollBlockID = nil
    }

    /// The reader jumped somewhere on purpose: a heading, a find match or the title picked in the
    /// outline. Ends the offer — "Back to top" belongs to the restore, not to a place the reader
    /// chose — and, once there is content, spends the restore decision as a scroll would, so a
    /// restore that had not happened yet cannot pull the page away from the jump. Where the jump
    /// lands is remembered like any other place, from the top visible block when they leave.
    func noteDeliberateJump(blocks: [EditorBlock]) {
        dismissBackToTop()
        cancelPendingRestore()
        beginRestore(blocks: blocks, userHasScrolled: true)
    }

    /// Ends the offer: the reader scrolled, tapped it, or left.
    func dismissBackToTop() {
        offerTask?.cancel()
        offerTask = nil
        if offersBackToTop { offersBackToTop = false }
    }

    /// Records where the reader is, or forgets the position when they are back at the top.
    /// Nothing is written while a restore is still waiting to scroll: the page is at the top
    /// until it does, and saving that would replace the position about to be restored.
    func persist(blocks: [EditorBlock], topVisibleBlockID: UUID?) {
        guard hasDecidedRestore, pendingScrollBlockID == nil else { return }
        switch readingPositionUpdate(topVisibleBlockID: topVisibleBlockID, blocks: blocks) {
        case .keep:
            break
        case .clear:
            store.remove(serverOrigin: serverOrigin, documentID: documentID)
        case .save(let blockID, let fingerprint, let blockIndex):
            store.save(
                blockID: blockID, fingerprint: fingerprint, blockIndex: blockIndex,
                serverOrigin: serverOrigin, documentID: documentID)
        }
    }
}
