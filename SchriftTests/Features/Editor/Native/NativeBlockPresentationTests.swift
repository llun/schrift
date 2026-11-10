import UIKit
import XCTest

@testable import Schrift

/// PR05b: block chrome and block controls. Every block type renders from the
/// replica without a marker character in storage or Yjs; prop edits (checked,
/// start, language, emoji) and slash-menu type changes are one durable command
/// each; Return and multi-line paste stay inside a code block; presentation
/// changes write nothing.
@MainActor
final class NativeBlockPresentationTests: NativeEditingTestCase {
    // MARK: - Fixtures

    private func node(
        _ node: String, _ id: String, _ text: String = "", _ props: [(key: String, value: YAnyValue)] = []
    ) -> BlockNoteBlock {
        BlockNoteBlock(node: node, props: props, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func headingBlock(_ id: String, _ text: String, level: Int) -> BlockNoteBlock {
        node("heading", id, text, Self.paragraphProps + [("level", .int(level)), ("isToggleable", .bool(false))])
    }

    private func numbered(_ id: String, _ text: String, start: Int? = nil) -> BlockNoteBlock {
        node("numberedListItem", id, text, Self.paragraphProps + [("start", start.map { .int($0) } ?? .undefined)])
    }

    private func check(_ id: String, _ text: String, checked: Bool = false) -> BlockNoteBlock {
        node("checkListItem", id, text, Self.paragraphProps + [("checked", .bool(checked))])
    }

    private func code(_ id: String, _ text: String, language: String = "text") -> BlockNoteBlock {
        node("codeBlock", id, text, [("language", .string(language))])
    }

    private var everyType: [BlockNoteBlock] {
        [
            headingBlock("h1", "Title", level: 1), headingBlock("h2", "Section", level: 2),
            headingBlock("h3", "Sub", level: 3), paragraph("p", "Body"), bullet("b", "Bullet"),
            numbered("n1", "One"), numbered("n2", "Two"), check("c1", "Open"), check("c2", "Done", checked: true),
            node("quote", "q", "Quoted", [("backgroundColor", .string("default")), ("textColor", .string("default"))]),
            node(
                "callout", "co", "Note",
                [("textAlignment", .string("left")), ("backgroundColor", .string("red")), ("emoji", .string("🔥"))]),
            code("code", "let a = 1\nlet b = 2", language: "swift"), node("divider", "d"), node("pageBreak", "pb"),
            paragraph("end", "End"),
        ]
    }

    /// Lays the view out in a window so fragments and controls exist.
    private func host(_ harness: Harness, height: CGFloat = 2_000) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        harness.view.frame = window.bounds
        window.addSubview(harness.view)
        window.isHidden = false
        harness.view.layoutIfNeeded()
        return window
    }

    private func attribute(_ harness: Harness, _ key: NSAttributedString.Key, _ blockID: String) throws -> Any? {
        let entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: blockID))
        return harness.view.textStorage.attribute(key, at: entry.range.location, effectiveRange: nil)
    }

    private func fragment(_ harness: Harness, _ blockID: String) throws -> NativeBlockFragment {
        let layout = try XCTUnwrap(harness.view.textLayoutManager)
        let entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: blockID))
        let location = try XCTUnwrap(
            layout.location(layout.documentRange.location, offsetBy: entry.range.location))
        layout.ensureLayout(for: try XCTUnwrap(NSTextRange(location: location)))
        return try XCTUnwrap(layout.textLayoutFragment(for: location) as? NativeBlockFragment)
    }

    /// The journal replayed into a fresh replica, as BlockNote's XML.
    private func replayedXML(_ harness: Harness) throws -> String {
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        let replica = YDoc(clientID: 98)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        return YXMLString.fragment(replica)
    }

    private func assertNoMarkers(_ xml: String, file: StaticString = #filePath, line: UInt = #line) {
        for marker in ["•", "☐", "☑", "✓", "\u{2028}", "💡 ", "1. ", "2. "] {
            XCTAssertFalse(xml.contains(marker), "no \(marker) in Y text", file: file, line: line)
        }
    }

    // MARK: - Every type renders

    func testEveryBlockTypeRendersFromTheReplicaWithoutMarkers() async throws {
        let harness = try await makeHarness(everyType)
        addTeardownBlock { await harness.close() }
        let window = host(harness)
        defer { window.isHidden = true }
        let session = harness.session
        let types = ["heading", "paragraph", "bulletListItem", "numberedListItem", "checkListItem", "quote", "callout"]
        for block in session.surface.blocks {
            XCTAssertFalse(AttributedDocumentProjection.isPlaceholder(block), "\(block.node) is modeled")
        }
        // Storage holds only replica text and one separator per block; a code
        // block's "\n" displays as U+2028, the same UTF-16 length.
        XCTAssertEqual(
            harness.view.textStorage.string,
            "Title\nSection\nSub\nBody\nBullet\nOne\nTwo\nOpen\nDone\nQuoted\nNote\n"
                + "let a = 1\u{2028}let b = 2\n\n\nEnd\n")
        for (id, level) in [("h1", 1), ("h2", 2), ("h3", 3)] {
            XCTAssertEqual(try attribute(harness, .accessibilityTextHeadingLevel, id) as? Int, level)
        }
        XCTAssertGreaterThan(
            try XCTUnwrap(try attribute(harness, .font, "h1") as? UIFont).pointSize,
            try XCTUnwrap(try attribute(harness, .font, "h3") as? UIFont).pointSize)
        XCTAssertEqual(try attribute(harness, .nativeListNumber, "n1") as? Int, 1)
        XCTAssertEqual(try attribute(harness, .nativeListNumber, "n2") as? Int, 2)
        XCTAssertEqual(try attribute(harness, .nativeChecked, "c1") as? Bool, false)
        XCTAssertEqual(try attribute(harness, .nativeChecked, "c2") as? Bool, true)
        XCTAssertEqual(try attribute(harness, .nativeCalloutEmoji, "co") as? String, "🔥")
        XCTAssertEqual(try attribute(harness, .nativeCalloutBackground, "co") as? String, "red")
        XCTAssertEqual(try attribute(harness, .nativeCodeLanguage, "code") as? String, "swift")
        let codeFont = try XCTUnwrap(try attribute(harness, .font, "code") as? UIFont)
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let quoteFont = try XCTUnwrap(try attribute(harness, .font, "q") as? UIFont)
        XCTAssertTrue(quoteFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        // Gutters and panels are paragraph indents, never characters.
        for id in ["b", "n1", "c1", "q", "co", "code"] {
            let style = try XCTUnwrap(try attribute(harness, .paragraphStyle, id) as? NSParagraphStyle)
            XCTAssertGreaterThan(style.headIndent, 0, id)
        }
        // Every block draws through a block fragment that knows its type.
        for block in session.surface.blocks {
            XCTAssertEqual(try fragment(harness, block.id).blockType, block.node)
        }
        XCTAssertEqual(Set(session.surface.blocks.map(\.node)).isSuperset(of: types), true)
        assertNoMarkers(try replayedXML(harness))
        try await assertConsistent(harness, localCommands: 0)
    }

    /// The widening is the native reading only: the classic projection (live
    /// path, save shadow, preservation) still treats these as before.
    func testOnlyTheNativeProjectionModelsCalloutPageBreakAndStarts() throws {
        let blocks = [
            node(
                "callout", "co", "Note",
                [("textAlignment", .string("left")), ("backgroundColor", .string("default")), ("emoji", .string("💡"))]),
            node("pageBreak", "pb"), numbered("n3", "Three", start: 3), numbered("nu", "Unset"),
        ]
        let doc = try makeDoc(blocks, clientID: 5)
        defer { doc.destroy() }
        XCTAssertTrue(YBlockProjection.project(doc, nativeMarks: true).isFullyModeled)
        let classic = YBlockProjection.project(doc).blocks.map(\.fidelity)
        XCTAssertTrue(classic[0].isOpaque, "classic: callout stays an unknown node")
        XCTAssertTrue(classic[1].isOpaque, "classic: page break stays an unknown node")
        XCTAssertEqual(classic[2], .lossy(reasons: ["prop:start"]))
        XCTAssertEqual(classic[3], .lossy(reasons: ["prop:start"]))
    }

    /// A divider and a page break are different blocks with different chrome,
    /// and neither has text to type into.
    func testDividerAndPageBreakStayDistinct() async throws {
        let harness = try await makeHarness([paragraph("a", "Above"), node("divider", "d"), node("pageBreak", "pb")])
        addTeardownBlock { await harness.close() }
        let window = host(harness)
        defer { window.isHidden = true }
        XCTAssertEqual(harness.session.surface.blocks.map(\.node), ["paragraph", "divider", "pageBreak"])
        let divider = try render(try fragment(harness, "d"))
        let pageBreak = try render(try fragment(harness, "pb"))
        XCTAssertNotEqual(divider, pageBreak, "a page break is not drawn as a divider")
        XCTAssertTrue(divider.contains { $0 != 0 }, "the divider draws a rule")
        XCTAssertTrue(pageBreak.contains { $0 != 0 }, "the page break draws its rule and label")

        for id in ["d", "pb"] {
            setSelection(harness, NSRange(location: try location(harness.session, id, 0), length: 0))
            harness.view.insertText("x")
            await harness.settle()
            XCTAssertEqual(harness.input.noticeKey, .native_editor_input_unavailable, id)
        }
        let xml = try replayedXML(harness)
        XCTAssertTrue(xml.contains(#"<divider></divider>"#), xml)
        XCTAssertTrue(xml.contains(#"<pagebreak></pagebreak>"#), xml)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// The fragment's chrome alone (no text), as RGBA bytes.
    private func render(_ fragment: NativeBlockFragment) throws -> [UInt8] {
        let frame = fragment.layoutFragmentFrame
        let size = CGSize(width: 390, height: max(1, frame.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            fragment.draw(at: .zero, in: context.cgContext)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let bitmap = try XCTUnwrap(
            CGContext(
                data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return bytes
    }

    // MARK: - Checkbox

    func testCheckboxTapIsOnePropOnlyCommand() async throws {
        let harness = try await makeHarness([paragraph("p", "Intro"), check("task", "Buy milk")])
        addTeardownBlock { await harness.close() }
        let window = host(harness)
        defer { window.isHidden = true }
        let session = harness.session
        let recorder = PatchLog(session)
        setSelection(harness, NSRange(location: 2, length: 0))
        let button = try XCTUnwrap(harness.view.blockControls.checkboxes["task"])

        button.sendActions(for: .primaryActionTriggered)
        await harness.settle()
        XCTAssertEqual(
            harness.log.commands.last?.kind, .props([ProjectedProp(key: "checked", value: .bool(true))]))
        XCTAssertTrue(try block(session, "task").props.contains(ProjectedProp(key: "checked", value: .bool(true))))
        XCTAssertEqual(try block(session, "task").node, "checkListItem", "never a type change")
        XCTAssertEqual(text(of: try block(session, "task")), "Buy milk")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 2, length: 0), "the caret stays")
        XCTAssertEqual(recorder.kinds, ["props"])
        XCTAssertEqual(try attribute(harness, .nativeChecked, "task") as? Bool, true)
        try await assertConsistent(harness, localCommands: 1)

        harness.view.layoutIfNeeded()
        harness.view.blockControls.checkboxes["task"]?.sendActions(for: .primaryActionTriggered)
        await harness.settle()
        XCTAssertEqual(
            harness.log.commands.last?.kind, .props([ProjectedProp(key: "checked", value: .bool(false))]))
        XCTAssertEqual(try attribute(harness, .nativeChecked, "task") as? Bool, false)
        try await assertConsistent(harness, localCommands: 2)
    }

    /// The same attribute struct BlockNote's `updateBlock` writes for a tick.
    func testCheckboxToggleMatchesTheNodeCapture() async throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures["check-toggle"])
        let seed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed])))
        let session = try await NativeEditorSession.seed(state: seed, clientID: 2, gc: false)
        addTeardownBlock { await session.close().value }
        let updates = Locked<[Data]>([])
        session.enableTyping(persist: { _, update in updates.update { $0.append(update) } })
        let input = try XCTUnwrap(session.input)
        let toggled = await session.run { input.toggleCheckbox(blockID: "k-3") }
        XCTAssertTrue(toggled)
        XCTAssertEqual(updates.value.map { $0.base64EncodedString() }, ["AQECAKgBCwF4AQEBCwE="], "BlockNote's bytes")
        try assertConverges(seed: seed, updates.value, xml: capture.xml)
    }

    func testHeadingLevelPropMatchesTheNodeCapture() async throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures["heading-level"])
        let seed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed])))
        let session = try await NativeEditorSession.seed(state: seed, clientID: 2, gc: false)
        addTeardownBlock { await session.close().value }
        let updates = Locked<[Data]>([])
        let command = NativeEditCommand(
            id: UUID(), baseRevision: 0, blockID: "h-3", kind: .props([ProjectedProp(key: "level", value: .int(2))])
        )
        let error = await session.engine { engine -> DocumentEngineError? in
            do {
                try engine.applyStructural(command) { update in
                    updates.update { $0.append(update) }
                }
                return nil
            } catch {
                return error as? DocumentEngineError
            }
        }
        XCTAssertNil(error)
        XCTAssertEqual(updates.value.map { $0.base64EncodedString() }, ["AQECAKgBCwF9AgEBAQsB"])
        try assertConverges(seed: seed, updates.value, xml: capture.xml)
    }

    private func assertConverges(
        seed: Data, _ updates: [Data], xml: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let replica = YDoc(clientID: 9, gc: false)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(seed))
        for update in updates { try replica.applyUpdate(YUpdateDecoder.decode(update)) }
        XCTAssertEqual(YXMLString.fragment(replica), xml, file: file, line: line)
        XCTAssertNil(replica.store.pendingStructs, file: file, line: line)
    }

    // MARK: - Props are validated intents

    func testPropEditsAreValidatedBeforeArming() async throws {
        let harness = try await makeHarness([
            check("task", "Task"), numbered("n", "One"), code("code", "x"), paragraph("p", "Plain"),
            node(
                "callout", "co", "Note",
                [("textAlignment", .string("left")), ("backgroundColor", .string("default")), ("emoji", .string("💡"))]),
        ])
        addTeardownBlock { await harness.close() }
        let refused: [(String, [ProjectedProp])] = [
            ("task", [ProjectedProp(key: "checked", value: .string("yes"))]),
            ("task", [ProjectedProp(key: "start", value: .int(2))]),
            ("p", [ProjectedProp(key: "checked", value: .bool(true))]),
            ("n", [ProjectedProp(key: "start", value: .int(0))]),
            ("n", [ProjectedProp(key: "start", value: .string("3"))]),
            ("code", [ProjectedProp(key: "language", value: .string("two words"))]),
            ("code", [ProjectedProp(key: "language", value: .string(""))]),
            ("co", [ProjectedProp(key: "emoji", value: .string("ab"))]),
            ("co", [ProjectedProp(key: "emoji", value: .string("🔥🔥"))]),
            ("p", []),
        ]
        for (id, props) in refused {
            let error = await harness.engine { engine -> DocumentEngineError? in
                do {
                    try engine.applyStructural(
                        NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, kind: .props(props))
                    ) { _ in }
                    return nil
                } catch {
                    return error as? DocumentEngineError
                }
            }
            XCTAssertEqual(error, .unsupportedNativeInput, "\(id) \(props)")
        }
        let lang1 = await harness.run { harness.input.setCodeLanguage(blockID: "code", language: "swift") }
        XCTAssertTrue(lang1)
        let emoji = await harness.run { harness.input.setCalloutEmoji(blockID: "co", emoji: "🔥") }
        XCTAssertTrue(emoji)
        let lang2 = await harness.run { harness.input.setCodeLanguage(blockID: "code", language: "swift") }
        XCTAssertTrue(lang2, "unchanged writes nothing")
        let lang3 = await harness.run { harness.input.setCodeLanguage(blockID: "p", language: "swift") }
        XCTAssertFalse(lang3)
        XCTAssertEqual(
            harness.log.commands.map(\.kind),
            [
                .props([ProjectedProp(key: "language", value: .string("swift"))]),
                .props([ProjectedProp(key: "emoji", value: .string("🔥"))]),
            ])
        XCTAssertEqual(try attribute(harness, .nativeCodeLanguage, "code") as? String, "swift")
        XCTAssertEqual(try attribute(harness, .nativeCalloutEmoji, "co") as? String, "🔥")
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - Numbering

    /// BlockNote's numbering: a run starts at its first item's `start`; a
    /// later item's start is ignored; anything else breaks the run.
    func testNumberStartsFollowBlockNote() async throws {
        let harness = try await makeHarness([
            numbered("a", "A", start: 3), numbered("b", "B"), numbered("c", "C", start: 9), paragraph("p", "Break"),
            numbered("d", "D"), numbered("e", "E"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        func numbers() throws -> [Int?] {
            try ["a", "b", "c", "d", "e"].map { try attribute(harness, .nativeListNumber, $0) as? Int }
        }
        XCTAssertEqual(try numbers(), [3, 4, 5, 1, 2])

        let started = await harness.run { harness.input.setNumberStart(blockID: "a", start: 10) }
        XCTAssertTrue(started)
        XCTAssertEqual(harness.log.commands.last?.kind, .props([ProjectedProp(key: "start", value: .int(10))]))
        XCTAssertEqual(try numbers(), [10, 11, 12, 1, 2])
        try await assertConsistent(harness, localCommands: 1)

        // A split inserts an item mid-run: everything after renumbers.
        setSelection(harness, NSRange(location: try location(session, "b", 1), length: 0))
        harness.view.insertText("\n")
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node).filter { $0 == "numberedListItem" }.count, 6)
        XCTAssertEqual(try numbers(), [10, 11, 13, 1, 2])
        try await assertConsistent(harness, localCommands: 2)

        // Turning the paragraph into a list item joins the two runs.
        setSelection(harness, NSRange(location: try location(session, "p", 0), length: 0))
        harness.view.insertText("/")
        await harness.settle()
        let numberedItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "numbered" })
        let applied = await harness.run { harness.input.applySlashItem(numberedItem) }
        XCTAssertTrue(applied)
        XCTAssertEqual(try numbers(), [10, 11, 13, 15, 16])
        try await assertConsistent(harness, localCommands: 4)

        let unset = await harness.run { harness.input.setNumberStart(blockID: "a", start: nil) }
        XCTAssertTrue(unset)
        XCTAssertEqual(harness.log.commands.last?.kind, .props([ProjectedProp(key: "start", value: .undefined)]))
        XCTAssertEqual(try numbers(), [1, 2, 4, 6, 7])
        try await assertConsistent(harness, localCommands: 5)
    }

    // MARK: - Code

    func testReturnInCodeInsertsALineBreakInTheSameBlock() async throws {
        let harness = try await makeHarness([code("code", "let a = 1"), paragraph("p", "After")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        setSelection(harness, NSRange(location: try location(session, "code", 9), length: 0))
        harness.view.insertText("\n")
        await harness.settle()
        XCTAssertEqual(
            harness.log.commands.last?.kind, .replace(range: 9..<9, replacement: "\n", marks: nil))
        harness.view.insertText("let b = 2")
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.id), ["code", "p"], "no block was created")
        XCTAssertEqual(text(of: try block(session, "code")), "let a = 1\nlet b = 2")
        XCTAssertEqual(
            harness.view.textStorage.string, "let a = 1\u{2028}let b = 2\nAfter\n", "one TextKit paragraph")
        // Backspace after the line break deletes it, still inside the block.
        setSelection(harness, NSRange(location: try location(session, "code", 10), length: 0))
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "code")), "let a = 1let b = 2")
        try await assertConsistent(harness, localCommands: 3)
        XCTAssertTrue(try replayedXML(harness).contains(#"<codeblock language="text">let a = 1let b = 2</codeblock>"#))
    }

    func testMultiLinePasteInCodeStaysInTheBlockAndCopiesBack() async throws {
        let harness = try await makeHarness([code("code", "start"), paragraph("p", "After")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        setSelection(harness, NSRange(location: try location(session, "code", 5), length: 0))
        harness.pasteboard.string = "\r\nfunc a() {\r\n    1\r\n}"
        let pasted = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pasted)
        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["code", "p"])
        XCTAssertEqual(text(of: try block(session, "code")), "start\nfunc a() {\n    1\n}")
        let xml = try replayedXML(harness)
        XCTAssertTrue(xml.contains("start\nfunc a() {\n    1\n}</codeblock>"), xml)
        assertNoMarkers(xml)

        // Copy gives the source's own line breaks back.
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: "code"))
        setSelection(harness, entry.textRange)
        harness.input.copySelection()
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "start\nfunc a() {\n    1\n}")
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Slash menu

    func testSlashMenuChangesTheBlockTypeInOneCommandEach() async throws {
        let expected: [(String, String, Int?)] = [
            ("heading1", "heading", 1), ("heading2", "heading", 2), ("heading3", "heading", 3),
            ("bullet", "bulletListItem", nil), ("numbered", "numberedListItem", nil),
            ("checklist", "checkListItem", nil), ("quote", "quote", nil), ("code", "codeBlock", nil),
            ("paragraph", "paragraph", nil),
        ]
        XCTAssertEqual(
            NativeInputCoordinator.slashItems.map(\.id),
            [
                "paragraph", "heading1", "heading2", "heading3", "toggleHeading", "bullet", "numbered", "checklist",
                "toggleList", "quote", "code",
            ],
            "divider, photo and file wait for later slices; the toggles are NativeToggleTests'")
        for (itemID, node, level) in expected {
            let harness = try await makeHarness([paragraph("p", "Above"), paragraph("s", "")])
            addTeardownBlock { await harness.close() }
            let session = harness.session
            setSelection(harness, NSRange(location: try location(session, "s", 0), length: 0))
            harness.view.insertText("/")
            harness.view.insertText("h")
            await harness.settle()
            XCTAssertEqual(harness.input.slashMenuQuery, "h", itemID)
            let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == itemID })
            let applied = await harness.run { harness.input.applySlashItem(item) }
            XCTAssertTrue(applied, itemID)
            let props = level.map { [ProjectedProp(key: "level", value: .int($0))] } ?? []
            XCTAssertEqual(
                harness.log.commands.last?.kind, .blockType(node: node, props: props, removing: 0..<2), itemID)
            let converted = try block(session, "s")
            XCTAssertEqual(converted.node, node, itemID)
            XCTAssertEqual(text(of: converted), "", "the query is removed")
            if let level {
                XCTAssertTrue(converted.props.contains(ProjectedProp(key: "level", value: .int(level))), itemID)
            }
            XCTAssertNil(harness.input.slashMenuQuery, itemID)
            XCTAssertEqual(harness.view.selectedRange.location, try location(session, "s", 0), itemID)
            try await assertConsistent(harness, localCommands: 3)
            await harness.close()
        }
    }

    func testSlashMenuIsOnlyForAParagraphThatIsTheCommand() async throws {
        let harness = try await makeHarness([
            headingBlock("h", "/head", level: 2), paragraph("p", "Text /h"), paragraph("s", "/"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let heading = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "heading1" })
        for (id, offset) in [("h", 5), ("p", 7)] {
            setSelection(harness, NSRange(location: try location(session, id, offset), length: 0))
            XCTAssertNil(harness.input.slashMenuQuery, id)
            let applied = await harness.run { harness.input.applySlashItem(heading) }
            XCTAssertFalse(applied, id)
        }
        setSelection(harness, NSRange(location: try location(session, "s", 1), length: 0))
        XCTAssertEqual(harness.input.slashMenuQuery, "")
        // An item the native editor cannot apply yet is refused, not approximated.
        let divider = try XCTUnwrap(allSlashMenuItems.first { $0.id == "divider" })
        let appliedDivider = await harness.run { harness.input.applySlashItem(divider) }
        XCTAssertFalse(appliedDivider)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// "/" typed in front of existing text: the choice consumes only the
    /// "/query" token before the caret, never the user's text after it.
    func testSlashChoiceKeepsTheTextAfterTheQuery() async throws {
        let harness = try await makeHarness([paragraph("p", "Notes from meeting")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        setSelection(harness, NSRange(location: try location(session, "p", 0), length: 0))
        for character in ["/", "h", "1"] { harness.view.insertText(character) }
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "p")), "/h1Notes from meeting")
        XCTAssertEqual(harness.input.slashMenuQuery, "h1")
        let heading = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "heading1" })
        let applied = await harness.run { harness.input.applySlashItem(heading) }
        XCTAssertTrue(applied)
        XCTAssertEqual(
            harness.log.commands.last?.kind,
            .blockType(node: "heading", props: [ProjectedProp(key: "level", value: .int(1))], removing: 0..<3))
        XCTAssertEqual(try block(session, "p").node, "heading")
        XCTAssertEqual(text(of: try block(session, "p")), "Notes from meeting", "the user's text stays")
        try await assertConsistent(harness, localCommands: 4)

        // A query with a space in it is prose, not a command.
        let second = try await makeHarness([paragraph("q", "/h1 x")])
        addTeardownBlock { await second.close() }
        setSelection(second, NSRange(location: try location(second.session, "q", 5), length: 0))
        XCTAssertNil(second.input.slashMenuQuery)
        let appliedSecond = await second.run { second.input.applySlashItem(heading) }
        XCTAssertFalse(appliedSecond)
        try await assertConsistent(second, localCommands: 0)
    }

    /// "/code" in BlockNote's own empty paragraph, then the menu: the XML
    /// BlockNote's query clear and `updateBlock` leave.
    func testSlashToCodeConvergesToTheNodeCapture() async throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures["p-empty-to-code"])
        let seed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed])))
        let session = try await NativeEditorSession.seed(state: seed, clientID: 2, gc: false)
        addTeardownBlock { await session.close().value }
        let updates = Locked<[Data]>([])
        session.enableTyping(persist: { _, update in updates.update { $0.append(update) } })
        let input = try XCTUnwrap(session.input)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        input.textViewDidChangeSelection(session.textView)
        session.textView.insertText("/code")
        await session.settle()
        XCTAssertEqual(input.slashMenuQuery, "code")
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "code" })
        let applied = await session.run { input.applySlashItem(item) }
        XCTAssertTrue(applied)
        XCTAssertEqual(updates.value.count, 2)
        try assertConverges(seed: seed, updates.value, xml: capture.xml)
    }

    /// BlockNote's `updateBlock` to a heading keeps the paragraph's styled props.
    func testTypeChangeKeepsPropsLikeTheNodeCapture() async throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures["styled-to-heading"])
        let seed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed])))
        let session = try await NativeEditorSession.seed(state: seed, clientID: 2, gc: false)
        addTeardownBlock { await session.close().value }
        let updates = Locked<[Data]>([])
        let command = NativeEditCommand(
            id: UUID(), baseRevision: 0, blockID: "p-p",
            kind: .blockType(node: "heading", props: [ProjectedProp(key: "level", value: .int(2))], removing: 0..<0)
        )
        let error = await session.engine { engine -> DocumentEngineError? in
            do {
                try engine.applyStructural(command) { update in
                    updates.update { $0.append(update) }
                }
                return nil
            } catch {
                return error as? DocumentEngineError
            }
        }
        XCTAssertNil(error)
        try assertConverges(seed: seed, updates.value, xml: capture.xml)
    }

    // MARK: - Presentation writes nothing

    func testThemeAndDynamicTypeChangesProduceNoTransactions() async throws {
        let harness = try await makeHarness(everyType)
        addTeardownBlock { await harness.close() }
        let window = host(harness)
        defer { window.isHidden = true }
        let session = harness.session
        let recorder = PatchLog(session)
        let revision = await session.engine { $0.revision }
        let text = harness.view.textStorage.string
        let bodyFont = try XCTUnwrap(try attribute(harness, .font, "p") as? UIFont)
        let gutter = try XCTUnwrap(try attribute(harness, .paragraphStyle, "b") as? NSParagraphStyle).headIndent

        for theme in AppTheme.allCases { harness.view.blockControls.theme = theme }
        window.overrideUserInterfaceStyle = .dark
        harness.view.layoutIfNeeded()
        window.overrideUserInterfaceStyle = .light
        harness.view.layoutIfNeeded()
        session.surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            labels: session.surface.labels)
        harness.view.layoutIfNeeded()
        await harness.settle()

        XCTAssertGreaterThan(try XCTUnwrap(try attribute(harness, .font, "p") as? UIFont).pointSize, bodyFont.pointSize)
        XCTAssertGreaterThan(
            try XCTUnwrap(try attribute(harness, .paragraphStyle, "b") as? NSParagraphStyle).headIndent, gutter,
            "the gutter scales with Dynamic Type")
        XCTAssertEqual(harness.view.textStorage.string, text)
        let finalRevision = await session.engine { $0.revision }
        XCTAssertEqual(finalRevision, revision)
        XCTAssertTrue(recorder.patches.isEmpty, "no Yjs transaction reached the engine")
        try await assertConsistent(harness, localCommands: 0)
    }

    // MARK: - Relaunch

    func testReplayAfterRelaunchRestoresEveryPropAndType() async throws {
        let harness = try await makeHarness([
            check("task", "Task"), numbered("n", "One"), code("code", "x"), paragraph("s", ""),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let checked = await harness.run { harness.input.toggleCheckbox(blockID: "task") }
        XCTAssertTrue(checked)
        let started = await harness.run { harness.input.setNumberStart(blockID: "n", start: 4) }
        XCTAssertTrue(started)
        let lang = await harness.run { harness.input.setCodeLanguage(blockID: "code", language: "python") }
        XCTAssertTrue(lang)
        setSelection(harness, NSRange(location: try location(session, "code", 1), length: 0))
        harness.view.insertText("\n")
        await harness.settle()
        setSelection(harness, NSRange(location: try location(session, "s", 0), length: 0))
        harness.view.insertText("/")
        await harness.settle()
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "quote" })
        let applied = await harness.run { harness.input.applySlashItem(item) }
        XCTAssertTrue(applied)
        try await assertConsistent(harness, localCommands: 6)
        let expected = session.surface.blocks
        let expectedText = harness.view.textStorage.string
        await session.close().value

        let restored = try unwrapped(try await NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        addTeardownBlock {
            await restored.close().value
            try? FileManager.default.removeItem(at: harness.directory)
        }
        XCTAssertEqual(restored.surface.blocks, expected)
        XCTAssertEqual(restored.textView.textStorage.string, expectedText)
        XCTAssertEqual(
            restored.surface.blocks.map(\.node), ["checkListItem", "numberedListItem", "codeBlock", "quote"])
        let restoredRevision = await restored.engine { $0.revision }
        XCTAssertEqual(restoredRevision, 6)
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: restored.surface.blocks, traits: restored.surface.traits, labels: restored.surface.labels)
        XCTAssertTrue(restored.textView.textStorage.isEqual(to: fresh))
    }
}
