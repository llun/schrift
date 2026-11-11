import UIKit
import XCTest

@testable import Schrift

/// PR05a: inline marks, links and colours on the native selection. Each
/// action is one durable `.marks` (or typing) command through the engine; a
/// mark-only change patches marks only and never touches the text.
@MainActor
final class NativeFormattingTests: NativeEditingTestCase {
    private let bold = TextMark(key: "bold", valueJSON: "{}")

    // MARK: - Mark-only commands

    func testBoldOverAWordIsOneMarksOnlyCommandAndTogglesOff() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let recorder = PatchLog(session)
        let before = texts(session)
        try select(harness, from: (Self.firstID, 0), to: (Self.firstID, 5))

        let toggled1 = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(toggled1)
        XCTAssertEqual(
            harness.log.commands.last?.kind,
            .marks(NativeMarkCommand(startOffset: 0, endBlockID: Self.firstID, endOffset: 5, attributes: [bold])))
        XCTAssertEqual(try block(session, Self.firstID).runs.map(\.text), ["First", " paragraph."])
        XCTAssertEqual(try block(session, Self.firstID).runs.first?.marks.map(\.key), ["bold"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 0, length: 5), "the selection is kept")
        XCTAssertEqual(harness.input.activeMarks, [bold])
        assertMarksOnly(recorder, session: session, texts: before)
        try await assertConsistent(harness, localCommands: 1)

