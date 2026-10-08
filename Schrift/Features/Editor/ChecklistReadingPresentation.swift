import Foundation

/// A disposable reading projection. The editor, serializer and collaboration bridge
/// always own the full source array; the source index also preserves numbered runs.
///
/// Hiding a completed item also hides what belongs to it. First, the list items nested
/// under it (its `indent` subtree): they are part of that item, and left on screen they
/// would draw indented under whichever unrelated item precedes the hidden one. Then the
/// media after it: the run of image and attachment leaves directly following the item
/// (or its subtree) — only list items nest, so a photo "under" a checked item is the
/// leaf that follows it. The media run ends at the first block that is not media, so
/// prose, headings and other items are never hidden; a queued photo also ends it and
/// stays visible. `hiddenCount` still counts completed items only — every checked item
/// hidden, nested ones included — it is what the "Completed items hidden" notice reports.
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
            if let depth = hiddenSubtreeDepth, blockIsListItem(block.kind), block.indent > depth {
                if case .checklistItem(checked: true) = block.kind { hiddenCount += 1 }
                continue
            }
            hiddenSubtreeDepth = nil
            if hidingCompleted, case .checklistItem(checked: true) = block.kind {
                hiddenCount += 1
                hidingAttachedMedia = true
                hiddenSubtreeDepth = block.indent
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
