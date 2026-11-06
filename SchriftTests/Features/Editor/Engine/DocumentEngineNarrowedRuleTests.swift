import XCTest

@testable import Schrift

/// Review round 2: the `.text` fast path is narrowed to one shape, and every
/// other touched block is rebuilt from its projection.
@MainActor
final class DocumentEngineNarrowedRuleTests: DocumentEngineTestCase {
    private static let parentID = "b0000000-0000-4000-8000-0000000000d1"
    private static let childID = "b0000000-0000-4000-8000-0000000000d2"
    private static let newRootID = "b0000000-0000-4000-8000-0000000000d3"

    private func nestedSeed() -> [BlockNoteBlock] {
        [
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Parent")],
                id: Self.parentID,
                children: [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Child")],
                        id: Self.childID)
                ])
        ]
    }

    private func rootGroup(_ doc: YDoc) throws -> YType {
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        var item = root.start
        while let current = item {
            defer { item = current.right }
            if case .type(let type) = current.content, type.typeRef == .xmlElement(nodeName: "blockGroup") {
                return type
            }
        }
        throw XCTSkip("no root group")
    }

    private func hasReset(_ patch: BlockPatch) -> Bool {
        patch.changes.contains { if case .reset = $0 { return true } else { return false } }
    }

    private func hasReplace(_ patch: BlockPatch, _ id: String) -> Bool {
        patch.changes.contains {
            if case .replaceBlock(let blockID, _) = $0 { return blockID == id } else { return false }
        }
    }

    // MARK: - 1. Fragment root / root group

    func testPopulatingAnEmptyFragmentResetsTheSurface() throws {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let surface = HeadlessSurface()
        let engine = DocumentEngine(doc: doc, surface: surface)

        try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1)))

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(hasReset(patch), "populating an empty fragment must reset, got \(patch.changes)")
        assertSurfaceMatchesProjection(surface, doc, "after populating the empty fragment")
        _ = engine
    }

    func testReplacingTheRootGroupResetsTheSurface() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        let oldGroup = try rootGroup(doc)
        try doc.transact { tx in
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            _ = try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            let element = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            _ = try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
            let text = YType(typeRef: .xmlText)
            _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)])
            try text.insert(0, "New root")
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string(Self.newRootID)]))
            oldGroup.item?.delete(tx)
        }

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(hasReset(patch), "replacing the root group must reset, got \(patch.changes)")
        XCTAssertEqual(surface.blocks.map(\.id), [Self.newRootID])
        assertSurfaceMatchesProjection(surface, doc, "after replacing the root group")
        _ = engine
    }

    // MARK: - 2. Several XmlText children

    func testTwoTextChildrenReplaceTheBlock() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let index = BlockIndex(doc: doc)
        let entry = try XCTUnwrap(index.entries[Self.firstID])
        let element = try XCTUnwrap(entry.element)
        let oldText = try XCTUnwrap(entry.textType)
        try doc.transact { tx in
            oldText.item?.delete(tx)
            let first = YType(typeRef: .xmlText)
            let second = YType(typeRef: .xmlText)
            _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(first), .type(second)])
            try first.insert(0, "Parent")
            try second.insert(0, "Tail")
        }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        // Offset 7 is inside the second text child: its own delta offset is 1,
        // so a `.text` patch would land at the wrong block offset.
        try engine.replaceText(block: Self.firstID, range: 7..<7, with: "X")

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(hasReplace(patch, Self.firstID), "two text children must rebuild, got \(patch.changes)")
        XCTAssertEqual(text(of: try XCTUnwrap(block(surface, Self.firstID))), "ParentTXail")
        assertSurfaceMatchesProjection(surface, doc, "after inserting in the second text child")
    }

    // MARK: - 3. Container replaced in place

    func testReplacingAContainerWithTheSameIDReplacesTheBlock() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        let index = BlockIndex(doc: doc)
        let entry = try XCTUnwrap(index.entries[Self.firstID])
        let group = try rootGroup(doc)
        try doc.transact { tx in
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: entry.containerItem.left, [.type(container)])
            let element = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            _ = try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
            let text = YType(typeRef: .xmlText)
            _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)])
            try text.insert(0, "Replaced")
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string(Self.firstID)]))
            entry.containerItem.delete(tx)
        }

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(hasReplace(patch, Self.firstID), "a replaced container must rebuild, got \(patch.changes)")
        XCTAssertEqual(text(of: try XCTUnwrap(block(surface, Self.firstID))), "Replaced")
        assertSurfaceMatchesProjection(surface, doc, "after replacing the container")
        _ = engine
    }

    // MARK: - 4. Nested element attributes

    func testNestedElementAttributesReplaceTheTopLevelBlock() throws {
        let doc = try makeDoc(nestedSeed(), clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.setBlockType(block: Self.childID, to: "paragraph", props: [("textColor", .string("red"))])

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(
            hasReplace(patch, Self.parentID), "nested attributes must rebuild the parent, got \(patch.changes)")
        XCTAssertFalse(
            patch.changes.contains { if case .props = $0 { return true } else { return false } },
            "a nested attribute change is not the parent's props")
        assertSurfaceMatchesProjection(surface, doc, "after the nested attribute change")
    }

    // MARK: - 5. Parent text with nested children

    func testParentTextEditWithNestedChildrenReplacesTheBlock() throws {
        let doc = try makeDoc(nestedSeed(), clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.replaceText(block: Self.parentID, range: 0..<0, with: "X")

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(hasReplace(patch, Self.parentID), "a parent with children must rebuild, got \(patch.changes)")
        assertSurfaceMatchesProjection(surface, doc, "after the parent text edit")
    }

    // MARK: - 6. Patch origin

    func testLocalAndRemotePatchesCarryTheirOrigin() throws {
        let local = try makeDoc(clientID: 1)
        let remote = try makeDoc(clientID: 2)
        defer {
            local.destroy()
            remote.destroy()
        }
        let localSurface = HeadlessSurface(blocks: projection(local))
        let localEngine = DocumentEngine(doc: local, surface: localSurface)
        let remoteEngine = DocumentEngine(doc: remote, surface: HeadlessSurface(blocks: projection(remote)))

        try localEngine.replaceText(block: Self.firstID, range: 0..<0, with: "A")
        XCTAssertEqual(localSurface.appliedPatches.last?.origin, .localUser)

        let update = try remoteEngine.replaceText(block: Self.firstID, range: 0..<0, with: "B")
        try local.applyUpdate(try YUpdateDecoder.decode(update), origin: .remote)
        XCTAssertEqual(localSurface.appliedPatches.last?.origin, .remote)
        assertSurfaceMatchesProjection(localSurface, local, "after the remote update")
    }

    // MARK: - 7. O(touched) emit loop

    func testTextTransactionVisitsOnlyTouchedEntries() throws {
        let blocks = (0..<60).map { index in
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("Paragraph number \(index) with some text in it.")],
                id: String(format: "b0000000-0000-4000-8000-%012d", index))
        }
        let doc = try makeDoc(blocks, clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let before = engine.visitedEntryCount

        try engine.replaceText(block: "b0000000-0000-4000-8000-000000000030", range: 5..<5, with: "X")

        XCTAssertEqual(engine.visitedEntryCount - before, 1, "the emit loop must visit only the touched block")
        assertSurfaceMatchesProjection(surface, doc, "after typing in a 60-block document")
    }

    // MARK: - 8. Deterministic mark order

    func testInsertMarksFollowFormatItemOrderDeterministically() throws {
        let blocks = [
            BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [], id: Self.firstID)
        ]
        let doc = try makeDoc(blocks, clientID: 1)
        defer { doc.destroy() }
        let index = BlockIndex(doc: doc)
        let text = try XCTUnwrap(index.entries[Self.firstID]?.textType)

        // The delta's attributes are a Dictionary; the text's format items keep
        // the caller's order. Build the items in the reverse of the Dictionary's
        // order, so only format-item order can produce the expected sequence.
        let attributes: [String: YDeltaAttribute] = ["bold": .json("{}"), "italic": .json("{}")]
        let dictionaryOrder = Array(attributes.keys)
        let itemOrder = Array(dictionaryOrder.reversed())
        let textAttributes = YTextAttributes(itemOrder.map { ($0, "{}") })
        try text.insert(0, "X", textAttributes)

        let marks = try XCTUnwrap(
            PatchBuilder.marks(in: text, range: 0..<1, attributes: attributes))
        XCTAssertEqual(marks.map(\.key), itemOrder)
        XCTAssertNotEqual(marks.map(\.key), dictionaryOrder)
    }
}
