import Foundation
import Observation

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
@MainActor @Observable final class ReadingPositionSession {
    /// Whether the "Back to top" pill is on screen.
    private(set) var offersBackToTop = false

    @ObservationIgnored private let store: ReadingPositionStore
    @ObservationIgnored private let serverOrigin: String
    @ObservationIgnored private let documentID: UUID
    @ObservationIgnored private let offerDuration: Duration
    @ObservationIgnored private var hasDecidedRestore = false
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
    /// A restore raises the "Back to top" offer, which dismisses itself after `offerDuration`.
    func beginRestore(blocks: [EditorBlock], userHasScrolled: Bool) -> UUID? {
        guard !hasDecidedRestore, !blocks.isEmpty else { return nil }
        hasDecidedRestore = true
        guard !userHasScrolled else { return nil }
        let saved = store.position(serverOrigin: serverOrigin, documentID: documentID)
        guard case .restore(let blockID) = readingPositionRestore(saved: saved, blocks: blocks) else { return nil }
        offersBackToTop = true
        offerTask?.cancel()
        offerTask = Task { [offerDuration] in
            try? await Task.sleep(for: offerDuration)
            guard !Task.isCancelled else { return }
            self.offersBackToTop = false
        }
        return blockID
    }

    /// Ends the offer: the reader scrolled, tapped it, or left.
    func dismissBackToTop() {
        offerTask?.cancel()
        offerTask = nil
        if offersBackToTop { offersBackToTop = false }
    }

    /// Records where the reader is, or forgets the position when they are back at the top.
    func persist(blocks: [EditorBlock], topVisibleBlockID: UUID?) {
        guard hasDecidedRestore else { return }
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
