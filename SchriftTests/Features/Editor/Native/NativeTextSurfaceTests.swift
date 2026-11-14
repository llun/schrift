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

    private func assertMatches(
        _ session: NativeEditorSession, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let replicaBlocks = await session.replicaDoc {
            NativeBlockProjection.project($0).blocks.map(BlockSnapshot.init)
        }
        let blocks = try XCTUnwrap(replicaBlocks, file: file, line: line)
        let surface = session.surface
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

    func testToggleableHeadingTextAndPropsAlwaysMatchFreshProjection() async throws {
        let id = Self.firstID
        let blocks = [
            BlockNoteBlock(
                node: "heading", props: Self.paragraphProps + [("level", .int(2)), ("isToggleable", .bool(true))],
                runs: [InlineRun(String(repeating: "heading ", count: 30))], id: id),
            Self.seedBlocks()[1],
        ]
        let state = BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)
        let session = try await NativeEditorSession.seed(state: state, clientID: 40)
        addTeardownBlock { await session.close().value }
        let recorder = PatchLog(session)

        let peerDoc = try makeDoc(blocks, clientID: 41)
        defer { peerDoc.destroy() }
        let peer = DocumentEngine(doc: peerDoc)

        // PR06b: the native projection models a toggle heading as text.
        XCTAssertFalse(AttributedDocumentProjection.isPlaceholder(session.surface.blocks[0]))
        let textUpdate = try peer.replaceText(block: id, range: 100..<100, with: "😀")
        try await session.integrateServerState(textUpdate)
        try await assertMatches(session)
        XCTAssertTrue(recorder.kinds.contains("text"))

        for toggleable in [false, true, false] {
            let propUpdate = try peer.setBlockType(
                block: id, to: "heading", props: [("level", .int(2)), ("isToggleable", .bool(toggleable))])
            try await session.integrateServerState(propUpdate)
            try await assertMatches(session)
            XCTAssertFalse(session.surface.blocks[0].isOpaque)
            XCTAssertEqual(AttributedDocumentProjection.isToggle(session.surface.blocks[0]), toggleable)
            let editUpdate = try peer.replaceText(block: id, range: 110..<110, with: "e\u{301}")
            try await session.integrateServerState(editUpdate)
            try await assertMatches(session)
        }
        XCTAssertTrue(recorder.kinds.contains("props"))
    }

    func testReplicaValidatedPlainTextStillEditsOnlyTheDeltaRange() async throws {
        let blocks = Self.seedBlocks()
        let state = BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)
        let session = try await NativeEditorSession.seed(state: state, clientID: 40)
        addTeardownBlock { await session.close().value }
        let peerDoc = try makeDoc(blocks, clientID: 41)
        defer { peerDoc.destroy() }
        let peer = DocumentEngine(doc: peerDoc)
        let edits = NativeStorageEdits()
        session.surface.storage.delegate = edits
        let update = try peer.replaceText(block: Self.firstID, range: 3..<4, with: "X")
        try await session.integrateServerState(update)
        XCTAssertEqual(edits.ranges, [NSRange(location: 3, length: 1)])
        try await assertMatches(session)
    }

    func testUnknownNodeWithInlineTextReceivesRemoteTextPatchesAsPlaceholder() async throws {
        let blocks = [
            BlockNoteBlock(
                node: "futureBlock", props: [], runs: [InlineRun(String(repeating: "unknown ", count: 30))],
                id: Self.firstID), Self.seedBlocks()[1],
        ]
        let state = BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)
        let session = try await NativeEditorSession.seed(state: state, clientID: 40)
        addTeardownBlock { await session.close().value }
        let peer = try makeDoc(blocks, clientID: 41)
        defer { peer.destroy() }
        let recorder = PatchLog(session)
        let text = try XCTUnwrap(BlockIndex(doc: peer).entries[Self.firstID]?.textType)
        for replacement in ["😀", "more text"] {
            try peer.transact { _ in try text.insert(120, replacement) }
            try await session.integrateServerState(try YStateEncoder.encodeStateAsUpdate(peer))
            try await assertMatches(session)
            XCTAssertTrue(AttributedDocumentProjection.isPlaceholder(session.surface.blocks[0]))
        }
        XCTAssertTrue(recorder.kinds.contains("text"))
    }

    func testCodeBlockGainingAndLosingAMarkRebuildsFidelity() async throws {
        let blocks = [
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("let value = 1")],
                id: Self.firstID),
            Self.seedBlocks()[1],
        ]
        let state = BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)
        let session = try await NativeEditorSession.seed(state: state, clientID: 40)
        addTeardownBlock { await session.close().value }
        let peer = try makeDoc(blocks, clientID: 41)
        defer { peer.destroy() }
        let recorder = PatchLog(session)
        let text = try XCTUnwrap(BlockIndex(doc: peer).entries[Self.firstID]?.textType)
        for mark in ["{}", "null"] {
            try peer.transact { _ in try text.format(0, 3, ["bold": mark]) }
            try await session.integrateServerState(try YStateEncoder.encodeStateAsUpdate(peer))
            try await assertMatches(session)
            XCTAssertEqual(session.surface.blocks[0].isOpaque, mark != "null")
        }
        XCTAssertTrue(recorder.kinds.contains("text"))
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
        // UIKit's own copy writes the general pasteboard; this test reads back
        // only what it wrote. Reading what was there before (to restore it) is
        // a read of another app's content: the paste consent alert blocks it.
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
            // A preview attachment (PR06e), labelled for VoiceOver.
            let attachment = storage.attribute(.attachment, at: entry.range.location, effectiveRange: nil)
            XCTAssertTrue(try XCTUnwrap(attachment as? NativeBlockAttachment).content.label.contains("preserved"))
        }
    }

    func testDocumentTitleResolverReadingAttachmentGeometryDoesNotTriggerExclusivityConflictDuringInsertOrReplace() {
        let initial = BlockSnapshot(id: "b1", node: "paragraph", props: [], runs: [InlineRun("Hello")])
        let surface = NativeTextSurface(blocks: [initial], storage: NativeTextView().textStorage)
        let targetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        surface.documentTitle = { [weak surface] id in
            surface?.attachmentGeometry.documentTitles[id] ?? (id == targetID ? "Spec" : nil)
        }
        let chip = InlineRun(
            "\u{FFFC}",
            inlineObject: .interlink(
                docID: targetID.uuidString.lowercased(), blockID: nil, title: nil, disabled: false, trigger: "/"))

        let inserted = BlockSnapshot(id: "b2", node: "paragraph", props: [], runs: [chip])
        surface.applyPatch(BlockPatch([.insert(after: "b1", blocks: [inserted])], origin: .localUser))
        XCTAssertEqual(surface.attachmentGeometry.documentTitles[targetID], "Spec")

        let secondID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        surface.documentTitle = { [weak surface] id in
            surface?.attachmentGeometry.documentTitles[id] ?? (id == secondID ? "Notes" : nil)
        }
        let replacedChip = InlineRun(
            "\u{FFFC}",
            inlineObject: .interlink(
                docID: secondID.uuidString.lowercased(), blockID: nil, title: nil, disabled: false, trigger: "/"))
        let replacement = BlockSnapshot(id: "b1", node: "paragraph", props: [], runs: [replacedChip])
        surface.applyPatch(BlockPatch([.replaceBlock(blockID: "b1", block: replacement)], origin: .localUser))
        XCTAssertEqual(surface.attachmentGeometry.documentTitles[secondID], "Notes")
    }

    func testHideCompletedChecklistsHidesSubtreesWithoutYjsWrites() async throws {
        let blocks = [
            BlockNoteBlock(
                node: "checkListItem",
                props: [
                    ("backgroundColor", .string("default")), ("textColor", .string("default")),
                    ("textAlignment", .string("left")), ("checked", .bool(true)),
                ],
                runs: [InlineRun("Done parent")],
                id: "c1",
                children: [
                    BlockNoteBlock(
                        node: "checkListItem",
                        props: [
                            ("backgroundColor", .string("default")), ("textColor", .string("default")),
                            ("textAlignment", .string("left")), ("checked", .bool(false)),
                        ],
                        runs: [InlineRun("Nested child")],
                        id: "c1-child"),
                    BlockNoteBlock(
                        node: "paragraph",
                        props: [
                            ("backgroundColor", .string("default")), ("textColor", .string("default")),
                            ("textAlignment", .string("left")),
                        ],
                        runs: [InlineRun("Nested note")],
                        id: "c1-note"),
                ]),
            BlockNoteBlock(
                node: "checkListItem",
                props: [
                    ("backgroundColor", .string("default")), ("textColor", .string("default")),
                    ("textAlignment", .string("left")), ("checked", .bool(false)),
                ],
                runs: [InlineRun("Open item")],
                id: "c2"),
            BlockNoteBlock(
                node: "paragraph",
                props: [
                    ("backgroundColor", .string("default")), ("textColor", .string("default")),
                    ("textAlignment", .string("left")),
                ],
                runs: [InlineRun("Trailing prose")],
                id: "p1"),
        ]
        let session = try await NativeEditorSession.seed(state: BlockNoteYjs.encode(blocks, clientID: 1))
        addTeardownBlock { await session.close().value }
        let surface = session.surface
        let beforeRevision = await session.engine { $0.revision }

        XCTAssertEqual(
            surface.checklistSummary,
            NativeTextSurface.NativeChecklistSummary(total: 3, completed: 1, hiddenCompleted: 0, allBlocksHidden: false))

        let changed = session.setChecklistPresentation(hidesCompleted: true, settlingIDs: [])
        XCTAssertTrue(changed)
        XCTAssertEqual(surface.hidden, [true, true, true, false, false])
        XCTAssertEqual(
            surface.checklistSummary,
            NativeTextSurface.NativeChecklistSummary(total: 3, completed: 1, hiddenCompleted: 1, allBlocksHidden: false))
        XCTAssertEqual(
            surface.survivingVisibleBlockID(around: "c1", nextHidesCompleted: true, settlingIDs: []),
            "c2")
        XCTAssertEqual(
            surface.survivingVisibleBlockID(around: "c1-note", nextHidesCompleted: true, settlingIDs: []),
            "c2")
        let afterRevision = await session.engine { $0.revision }
        XCTAssertEqual(afterRevision, beforeRevision, "presentation hiding must write zero Yjs transactions")

        XCTAssertTrue(session.setChecklistPresentation(hidesCompleted: false, settlingIDs: []))
        XCTAssertEqual(surface.hidden, [false, false, false, false, false])
        XCTAssertEqual(surface.checklistSummary.hiddenCompleted, 0)
    }

    func testChecklistSettlingDelayAndAllHiddenState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettlingTests.\(UUID())")
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example.org", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let blocks = [
            BlockNoteBlock(
                node: "checkListItem",
                props: [("checked", .bool(true))],
                runs: [InlineRun("Already done")],
                id: "c1"),
            BlockNoteBlock(
                node: "checkListItem",
                props: [("checked", .bool(false))],
                runs: [InlineRun("Last task")],
                id: "c2",
                children: [
                    BlockNoteBlock(node: "paragraph", props: [], runs: [InlineRun("Child note")], id: "c2-child")
                ]),
        ]
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(blocks, clientID: 1))
        let restored = try await NativeEditorSession.restore(store: store, scope: scope, editable: true)
        let session = try XCTUnwrap(restored)
        addTeardownBlock {
            await session.close().value
            try? FileManager.default.removeItem(at: directory)
        }
        session.setEditing(false)
        XCTAssertTrue(session.setChecklistPresentation(hidesCompleted: true, settlingIDs: []))
        XCTAssertEqual(session.surface.hidden, [true, false, false])
        XCTAssertFalse(session.surface.checklistSummary.allBlocksHidden)

        var settling = ChecklistSettlingStore<String>()
        let staleToken = settling.begin("c2")
        let activeToken = settling.begin("c2")
        _ = session.setChecklistPresentation(hidesCompleted: true, settlingIDs: settling.ids)
        let toggled = await session.run { session.input?.toggleCheckbox(blockID: "c2") == true }
        XCTAssertTrue(toggled)

        // During the settle beat, `c2` stays visible while already checked.
        XCTAssertTrue(NativeTextSurface.isCheckedChecklist(session.surface.blocks[1]))
        XCTAssertEqual(session.surface.hidden, [true, false, false])
        XCTAssertFalse(session.surface.checklistSummary.allBlocksHidden)
        XCTAssertFalse(settling.finish("c2", token: staleToken), "stale token cannot finish early")

        // After settling completes, `c2` and its child collapse into the all-hidden state.
        XCTAssertTrue(settling.finish("c2", token: activeToken))
        XCTAssertTrue(session.setChecklistPresentation(hidesCompleted: true, settlingIDs: settling.ids))
        XCTAssertEqual(session.surface.hidden, [true, true, true])
        XCTAssertEqual(
            session.surface.checklistSummary,
            NativeTextSurface.NativeChecklistSummary(total: 2, completed: 2, hiddenCompleted: 2, allBlocksHidden: true))

        // Show completed restores visibility for Reading mode.
        XCTAssertTrue(session.setChecklistPresentation(hidesCompleted: false, settlingIDs: []))
        XCTAssertFalse(session.surface.checklistSummary.allBlocksHidden)
        XCTAssertEqual(session.surface.hidden, [false, false, false])
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
