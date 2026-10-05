import Foundation

/// A disposable reading projection. The editor, serializer and collaboration bridge
/// always own the full source array; the source index also preserves numbered runs.
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
        rows = blocks.enumerated().compactMap { index, block in
            if hidingCompleted, case .checklistItem(checked: true) = block.kind { return nil }
            return Row(sourceIndex: index, block: block)
        }
        hiddenCount = blocks.count - rows.count
        hasChecklistItems = blocks.contains { if case .checklistItem = $0.kind { true } else { false } }
    }
}