        let toggled2 = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(toggled2)
        XCTAssertEqual(
            harness.log.commands.last?.kind,
            .marks(
                NativeMarkCommand(
                    startOffset: 0, endBlockID: Self.firstID, endOffset: 5,
                    attributes: [TextMark(key: "bold", valueJSON: "null")])))
        XCTAssertEqual(try block(session, Self.firstID).runs.map(\.text), ["First paragraph."])
        XCTAssertEqual(harness.input.activeMarks, [])
        assertMarksOnly(recorder, session: session, texts: before)
        try await assertConsistent(harness, localCommands: 2)
    }

    /// A half-bold selection reads as not bold; Bold turns it all on. Mixed
    /// marks under one new mark still patch marks only, one delta per run.
    func testPartialAndMixedRunsToggleAllOn() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let recorder = PatchLog(session)
        let before = texts(session)
        // "has bold": "has " is plain, "bold" is bold.
        try select(harness, from: (Self.secondID, 17), to: (Self.secondID, 25))
        XCTAssertEqual(harness.input.activeMarks, [], "a partial run is not on")
        let toggledBold = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(toggledBold)
        XCTAssertEqual(try runs(session, Self.secondID, "bold"), ["has bold words"])
        try await assertConsistent(harness, localCommands: 1)

        // "paragraph has bold": plain, then bold; italic then underline over it.
        try select(harness, from: (Self.secondID, 7), to: (Self.secondID, 11))
        let toggledItalic = await harness.run { harness.input.toggleMark("italic") }
        XCTAssertTrue(toggledItalic)
        try select(harness, from: (Self.secondID, 7), to: (Self.secondID, 25))
        XCTAssertEqual(harness.input.activeMarks, [])
        let toggledUnderline = await harness.run { harness.input.toggleMark("underline") }
        XCTAssertTrue(toggledUnderline)
        let second = try block(session, Self.secondID)
        XCTAssertEqual(
            second.runs.map { "\($0.text)|\($0.marks.map(\.key).sorted().joined(separator: ","))" },
            [
                "Second |", "para|italic,underline", "graph |underline", "has bold|bold,underline",
                " words|bold", " inside it.|",
            ])
        XCTAssertEqual(harness.input.activeMarks.map(\.key), ["underline"])
        assertMarksOnly(recorder, session: session, texts: before)
        try await assertConsistent(harness, localCommands: 3)
    }

    func testFormattingAcrossBlocksIsOneCommand() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let recorder = PatchLog(session)
        let before = texts(session)
        try select(harness, from: (Self.thirdID, 5), to: (Self.firstID, 6))
        let toggledItalic = await harness.run { harness.input.toggleMark("italic") }
        XCTAssertTrue(toggledItalic)
        XCTAssertEqual(
            harness.log.commands.last?.kind,
            .marks(
                NativeMarkCommand(
                    startOffset: 6, endBlockID: Self.thirdID, endOffset: 5,
                    attributes: [TextMark(key: "italic", valueJSON: "{}")])))
        XCTAssertEqual(try runs(session, Self.firstID, "italic"), ["paragraph."])
        XCTAssertEqual(try runs(session, Self.secondID, "italic").joined(), text(of: try block(session, Self.secondID)))
        XCTAssertEqual(try runs(session, Self.thirdID, "italic"), ["Third"])
        XCTAssertEqual(recorder.patches.count, 1, "one transaction")
        assertMarksOnly(recorder, session: session, texts: before)
        try await assertConsistent(harness, localCommands: 1)

        // A whole block with its separator ends at the next block's start:
        // nothing is written there.
        try select(harness, from: (Self.firstID, 0), to: (Self.secondID, 0))
        let toggledStrike = await harness.run { harness.input.toggleMark("strike") }
        XCTAssertTrue(toggledStrike)
        XCTAssertEqual(try runs(session, Self.firstID, "strike").joined(), "First paragraph.")
        XCTAssertEqual(try runs(session, Self.secondID, "strike"), [])
        try await assertConsistent(harness, localCommands: 2)
    }

    func testAnUnsupportedBlockInTheRangeRefusesTheWholeCommand() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "table", props: [], runs: [], id: "t"),
            paragraph("b", "Beta"),
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("text"))], runs: [InlineRun("let x")], id: "c"),
        ])
        addTeardownBlock { await harness.close() }
        try select(harness, from: ("a", 2), to: ("b", 2))
        let boldRefused1 = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertFalse(boldRefused1)
        try select(harness, from: ("c", 0), to: ("c", 3))
        let boldRefused2 = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertFalse(boldRefused2)
        XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable)
        XCTAssertEqual(texts(harness.session).first, "Alpha")
        XCTAssertTrue(harness.session.surface.blocks.allSatisfy { $0.runs.allSatisfy { $0.marks.isEmpty } })
        try await assertConsistent(harness, localCommands: 0)
    }

    func testColorsAreBlockNoteNamesAndRenderInBothThemes() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.thirdID, 0), to: (Self.thirdID, 5))
        let colorRed = await harness.run { harness.input.setColor(NativeMark.textColor, name: "red") }
        XCTAssertTrue(colorRed)
        let colorYellow = await harness.run { harness.input.setColor(NativeMark.backgroundColor, name: "yellow") }
        XCTAssertTrue(colorYellow)
        let third = try block(session, Self.thirdID)
        XCTAssertEqual(
            third.runs.first?.marks.map { "\($0.key)=\($0.valueJSON)" }.sorted(),
            [#"backgroundColor={"stringValue":"yellow"}"#, #"textColor={"stringValue":"red"}"#])
        let location = try location(session, Self.thirdID, 1)
        let foreground = try XCTUnwrap(
            harness.view.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor)
        let light = foreground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = foreground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotEqual(light, UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        XCTAssertNotNil(harness.view.textStorage.attribute(.backgroundColor, at: location, effectiveRange: nil))
        XCTAssertEqual(light, dark, "BlockNote's red is the same in both themes")
        try await assertConsistent(harness, localCommands: 2)

        let colorCleared = await harness.run { harness.input.setColor(NativeMark.textColor, name: nil) }
        XCTAssertTrue(colorCleared)
        XCTAssertEqual(try block(session, Self.thirdID).runs.first?.marks.map(\.key), ["backgroundColor"])
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Unknown marks

    func testUnknownMarksRenderAndSurviveEveryEdit() async throws {
        let comment = (key: "comment", valueJSON: #"{"threadId":"t1"}"#)
        let harness = try await makeHarness([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("keep "), InlineRun("this", marks: [comment]), InlineRun(" note")], id: "u")
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.canType, "an unknown mark no longer makes the document read-only")
        XCTAssertEqual(texts(session), ["keep this note"])
        func commentRuns() throws -> [String] {
            try block(session, "u").runs.filter { $0.marks.contains { $0.key == "comment" } }.map(\.text)
        }
        XCTAssertEqual(try commentRuns(), ["this"])

        try select(harness, from: ("u", 0), to: ("u", 14))
        let boldToggled = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(boldToggled)
        XCTAssertEqual(try commentRuns(), ["this"])
        XCTAssertEqual(
            try block(session, "u").runs.first { $0.text == "this" }?.marks.map(\.key).sorted(), ["bold", "comment"])
        try await assertConsistent(harness, localCommands: 1)

        // Typing at its edge does not spread it; typing inside keeps it.
        setSelection(harness, NSRange(location: 9, length: 0))
        let replaced1 = await harness.run { harness.input.replace(range: NSRange(location: 9, length: 0), with: "!") }
        XCTAssertTrue(replaced1)
        setSelection(harness, NSRange(location: 6, length: 0))
        let replaced2 = await harness.run { harness.input.replace(range: NSRange(location: 6, length: 0), with: "i") }
        XCTAssertTrue(replaced2)
        XCTAssertEqual(try commentRuns(), ["tihis"])
        XCTAssertEqual(texts(session), ["keep tihis! note"])
        try await assertConsistent(harness, localCommands: 3)

        // A Return through it keeps both halves marked.
        setSelection(harness, NSRange(location: 7, length: 0))
        let newlineInserted = await harness.run { harness.input.insertNewline() }
        XCTAssertTrue(newlineInserted)
        XCTAssertEqual(
            session.surface.blocks.flatMap { $0.runs.filter { $0.marks.contains { $0.key == "comment" } } }.map(\.text),
            ["ti", "his"])
        try await assertConsistent(harness, localCommands: 4)
    }

    // MARK: - Links

    func testLinkInsertEditRelabelAndRemove() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        func link() throws -> [String] {
            try block(session, Self.firstID).runs.compactMap { run in
                run.marks.first { $0.key == "link" }.flatMap { YBlockProjection.linkHref(from: $0.valueJSON) }
                    .map { "\(run.text)→\($0)" }
            }
        }

        try select(harness, from: (Self.firstID, 0), to: (Self.firstID, 5))
        let new = try XCTUnwrap(harness.input.linkTarget())
        XCTAssertEqual(new.label, "First")
        XCTAssertNil(new.href)
        let badLink = await harness.run { harness.input.applyLink(label: "First", url: "javascript:alert(1)", to: new) }
        XCTAssertFalse(badLink)
        let goodLink1 = await harness.run { harness.input.applyLink(label: "First", url: "example.com/a", to: new) }
        XCTAssertTrue(goodLink1)
        XCTAssertEqual(
            harness.log.commands.last?.kind,
            .marks(
                NativeMarkCommand(
                    startOffset: 0, endBlockID: Self.firstID, endOffset: 5,
                    attributes: [TextMark(key: "link", valueJSON: #"{"href":"https://example.com/a"}"#)])))
        XCTAssertEqual(try link(), ["First→https://example.com/a"])
        try await assertConsistent(harness, localCommands: 1)

        // A caret inside the link edits the whole link.
        setSelection(harness, NSRange(location: 2, length: 0))
        let existing = try XCTUnwrap(harness.input.linkTarget())
        XCTAssertEqual(existing.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(existing.href, "https://example.com/a")
        let goodLink2 = await harness.run {
            harness.input.applyLink(label: "First", url: "https://docs.example.org/", to: existing)
        }
        XCTAssertTrue(goodLink2)
        XCTAssertEqual(try link(), ["First→https://docs.example.org/"])
        try await assertConsistent(harness, localCommands: 2)

        // A new label is typed with the link, as one command.
        let relabel = try XCTUnwrap(harness.input.linkTarget())
        let relabeled = await harness.run {
            harness.input.applyLink(label: "Home", url: "https://docs.example.org/", to: relabel)
        }
        XCTAssertTrue(relabeled)
        XCTAssertEqual(texts(session).first, "Home paragraph.")
        XCTAssertEqual(try link(), ["Home→https://docs.example.org/"])
        try await assertConsistent(harness, localCommands: 3)

        setSelection(harness, NSRange(location: 1, length: 0))
        let toRemove = try XCTUnwrap(harness.input.linkTarget())
        let removed = await harness.run { harness.input.removeLink(toRemove) }
        XCTAssertTrue(removed)
        XCTAssertEqual(try link(), [])
        XCTAssertEqual(texts(session).first, "Home paragraph.")
        try await assertConsistent(harness, localCommands: 4)

        // At a caret with no label, the address is inserted as the link text.
        let end = try location(session, Self.firstID, 15)
        setSelection(harness, NSRange(location: end, length: 0))
        let caret = try XCTUnwrap(harness.input.linkTarget())
        let insertedLink = await harness.run { harness.input.applyLink(label: " ", url: "example.com", to: caret) }
        XCTAssertTrue(insertedLink)
        XCTAssertEqual(try link(), ["https://example.com→https://example.com"])
        try await assertConsistent(harness, localCommands: 5)
    }

    // MARK: - Typing

    func testTypingContinuesTheMarksAtTheCaret() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        // The end of "bold words": typing stays bold, and Yjs inherits it, so
        // the command carries no explicit marks.
        let r1 = try range(session, Self.secondID, 31)
        setSelection(harness, r1)
        XCTAssertEqual(harness.input.activeMarks, [bold])
        let font = try XCTUnwrap(harness.view.typingAttributes[.font] as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold), "typing attributes follow the caret")
        let typedX = await harness.run { harness.input.replace(range: r1, with: "X") }
        XCTAssertTrue(typedX)
        XCTAssertEqual(harness.log.commands.last?.kind, .replace(range: 31..<31, replacement: "X"))
        XCTAssertEqual(try runs(session, Self.secondID, "bold"), ["bold wordsX"])
        try await assertConsistent(harness, localCommands: 1)

        // A toggle at a caret writes nothing; the next text carries it.
        let end = try range(session, Self.firstID, 16)
        setSelection(harness, end)
        let toggledBold = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(toggledBold)
        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(harness.input.activeMarks, [bold])
        let typedZ = await harness.run { harness.input.replace(range: end, with: "Z") }
        XCTAssertTrue(typedZ)
        XCTAssertEqual(harness.log.commands.last?.kind, .replace(range: 16..<16, replacement: "Z", marks: [bold]))
        XCTAssertEqual(try runs(session, Self.firstID, "bold"), ["Z"])
        try await assertConsistent(harness, localCommands: 2)

        // A link does not grow from its end (BlockNote's `inclusive: false`).
        try select(harness, from: (Self.thirdID, 0), to: (Self.thirdID, 5))
        let targetLink = try XCTUnwrap(harness.input.linkTarget())
        let linkApplied = await harness.run {
            harness.input.applyLink(label: "Third", url: "example.com", to: targetLink)
        }
        XCTAssertTrue(linkApplied)
        let r3 = try range(session, Self.thirdID, 5)
        setSelection(harness, r3)
        XCTAssertEqual(harness.input.activeMarks, [])
        let typedExcl = await harness.run {
            harness.input.replace(range: r3, with: "!")
        }
        XCTAssertTrue(typedExcl)
        XCTAssertEqual(harness.log.commands.last?.kind, .replace(range: 5..<5, replacement: "!", marks: []))
        XCTAssertEqual(try runs(session, Self.thirdID, "link"), ["Third"])
        try await assertConsistent(harness, localCommands: 4)
    }

    // MARK: - Hygiene

    func testAThemeChangeWritesNoTransaction() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 0), to: (Self.firstID, 5))
        let colorSet = await harness.run { harness.input.setColor(NativeMark.textColor, name: "blue") }
        XCTAssertTrue(colorSet)
        let codeSet = await harness.run { harness.input.toggleMark("code") }
        XCTAssertTrue(codeSet)
        let revision = await session.engine { $0.revision }
        let journal = try XCTUnwrap(harness.store.restore(for: harness.scope)).manifest.journal.count
        let storage = NSAttributedString(attributedString: harness.view.textStorage)

        // Light/dark alone: dynamic colours resolve at draw time; storage is untouched.
        harness.view.overrideUserInterfaceStyle = .dark
        session.surface.updatePresentation(
            traits: session.surface.traits.modifyingTraits { $0.userInterfaceStyle = .dark },
            labels: session.surface.labels)
        XCTAssertTrue(harness.view.textStorage.isEqual(to: storage))
        // A Dynamic Type change restyles storage, still without a transaction.
        session.surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge),
            labels: session.surface.labels)
        XCTAssertFalse(harness.view.textStorage.isEqual(to: storage))
        let currentRevision = await session.engine { $0.revision }
        XCTAssertEqual(currentRevision, revision)
        XCTAssertEqual(try XCTUnwrap(harness.store.restore(for: harness.scope)).manifest.journal.count, journal)
        try await assertConsistent(harness, localCommands: 2)
    }

    func testNoMarkerCharactersReachTheReplicaText() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let before = texts(session)
        try select(harness, from: (Self.firstID, 0), to: (Self.thirdID, 5))
        for key in NativeMark.toggles {
            let toggled = await harness.run { harness.input.toggleMark(key) }
            XCTAssertTrue(toggled)
        }
        let target = try XCTUnwrap(harness.input.linkTarget())
        let applied = await harness.run { harness.input.applyLink(label: target.label, url: "example.com", to: target) }
        XCTAssertTrue(applied)
        XCTAssertEqual(texts(session), before)
        XCTAssertEqual(try replay(harness).map { text(of: $0) }, before, "the replica text has no marker characters")
        XCTAssertTrue(session.surface.blocks.prefix(2).allSatisfy { $0.runs.allSatisfy { $0.marks.count == 6 } })
        try await assertConsistent(harness, localCommands: NativeMark.toggles.count + 1)
    }

    func testRelaunchReplaysEveryMark() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try select(harness, from: (Self.firstID, 0), to: (Self.secondID, 6))
        let underline = await harness.run { harness.input.toggleMark("underline") }
        XCTAssertTrue(underline)
        let color = await harness.run { harness.input.setColor(NativeMark.backgroundColor, name: "green") }
        XCTAssertTrue(color)
        let r = try range(harness.session, Self.thirdID, 16)
        setSelection(harness, r)
        let italic = await harness.run { harness.input.toggleMark("italic") }
        XCTAssertTrue(italic)
        let replaced = await harness.run { harness.input.replace(range: r, with: "!") }
        XCTAssertTrue(replaced)
        try await assertConsistent(harness, localCommands: 3)

        let reopened = try unwrapped(try await NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        addTeardownBlock { await reopened.close().value }
        XCTAssertEqual(reopened.surface.blocks, harness.session.surface.blocks)
        let reopenedRevision = await reopened.engine { $0.revision }
        let sessionRevision = await harness.session.engine { $0.revision }
        XCTAssertEqual(reopenedRevision, sessionRevision)
        XCTAssertTrue(
            reopened.textView.textStorage.isEqual(
                to: AttributedDocumentProjection.attributedString(
                    blocks: harness.session.surface.blocks, traits: reopened.surface.traits,
                    labels: reopened.surface.labels)))
    }

    // MARK: - Helpers

    private func range(_ session: NativeEditorSession, _ id: String, _ offset: Int) throws -> NSRange {
        NSRange(location: try location(session, id, offset), length: 0)
    }

    /// The texts of the runs carrying `key`.
    private func runs(_ session: NativeEditorSession, _ id: String, _ key: String) throws -> [String] {
        try block(session, id).runs.filter { $0.marks.contains { $0.key == key } }.map(\.text)
    }

    /// Every recorded change is a `.text` delta that rewrites a range with the
    /// text it already held, and the block texts never changed.
    private func assertMarksOnly(
        _ recorder: PatchLog, session: NativeEditorSession, texts expected: [String], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(recorder.patches.isEmpty, file: file, line: line)
        for change in recorder.patches.flatMap(\.changes) {
            guard case .text(_, let deltas) = change else {
                return XCTFail("not a marks-only patch: \(change)", file: file, line: line)
            }
            XCTAssertTrue(deltas.allSatisfy { $0.range.count == $0.replacement.utf16.count }, file: file, line: line)
        }
        XCTAssertEqual(session.surface.blocks.map { text(of: $0) }, expected, file: file, line: line)
    }
}
