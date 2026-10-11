import Foundation

/// A disposable reading projection. The editor, serializer and collaboration bridge
/// always own the full source array; the source index also preserves numbered runs.
///
/// Hiding a completed item also hides what belongs to it. First, everything nested
/// under it (its `indent` subtree): list items and the photos, files and link lines
/// nested among them (`blockNestsAsLeaf`) are part of that item, and left on screen they
/// would draw indented under whichever unrelated item precedes the hidden one. A queued
/// photo inside the subtree is the exception — it stays visible (see below) without
/// ending the subtree. Then the flat media after it: the run of indent-zero image and
/// attachment leaves directly following the item (or its subtree) — the server's
/// markdown export flattens a photo nested under an item to the leaf that follows it, so
/// that is still read as belonging to the item. A *nested* leaf after the subtree is a
/// sibling of the hidden item, under another parent, and stays. The media run ends at
/// the first block that is not flat media, so prose, headings and other items are never
/// hidden; a queued photo also ends it and stays visible. `hiddenCount` still counts
/// completed items only — every checked item hidden, nested ones included — it is what
/// the "Completed items hidden" notice reports.
struct ChecklistReadingPresentation {
    struct Row: Identifiable {
        let sourceIndex: Int
        let block: EditorBlock
        var id: UUID { block.id }
    }

    let rows: [Row]
    let hiddenCount: Int
    let hasChecklistItems: Bool

    init(blocks: [EditorBlock], hidingCompleted: Bool) {
        var rows: [Row] = []
        var hiddenCount = 0
        var hidingAttachedMedia = false
        // The depth of the completed item whose nested items are being hidden, if any.
        var hiddenSubtreeDepth: Int?
        for (index, block) in blocks.enumerated() {
            if let depth = hiddenSubtreeDepth, blockIsListItem(block.kind) || blockNestsAsLeaf(block),
                block.indent > depth
            {
                if case .checklistItem(checked: true) = block.kind { hiddenCount += 1 }
                // A queued photo keeps its Retry/Remove card reachable, but the
                // subtree it sits in goes on hiding around it.
                if isQueuedPhoto(block.kind) { rows.append(Row(sourceIndex: index, block: block)) }
                continue
            }
            hiddenSubtreeDepth = nil
            if hidingCompleted, case .checklistItem(checked: true) = block.kind {
                hiddenCount += 1
                hidingAttachedMedia = true
                hiddenSubtreeDepth = block.indent
                continue
            }
            if hidingAttachedMedia, block.indent == 0, isChecklistAttachedMedia(block.kind) { continue }
            hidingAttachedMedia = false
            rows.append(Row(sourceIndex: index, block: block))
        }
        self.rows = rows
        self.hiddenCount = hiddenCount
        hasChecklistItems = blocks.contains { if case .checklistItem = $0.kind { true } else { false } }
    }
}

/// A queued photo (`schrift-attachment://` placeholder): its card carries the Retry/Remove
/// actions and the "missing" state, which must stay reachable while reading — so it is
/// never hidden, not even inside a completed item's subtree.
private func isQueuedPhoto(_ kind: BlockKind) -> Bool {
    guard case .image(_, let url) = kind else { return false }
    return pendingAttachmentID(fromPlaceholderURL: url) != nil
}

/// The leaves that ride along with the checklist item above them when it is hidden.
/// A queued photo never does (`isQueuedPhoto`).
private func isChecklistAttachedMedia(_ kind: BlockKind) -> Bool {
    switch kind {
    case .image(_, let url): pendingAttachmentID(fromPlaceholderURL: url) == nil
    case .attachment: true
    default: false
    }
}
