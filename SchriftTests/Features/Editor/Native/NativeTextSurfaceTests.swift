import UIKit
import XCTest

@testable import Schrift

@MainActor
final class NativeTextSurfaceTests: DocumentEngineTestCase {
    private func assertMatches(
        _ surface: NativeTextSurface, _ doc: YDoc, file: StaticString = #filePath, line: UInt = #line
    ) {
        let blocks = projection(doc)
        XCTAssertEqual(surface.blocks, blocks, file: file, line: line)
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: blocks, traits: surface.traits, labels: surface.labels)
        XCTAssertEqual(surface.storage.string, fresh.string, file: file, line: line)
        XCTAssertEqual(normalized(surface.storage), normalized(fresh), file: file, line: line)
        XCTAssertEqual(
            surface.rangeIndex.entries, ProjectionRangeIndex(blocks: blocks, labels: surface.labels).entries,
            file: file, line: line)
    }

    /// UIKit can copy/coalesce attribute objects. Compare their semantic values
    /// at every UTF-16 unit, independent of object identity and run boundaries.
    private func normalized(_ string: NSAttributedString) -> [[String: String]] {
        (0..<string.length).map { offset in
            string.attributes(at: offset, effectiveRange: nil).reduce(into: [:]) { values, entry in
                let (key, value) = entry
                if let font = value as? UIFont {
                    values[key.rawValue] =
                        "\(font.fontName)/\(font.pointSize)/\(font.fontDescriptor.symbolicTraits.rawValue)"
                } else if let paragraph = value as? NSParagraphStyle {
                    values[key.rawValue] =
                        "\(paragraph.alignment.rawValue)/\(paragraph.paragraphSpacing)"
                        + "/\(paragraph.headIndent)/\(paragraph.firstLineHeadIndent)"
                } else if let color = value as? UIColor {
                    var red: CGFloat = 0
                    var green: CGFloat = 0
                    var blue: CGFloat = 0
                    var alpha: CGFloat = 0
                    color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                        .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    values[key.rawValue] = "\(red)/\(green)/\(blue)/\(alpha)"
                } else if let url = value as? URL {
                    values[key.rawValue] = url.absoluteString
                } else {
                    values[key.rawValue] = String(describing: value)
                }
            }
        }
    }

    func testEveryPatchKindForEachOriginUsingASecondReplica() throws {
        for origin: YTransactionOrigin? in [.localUser, .remote, nil] {
            let doc = YDoc(clientID: 33)
            let peerDoc = try makeDoc(clientID: 22)
            defer {
                doc.destroy()
                peerDoc.destroy()
            }
            let surface = NativeTextSurface(blocks: [], storage: NativeTextView().textStorage)
            let recorder = NativeRecordingSurface(surface)
            let engine = DocumentEngine(doc: doc, surface: recorder)
            let peer = DocumentEngine(doc: peerDoc)
            _ = engine
            func deliver(_ bytes: Data) throws {
                try doc.applyUpdate(YUpdateDecoder.decode(bytes), origin: origin)
                assertMatches(surface, doc)
            }
            try deliver(BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
            try deliver(peer.replaceText(block: Self.firstID, range: 0..<0, with: "😀"))
            try deliver(
                peer.setBlockType(block: Self.thirdID, to: "paragraph", props: [("textAlignment", .string("right"))]))
            try deliver(peer.setBlockType(block: Self.thirdID, to: "heading", props: [("level", .int(1))]))
            try deliver(peer.splitBlock(block: Self.firstID, at: 2, newID: "split"))
            try deliver(peer.joinBlocks(block: "split"))
            XCTAssertEqual(recorder.kinds, ["text", "props", "insert", "remove", "replaceBlock", "reset"])
            XCTAssertTrue(recorder.patches.contains { $0.origin == BlockPatchOrigin(origin) })
        }
    }

    func testSelectionAndCopyAcrossParagraphsDoNotMutateStorage() {
        let view = NativeTextView()
        let surface = NativeTextSurface(
            blocks: Self.seedBlocks().map {
                BlockSnapshot(
                    id: $0.id, node: $0.node, props: $0.props.map { ProjectedProp(key: $0.key, value: $0.value) },
                    runs: $0.runs)
            }, storage: view.textStorage)
        let original = surface.storage.string
        let count = "First paragraph.\nSecond".utf16.count
        view.selectedRange = NSRange(location: 0, length: count)
        let previousClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboard }
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "First paragraph.\nSecond")
        XCTAssertEqual(surface.storage.string, original)
        XCTAssertFalse(view.isEditable)
        XCTAssertNotNil(view.textLayoutManager)
    }

    func testTextPatchEditsOnlyTheDeltaRangeAndPresentationChangesStayCanonical() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let storage = NSTextStorage()
        let surface = NativeTextSurface(blocks: projection(doc), storage: storage)
        let engine = DocumentEngine(doc: doc, surface: surface)
        let edits = NativeStorageEdits()
        storage.delegate = edits
        try engine.replaceText(block: Self.firstID, range: 3..<4, with: "X")
        XCTAssertEqual(edits.ranges, [NSRange(location: 3, length: 1)])
        assertMatches(surface, doc)
        let state = try YStateEncoder.encodeStateAsUpdate(doc)
        surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            labels: NativeEditorLabels())
        assertMatches(surface, doc)
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), state)
    }

    func testRepeatedPresentationWithEquivalentInputsDoesNotTouchStorage() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let storage = NSTextStorage()
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let surface = NativeTextSurface(blocks: projection(doc), storage: storage, traits: traits)
        let original = NSAttributedString(attributedString: storage)
        let ranges = surface.rangeIndex.entries
        let edits = NativeStorageEdits()
        storage.delegate = edits

        for _ in 0..<3 {
            surface.updatePresentation(
                traits: UITraitCollection {
                    $0.preferredContentSizeCategory = .large
                    $0.userInterfaceStyle = .dark
                }, labels: NativeEditorLabels())
        }

        XCTAssertTrue(edits.ranges.isEmpty, "unchanged presentation must not enter a storage editing cycle")
        XCTAssertTrue(surface.traits === traits, "a no-op must not replace even the stored trait inputs")
        XCTAssertEqual(normalized(storage), normalized(original))
        XCTAssertEqual(surface.rangeIndex.entries, ranges)
        assertMatches(surface, doc)
    }

    func testChangedPresentationWritesOnceAndRepeatedInputsDoNotWriteAgain() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let storage = NSTextStorage()
        let surface = NativeTextSurface(
            blocks: projection(doc), storage: storage,
            traits: UITraitCollection(preferredContentSizeCategory: .large))
        let edits = NativeStorageEdits()
        storage.delegate = edits
        let changedLabels = NativeEditorLabels(preservedBlock: "%@ (behouden)", unknownBlock: "Onbekend blok")

        surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .extraLarge), labels: changedLabels)
        XCTAssertFalse(edits.ranges.isEmpty, "a real presentation change must still restyle the surface")
        edits.ranges.removeAll()
        for _ in 0..<3 {
            surface.updatePresentation(
                traits: UITraitCollection(preferredContentSizeCategory: .extraLarge), labels: changedLabels)
        }

        XCTAssertTrue(edits.ranges.isEmpty)
        assertMatches(surface, doc)
    }

    func testAllSixPatchKindsFromRealEngineAndEveryOrigin() throws {
        let local = try makeDoc(clientID: 10)
        let remote = try makeDoc(clientID: 20)
        defer {
            local.destroy()
            remote.destroy()
        }
        let view = NativeTextView()
        XCTAssertNotNil(view.textLayoutManager)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        let surface = NativeTextSurface(blocks: projection(local), storage: view.textStorage)
        let recorder = NativeRecordingSurface(surface)
        let engine = DocumentEngine(doc: local, surface: recorder)
        let peer = DocumentEngine(doc: remote)
        assertMatches(surface, local)

        try engine.replaceText(block: Self.firstID, range: 5..<5, with: "😀e\u{301}")
        assertMatches(surface, local)
        XCTAssertEqual(recorder.patches.last?.origin, .localUser)
        XCTAssertTrue(recorder.kinds.contains("text"))

        try engine.setBlockType(block: Self.thirdID, to: "paragraph", props: [("textAlignment", .string("center"))])
        assertMatches(surface, local)
        XCTAssertTrue(recorder.kinds.contains("props"))

        try engine.formatRange(block: Self.secondID, range: 0..<6, marks: [TextMark(key: "italic", valueJSON: "{}")])
        assertMatches(surface, local)
        XCTAssertNotNil(
            surface.storage.attribute(
                .font, at: surface.rangeIndex.entry(for: Self.secondID)!.range.location, effectiveRange: nil))

        let update = try peer.setBlockType(block: Self.thirdID, to: "heading", props: [("level", .int(2))])
        try local.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        assertMatches(surface, local)
        XCTAssertTrue(recorder.patches.contains { $0.origin == .remote })
        XCTAssertTrue(recorder.kinds.contains("replaceBlock"))

        try engine.splitBlock(block: Self.firstID, at: 5, newID: "split")
        assertMatches(surface, local)
        XCTAssertTrue(recorder.kinds.contains("insert"))
        try engine.joinBlocks(block: "split")
        assertMatches(surface, local)
        XCTAssertTrue(recorder.kinds.contains("remove"))

        let text = try XCTUnwrap(BlockIndex(doc: local).entries[Self.firstID]?.textType)
        try local.transact { _ in try text.insert(0, "other") }
        assertMatches(surface, local)
        XCTAssertEqual(recorder.patches.last?.origin, .other)

        let root = try XCTUnwrap(local.share[BlockNoteYjs.fragmentField])
        try local.transact { tx in root.start?.delete(tx) }
        assertMatches(surface, local)
        XCTAssertTrue(recorder.kinds.contains("reset"))
        XCTAssertEqual(surface.storage.length, 0)
        XCTAssertNotNil(view.textLayoutManager)
    }

    func testEmptyRootBecomesPopulatedThenReceivesRemoteUnicodeAndMarkChanges() throws {
        let doc = YDoc(clientID: 99)
        let peerDoc = try makeDoc(clientID: 22)
        defer {
            doc.destroy()
            peerDoc.destroy()
        }
        let view = NativeTextView()
        let surface = NativeTextSurface(blocks: [], storage: view.textStorage)
        let recorder = NativeRecordingSurface(surface)
        let engine = DocumentEngine(doc: doc, surface: recorder)
        let peer = DocumentEngine(doc: peerDoc)
        _ = engine
        try doc.applyUpdate(
            YUpdateDecoder.decode(BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)), origin: .remote)
        assertMatches(surface, doc)
        XCTAssertEqual(recorder.kinds, ["reset"])
        for (range, replacement) in [(0..<0, "😀e\u{301}"), (0..<2, "🧑🏽‍💻"), (7..<9, "é")] {
            let update = try peer.replaceText(block: Self.firstID, range: range, with: replacement)
            try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
            assertMatches(surface, doc)
        }
        let formatted = try peer.formatRange(
            block: Self.thirdID, range: 0..<5,
            marks: [TextMark(key: "bold", valueJSON: "{}"), TextMark(key: "strike", valueJSON: "{}")])
        try doc.applyUpdate(YUpdateDecoder.decode(formatted), origin: .remote)
        assertMatches(surface, doc)
        let offset = try XCTUnwrap(surface.rangeIndex.entry(for: Self.thirdID)).range.location
        XCTAssertEqual(surface.storage.attribute(.strikethroughStyle, at: offset, effectiveRange: nil) as? Int, 1)
    }

    func testRepeatedSameOffsetDeltasKeepArrayOrderAndOnlyTouchTheirBlock() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = NativeTextSurface(blocks: projection(doc), storage: NSTextStorage())
        let engine = DocumentEngine(doc: doc, surface: surface)
        // Two insertions in one real transaction exercise builder coalescing.
        let text = try XCTUnwrap(BlockIndex(doc: doc).entries[Self.firstID]?.textType)
        try doc.transact { _ in
            try text.insert(0, "A")
            try text.insert(0, "B")
        }
        assertMatches(surface, doc)
        engine.detach()

        // The boundary also supports uncoalesced deltas at one pre-change offset.
        let beforeSibling = surface.storage.attributedSubstring(
            from: surface.rangeIndex.entry(for: Self.secondID)!.range)
        surface.applyPatch(
            BlockPatch([
                .text(
                    blockID: Self.firstID,
                    deltas: [
                        TextDelta(range: 0..<0, replacement: "1", marks: []),
                        TextDelta(range: 0..<0, replacement: "2", marks: []),
                    ])
            ]))
        XCTAssertTrue(surface.storage.string.hasPrefix("12BA"))
        let afterSibling = surface.storage.attributedSubstring(
            from: surface.rangeIndex.entry(for: Self.secondID)!.range)
        XCTAssertEqual(normalized(beforeSibling), normalized(afterSibling))
        XCTAssertEqual(beforeSibling.string, afterSibling.string)
    }

    func testDetachAndReopenSeedsTheCurrentProjection() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let first = NativeTextSurface(blocks: projection(doc), storage: NSTextStorage())
        let engine = DocumentEngine(doc: doc, surface: first)
        engine.detach()
        let old = first.storage.string
        let reopened = NativeTextSurface(blocks: projection(doc), storage: NSTextStorage())
        let second = DocumentEngine(doc: doc, surface: reopened)
        try second.replaceText(block: Self.firstID, range: 0..<0, with: "Reopened ")
        assertMatches(reopened, doc)
        XCTAssertEqual(first.storage.string, old)
    }

    func testSemanticMarksAndOpaqueBlocksHaveExplicitAttributes() throws {
        let blocks = [
            BlockSnapshot(
                id: "marks", node: "paragraph", props: [],
                runs: [
                    InlineRun("bold", marks: [("bold", "{}")]),
                    InlineRun("italic", marks: [("italic", "{}")]),
                    InlineRun("code", marks: [("code", "{}")]),
                    InlineRun("strike", marks: [("strike", "{}")]),
                    InlineRun("link", marks: [("link", "{\"href\":\"https://example.org\"}")]),
                ]),
            BlockSnapshot(id: "table", node: "table", props: [], runs: []),
            BlockSnapshot(id: "opaque", node: "paragraph", props: [], runs: [], isOpaque: true),
        ]
        let storage = AttributedDocumentProjection.attributedString(blocks: blocks)
        let index = ProjectionRangeIndex(blocks: blocks)
        XCTAssertTrue(
            (storage.attribute(.font, at: 0, effectiveRange: nil) as! UIFont).fontDescriptor.symbolicTraits.contains(
                .traitBold))
        XCTAssertTrue(
            (storage.attribute(.font, at: 4, effectiveRange: nil) as! UIFont).fontDescriptor.symbolicTraits.contains(
                .traitItalic))
        XCTAssertNotNil(storage.attribute(.link, at: 20, effectiveRange: nil))
        for id in ["table", "opaque"] {
            let entry = try XCTUnwrap(index.entry(for: id))
            XCTAssertEqual(
                storage.attribute(.nativePlaceholder, at: entry.range.location, effectiveRange: nil) as? Bool, true)
            XCTAssertTrue(storage.attributedSubstring(from: entry.textRange).string.contains("preserved"))
        }
    }
}

@MainActor
private final class NativeStorageEdits: NSObject, @preconcurrency NSTextStorageDelegate {
    var ranges: [NSRange] = []
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        ranges.append(editedRange)
    }
}

@MainActor
private final class NativeRecordingSurface: @preconcurrency EditorSurface {
    let native: NativeTextSurface
    var patches: [BlockPatch] = []
    var kinds: Set<String> {
        Set(
            patches.flatMap(\.changes).map {
                switch $0 {
                case .text: "text"
                case .props: "props"
                case .insert: "insert"
                case .remove: "remove"
                case .replaceBlock: "replaceBlock"
                case .reset: "reset"
                }
            })
    }
    init(_ native: NativeTextSurface) { self.native = native }
    func applyPatch(_ patch: BlockPatch) {
        patches.append(patch)
        native.applyPatch(patch)
    }
}
