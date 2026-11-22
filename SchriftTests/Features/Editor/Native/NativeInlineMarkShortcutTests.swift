import UIKit
import XCTest

@testable import Schrift

/// Inline markdown mark typing shortcuts in the native editor: `**x**` and
/// `__x__` (bold), `*x*` and `_x_` (italic), `` `x` `` (code), `~~x~~` (strike).
/// Delimiters delete and the mark applies in one engine transaction as the
/// closing delimiter is typed, with the caret right after the formatted text
/// and the new mark cleared for subsequent typing.
@MainActor
final class NativeInlineMarkShortcutTests: NativeEditingTestCase {
    override func makeHarness(
        _ blocks: [BlockNoteBlock] = seedBlocks(),
        interrupt: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil,
        hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> Harness {
        let harness = try await super.makeHarness(blocks, interrupt: interrupt, hooks: hooks)
        _ = await harness.session.history { $0.history.captureTimeout = 60_000 }
        addTeardownBlock { await harness.close() }
        return harness
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    private func select(_ session: NativeEditorSession, _ range: NSRange) {
        session.textView.selectedRange = range
        session.input?.textViewDidChangeSelection(session.textView)
    }

    /// Types `text` one character at a time, as the keyboard does.
    private func type(_ session: NativeEditorSession, _ text: String) {
        for character in text { session.textView.insertText(String(character)) }
    }

    private func markShortcutCommands(_ harness: Harness) -> [NativeMarkShortcutCommand] {
        harness.log.commands.compactMap {
            if case .markShortcut(let shortcut) = $0.kind { shortcut } else { nil }
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let base64 =
            BlockNoteTableCaptures.fixtures.first { $0.name == name }?.update
            ?? BlockNoteColumnCaptures.fixtures.first { $0.name == name }?.update
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(base64, name)))
    }

    private func stateWithMention(_ blocks: [BlockNoteBlock], blockID: String, at offset: Int) throws -> Data {
        let doc = try makeDoc(blocks, clientID: 1)
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        _ = try writer.insertInlineObject(
            .mention(userID: "u1", fullName: "Ada"), in: try writer.find(blockID), replacing: offset..<offset)
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private func markKeys(of run: InlineRun) -> Set<String> {
        Set(run.marks.map(\.key))
    }

    // MARK: - Pure matcher unit tests

    func testMatcherRecognizesAllSixDelimiters() {
        let cases: [(input: String, markKey: String, delimiter: String, openLen: Int, body: String)] = [
            ("**bold**", "bold", "**", 2, "bold"),
            ("__bold__", "bold", "__", 2, "bold"),
            ("*italic*", "italic", "*", 1, "italic"),
            ("_italic_", "italic", "_", 1, "italic"),
            ("`code`", "code", "`", 1, "code"),
            ("~~strike~~", "strike", "~~", 2, "strike"),
        ]
        for (input, markKey, delimiter, openLen, body) in cases {
            let match = detectInlineMarkShortcut(text: input, caretOffset: input.utf16.count)
            XCTAssertEqual(
                match,
                InlineMarkShortcutMatch(
                    fullRange: 0..<input.utf16.count, openLength: openLen, closeLength: openLen,
                    markKey: markKey, delimiter: delimiter),
                input)
            if let match {
                let units = Array(input.utf16)
                XCTAssertEqual(String(decoding: units[match.bodyRange], as: UTF16.self), body, input)
            }
        }
    }

    func testMatcherBoundaryAndBodyRules() {
        // After whitespace (space, tab, newline, NBSP) converts.
        for sep in [" ", "\t", "\n", "\u{00A0}"] {
            let text = "hi\(sep)**bold**"
            let match = detectInlineMarkShortcut(text: text, caretOffset: text.utf16.count)
            XCTAssertEqual(match?.markKey, "bold", "separator \(sep.debugDescription)")
            XCTAssertEqual(match?.fullRange, 3..<11, "separator \(sep.debugDescription)")
        }

        // Mid-block caret converts only the pair ending at the caret.
        let midBlock = "hi **bold** tail"
        let midMatch = detectInlineMarkShortcut(text: midBlock, caretOffset: 11)
        XCTAssertEqual(midMatch?.fullRange, 3..<11)
        XCTAssertEqual(midMatch?.markKey, "bold")
        XCTAssertNil(detectInlineMarkShortcut(text: midBlock, caretOffset: midBlock.utf16.count))

        // Leading or trailing space inside delimiters still converts with space in body.
        let leadingSpace = detectInlineMarkShortcut(text: "** text**", caretOffset: 9)
        XCTAssertEqual(leadingSpace?.markKey, "bold")
        XCTAssertEqual(leadingSpace?.bodyRange, 2..<7)

        // Emoji / surrogate pairs inside body and before whitespace.
        let emojiBody = "**👋**"
        let emojiMatch = detectInlineMarkShortcut(text: emojiBody, caretOffset: emojiBody.utf16.count)
        XCTAssertEqual(emojiMatch?.markKey, "bold")
        XCTAssertEqual(emojiMatch?.bodyRange, 2..<4)
        XCTAssertNil(detectInlineMarkShortcut(text: "👋**bold**", caretOffset: "👋**bold**".utf16.count))
        XCTAssertEqual(
            detectInlineMarkShortcut(text: "👋 **bold**", caretOffset: "👋 **bold**".utf16.count)?.fullRange,
            3..<11)

        // Inline object placeholder alone does not convert; with text it does.
        XCTAssertNil(detectInlineMarkShortcut(text: "**\u{FFFC}**", caretOffset: 5))
        XCTAssertEqual(detectInlineMarkShortcut(text: "**hi \u{FFFC}**", caretOffset: 8)?.markKey, "bold")

        // Rejected forms.
        let rejected = [
            "",
            "*",
            "**",
            "***",
            "****",
            "``",
            "```",
            "~~~~",
            "** **",
            "* *",
            "__ __",
            "_ _",
            "` `",
            "~~ ~~",
            "**\t**",
            "**bold*",
            "__bold_",
            "*bold**",
            "***bold**",
            "**bold***",
            "~strike~",
            "snake_case_",
            "foo**bar**",
            "a`b`",
            "a~~b~~",
            "(*italic*)",
            "**bold *italic* bold**",
            "__bold _italic_ bold__",
            "``code`",
        ]
        for sample in rejected {
            XCTAssertNil(
                detectInlineMarkShortcut(text: sample, caretOffset: sample.utf16.count),
                "expected no match for \(sample)")
        }

        // Inner-first: opening `**bold ` followed by `*italic*` matches italic.
        let inner = "**bold *italic*"
        let innerMatch = detectInlineMarkShortcut(text: inner, caretOffset: inner.utf16.count)
        XCTAssertEqual(innerMatch?.markKey, "italic")
        XCTAssertEqual(innerMatch?.fullRange, 7..<15)
    }

    // MARK: - Six delimiters & next typed character plain

    func testAllSixDelimitersConvertWithCorrectMarksAndCaret() async throws {
        let cases: [(typed: String, body: String, markKey: String, delimiter: String, len: Int)] = [
            ("**bold**", "bold", "bold", "**", 2),
            ("__bold__", "bold", "bold", "__", 2),
            ("*italic*", "italic", "italic", "*", 1),
            ("_italic_", "italic", "italic", "_", 1),
            ("`code`", "code", "code", "`", 1),
            ("~~strike~~", "strike", "strike", "~~", 2),
        ]
        for (typed, body, markKey, delimiter, len) in cases {
            let harness = try await makeHarness([paragraph("p", ""), paragraph("after", "Next")])
            let session = harness.session
            try caret(harness, "p", 0)
            type(session, typed)
            await harness.settle()

            let b = try block(session, "p")
            XCTAssertEqual(text(of: b), body, typed)
            XCTAssertEqual(b.runs.count, 1, typed)
            XCTAssertEqual(markKeys(of: b.runs[0]), [markKey], typed)
            XCTAssertEqual(
                harness.view.selectedRange,
                NSRange(location: try location(session, "p", body.utf16.count), length: 0),
                "caret sits right after formatted text: \(typed)")
            XCTAssertEqual(
                markShortcutCommands(harness),
                [
                    NativeMarkShortcutCommand(
                        fullRange: 0..<typed.utf16.count, openLength: len, closeLength: len, delimiter: delimiter,
                        attributes: [TextMark(key: markKey, valueJSON: "{}")])
                ], typed)
            XCTAssertFalse(
                harness.input.activeMarks.contains { $0.key == markKey },
                "new mark does not remain active for typing: \(typed)")

            // Next typed character is plain.
            type(session, " plain")
            await harness.settle()
            let afterTyping = try block(session, "p")
            XCTAssertEqual(text(of: afterTyping), "\(body) plain", typed)
            XCTAssertEqual(afterTyping.runs.count, 2, typed)
            XCTAssertEqual(afterTyping.runs[0].text, body, typed)
            XCTAssertEqual(markKeys(of: afterTyping.runs[0]), [markKey], typed)
            XCTAssertEqual(afterTyping.runs[1].text, " plain", typed)
            XCTAssertTrue(afterTyping.runs[1].marks.isEmpty, "next typed text is plain: \(typed)")

            try await assertConsistent(harness, localCommands: typed.count + 1 + " plain".count)
            await harness.close()
        }
    }

    /// Typing continuously past the closing delimiter holds the trailing keys
    /// behind the conversion barrier and replays them plain once it settles.
    func testContinuousTypingAfterClosingDelimiterIsPlain() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        type(session, "**bold** plain")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "bold plain")
        XCTAssertEqual(b.runs.count, 2)
        XCTAssertEqual(b.runs[0].text, "bold")
        XCTAssertEqual(markKeys(of: b.runs[0]), ["bold"])
        XCTAssertEqual(b.runs[1].text, " plain")
        XCTAssertTrue(b.runs[1].marks.isEmpty)
        try await assertConsistent(harness, localCommands: "**bold** plain".count + 1)
    }

