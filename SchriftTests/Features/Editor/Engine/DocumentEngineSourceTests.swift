import XCTest

@testable import Schrift

/// PR14 Step 2: engine, index, patch, selection, awareness, slash insertion,
/// and peer delete/replace guarantees for scoped `mathBlock`, `diagram`, and
/// inline `<math>` source editing.
@MainActor
final class DocumentEngineSourceTests: DocumentEngineTestCase {
    private func mathBlock(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: SourceBlock.mathBlock, props: [],
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func diagramBlock(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: SourceBlock.diagram, props: [],
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func inlineMathItemID(in doc: YDoc, blockID: String) throws -> YID {
        let writer = BlockNoteWriter(doc: doc)
        let block = try writer.find(blockID)
        let item = try XCTUnwrap(
            writer.children(block.element).first {
                guard case .type(let type) = $0.content else { return false }
                return type.typeRef == .xmlElement(nodeName: NativeInlineObject.mathNodeName)
            })
        return item.id
    }

    func testOpenSourceSyntheticIDsPlainTextRulesAndRefusedStructuralCommands() throws {
        let doc = try makeDoc(
            [
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps,
                    runs: [InlineRun("See  here")],
                    id: "p"),
                mathBlock("mx", "a + b"),
                diagramBlock("dx", "graph TD"),
            ],
            clientID: 1)
        defer { doc.destroy() }
        let seedWriter = BlockNoteWriter(doc: doc)
        try seedWriter.insertInlineMath(
            in: try seedWriter.find("p"), replacing: 4..<4, source: "x^2", trailingSpace: false)
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        let mxID = try XCTUnwrap(engine.openSource(.block(id: "mx")))
        let dxID = try XCTUnwrap(engine.openSource(.block(id: "dx")))
        let mathItem = try inlineMathItemID(in: doc, blockID: "p")
        let inlineID = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: mathItem)))

        XCTAssertTrue(mxID.hasPrefix("mx\(SourceTarget.separator)"))
        XCTAssertTrue(dxID.hasPrefix("dx\(SourceTarget.separator)"))
        XCTAssertTrue(inlineID.hasPrefix("p\(SourceTarget.separator)"))
        XCTAssertTrue(SourceTarget.isSourceID(mxID))
        XCTAssertEqual(SourceTarget.ownerID(of: inlineID), "p")

        XCTAssertEqual(engine.sourceSnapshot(mxID)?.first?.runs, [InlineRun("a + b")])
        XCTAssertEqual(engine.sourceSnapshot(mxID)?.first?.node, "codeBlock")
        XCTAssertEqual(engine.sourceSnapshot(inlineID)?.first?.runs, [InlineRun("x^2")])
        XCTAssertEqual(engine.sourceSnapshot(inlineID)?.first?.node, "paragraph")

        // Newlines allowed in mathBlock/diagram, forbidden in inline math.
        try engine.replaceText(block: mxID, range: 5..<5, with: "\nc + d")
        try engine.replaceText(block: dxID, range: 8..<8, with: "\n  A-->B")
        XCTAssertEqual(engine.sourceSnapshot(mxID)?.first?.runs, [InlineRun("a + b\nc + d")])
        XCTAssertThrowsError(try engine.replaceText(block: inlineID, range: 3..<3, with: "\n+y")) {
            XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput)
        }

        // Formatting marks and U+FFFC refused in all source targets.
        XCTAssertThrowsError(
            try engine.replaceText(
                block: mxID, range: 0..<1, with: "z", marks: [TextMark(key: "bold", valueJSON: "{}")])
        ) { XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput) }
        XCTAssertThrowsError(try engine.replaceText(block: inlineID, range: 0..<0, with: "\u{fffc}")) {
            XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput)
        }

        // Structural commands refused on open source targets.
        for kind: NativeEditCommand.Kind in [
            .split(offset: 1, newID: "s1", open: []),
            .marks(
                NativeMarkCommand(
                    startOffset: 0, endBlockID: mxID, endOffset: 1,
                    attributes: [TextMark(key: "bold", valueJSON: "{}")])),
            .lineBreak(offset: 1),
            .blockType(node: "paragraph", props: [], removing: 0..<0),
            .insertSourceBlock(node: SourceBlock.mathBlock, newID: "s2", removing: 0..<0),
            .insertInlineMath(replacing: 0..<0),
        ] {
            XCTAssertThrowsError(
                try engine.applyStructural(
                    NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: mxID, kind: kind),
                    persist: { _ in })
            ) { XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput) }
        }
    }

    func testEmptySourceAnchorsSelectionComposesAndUpdatesOuterPreviewWithoutOuterTextPatch() throws {
        let doc = try makeDoc([mathBlock("mx", "")], clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))
        XCTAssertEqual(engine.sourceSnapshot(sid)?.first?.runs, [])

        // Empty source element supports selection and IME composition from offset 0.
        try engine.setSelection(
            EditorSelection(
                anchor: EditorPosition(blockID: sid, offset: 0),
                head: EditorPosition(blockID: sid, offset: 0)))
        XCTAssertEqual(try engine.currentSelection()?.head, EditorPosition(blockID: sid, offset: 0, assoc: -1))

        try engine.compositionBegan(blockID: sid)
        try engine.compositionCommitted(text: "\\alpha")
        XCTAssertEqual(engine.sourceSnapshot(sid)?.first?.runs, [InlineRun("\\alpha")])
        XCTAssertEqual(try engine.currentSelection()?.head, EditorPosition(blockID: sid, offset: 6, assoc: -1))

        // Outer document surface gets `.replaceBlock("mx")` with updated `.source` preview,
        // never `.text("mx", ...)`.
        let outerChanges = surface.appliedPatches.flatMap(\.changes)
        XCTAssertFalse(
            outerChanges.contains {
                if case .text(let id, _) = $0 { return id == "mx" }
                return false
            })
        guard case .source(_, let lines, _)? = surface.blocks.first(where: { $0.id == "mx" })?.preview else {
            return XCTFail("missing outer preview")
        }
        XCTAssertEqual(lines, ["\\alpha"])
    }

    func testClosedSourceNeverEmitsTextPatchOnPeerEdit() throws {
        let a = try makeDoc([mathBlock("mx", "x^2")], clientID: 1)
        let b = try makeDoc([mathBlock("mx", "x^2")], clientID: 2)
        defer {
            a.destroy()
            b.destroy()
        }
        let surfaceA = HeadlessSurface(blocks: projection(a))
        let engineA = DocumentEngine(doc: a, surface: surfaceA)

        // Peer writes directly inside closed mathBlock XmlText.
        let writerB = BlockNoteWriter(doc: b)
        let elementB = try writerB.findSource("mx").element
        let update = try writerB.replaceSourceText(in: elementB, range: 3..<3, with: " + y^2", block: "mx")
        try a.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        _ = engineA.revision

        let changes = surfaceA.appliedPatches.flatMap(\.changes)
        XCTAssertFalse(
            changes.contains {
                if case .text(let id, _) = $0 { return id == "mx" }
                return false
            })
        XCTAssertTrue(
            changes.contains {
                if case .replaceBlock(let id, let block) = $0, id == "mx",
                    case .source(_, let lines, _)? = block.preview
                {
                    return lines == ["x^2 + y^2"]
                }
                return false
            })
        assertSurfaceMatchesProjection(surfaceA, a, "outer preview matches replica")
    }

    func testPeerDeleteReplaceItemIDAndUnfamiliarEditDropOpenSourceAndOrphanComposition() throws {
        // 1. Peer deletes mathBlock while open and composing.
        do {
            let local = try makeDoc(
                [
                    BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("A")], id: "p"),
                    mathBlock("mx", "x"),
                ],
                clientID: 1)
            let peer = try makeDoc(
                [
                    BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("A")], id: "p"),
                    mathBlock("mx", "x"),
                ],
                clientID: 2)
            defer {
                local.destroy()
                peer.destroy()
            }
            let surface = HeadlessSurface(blocks: projection(local))
            let engine = DocumentEngine(doc: local, surface: surface)
            let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))

            try engine.compositionBegan(blockID: sid, at: 1)
            let writer = BlockNoteWriter(doc: peer)
            let target = try writer.findSource("mx")
            let update = try writer.deleteBlock(target.item, id: "mx")
            try local.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)

            let result = try engine.compositionCommitted(text: "z", commandID: UUID()) { _, _ in }
            XCTAssertEqual(result, .orphaned)
            XCTAssertNil(engine.sourceSnapshot(sid))
            XCTAssertTrue(
                surface.appliedPatches.flatMap(\.changes).contains {
                    if case .reset(let blocks) = $0 {
                        return !blocks.contains { $0.id == sid || $0.id == "mx" }
                    }
                    if case .remove(let ids) = $0 { return ids.contains(sid) }
                    return false
                })
            XCTAssertFalse(surface.blocks.contains { $0.id == sid || $0.id == "mx" })
        }

        // 2. Peer replaces mathBlock's inner element with a brand new mathBlock item under same container id.
        do {
            let local = try makeDoc([mathBlock("mx", "old")], clientID: 1)
            let peer = try makeDoc([mathBlock("mx", "old")], clientID: 2)
            defer {
                local.destroy()
                peer.destroy()
            }
            let surface = HeadlessSurface(blocks: projection(local))
            let engine = DocumentEngine(doc: local, surface: surface)
            let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))

            let writer = BlockNoteWriter(doc: peer)
            let update = try writer.transaction { tx in
                let old = try writer.findSource("mx")
                old.element.item?.delete(tx)
                let replacement = YType(typeRef: .xmlElement(nodeName: SourceBlock.mathBlock))
                _ = try YWrite.insertAfter(tx, into: old.container, after: nil, [.type(replacement)])
                let text = YType(typeRef: .xmlText)
                _ = try YWrite.insertAfter(tx, into: replacement, after: nil, [.type(text)])
                try text.insert(0, "new", [:])
            }
            try local.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)

            XCTAssertNil(engine.sourceSnapshot(sid), "replaced item must drop old source surface")
            XCTAssertTrue(
                surface.appliedPatches.flatMap(\.changes).contains {
                    if case .remove(let ids) = $0 { return ids.contains(sid) }
                    return false
                })
        }

        // 3. Peer adds an invalid mark inside an open inline math -> dropped as unfamiliar.
        do {
            let local = try makeDoc(
                [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps,
                        runs: [], id: "p")
                ],
                clientID: 1)
            let seedWriter = BlockNoteWriter(doc: local)
            try seedWriter.insertInlineMath(
                in: try seedWriter.find("p"), replacing: 0..<0, source: "a", trailingSpace: false)
            let peer = YDoc(clientID: 2, gc: true)
            try peer.applyUpdate(YUpdateDecoder.decode(try YStateEncoder.encodeStateAsUpdate(local)))
            defer {
                local.destroy()
                peer.destroy()
            }
            let surface = HeadlessSurface(blocks: projection(local))
            let engine = DocumentEngine(doc: local, surface: surface)
            let itemID = try inlineMathItemID(in: local, blockID: "p")
            let sid = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: itemID)))

            let peerMathItem = try inlineMathItemID(in: peer, blockID: "p")
            let writer = BlockNoteWriter(doc: peer)
            let update = try writer.transaction { _ in
                let p = try writer.find("p")
                guard let child = writer.children(p.element).first(where: { $0.id == peerMathItem }),
                    case .type(let mathEl) = child.content,
                    let textItem = writer.children(mathEl).first,
                    case .type(let xmlText) = textItem.content
                else { return }
                try xmlText.format(0, 1, ["bold": "true"])
            }
            try local.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)

            XCTAssertNil(engine.sourceSnapshot(sid), "unfamiliar source edit must close source surface")
            XCTAssertTrue(
                surface.appliedPatches.flatMap(\.changes).contains {
                    if case .remove(let ids) = $0 { return ids.contains(sid) }
                    return false
                })
        }
    }

    func testAwarenessAndUndoNestedSelectionAdaptBetweenOpenAndClosedSource() throws {
        let doc = try makeDoc(
            [
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps,
                    runs: [InlineRun("Abcd")],
                    id: "p"),
                mathBlock("mx", "e = mc^2"),
            ],
            clientID: 1)
        defer { doc.destroy() }
        let seedWriter = BlockNoteWriter(doc: doc)
        try seedWriter.insertInlineMath(
            in: try seedWriter.find("p"), replacing: 2..<2, source: "xyz", trailingSpace: false)
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let history = ReplicaHistory(doc: doc, engine: engine)
        defer { history.destroy() }

        // Open mathBlock source, type with selection, check awareness open vs closed.
        let mxID = try XCTUnwrap(engine.openSource(.block(id: "mx")))
        try engine.setSelection(
            EditorSelection(
                anchor: EditorPosition(blockID: mxID, offset: 2),
                head: EditorPosition(blockID: mxID, offset: 2)))
        let openRel = try XCTUnwrap(engine.awarenessPosition(EditorPosition(blockID: mxID, offset: 2)))
        XCTAssertEqual(engine.peerPlace(openRel), .text(EditorPosition(blockID: mxID, offset: 2, assoc: -1)))

        try engine.replaceText(block: mxID, range: 2..<2, with: "+1")
        XCTAssertEqual(engine.sourceSnapshot(mxID)?.first?.runs, [InlineRun("e +1= mc^2")])

        engine.closeSource(mxID)
        XCTAssertEqual(engine.peerPlace(openRel), .block("mx"))

        // Undo after closing source restores selection to card "mx" without crashing or bad offset.
        XCTAssertTrue(
            try engine.applyHistoryStep(
                NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "mx", kind: .undo),
                step: { try history.step(undo: true) },
                persist: { _ in }))
        XCTAssertEqual(try engine.currentSelection()?.head, EditorPosition(blockID: "mx", offset: 0, assoc: -1))
        guard case .source(_, let lines, _)? = surface.blocks.first(where: { $0.id == "mx" })?.preview else {
            return XCTFail("missing preview after undo")
        }
        XCTAssertEqual(lines, ["e = mc^2"])

        // Inline math closed restores nested selection back to inline math chip offset (2) in "p".
        let itemID = try inlineMathItemID(in: doc, blockID: "p")
        let inlineID = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: itemID)))
        history.stopCapturing()
        try engine.setSelection(
            EditorSelection(
                anchor: EditorPosition(blockID: inlineID, offset: 3),
                head: EditorPosition(blockID: inlineID, offset: 3)))
        let inlineRel = try XCTUnwrap(engine.awarenessPosition(EditorPosition(blockID: inlineID, offset: 3)))
        XCTAssertEqual(engine.peerPlace(inlineRel), .text(EditorPosition(blockID: inlineID, offset: 3, assoc: -1)))

        try engine.replaceText(block: inlineID, range: 3..<3, with: "+1")
        engine.closeSource(inlineID)
        XCTAssertEqual(engine.peerPlace(inlineRel), .block("p"))

        XCTAssertTrue(
            try engine.applyHistoryStep(
                NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "p", kind: .undo),
                step: { try history.step(undo: true) },
                persist: { _ in }))
        XCTAssertEqual(try engine.currentSelection()?.head, EditorPosition(blockID: "p", offset: 2, assoc: -1))
    }

    func testCanonicalIndexRejectsSourceSeparatorInBlockID() throws {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(
            YUpdateDecoder.decode(
                BlockNoteYjs.encode(
                    [
                        BlockNoteBlock(
                            node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("hi")], id: "a\u{2}b")
                    ],
                    clientID: 1)))
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        XCTAssertNil(engine.openSource(.block(id: "a\u{2}b")))
        XCTAssertThrowsError(try engine.replaceText(block: "a\u{2}b", range: 0..<0, with: "x")) {
            XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput)
        }
    }

    func testClosedColumnSourceCanOpenEditAndReportAwareness() throws {
        let capture = try XCTUnwrap(BlockNoteSourceCaptures.fixtures.first { $0.name == "sourceInColumns" })
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: capture.update))))
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))
        let rel = try XCTUnwrap(engine.awarenessPosition(EditorPosition(blockID: sid, offset: 1)))
        XCTAssertEqual(engine.peerPlace(rel), .text(EditorPosition(blockID: sid, offset: 1, assoc: -1)))

        try engine.replaceText(block: sid, range: 3..<3, with: "+1")
        XCTAssertEqual(engine.sourceSnapshot(sid)?.first?.runs, [InlineRun("x^2+1")])

        // Closing source still maps column peer cursor back to the closed columnList card "cl".
        engine.closeSource(sid)
        XCTAssertEqual(engine.peerPlace(rel), .block("cl"))
    }

    func testS1OpenSourceRefusesOversizedAndObjectReplacementCharacters() throws {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.transact(local: true) { tx in
            let root = doc.get(BlockNoteYjs.fragmentField)
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            var after: YItem?
            func addBlock(_ id: String, node: String, textValue: String) throws {
                let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                after = try YWrite.insertAfter(tx, into: group, after: after, [.type(container)])
                try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
                let el = YType(typeRef: .xmlElement(nodeName: node))
                try YWrite.insertAfter(tx, into: container, after: nil, [.type(el)])
                let txt = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: el, after: nil, [.type(txt)])
                try txt.insert(0, textValue, nil)
            }
            try addBlock(
                "mx-huge", node: SourceBlock.mathBlock,
                textValue: String(repeating: "a", count: SourceBlock.maxSourceUTF16 + 1))
            try addBlock("dx-fffc", node: SourceBlock.diagram, textValue: "graph\u{FFFC}TD")
            try addBlock(
                "mx-editable", node: SourceBlock.mathBlock,
                textValue: String(repeating: "b", count: NativeInlineObject.maxMathUTF16 + 1))

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("p")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            var pChild: YItem?
            for mathText in [
                String(repeating: "x", count: NativeInlineObject.maxMathUTF16 + 1),
                "a\u{FFFC}b",
            ] {
                let math = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
                pChild = try YWrite.insertAfter(tx, into: pEl, after: pChild, [.type(math)])
                let txt = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: math, after: nil, [.type(txt)])
                try txt.insert(0, mathText, nil)
            }
        }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        XCTAssertNil(engine.openSource(.block(id: "mx-huge")))
        XCTAssertNil(engine.openSource(.block(id: "dx-fffc")))
        XCTAssertNotNil(engine.openSource(.block(id: "mx-editable")))

        let writer = BlockNoteWriter(doc: doc)
        let pChildren = writer.children(try writer.find("p").element)
        XCTAssertEqual(pChildren.count, 2)
        XCTAssertNil(engine.openSource(.inlineMath(blockID: "p", itemID: pChildren[0].id)))
        XCTAssertNil(engine.openSource(.inlineMath(blockID: "p", itemID: pChildren[1].id)))
    }

    func testS2CompositionCommittedRejectsControlAndOverflowWithoutFreezing() throws {
        let doc = try makeDoc(
            [
                BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("x")], id: "p"),
                mathBlock("mx", String(repeating: "a", count: SourceBlock.maxSourceUTF16 - 5)),
            ],
            clientID: 1)
        defer { doc.destroy() }
        let seedWriter = BlockNoteWriter(doc: doc)
        try seedWriter.insertInlineMath(
            in: try seedWriter.find("p"), replacing: 1..<1,
            source: String(repeating: "y", count: NativeInlineObject.maxMathUTF16 - 5), trailingSpace: false)

        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let mxID = try XCTUnwrap(engine.openSource(.block(id: "mx")))
        try engine.compositionBegan(blockID: mxID, at: 0)
        XCTAssertThrowsError(try engine.compositionCommitted(text: "\u{000C}")) {
            XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput)
        }
        XCTAssertFalse(engine.nativeWriteFailed)
        XCTAssertFalse(engine.isComposing)

        try engine.compositionBegan(blockID: mxID, at: 0)
        XCTAssertThrowsError(try engine.compositionCommitted(text: "123456")) {
            XCTAssertEqual($0 as? DocumentEngineError, .payloadTooLarge)
        }
        XCTAssertFalse(engine.nativeWriteFailed)
        XCTAssertFalse(engine.isComposing)

        let mathItem = try inlineMathItemID(in: doc, blockID: "p")
        let inlineID = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: mathItem)))
        for bad in ["\t", "\u{202E}", "\u{001B}"] {
            try engine.compositionBegan(blockID: inlineID, at: 0)
            XCTAssertThrowsError(try engine.compositionCommitted(text: bad)) {
                XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput)
            }
            XCTAssertFalse(engine.nativeWriteFailed)
            XCTAssertFalse(engine.isComposing)
        }
        try engine.compositionBegan(blockID: inlineID, at: 0)
        XCTAssertThrowsError(try engine.compositionCommitted(text: "123456")) {
            XCTAssertEqual($0 as? DocumentEngineError, .payloadTooLarge)
        }
        XCTAssertFalse(engine.nativeWriteFailed)
        XCTAssertFalse(engine.isComposing)

        // Valid commit still succeeds afterwards.
        try engine.compositionBegan(blockID: inlineID, at: 0)
        try engine.compositionCommitted(text: "12345")
        XCTAssertEqual(
            engine.sourceSnapshot(inlineID)?.first?.runs.first?.text.utf16.count, NativeInlineObject.maxMathUTF16)
    }

    func testS3InlinePasteAndTableClipboardAndCumulativeSourceCaps() throws {
        let doc = try makeDoc(
            [
                BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("hi")], id: "p"),
                mathBlock("mx", String(repeating: "a", count: SourceBlock.maxSourceUTF16 - 4)),
            ],
            clientID: 1)
        defer { doc.destroy() }
        let seedWriter = BlockNoteWriter(doc: doc)
        try seedWriter.insertInlineMath(
            in: try seedWriter.find("p"), replacing: 2..<2,
            source: String(repeating: "b", count: NativeInlineObject.maxMathUTF16 - 4), trailingSpace: false)
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        // 1. 11 <math> elements of 20,000 UTF-16 units = 220,000 > NativeClipboard.maxPasteUTF16 (200,000).
        let mathSource = String(repeating: "x", count: NativeInlineObject.maxMathUTF16)
        let mathElements: [BlockNoteWriter.Copy] = (0..<11).map { _ in
            .element(NativeInlineObject.mathNodeName, [], [.text([.run(InlineRun(mathSource))])])
        }
        let hugeInlinePayload = try BlockNoteInlinePayload.encode([mathElements])
        XCTAssertThrowsError(
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .pasteInline(
                        payload: hugeInlinePayload,
                        range: NativeRangeCommand(
                            startOffset: 0, endBlockID: "p", endOffset: 0, replacement: "", newBlockIDs: []))),
                persist: { _ in })
        ) { XCTAssertEqual($0 as? DocumentEngineError, .payloadTooLarge) }

        // 2. TableClipboard.isTooLarge counts inline .math source UTF-16 length.
        let cells: [[TablePastedCell]] = [
            (0..<11).map { _ in
                TablePastedCell(
                    node: "tableCell", attrs: [:], runs: [InlineRun(inlineObject: .math(source: mathSource))])
            }
        ]
        XCTAssertTrue(TableClipboard.isTooLarge(cells, repeated: 1))

        // 3. Cumulative replaceText bounds for mathBlock and inline <math>.
        let mxID = try XCTUnwrap(engine.openSource(.block(id: "mx")))
        XCTAssertThrowsError(try engine.replaceText(block: mxID, range: 0..<0, with: "12345")) {
            XCTAssertEqual($0 as? DocumentEngineError, .payloadTooLarge)
        }
        try engine.replaceText(block: mxID, range: 0..<0, with: "1234")

        let mathItem = try inlineMathItemID(in: doc, blockID: "p")
        let inlineID = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: mathItem)))
        XCTAssertThrowsError(try engine.replaceText(block: inlineID, range: 0..<0, with: "12345")) {
            XCTAssertEqual($0 as? DocumentEngineError, .payloadTooLarge)
        }
        try engine.replaceText(block: inlineID, range: 0..<0, with: "1234")
    }
}
