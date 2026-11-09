import XCTest

@testable import Schrift

/// PR05a's mark commands checked against the node yjs 13.6.33 + BlockNote
/// 0.56.0 captures: each durable engine command's update, applied to a fresh
/// replica of the capture's seed, reaches the web's XML.
@MainActor
final class NativeMarkOracleTests: XCTestCase {
    typealias Checkpoint = (label: String, updateBase64: String, xml: String)

    /// `toggleStyles` bold on and then off over "cdef": one `.marks` command
    /// each, byte-identical to the web's update.
    func testBoldOnAndOffMatchTheCapture() throws {
        let checkpoints = BlockNote056ToggleBoldOnOffTests.checkpoints
        try assertSteps(checkpoints, identical: true, blockID: "p-b") { step in
            [
                .marks(
                    NativeMarkCommand(
                        startOffset: 2, endBlockID: "p-b", endOffset: 6,
                        attributes: [TextMark(key: "bold", valueJSON: step == 1 ? "{}" : "null")]))
            ]
        }
    }

    /// Typing with bold, a link and a text colour: the native typing command's
    /// explicit marks reach the web's XML (the bytes differ only in where the
    /// format closers are, see `BlockNoteWriterOracleTests`).
    func testTypingMarksLinkAndColorMatchTheCapture() throws {
        let checkpoints = BlockNote056TypingMarksLinkColorTests.checkpoints
        let link = TextMark(key: "link", valueJSON: NativeMark.linkValue("https://example.com/"))
        try assertSteps(checkpoints, identical: false, blockID: "p-a") { step in
            func typing(_ offset: Int, _ text: String, _ marks: [TextMark]?) -> NativeEditCommand.Kind {
                .replace(range: offset..<offset, replacement: text, marks: marks)
            }
            switch step {
            case 1: return [typing(0, "Hi ", nil)]
            case 2: return [typing(3, "there", [TextMark(key: "bold", valueJSON: "{}")])]
            case 3: return [typing(8, " ", []), typing(9, "link", [link])]
            default:
                return [typing(13, " red", [TextMark(key: "textColor", valueJSON: NativeMark.colorValue("red"))])]
            }
        }
    }

    private func assertSteps(
        _ checkpoints: [Checkpoint], identical: Bool, blockID: String, commands: (Int) -> [NativeEditCommand.Kind]
    ) throws {
        let seed = try XCTUnwrap(Data(base64Encoded: checkpoints[0].updateBase64))
        // The captures' author client, so a byte-identical step is comparable.
        let session = try NativeEditorSession(state: seed) { YDoc(clientID: 2, gc: false) }
        defer { session.close() }
        let replica = YDoc(clientID: 9, gc: false)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(seed))
        for step in 1..<checkpoints.count {
            for kind in commands(step) {
                let command = NativeEditCommand(
                    id: UUID(), baseRevision: session.engine.revision, blockID: blockID, kind: kind)
                var updates: [Data] = []
                if case .marks = command.kind {
                    try session.engine.applyStructural(command) { updates.append($0) }
                } else {
                    try session.engine.replaceText(command) { updates.append($0) }
                }
                XCTAssertEqual(updates.count, 1, checkpoints[step].label)
                let update = try XCTUnwrap(updates.first)
                try replica.applyUpdate(YUpdateDecoder.decode(update))
                if identical { XCTAssertEqual(update, Data(base64Encoded: checkpoints[step].updateBase64)) }
            }
            XCTAssertEqual(YXMLString.fragment(replica), checkpoints[step].xml, checkpoints[step].label)
            XCTAssertNil(replica.store.pendingStructs)
            XCTAssertNil(replica.store.pendingDs)
        }
    }
}