    // MARK: - Whitespace and mid-word rules

    func testLeadingSpaceInsideDelimitersConvertsWithSpaceInMark() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        type(session, "** text**")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), " text")
        XCTAssertEqual(b.runs.count, 1)
        XCTAssertEqual(markKeys(of: b.runs[0]), ["bold"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "p", 5), length: 0))
        try await assertConsistent(harness, localCommands: "** text**".count + 1)
    }

    func testWhitespaceOnlyBodyStaysLiteral() async throws {
        // Typed after "Hi " so "* " does not trigger the block-start bullet shortcut.
        for sample in ["** **", "* *", "__ __", "_ _", "` `", "~~ ~~"] {
            let harness = try await makeHarness([paragraph("p", "Hi ")])
            let session = harness.session
            try caret(harness, "p", 3)
            type(session, sample)
            await harness.settle()

            let b = try block(session, "p")
            XCTAssertEqual(text(of: b), "Hi \(sample)", sample)
            XCTAssertTrue(b.runs.allSatisfy(\.marks.isEmpty), sample)
            XCTAssertTrue(markShortcutCommands(harness).isEmpty, sample)
            try await assertConsistent(harness, localCommands: sample.count)
            await harness.close()
        }
    }

    func testMidWordDelimitersStayLiteral() async throws {
        for sample in ["snake_case_", "foo**bar**", "a`b`", "x~~y~~"] {
            let harness = try await makeHarness([paragraph("p", "")])
            let session = harness.session
            try caret(harness, "p", 0)
            type(session, sample)
            await harness.settle()

            let b = try block(session, "p")
            XCTAssertEqual(text(of: b), sample, sample)
            XCTAssertTrue(b.runs.allSatisfy(\.marks.isEmpty), sample)
            XCTAssertTrue(markShortcutCommands(harness).isEmpty, sample)
            try await assertConsistent(harness, localCommands: sample.count)
            await harness.close()
        }
    }

    // MARK: - Nesting & mark interactions

    func testOuterBoldWithUnconvertedInnerStarsDoesNotConvert() async throws {
        let harness = try await makeHarness([paragraph("p", "**bold *italic* bold*")])
        let session = harness.session
        try caret(harness, "p", "**bold *italic* bold*".utf16.count)
        type(session, "*")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "**bold *italic* bold**")
        XCTAssertTrue(b.runs.allSatisfy(\.marks.isEmpty))
        XCTAssertTrue(markShortcutCommands(harness).isEmpty)
        try await assertConsistent(harness, localCommands: 1)
    }

    func testInnerFirstTypingConvertsInnerItalicThenOuterBold() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        type(session, "**bold *italic* bold**")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "bold italic bold")
        XCTAssertEqual(b.runs.count, 3)
        XCTAssertEqual(b.runs[0].text, "bold ")
        XCTAssertEqual(markKeys(of: b.runs[0]), ["bold"])
        XCTAssertEqual(b.runs[1].text, "italic")
        XCTAssertEqual(markKeys(of: b.runs[1]), ["bold", "italic"])
        XCTAssertEqual(b.runs[2].text, " bold")
        XCTAssertEqual(markKeys(of: b.runs[2]), ["bold"])
        XCTAssertEqual(markShortcutCommands(harness).count, 2)
        try await assertConsistent(harness, localCommands: "**bold *italic* bold**".count + 2)
    }

    func testItalicInsideExistingBoldAddsItalicAndKeepsBoldAfterward() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("Hi ", marks: [("bold", "{}")])], id: "p")
        ])
        let session = harness.session
        try caret(harness, "p", 3)
        type(session, "*em*")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "Hi em")
        XCTAssertEqual(b.runs.count, 2)
        XCTAssertEqual(b.runs[0].text, "Hi ")
        XCTAssertEqual(markKeys(of: b.runs[0]), ["bold"])
        XCTAssertEqual(b.runs[1].text, "em")
        XCTAssertEqual(markKeys(of: b.runs[1]), ["bold", "italic"])
        XCTAssertEqual(Set(harness.input.activeMarks.map(\.key)), ["bold"])

        // Subsequent typing continues bold without italic.
        type(session, "!")
        await harness.settle()
        let after = try block(session, "p")
        XCTAssertEqual(text(of: after), "Hi em!")
        XCTAssertEqual(after.runs.last?.text, "!")
        XCTAssertEqual(after.runs.last.map(markKeys), ["bold"])
        try await assertConsistent(harness, localCommands: "*em*!".count + 1)
    }

    func testCodeShortcutReplacesBoldItalicAndStrike() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("Hi ", marks: [("bold", "{}"), ("italic", "{}"), ("strike", "{}")])], id: "p")
        ])
        let session = harness.session
        try caret(harness, "p", 3)
        type(session, "`fn()`")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "Hi fn()")
        XCTAssertEqual(b.runs.count, 2)
        XCTAssertEqual(b.runs[0].text, "Hi ")
        XCTAssertEqual(markKeys(of: b.runs[0]), ["bold", "italic", "strike"])
        XCTAssertEqual(b.runs[1].text, "fn()")
        XCTAssertEqual(markKeys(of: b.runs[1]), ["code"], "code excludes bold/italic/strike")
        XCTAssertTrue(harness.input.activeMarks.isEmpty)

        // One undo restores the literal backticks and original marks.
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        let restored = try block(session, "p")
        XCTAssertEqual(text(of: restored), "Hi `fn()`")
        XCTAssertEqual(restored.runs.count, 1)
        XCTAssertEqual(markKeys(of: restored.runs[0]), ["bold", "italic", "strike"])
        try await assertConsistent(harness, localCommands: "`fn()`".count + 2)
    }

    // MARK: - Block types, code blocks, code text, tables & opaque blocks

    func testShortcutWorksInHeadingsListItemsAndQuotes() async throws {
        let blocks: [(node: String, props: [(String, YAnyValue)])] = [
            ("heading", Self.paragraphProps + [("level", .int(2))]),
            ("bulletListItem", Self.paragraphProps),
            ("numberedListItem", Self.paragraphProps),
            ("checkListItem", Self.paragraphProps + [("checked", .bool(false))]),
            ("quote", [("backgroundColor", .string("default")), ("textColor", .string("default"))]),
        ]
        for (node, props) in blocks {
            let harness = try await makeHarness([BlockNoteBlock(node: node, props: props, runs: [], id: "b")])
            let session = harness.session
            try caret(harness, "b", 0)
            type(session, "**ok**")
            await harness.settle()

            let b = try block(session, "b")
            XCTAssertEqual(b.node, node)
            XCTAssertEqual(text(of: b), "ok", node)
            XCTAssertEqual(b.runs.count, 1, node)
            XCTAssertEqual(markKeys(of: b.runs[0]), ["bold"], node)
            try await assertConsistent(harness, localCommands: "**ok**".count + 1)
            await harness.close()
        }
    }

    func testNoConversionInCodeBlock() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(node: "codeBlock", props: [("language", .string("swift"))], runs: [], id: "code")
        ])
        let session = harness.session
        try caret(harness, "code", 0)
        type(session, "**bold** *em* `x` ~~s~~")
        await harness.settle()

        let b = try block(session, "code")
        XCTAssertEqual(text(of: b), "**bold** *em* `x` ~~s~~")
        XCTAssertTrue(b.runs.allSatisfy(\.marks.isEmpty))
        XCTAssertTrue(markShortcutCommands(harness).isEmpty)
        try await assertConsistent(harness, localCommands: "**bold** *em* `x` ~~s~~".count)
    }

    func testNoConversionInsideCodeMarkedText() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("x ", marks: [("code", "{}")])], id: "p")
        ])
        let session = harness.session
        try caret(harness, "p", 2)
        type(session, "**bold**")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "x **bold**")
        XCTAssertEqual(b.runs.count, 1)
        XCTAssertEqual(markKeys(of: b.runs[0]), ["code"])
        XCTAssertTrue(markShortcutCommands(harness).isEmpty)
        try await assertConsistent(harness, localCommands: "**bold**".count)
    }

    func testNoConversionWhenWrappingCodeMarkedBody() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("**"), InlineRun("code", marks: [("code", "{}")]), InlineRun("*")], id: "p")
        ])
        let session = harness.session
        try caret(harness, "p", 7)
        type(session, "*")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "**code**")
        XCTAssertTrue(markShortcutCommands(harness).isEmpty)
        try await assertConsistent(harness, localCommands: 1)
    }

    func testShortcutConvertsInATableCellAndOneUndoRestoresDelimiters() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        let table = try await unwrapped(await harness.session.openTable("tbl"), "the table opens")
        addTeardownBlock { await table.close().value }
        let input = try XCTUnwrap(table.input)
        let cellID = table.surface.blocks[0].id
        input.showCell([cellID])
        let initial = text(of: table.surface.blocks[0])
        select(table, NSRange(location: try location(table, cellID, initial.utf16.count), length: 0))
        type(table, " **bold**")
        await table.settle()
        await harness.settle()

        XCTAssertEqual(text(of: table.surface.blocks[0]), "\(initial) bold")
        XCTAssertEqual(table.surface.blocks[0].runs.last?.text, "bold")
        XCTAssertEqual(table.surface.blocks[0].runs.last.map(markKeys), ["bold"])
        XCTAssertEqual(
            table.textView.selectedRange,
            NSRange(location: try location(table, cellID, "\(initial) bold".utf16.count), length: 0))
        XCTAssertFalse(input.activeMarks.contains { $0.key == "bold" })

        // Next typed character in the cell is plain.
        type(table, "!")
        await table.settle()
        await harness.settle()
        XCTAssertEqual(text(of: table.surface.blocks[0]), "\(initial) bold!")
        XCTAssertEqual(table.surface.blocks[0].runs.last?.text, "!")
        XCTAssertTrue(table.surface.blocks[0].runs.last?.marks.isEmpty == true)

        // Undo the "!", then one undo restores the literal delimiters.
        let undoneBang = await table.run { input.undo() }
        XCTAssertTrue(undoneBang)
        let undoneShortcut = await table.run { input.undo() }
        XCTAssertTrue(undoneShortcut)
        await harness.settle()
        XCTAssertEqual(text(of: table.surface.blocks[0]), "\(initial) **bold**")
        XCTAssertFalse(table.surface.blocks[0].runs.contains { $0.marks.contains { $0.key == "bold" } })

        await table.close().value
        await harness.settle()
        try await assertConsistent(harness, localCommands: " **bold**".count + 1 + 1 + 2)
    }

    // MARK: - Undo, IME, paste, barrier path & engine validation

    func testOneUndoRestoresLiteralDelimitersAndRedoReapplies() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        type(session, "**bold**")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "p")), "bold")
        XCTAssertEqual(markKeys(of: try block(session, "p").runs[0]), ["bold"])

        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        let afterUndo = try block(session, "p")
        XCTAssertEqual(text(of: afterUndo), "**bold**", "one undo restores literal delimiters")
        XCTAssertTrue(afterUndo.runs.allSatisfy(\.marks.isEmpty), "mark is removed on undo")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "p", 8), length: 0))

        let redone = await harness.run { harness.input.redo() }
        XCTAssertTrue(redone)
        let afterRedo = try block(session, "p")
        XCTAssertEqual(text(of: afterRedo), "bold")
        XCTAssertEqual(markKeys(of: afterRedo.runs[0]), ["bold"])
        try await assertConsistent(harness, localCommands: "**bold**".count + 3)
    }

    func testIMECompositionDoesNotConvert() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        session.textView.setMarkedText("**bold**", selectedRange: NSRange(location: 8, length: 0))
        await harness.settle()
        XCTAssertTrue(markShortcutCommands(harness).isEmpty, "marked text never converts")

        session.textView.unmarkText()
        await harness.settle()
        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "**bold**")
        XCTAssertTrue(b.runs.allSatisfy(\.marks.isEmpty))
        XCTAssertTrue(markShortcutCommands(harness).isEmpty, "IME commit never triggers inline shortcut")
        try await assertConsistent(harness, localCommands: 1)
    }

    func testPasteOfDelimitedTextDoesNotConvert() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        harness.pasteboard.string = "**bold**"
        let pasted = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pasted)

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "**bold**")
        XCTAssertTrue(b.runs.allSatisfy(\.marks.isEmpty))
        XCTAssertTrue(markShortcutCommands(harness).isEmpty)
        try await assertConsistent(harness, localCommands: 1)
    }

    func testShortcutConvertsOnBarrierPathWithInlineObject() async throws {
        let harness = try await makeHarness(
            state: try stateWithMention([paragraph("p", "Hi ")], blockID: "p", at: 3))
        let session = harness.session
        // Caret right after the mention + space.
        try caret(harness, "p", 4)
        type(session, " **bold**")
        await harness.settle()

        let b = try block(session, "p")
        XCTAssertEqual(text(of: b), "Hi \u{FFFC} bold")
        XCTAssertEqual(b.runs.last?.text, "bold")
        XCTAssertEqual(b.runs.last.map(markKeys), ["bold"])
        XCTAssertEqual(
            harness.view.selectedRange,
            NSRange(location: try location(session, "p", "Hi \u{FFFC} bold".utf16.count), length: 0))
        try await assertConsistent(harness, localCommands: " **bold**".count + 1)
    }

    func testEngineValidationRefusesInvalidMarkShortcuts() async throws {
        let harness = try await makeHarness([
            paragraph("p", "**bold**"),
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("**"), InlineRun("code", marks: [("code", "{}")]), InlineRun("**")], id: "coded"),
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("**bold**")], id: "cb"),
            BlockNoteBlock(
                node: "futureBlock", props: [("x-future", .string("kept"))], runs: [InlineRun("**bold**")],
                id: "opaque"),
        ])

        let validBold = NativeMarkShortcutCommand(
            fullRange: 0..<8, openLength: 2, closeLength: 2, delimiter: "**",
            attributes: [TextMark(key: "bold", valueJSON: "{}")])
        let mismatched = NativeMarkShortcutCommand(
            fullRange: 0..<8, openLength: 2, closeLength: 2, delimiter: "__",
            attributes: [TextMark(key: "bold", valueJSON: "{}")])
        let emptyBody = NativeMarkShortcutCommand(
            fullRange: 0..<4, openLength: 2, closeLength: 2, delimiter: "**",
            attributes: [TextMark(key: "bold", valueJSON: "{}")])

        let refusedMismatched = await harness.engine { engine in
            let cmd = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "p", kind: .markShortcut(mismatched))
            return !engine.canApplyStructural(cmd)
        }
        XCTAssertTrue(refusedMismatched ?? false)

        let refusedEmptyBody = await harness.engine { engine in
            let cmd = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "p", kind: .markShortcut(emptyBody))
            return !engine.canApplyStructural(cmd)
        }
        XCTAssertTrue(refusedEmptyBody ?? false)

        for targetID in ["coded", "cb", "opaque"] {
            let refused = await harness.engine { engine in
                let cmd = NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: targetID, kind: .markShortcut(validBold))
                return !engine.canApplyStructural(cmd)
            }
            XCTAssertTrue(refused ?? false, "engine must refuse .markShortcut on \(targetID)")
        }
    }
}
