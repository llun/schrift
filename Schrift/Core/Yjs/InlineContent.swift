import Foundation

// MARK: - Inline runs -> pieces (shared by the from-scratch encoder and YWrite)

/// One inline item in the open/carry/close-format sequence for a run list.
enum InlinePiece: Equatable {
    case string(String)
    /// `valueJSON == "null"` closes a mark.
    case format(key: String, valueJSON: String)
}

/// The shared source of inline shape: turns a run list into the ordered
/// open/carry/close-format sequence yjs's `Y.XmlText.applyDelta` would
/// produce, independent of how each piece is ultimately encoded. Both the
/// from-scratch encoder (`BlockNoteYjs.emitInline`) and the live-replica
/// write path consume this so they cannot drift from one another.
enum InlineContent {
    /// The ordered `ContentFormat`/`ContentString` sequence for `runs`,
    /// mirroring yjs `Y.XmlText.applyDelta`: open marks when first present,
    /// carry across runs, close (value `null`) once no longer active, incl.
    /// after the last run.
    static func pieces(for runs: [InlineRun]) -> [InlinePiece] {
        var out: [InlinePiece] = []
        var openMarks: [(key: String, valueJSON: String)] = []
        for run in runs {
            let newMarks = run.marks
            // Close marks that are open but not present (or changed) in this run.
            for open in openMarks
            where !newMarks.contains(where: { $0.key == open.key && $0.valueJSON == open.valueJSON }) {
                out.append(.format(key: open.key, valueJSON: "null"))
            }
            // Open marks newly present in this run.
            for mark in newMarks
            where !openMarks.contains(where: { $0.key == mark.key && $0.valueJSON == mark.valueJSON }) {
                out.append(.format(key: mark.key, valueJSON: mark.valueJSON))
            }
            if !run.text.isEmpty { out.append(.string(run.text)) }
            openMarks = newMarks
        }
        // Close any marks still open after the last run.
        for open in openMarks {
            out.append(.format(key: open.key, valueJSON: "null"))
        }
        return out
    }
}
