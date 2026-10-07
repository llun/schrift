import Foundation

/// A disposable reading projection. The editor, serializer and collaboration bridge
/// always own the full source array; the source index also preserves numbered runs.
///
/// Hiding a completed item also hides the media that belongs to it: the run of image
/// and attachment leaves directly after it. The editor has no nested blocks, so a
/// photo "under" a checked item is the leaf that follows it; leaving it on screen
/// stranded it beneath whichever unrelated item happened to precede the hidden one.
/// The run ends at the first block that is not media, so prose, headings and other
/// items are never hidden; a queued photo also ends it and stays visible.
/// `hiddenCount` still counts completed items only — it is what the "Completed items
/// hidden" notice reports.
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
        for (index, block) in blocks.enumerated() {
            if hidingCompleted, case .checklistItem(checked: true) = block.kind {
                hiddenCount += 1
                hidingAttachedMedia = true
                continue
            }
            if hidingAttachedMedia, isChecklistAttachedMedia(block.kind) { continue }
            hidingAttachedMedia = false
            rows.append(Row(sourceIndex: index, block: block))
        }
        self.rows = rows
        self.hiddenCount = hiddenCount
        hasChecklistItems = blocks.contains { if case .checklistItem = $0.kind { true } else { false } }
    }
}

/// The leaves that ride along with the checklist item above them when it is hidden.
/// A queued photo (`schrift-attachment://` placeholder) never does: its card carries the
/// Retry/Remove actions and the "missing" state, which must stay reachable while reading.
private func isChecklistAttachedMedia(_ kind: BlockKind) -> Bool {
    switch kind {
    case .image(_, let url): pendingAttachmentID(fromPlaceholderURL: url) == nil
    case .attachment: true
    default: false
    }
}
