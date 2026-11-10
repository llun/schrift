import Foundation
import UIKit

/// Keeps the native selection as directed engine relative positions, so it
/// survives peer edits and rebuilds, and restores it with affinity after each
/// patch that is not the editor's own command echo.
///
/// UIKit's `selectedRange` is unordered, so direction is inferred from the
/// previous range, as hardware Shift-arrows move it: when the end moved and the
/// start held, the head is the end; when the start moved and the end held, the
/// head is the start; otherwise the direction holds. A non-empty range keeps a
/// peer's insertion at either boundary outside it; a caret keeps left affinity.
/// A selection with an endpoint the engine cannot capture (a placeholder) is
/// not tracked: the engine selection is cleared rather than left stale.
///
/// When one endpoint's block disappears the selection collapses to the other.
/// When both do, the caret moves visibly to the nearest surviving block: the
/// start of the block after the head's old block, else the end of the one
/// before it, else the block now at its old position.
///
/// The relative positions live in the replica session (PR08b): each capture
/// is posted with an increasing `seq`, and a delivery's resolved endpoints are
/// used only when they answer the latest capture (a newer one is in flight
/// otherwise, and the view's own range stands).
@MainActor
final class NativeSelectionCoordinator {
    private let post: (UInt64, EditorSelection?) -> Void
    private let surface: NativeTextSurface
    private weak var view: NativeTextView?
    private var isRestoring = false
    private var previous: NSRange?
    private(set) var isBackward = false
    /// How many restores set the view's selection. A programmatic set sends no
    /// delegate callback, so tests read this to prove a set did not happen.
    private(set) var restoredSelections = 0
    /// The head block's neighbours and position at the last capture; nil when
    /// nothing is tracked.
    private var fallback: (before: String?, after: String?, position: Int)?
    /// The latest capture posted to the session.
    private(set) var seq: UInt64 = 0

    /// `post` sends one capture (seq, selection) to the replica session.
    init(surface: NativeTextSurface, view: NativeTextView, post: @escaping (UInt64, EditorSelection?) -> Void) {
        self.post = post
        self.surface = surface
        self.view = view
    }

    /// UIKit changed the selection. Storage edits by a patch move it too; the
    /// patch's own restoration decides where it goes then.
    func selectionDidChange() {
        guard !isRestoring, !surface.isApplyingPatch, let view else { return }
        publish(view.selectedRange)
    }

    /// Places a selection the editor chose (a command's caret) and captures it.
    func place(_ range: NSRange) {
        guard let view else { return }
        isRestoring = true
        view.selectedRange = range
        isRestoring = false
        publish(range)
    }

    /// Captures a document selection as directed relative endpoints.
    func publish(_ range: NSRange) {
        isBackward = direction(of: range)
        previous = range
        let index = surface.rangeIndex
        guard let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: range.length > 0)
        else { return clear() }
        let lower = EditorPosition(
            blockID: index.entries[start.position].blockID, offset: start.offset, assoc: range.length > 0 ? 0 : -1)
        let upper = EditorPosition(blockID: index.entries[end.position].blockID, offset: end.offset, assoc: -1)
        // The engine captures only projectable text: a placeholder endpoint is
        // not tracked.
        guard !AttributedDocumentProjection.isPlaceholder(surface.blocks[start.position]),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[end.position])
        else { return clear() }
        seq += 1
        post(
            seq, isBackward ? EditorSelection(anchor: upper, head: lower) : EditorSelection(anchor: lower, head: upper))
        let head = isBackward ? start.position : end.position
        fallback = (
            head > 0 ? index.entries[head - 1].blockID : nil,
            head + 1 < index.entries.count ? index.entries[head + 1].blockID : nil, head
        )
    }

    /// Re-applies the relative selection after a peer patch, a rebuild or a
    /// history step, from the endpoints the session resolved. The editor's own
    /// commands place their caret themselves. Endpoints for an older capture
    /// are ignored: a newer one is in flight.
    func restore(from resolved: ReplicaSelection?) {
        guard let resolved, resolved.seq == seq, resolved.tracked, let view, !isRestoring,
            view.markedTextRange == nil
        else { return }
        let anchor = resolved.anchor.flatMap(documentOffset)
        let head = resolved.head.flatMap(documentOffset)
        let range: NSRange
        if let anchor, let head {
            range = NSRange(location: min(anchor, head), length: abs(head - anchor))
            isBackward = head < anchor
        } else if let survivor = anchor ?? head {
            range = NSRange(location: survivor, length: 0)
        } else {
            // Only both endpoints gone needs the neighbours of the last capture.
            guard let fallback else { return }
            let index = surface.rangeIndex
            guard !index.entries.isEmpty else { return clear() }
            if let id = fallback.after, let entry = index.entry(for: id) {
                range = NSRange(location: entry.textRange.location, length: 0)
            } else if let id = fallback.before, let entry = index.entry(for: id) {
                range = NSRange(location: NSMaxRange(entry.textRange), length: 0)
            } else {
                let entry = index.entries[min(fallback.position, index.entries.count - 1)]
                range = NSRange(location: entry.textRange.location, length: 0)
            }
        }
        // Setting `selectedRange` ends a selection drag in progress, so only a
        // patch that moved the range's document offsets sets it: an edit after
        // the selection leaves the view alone. UIKit does not shift the range
        // for an edit before it, so that one must be corrected.
        if view.selectedRange != range {
            restoredSelections += 1
            isRestoring = true
            view.selectedRange = range
            isRestoring = false
        }
        previous = range
        // A collapsed fallback is captured again, from the block that survived.
        if anchor == nil || head == nil { publish(range) }
    }

    private func clear() {
        fallback = nil
        seq += 1
        post(seq, nil)
    }

    private func direction(of range: NSRange) -> Bool {
        guard range.length > 0, let previous else { return false }
        if previous.location == range.location, NSMaxRange(previous) != NSMaxRange(range) { return false }
        if NSMaxRange(previous) == NSMaxRange(range), previous.location != range.location { return true }
        return isBackward
    }

    private func documentOffset(_ position: EditorPosition) -> Int? {
        guard let entry = surface.rangeIndex.entry(for: position.blockID) else { return nil }
        return entry.textRange.location + min(max(0, position.offset), entry.textRange.length)
    }
}
