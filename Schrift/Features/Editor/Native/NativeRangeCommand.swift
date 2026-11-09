import Foundation

/// One replacement over a document-ordered range that may span blocks: typing,
/// Backspace/Delete, paste, cut or dictation over a selection, or a pasted
/// newline. The range starts in the command's `blockID` at `startOffset` and
/// ends in `endBlockID` at `endOffset` (replica UTF-16 offsets). `replacement`
/// is plain text in which "\n" splits blocks; `newBlockIDs` names the blocks
/// after the first line, in order. The coordinator mints those ids once, so a
/// block has one model id; the engine refuses a count that does not match the
/// replacement or an id the replica already uses.
struct NativeRangeCommand: Equatable, Sendable {
    let startOffset: Int
    let endBlockID: String
    let endOffset: Int
    let replacement: String
    let newBlockIDs: [String]

    /// The replacement's lines. An empty replacement is one empty line, so a
    /// delete joins the first and last block without creating a block.
    static func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
