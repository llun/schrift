import Foundation
import XCTest

@testable import Schrift

final class BlockNoteSourceOracleTests: XCTestCase {
    private static let testOrigin = "https://docs.example"

    func testAllSourceCapturesAreModeledAndMatchYProviderShadow() throws {
        let requiresOrigin = Set(["inlineMathBesideChips", "inlineMathInTable"])
        let canonicalFallbackOnly = Set([
            "bulletsAroundMath",
            "bulletsAroundDiagram",
            "nestedUnderBullet",
            "inlineMathOnlyBlock",
            "inlineMathAdjacent",
            "inlineMathInLists",
            "inlineMathInColumns",
        ])

        for fixture in BlockNoteSourceCaptures.fixtures {
            let doc = try decodeDoc(fixture.update)
            defer { doc.destroy() }

            XCTAssertEqual(YXMLString.fragment(doc), fixture.xml, "\(fixture.name): xml")

            let native = NativeBlockProjection.project(doc)
            XCTAssertTrue(native.isFullyRenderable, "\(fixture.name): renderable")
            if fixture.name == "inlineMathInQuoteAndCallout" {
                XCTAssertEqual(native.blocks.first?.block.fidelity, .modeled)
                XCTAssertEqual(native.blocks.last?.block.fidelity, .lossy(reasons: ["prop:emoji"]))
            } else {
                XCTAssertTrue(native.isFullyModeled, "\(fixture.name): modeled")
            }

            for snapshot in native.blocks {
                for run in snapshot.block.runs where run.inlineObject != nil {
                    XCTAssertEqual(run.text, "\u{FFFC}", "\(fixture.name): 1-unit placeholder")
                    XCTAssertTrue(run.marks.isEmpty, "\(fixture.name): inline object carries no marks")
                }
            }

            let shadow = try XCTUnwrap(
                NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin),
                "\(fixture.name): expected shadow with origin")
            XCTAssertEqual(
                syncCanonicalMarkdown(shadow), syncCanonicalMarkdown(fixture.markdown),
                "\(fixture.name): syncCanonicalMarkdown mismatch")
            XCTAssertEqual(
                canonicalMarkdown(shadow), canonicalMarkdown(fixture.markdown),
                "\(fixture.name): canonicalMarkdown mismatch")
            if !canonicalFallbackOnly.contains(fixture.name) {
                XCTAssertEqual(shadow, fixture.markdown, "\(fixture.name): exact shadow mismatch")
            }

            let slashOriginShadow = NativeBlockProjection.markdownShadow(
                doc, interlinkingOrigin: Self.testOrigin + "/")
            XCTAssertEqual(slashOriginShadow, shadow, "\(fixture.name): trailing slash trimmed")

            let nilOriginShadow = NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: nil)
            let emptyOriginShadow = NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: "")
            let slashOnlyOriginShadow = NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: "/")
            if requiresOrigin.contains(fixture.name) {
                XCTAssertNil(nilOriginShadow, "\(fixture.name): active interlink fails closed without origin")
                XCTAssertNil(emptyOriginShadow, "\(fixture.name): active interlink fails closed on empty origin")
                XCTAssertNil(slashOnlyOriginShadow, "\(fixture.name): active interlink fails closed on '/' origin")
            } else {
                XCTAssertEqual(nilOriginShadow, shadow, "\(fixture.name): nil origin allowed without active interlink")
                XCTAssertEqual(emptyOriginShadow, shadow, "\(fixture.name): empty origin allowed")
                XCTAssertEqual(slashOnlyOriginShadow, shadow, "\(fixture.name): slash-only origin allowed")
            }
        }
    }

    func testClassicProjectionKeepsSourceBlocksAndInlineMathOpaque() throws {
        let names = ["mathBlockBasic", "diagramBasic", "inlineMathBasic", "mathBlockOnly", "diagramOnly"]
        for name in names {
            let fixture = try XCTUnwrap(BlockNoteSourceCaptures.fixtures.first { $0.name == name }, name)
            let doc = try decodeDoc(fixture.update)
            defer { doc.destroy() }

            let classic = YBlockProjection.project(doc)
            XCTAssertFalse(classic.blocks.isEmpty, "\(name): classic blocks present")
            XCTAssertTrue(
                classic.blocks.contains { block in
                    if case .opaque = block.fidelity { return true }
                    return false
                },
                "\(name): classic projection must keep math/diagram opaque")
        }
    }

    func testAllWebSourceAndInlineMathEditsMatchXMLAndShadowWhenPerformedNatively() throws {
        var covered: Set<String> = []

        func runEdit(
            _ name: String,
            exactShadow: Bool = true,
            perform: (YDoc, BlockNoteWriter) throws -> Void
        ) throws {
            let capture = try XCTUnwrap(BlockNoteSourceCaptures.edits.first { $0.name == name }, "missing \(name)")
            covered.insert(name)
            let doc = try decodeDoc(capture.seed)
            defer { doc.destroy() }
            let writer = BlockNoteWriter(doc: doc, schemas: BlockNoteWriter.nativePropSchemas)

            try perform(doc, writer)

            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, "\(name): xml mismatch")
            let shadow = try XCTUnwrap(
                NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin),
                "\(name): expected shadow")
            XCTAssertEqual(
                syncCanonicalMarkdown(shadow), syncCanonicalMarkdown(capture.markdown),
                "\(name): syncCanonicalMarkdown mismatch")
            if exactShadow {
                XCTAssertEqual(shadow, capture.markdown, "\(name): exact shadow mismatch")
            }
        }

        func inlineMathElement(in blockElement: YType, writer: BlockNoteWriter) throws -> YType {
            for item in writer.children(blockElement) {
                if case .type(let child) = item.content,
                    child.typeRef == .xmlElement(nodeName: NativeInlineObject.mathNodeName)
                {
                    return child
                }
            }
            throw NSError(domain: "BlockNoteSourceOracleTests", code: 1)
        }

        func firstTableParagraphItem(tableID: String, in doc: YDoc, writer: BlockNoteWriter) throws -> YItem {
            guard let root = doc.share[BlockNoteYjs.fragmentField] else {
                throw BlockNoteWriter.Error.missingBlock(tableID)
            }
            for item in writer.children(root) {
                guard case .type(let group) = item.content else { continue }
                for blockItem in writer.children(group) {
                    guard case .type(let container) = blockItem.content,
                        container.typeRef == .xmlElement(nodeName: "blockContainer"),
                        BlockIndex.blockID(of: container) == tableID,
                        let first = writer.children(container).first,
                        case .type(let tableElement) = first.content,
                        tableElement.typeRef == .xmlElement(nodeName: "table")
                    else { continue }
                    for rowItem in writer.children(tableElement) {
                        guard case .type(let row) = rowItem.content else { continue }
                        for cellItem in writer.children(row) {
                            guard case .type(let cell) = cellItem.content else { continue }
                            for tpItem in writer.children(cell) {
                                if case .type(let tp) = tpItem.content,
                                    tp.typeRef == .xmlElement(nodeName: "tableParagraph")
                                {
                                    return tpItem
                                }
                            }
                        }
                    }
                }
            }
            throw BlockNoteWriter.Error.missingBlock(tableID)
        }

        func findColumnListItem(id: String, in doc: YDoc, writer: BlockNoteWriter) throws -> YItem {
            guard let root = doc.share[BlockNoteYjs.fragmentField] else {
                throw BlockNoteWriter.Error.missingBlock(id)
            }
            for item in writer.children(root) {
                guard case .type(let group) = item.content else { continue }
                for candidate in writer.children(group) {
                    if case .type(let type) = candidate.content,
                        type.typeRef == .xmlElement(nodeName: "columnList"),
                        BlockIndex.blockID(of: type) == id
                    {
                        return candidate
                    }
                }
            }
            throw BlockNoteWriter.Error.missingBlock(id)
        }

        try runEdit("typeIntoMathBlock") { _, writer in
            let mx = try writer.findSource("mx")
            let len = SourceBlock.plainText(of: mx.element)?.utf16.count ?? 0
            try writer.replaceSourceText(in: mx.element, range: len..<len, with: " + y^2", block: "mx")
        }
        try runEdit("typeIntoMathBlockEmpty") { _, writer in
            let mx = try writer.findSource("mx")
            try writer.replaceSourceText(in: mx.element, range: 0..<0, with: "\\alpha", block: "mx")
        }
        try runEdit("typeIntoDiagram") { _, writer in
            let dx = try writer.findSource("dx")
            let len = SourceBlock.plainText(of: dx.element)?.utf16.count ?? 0
            try writer.replaceSourceText(in: dx.element, range: len..<len, with: "\n  B-->C", block: "dx")
        }
        try runEdit("typeIntoDiagramEmpty") { _, writer in
            let dx = try writer.findSource("dx")
            try writer.replaceSourceText(in: dx.element, range: 0..<0, with: "graph LR", block: "dx")
        }
        try runEdit("typeIntoInlineMath") { _, writer in
            let p = try writer.find("p")
            let math = try inlineMathElement(in: p.element, writer: writer)
            let len = NativeInlineObject.read(math)?.visibleText.utf16.count ?? 0
            try writer.replaceSourceText(in: math, range: len..<len, with: "+b^2", block: "p")
        }
        try runEdit("typeIntoInlineMathEmpty") { _, writer in
            let p = try writer.find("p")
            let math = try inlineMathElement(in: p.element, writer: writer)
            try writer.replaceSourceText(in: math, range: 0..<0, with: "x", block: "p")
        }
        try runEdit("replaceMathBlockContent") { _, writer in
            let mx = try writer.findSource("mx")
            let len = SourceBlock.plainText(of: mx.element)?.utf16.count ?? 0
            try writer.replaceSourceText(in: mx.element, range: 0..<len, with: "\\frac{a}{b}", block: "mx")
        }
        try runEdit("replaceDiagramContent") { _, writer in
            let dx = try writer.findSource("dx")
            let len = SourceBlock.plainText(of: dx.element)?.utf16.count ?? 0
            try writer.replaceSourceText(
                in: dx.element, range: 0..<len, with: "sequenceDiagram\n  A->>B: Ok", block: "dx")
        }
        try runEdit("replaceInlineMathContent") { _, writer in
            let p = try writer.find("p")
            let math = try inlineMathElement(in: p.element, writer: writer)
            let len = NativeInlineObject.read(math)?.visibleText.utf16.count ?? 0
            try writer.replaceSourceText(in: math, range: 0..<len, with: "c\\cdot d", block: "p")
        }
        try runEdit("replaceParagraphAcrossInlineMath") { _, writer in
            try writer.replaceText(block: "p", range: 1..<4, with: "X")
        }
        try runEdit("emptyMathBlock") { _, writer in
            let mx = try writer.findSource("mx")
            let len = SourceBlock.plainText(of: mx.element)?.utf16.count ?? 0
            try writer.replaceSourceText(in: mx.element, range: 0..<len, with: "", block: "mx")
        }
        try runEdit("emptyDiagram") { _, writer in
            let dx = try writer.findSource("dx")
            let len = SourceBlock.plainText(of: dx.element)?.utf16.count ?? 0
            try writer.replaceSourceText(in: dx.element, range: 0..<len, with: "", block: "dx")
        }
        try runEdit("emptyInlineMath") { _, writer in
            let p = try writer.find("p")
            let math = try inlineMathElement(in: p.element, writer: writer)
            let len = NativeInlineObject.read(math)?.visibleText.utf16.count ?? 0
            try writer.replaceSourceText(in: math, range: 0..<len, with: "", block: "p")
        }
        try runEdit("deleteMathBlock") { _, writer in
            let mx = try writer.findSource("mx")
            try writer.deleteBlock(mx.item, id: "mx")
        }
        try runEdit("deleteDiagram") { _, writer in
            let dx = try writer.findSource("dx")
            try writer.deleteBlock(dx.item, id: "dx")
        }
        try runEdit("deleteInlineMath") { _, writer in
            try writer.replaceText(block: "p", range: 7..<8, with: "")
        }
        try runEdit("deleteInlineMathBetweenBold") { _, writer in
            try writer.replaceText(block: "p", range: 5..<6, with: "")
        }
        try runEdit("deleteInlineMathInTableCell") { doc, writer in
            let tpItem = try firstTableParagraphItem(tableID: "tbl", in: doc, writer: writer)
            let target = try writer.tableParagraphTarget(tpItem, id: "tbl")
            try writer.replaceText(in: target, range: 2..<3, with: "")
        }
        try runEdit("deleteColumnMathBlockDropsColumnList") { doc, writer in
            let cl = try findColumnListItem(id: "cl", in: doc, writer: writer)
            try writer.applyColumns(.remove(index: 0), list: cl, block: "cl")
        }
        try runEdit("boldAcrossInlineMath") { _, writer in
            try writer.formatRange(block: "p", range: 0..<14, attributes: ["bold": "true"])
        }
        try runEdit("turnInlineMathParagraphIntoHeading") { _, writer in
            try writer.setBlockType(
                block: "p", to: "heading", props: [("level", .int(2)), ("isToggleable", .bool(false))])
        }
        try runEdit("splitAfterInlineMath") { _, writer in
            try writer.splitBlock(block: "p", at: 8, newID: "1")
        }
        try runEdit("slashMathBlockOnEmptyParagraph") { _, writer in
            let p = try writer.find("p")
            try writer.insertSourceBlock(SourceBlock.mathBlock, at: p.item, in: p.group, replacing: true, blockID: "p")
        }
        try runEdit("slashMathBlockOnStyledEmptyParagraph") { _, writer in
            let p = try writer.find("p")
            try writer.insertSourceBlock(SourceBlock.mathBlock, at: p.item, in: p.group, replacing: true, blockID: "p")
        }
        try runEdit("slashMathBlockAfterNonEmptyParagraph") { _, writer in
            let p = try writer.find("p")
            try writer.insertSourceBlock(SourceBlock.mathBlock, at: p.item, in: p.group, replacing: false, blockID: "1")
        }
        try runEdit("slashMathBlockNestedInToggle", exactShadow: false) { _, writer in
            let tp = try writer.find("tp")
            try writer.insertSourceBlock(
                SourceBlock.mathBlock, at: tp.item, in: tp.group, replacing: true, blockID: "tp")
        }
        try runEdit("slashDiagramOnEmptyParagraph") { _, writer in
            let p = try writer.find("p")
            try writer.insertSourceBlock(SourceBlock.diagram, at: p.item, in: p.group, replacing: true, blockID: "p")
        }
        try runEdit("slashDiagramOnStyledEmptyParagraph") { _, writer in
            let p = try writer.find("p")
            try writer.insertSourceBlock(SourceBlock.diagram, at: p.item, in: p.group, replacing: true, blockID: "p")
        }
        try runEdit("slashDiagramAfterNonEmptyParagraph") { _, writer in
            let p = try writer.find("p")
            try writer.insertSourceBlock(SourceBlock.diagram, at: p.item, in: p.group, replacing: false, blockID: "1")
        }
        try runEdit("slashInlineMathInEmptyParagraph") { _, writer in
            let p = try writer.find("p")
            try writer.insertInlineMath(in: p, replacing: 0..<0)
        }
        try runEdit("slashInlineMathInMiddle") { _, writer in
            let p = try writer.find("p")
            try writer.insertInlineMath(in: p, replacing: 6..<6)
        }
        try runEdit("slashInlineMathAtEnd") { _, writer in
            let p = try writer.find("p")
            try writer.insertInlineMath(in: p, replacing: 4..<4)
        }
        try runEdit("slashInlineMathInTableCell") { doc, writer in
            let tpItem = try firstTableParagraphItem(tableID: "tbl", in: doc, writer: writer)
            let target = try writer.tableParagraphTarget(tpItem, id: "tbl")
            try writer.insertInlineMath(in: target, replacing: 4..<4)
        }

        XCTAssertEqual(covered, Set(BlockNoteSourceCaptures.edits.map(\.name)))
    }

    @MainActor
    func testAllWebSourceAndInlineMathEditsThroughEngineMatchXMLAndShadow() throws {
        var covered: Set<String> = []

        func firstTableParagraphID(tableID: String, engine: DocumentEngine, doc: YDoc) throws -> String {
            let writer = BlockNoteWriter(doc: doc)
            guard let root = doc.share[BlockNoteYjs.fragmentField] else {
                throw NSError(domain: "BlockNoteSourceOracleTests", code: 2)
            }
            for item in writer.children(root) {
                guard case .type(let group) = item.content else { continue }
                for blockItem in writer.children(group) {
                    guard case .type(let container) = blockItem.content,
                        container.typeRef == .xmlElement(nodeName: "blockContainer"),
                        BlockIndex.blockID(of: container) == tableID,
                        let first = writer.children(container).first,
                        case .type(let tableElement) = first.content,
                        tableElement.typeRef == .xmlElement(nodeName: "table")
                    else { continue }
                    for row in writer.children(tableElement) {
                        guard case .type(let rowType) = row.content else { continue }
                        for cell in writer.children(rowType) {
                            guard case .type(let cellType) = cell.content else { continue }
                            if let paragraphItem = writer.children(cellType).first {
                                return TableGrid.paragraphID(table: tableID, item: paragraphItem.id)
                            }
                        }
                    }
                }
            }
            throw NSError(domain: "BlockNoteSourceOracleTests", code: 2)
        }

        func firstInlineMathItemID(blockID: String, engine: DocumentEngine, doc: YDoc) throws -> YID {
            let writer = BlockNoteWriter(doc: doc)
            let block = try writer.find(blockID)
            guard
                let item = writer.children(block.element).first(where: {
                    guard case .type(let type) = $0.content else { return false }
                    return type.typeRef == .xmlElement(nodeName: NativeInlineObject.mathNodeName)
                })
            else {
                throw NSError(domain: "BlockNoteSourceOracleTests", code: 1)
            }
            return item.id
        }

        func runEngineEdit(
            _ name: String,
            exactShadow: Bool = true,
            perform: (DocumentEngine, YDoc, HeadlessSurface) throws -> Void
        ) throws {
            let capture = try XCTUnwrap(BlockNoteSourceCaptures.edits.first { $0.name == name }, "missing \(name)")
            covered.insert(name)
            let doc = try decodeDoc(capture.seed)
            defer { doc.destroy() }
            let blocks = NativeBlockProjection.project(doc, interlinkingOrigin: Self.testOrigin).blocks.map(
                BlockSnapshot.init)
            let surface = HeadlessSurface(blocks: blocks)
            let engine = DocumentEngine(doc: doc, surface: surface)
            try perform(engine, doc, surface)
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, "\(name): xml mismatch")
            let shadow = try XCTUnwrap(
                NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin),
                "\(name): expected shadow")
            XCTAssertEqual(
                syncCanonicalMarkdown(shadow), syncCanonicalMarkdown(capture.markdown),
                "\(name): syncCanonicalMarkdown mismatch")
            if exactShadow {
                XCTAssertEqual(shadow, capture.markdown, "\(name): exact shadow mismatch")
            }
        }

        try runEngineEdit("typeIntoMathBlock") { engine, _, surface in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: len..<len, with: " + y^2")
            guard case .source(let node, let lines, _)? = surface.blocks.first(where: { $0.id == "mx" })?.preview
            else { return XCTFail("expected source preview update") }
            XCTAssertEqual(node, SourceBlock.mathBlock)
            XCTAssertEqual(lines, ["x^2 + y^2"])
        }
        try runEngineEdit("typeIntoMathBlockEmpty") { engine, _, _ in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))
            try engine.replaceText(block: sid, range: 0..<0, with: "\\alpha")
        }
        try runEngineEdit("typeIntoDiagram") { engine, _, _ in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "dx")))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: len..<len, with: "\n  B-->C")
        }
        try runEngineEdit("typeIntoDiagramEmpty") { engine, _, _ in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "dx")))
            try engine.replaceText(block: sid, range: 0..<0, with: "graph LR")
        }
        try runEngineEdit("typeIntoInlineMath") { engine, doc, _ in
            let itemID = try firstInlineMathItemID(blockID: "p", engine: engine, doc: doc)
            let sid = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: itemID)))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: len..<len, with: "+b^2")
        }
        try runEngineEdit("typeIntoInlineMathEmpty") { engine, doc, _ in
            let itemID = try firstInlineMathItemID(blockID: "p", engine: engine, doc: doc)
            let sid = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: itemID)))
            try engine.replaceText(block: sid, range: 0..<0, with: "x")
        }
        try runEngineEdit("replaceMathBlockContent") { engine, _, _ in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: 0..<len, with: "\\frac{a}{b}")
        }
        try runEngineEdit("replaceDiagramContent") { engine, _, _ in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "dx")))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: 0..<len, with: "sequenceDiagram\n  A->>B: Ok")
        }
        try runEngineEdit("replaceInlineMathContent") { engine, doc, _ in
            let itemID = try firstInlineMathItemID(blockID: "p", engine: engine, doc: doc)
            let sid = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: itemID)))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: 0..<len, with: "c\\cdot d")
        }
        try runEngineEdit("replaceParagraphAcrossInlineMath") { engine, _, _ in
            try engine.replaceText(block: "p", range: 1..<4, with: "X")
        }
        try runEngineEdit("emptyMathBlock") { engine, _, _ in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "mx")))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: 0..<len, with: "")
        }
        try runEngineEdit("emptyDiagram") { engine, _, _ in
            let sid = try XCTUnwrap(engine.openSource(.block(id: "dx")))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: 0..<len, with: "")
        }
        try runEngineEdit("emptyInlineMath") { engine, doc, _ in
            let itemID = try firstInlineMathItemID(blockID: "p", engine: engine, doc: doc)
            let sid = try XCTUnwrap(engine.openSource(.inlineMath(blockID: "p", itemID: itemID)))
            let len = engine.sourceSnapshot(sid)?.first?.runs.map(\.text).joined().utf16.count ?? 0
            try engine.replaceText(block: sid, range: 0..<len, with: "")
        }
        try runEngineEdit("deleteMathBlock") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "mx", kind: .deleteBlock)
            ) { _ in }
        }
        try runEngineEdit("deleteDiagram") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "dx", kind: .deleteBlock)
            ) { _ in }
        }
        try runEngineEdit("deleteInlineMath") { engine, _, _ in
            try engine.replaceText(block: "p", range: 7..<8, with: "")
        }
        try runEngineEdit("deleteInlineMathBetweenBold") { engine, _, _ in
            try engine.replaceText(block: "p", range: 5..<6, with: "")
        }
        try runEngineEdit("deleteInlineMathInTableCell") { engine, doc, _ in
            XCTAssertTrue(engine.openTable("tbl"))
            let tpID = try firstTableParagraphID(tableID: "tbl", engine: engine, doc: doc)
            try engine.replaceText(block: tpID, range: 2..<3, with: "")
        }
        try runEngineEdit("deleteColumnMathBlockDropsColumnList") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "cl",
                    kind: .columns(.remove(index: 0), expecting: nil))
            ) { _ in }
        }
        try runEngineEdit("boldAcrossInlineMath") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .marks(
                        NativeMarkCommand(
                            startOffset: 0, endBlockID: "p", endOffset: 14,
                            attributes: [TextMark(key: "bold", valueJSON: "{}")])))
            ) { _ in }
        }
        try runEngineEdit("turnInlineMathParagraphIntoHeading") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .blockType(
                        node: "heading",
                        props: [
                            ProjectedProp(key: "level", value: .int(2)),
                            ProjectedProp(key: "isToggleable", value: .bool(false)),
                        ],
                        removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("splitAfterInlineMath") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .split(offset: 8, newID: "1", open: []))
            ) { _ in }
        }
        try runEngineEdit("slashMathBlockOnEmptyParagraph") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertSourceBlock(node: SourceBlock.mathBlock, newID: "unused", removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashMathBlockOnStyledEmptyParagraph") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertSourceBlock(node: SourceBlock.mathBlock, newID: "unused", removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashMathBlockAfterNonEmptyParagraph") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertSourceBlock(node: SourceBlock.mathBlock, newID: "1", removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashMathBlockNestedInToggle", exactShadow: false) { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "tp",
                    kind: .insertSourceBlock(node: SourceBlock.mathBlock, newID: "unused", removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashDiagramOnEmptyParagraph") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertSourceBlock(node: SourceBlock.diagram, newID: "unused", removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashDiagramOnStyledEmptyParagraph") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertSourceBlock(node: SourceBlock.diagram, newID: "unused", removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashDiagramAfterNonEmptyParagraph") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertSourceBlock(node: SourceBlock.diagram, newID: "1", removing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashInlineMathInEmptyParagraph") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertInlineMath(replacing: 0..<0))
            ) { _ in }
        }
        try runEngineEdit("slashInlineMathInMiddle") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertInlineMath(replacing: 6..<6))
            ) { _ in }
        }
        try runEngineEdit("slashInlineMathAtEnd") { engine, _, _ in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "p",
                    kind: .insertInlineMath(replacing: 4..<4))
            ) { _ in }
        }
        try runEngineEdit("slashInlineMathInTableCell") { engine, doc, _ in
            XCTAssertTrue(engine.openTable("tbl"))
            let tpID = try firstTableParagraphID(tableID: "tbl", engine: engine, doc: doc)
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: tpID,
                    kind: .insertInlineMath(replacing: 4..<4))
            ) { _ in }
        }

        XCTAssertEqual(covered, Set(BlockNoteSourceCaptures.edits.map(\.name)))
    }

    func testInvalidAndUnfamiliarSourceShapesFailClosed() throws {
        // 1. Extra prop on mathBlock / diagram stays opaque and nil shadow.
        for node in [SourceBlock.mathBlock, SourceBlock.diagram] {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateContainer(doc, id: "s1", node: node) { element, tx in
                try YWrite.mapSet(tx, on: element, key: "latex", .any([.string("x^2")]))
            }
            let native = NativeBlockProjection.project(doc)
            XCTAssertEqual(native.blocks.first?.block.fidelity, .opaque(reason: "\(node): props"))
            XCTAssertFalse(native.isFullyModeled)
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }

        // 2. Marked text inside mathBlock / diagram stays opaque and nil shadow.
        for node in [SourceBlock.mathBlock, SourceBlock.diagram] {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateContainer(doc, id: "s2", node: node) { element, tx in
                let text = YType(typeRef: .xmlText)
                _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)])
                try text.insert(0, "x^2", ["bold": "true"])
            }
            let native = NativeBlockProjection.project(doc)
            XCTAssertEqual(native.blocks.first?.block.fidelity, .opaque(reason: "\(node): marked"))
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }

        // 3. Extra XmlElement / multiple XmlText children inside mathBlock / diagram fail closed.
        for node in [SourceBlock.mathBlock, SourceBlock.diagram] {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateContainer(doc, id: "s3", node: node) { element, tx in
                let nested = YType(typeRef: .xmlElement(nodeName: "paragraph"))
                _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(nested)])
            }
            let native = NativeBlockProjection.project(doc)
            XCTAssertEqual(native.blocks.first?.block.fidelity, .opaque(reason: "\(node): content"))
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }

        // 4. Inline math with extra prop or marked text or element child stays opaque and nil shadow.
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateContainer(doc, id: "p1", node: "paragraph") { element, tx in
                let math = YType(typeRef: .xmlElement(nodeName: "math"))
                _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(math)])
                try YWrite.mapSet(tx, on: math, key: "evil", .any([.string("x")]))
                XCTAssertNil(NativeInlineObject.read(math))
            }
            XCTAssertEqual(
                NativeBlockProjection.project(doc).blocks.first?.block.fidelity,
                .opaque(reason: "non-text inline content"))
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateContainer(doc, id: "p2", node: "paragraph") { element, tx in
                let math = YType(typeRef: .xmlElement(nodeName: "math"))
                _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(math)])
                let text = YType(typeRef: .xmlText)
                _ = try YWrite.insertAfter(tx, into: math, after: nil, [.type(text)])
                try text.insert(0, "x", ["bold": "true"])
                XCTAssertNil(NativeInlineObject.read(math))
            }
            XCTAssertEqual(
                NativeBlockProjection.project(doc).blocks.first?.block.fidelity,
                .opaque(reason: "non-text inline content"))
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }

        // 5. Writer refuses inline math inside codeBlock and replaceSourceText on non-source elements.
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateContainer(doc, id: "cb", node: "codeBlock") { element, tx in
                let text = YType(typeRef: .xmlText)
                _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)])
                try text.insert(0, "let x = 1", [:])
            }
            let writer = BlockNoteWriter(doc: doc, schemas: BlockNoteWriter.nativePropSchemas)
            let target = try writer.find("cb")
            XCTAssertThrowsError(try writer.insertInlineMath(in: target, replacing: 0..<0)) { error in
                XCTAssertEqual(error as? BlockNoteWriter.Error, .unsupportedBlockType("codeBlock"))
            }
        }
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateContainer(doc, id: "p3", node: "paragraph") { _, _ in }
            let writer = BlockNoteWriter(doc: doc, schemas: BlockNoteWriter.nativePropSchemas)
            let target = try writer.find("p3")
            XCTAssertThrowsError(try writer.replaceSourceText(in: target.element, range: 0..<0, with: "x", block: "p3"))
        }
    }

    func testSourceAndInlineMathPasteboardValidationAndBoundaries() throws {
        // Valid mathBlock (with newline/tab), diagram, and paragraph containing inline math survive paste validation.
        let validCopies: [BlockNoteWriter.Copy] = [
            .element(
                "blockContainer", [("id", .string("m1"))],
                [.element("mathBlock", [], [.text([.run(InlineRun("a +\n\tb"))])])]),
            .element(
                "blockContainer", [("id", .string("d1"))],
                [.element("diagram", [], [.text([.run(InlineRun(SourceBlock.defaultDiagramSource))])])]),
            .element(
                "blockContainer", [("id", .string("p1"))],
                [
                    .element(
                        "paragraph", [],
                        [.element("math", [], [.text([.run(InlineRun("x^2"))])]), .text([.run(InlineRun(" end"))])])
                ]),
        ]
        let validData = try BlockNoteSubtreePayload.encode(validCopies)
        let decodedValid = try BlockNoteSubtreePayload.validatingPastable(BlockNoteSubtreePayload.decode(validData))
        XCTAssertEqual(decodedValid.count, 3)
        if case .element(_, _, let pKids) = decodedValid[2],
            case .element("paragraph", _, let content) = pKids[0],
            case .element("math", let props, let mathKids) = content[0]
        {
            XCTAssertTrue(props.isEmpty)
            XCTAssertEqual(SourceBlock.plainText(of: mathKids), "x^2")
        } else {
            XCTFail("expected preserved inline math child")
        }

        // BlockNoteInlinePayload preserves inline math source.
        let inlineSlice: [[BlockNoteWriter.Copy]] = [
            [
                .text([.run(InlineRun("See "))]),
                .element("math", [], [.text([.run(InlineRun("x+1"))])]),
            ]
        ]
        let inlineData = try BlockNoteInlinePayload.encode(inlineSlice)
        let decodedInline = try BlockNoteInlinePayload.decode(inlineData)
        if case .element("math", let props, let kids) = decodedInline[0][1] {
            XCTAssertTrue(props.isEmpty)
            XCTAssertEqual(SourceBlock.plainText(of: kids), "x+1")
        } else {
            XCTFail("expected preserved math in BlockNoteInlinePayload")
        }

        // Crafted adversarial payloads fail closed.
        let adversarialSubtrees: [BlockNoteWriter.Copy] = [
            // Extra prop on mathBlock
            .element(
                "blockContainer", [("id", .string("bad1"))], [.element("mathBlock", [("latex", .string("x"))], [])]),
            // Extra prop on diagram
            .element(
                "blockContainer", [("id", .string("bad2"))], [.element("diagram", [("engine", .string("mermaid"))], [])]
            ),
            // Control char in diagram
            .element(
                "blockContainer", [("id", .string("bad3"))],
                [.element("diagram", [], [.text([.run(InlineRun("a\u{0007}b"))])])]),
            // Marks in mathBlock
            .element(
                "blockContainer", [("id", .string("bad4"))],
                [.element("mathBlock", [], [.text([.run(InlineRun("x", marks: [("bold", "true")]))])])]),
            // Nested element in diagram
            .element(
                "blockContainer", [("id", .string("bad5"))], [.element("diagram", [], [.element("math", [], [])])]),
            // Newline in inline math
            .element(
                "blockContainer", [("id", .string("bad6"))],
                [.element("paragraph", [], [.element("math", [], [.text([.run(InlineRun("a\nb"))])])])]),
            // Oversized mathBlock
            .element(
                "blockContainer", [("id", .string("bad8"))],
                [
                    .element(
                        "mathBlock", [],
                        [.text([.run(InlineRun(String(repeating: "a", count: SourceBlock.maxSourceUTF16 + 1)))])])
                ]),
            // Oversized inline math
            .element(
                "blockContainer", [("id", .string("bad9"))],
                [
                    .element(
                        "paragraph", [],
                        [
                            .element(
                                "math", [],
                                [
                                    .text([
                                        .run(
                                            InlineRun(
                                                String(repeating: "x", count: NativeInlineObject.maxMathUTF16 + 1)))
                                    ])
                                ])
                        ])
                ]),
        ]
        for bad in adversarialSubtrees {
            let encoded = try BlockNoteSubtreePayload.encode([bad])
            XCTAssertThrowsError(
                try BlockNoteSubtreePayload.validatingPastable(BlockNoteSubtreePayload.decode(encoded)))
        }
        XCTAssertThrowsError(
            try BlockNoteSubtreePayload.encode([
                .element(
                    "blockContainer", [("id", .string("badEl"))],
                    [.element("diagram", [], [.element("paragraph", [], [])])])
            ]))
        XCTAssertThrowsError(
            try BlockNoteSubtreePayload.encode([
                .element(
                    "blockContainer", [("id", .string("badProp"))],
                    [.element("paragraph", [], [.element("math", [("src", .string("x"))], [])])])
            ]))

        // Marked or nested element inside inline math is refused at encode/validate boundary too.
        XCTAssertThrowsError(
            try BlockNoteInlinePayload.encode([
                [
                    .element("math", [], [.text([.run(InlineRun("x", marks: [("bold", "true")]))])])
                ]
            ]))
        XCTAssertThrowsError(
            try BlockNoteInlinePayload.encode([
                [
                    .element("math", [], [.element("userMentionInline", [("userId", .string("u1"))], [])])
                ]
            ]))
        let newlineInlineData = try BlockNoteInlinePayload.encode([
            [
                .element("math", [], [.text([.run(InlineRun("a\nb"))])])
            ]
        ])
        XCTAssertThrowsError(try BlockNoteInlinePayload.decode(newlineInlineData))
    }

    // MARK: - Helpers

    private func decodeDoc(_ base64: String) throws -> YDoc {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let doc = YDoc(clientID: 1, gc: true)
        try doc.applyUpdate(YUpdateDecoder.decode(data))
        return doc
    }

    private func populateContainer(
        _ doc: YDoc, id: String, node: String, fill: (YType, YTransaction) throws -> Void
    ) throws {
        _ = try doc.transact(local: true) { tx in
            let root = doc.get(BlockNoteYjs.fragmentField)
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            _ = try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
            let element = YType(typeRef: .xmlElement(nodeName: node))
            _ = try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
            try fill(element, tx)
        }
    }
}
