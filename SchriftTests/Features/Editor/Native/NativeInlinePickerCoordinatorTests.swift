import UIKit
import XCTest

@testable import Schrift

/// Step 2 of native inline pickers (`PR13c2`): coordinator trigger tracking,
/// slash "Link a page" replacement without persisted `mentionSearchInline`,
/// mention lazy access loading, keyboard precedence in `NativeTextView`, IME
/// suppression, undo/redo, and peer-edit anchor adjustment.
@MainActor
final class NativeInlinePickerCoordinatorTests: NativeEditingTestCase {
    @MainActor
    private final class SourceBox {
        var canInsertPageLink = true
        var pageLinks: [Schrift.Document] = []
        var excludedDocumentID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
        var recordedTitles: [(UUID, String)] = []
        var canMention = true
        var mentionState: NativeInlinePickerSource.MentionAccessState = .idle
        var isOffline = false
        var requestedMentionKeys: [InlineTriggerKey] = []
        var clearedFailures = 0

        func makeSource() -> NativeInlinePickerSource {
            NativeInlinePickerSource(
                canInsertPageLink: { self.canInsertPageLink },
                pageLinkCandidates: { self.pageLinks },
                excludedDocumentID: excludedDocumentID,
                onRecordDocumentTitle: { id, title in
                    self.recordedTitles.append((id, title))
                },
                canMention: { self.canMention },
                mentionState: { self.mentionState },
                requestMentions: { key in
                    guard !self.isOffline else { return }
                    self.requestedMentionKeys.append(key)
                    if case .idle = self.mentionState { self.mentionState = .loading }
                },
                clearMentionFailure: {
                    self.clearedFailures += 1
                    self.mentionState = .idle
                })
        }
    }

    private func makeDocument(
        id: UUID, title: String?, updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Schrift.Document {
        Schrift.Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: 0, path: "0001",
            createdAt: updatedAt, updatedAt: updatedAt, userRole: nil, creator: nil)
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    private func type(_ harness: Harness, _ text: String) {
        XCTAssertTrue(harness.input.replace(range: harness.view.selectedRange, with: text))
    }

    private func attach(_ harness: Harness, source: SourceBox) {
        harness.input.inlinePickerSource = source.makeSource()
        harness.input.refreshInlinePicker()
    }

    private func keyCommand(
        _ view: NativeTextView, input: String, modifiers: UIKeyModifierFlags = []
    ) -> UIKeyCommand? {
        view.keyCommands?.first { $0.input == input && $0.modifierFlags == modifiers }
    }

    private func yes(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }

    private func interlinkRun(_ docID: UUID) -> InlineRun {
        InlineRun(
            inlineObject: .interlink(
                docID: docID.uuidString.lowercased(), blockID: "", title: nil, disabled: false, trigger: "/"))
    }

    private func mentionRun(userID: String, fullName: String) -> InlineRun {
        InlineRun(inlineObject: .mention(userID: userID, fullName: fullName))
    }

    // MARK: - Double-bracket `[[` page link

    func testDoubleBracketSelectReplacesQueryWithInterlinkAndPrimesTitleImmediately() async throws {
        let alphaID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let betaID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let source = SourceBox()
        source.pageLinks = [
            makeDocument(id: betaID, title: "Another Spec"),
            makeDocument(id: alphaID, title: "Spec Overview"),
        ]

        let harness = try await makeHarness([paragraph("p", "See  here")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        try caret(harness, "p", 4)
        type(harness, "[[spec")
        await harness.settle()

        guard case .pageLink(let state)? = harness.input.inlinePicker else {
            return XCTFail("expected page link picker for `[[spec`")
        }
        XCTAssertEqual(state.query, "spec")
        XCTAssertEqual(state.matches.map(\.id), [alphaID, betaID])
        XCTAssertEqual(state.highlighted?.id, alphaID)

        let committed = await harness.run {
            harness.input.commitHighlightedInlinePicker()
        }
        XCTAssertTrue(committed)
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(harness.session, "p", 5), length: 0))
        XCTAssertEqual(harness.session.surface.attachmentGeometry.documentTitles[alphaID], "Spec Overview")
        XCTAssertEqual(source.recordedTitles.map(\.0), [alphaID])

        let block = try self.block(harness.session, "p")
        XCTAssertEqual(block.runs, [InlineRun("See "), interlinkRun(alphaID), InlineRun(" here")])

        let xml = await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
        XCTAssertFalse(xml.lowercased().contains("mentionsearchinline"))
        XCTAssertTrue(xml.contains(#"docId="\#(alphaID.uuidString.lowercased())""#))
        XCTAssertFalse(xml.contains(#"title="Spec Overview""#))
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - Slash `"Link a page"`

    func testSlashMenuIncludesLinkPageWhenPermittedAndReplacesWithoutMentionSearchInline() async throws {
        let targetID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let source = SourceBox()
        source.pageLinks = [makeDocument(id: targetID, title: "Design Notes")]

        let harness = try await makeHarness([paragraph("p", "")])
        addTeardownBlock { await harness.close() }

        XCTAssertFalse(harness.input.slashItems.contains { $0.action == .linkPage })
        attach(harness, source: source)
        XCTAssertTrue(harness.input.slashItems.contains { $0.action == .linkPage })

        try caret(harness, "p", 0)
        type(harness, "/link")
        await harness.settle()

        let applied = await harness.run {
            harness.input.applySlashItem(linkPageSlashItem)
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(try block(harness.session, "p").runs, [])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(harness.session, "p", 0), length: 0))

        guard case .pageLink(let emptyState)? = harness.input.inlinePicker else {
            return XCTFail("expected inline page link picker right after applying slash item")
        }
        XCTAssertEqual(emptyState.query, "")
        XCTAssertEqual(emptyState.matches.map(\.id), [targetID])

        let xmlMidSession = await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
        XCTAssertFalse(xmlMidSession.lowercased().contains("mentionsearchinline"))

        type(harness, "design")
        await harness.settle()
        guard case .pageLink(let filteredState)? = harness.input.inlinePicker else {
            return XCTFail("expected filtered page link picker")
        }
        XCTAssertEqual(filteredState.query, "design")

        yes(await harness.run { harness.input.selectPageLink(source.pageLinks[0]) })
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertEqual(try block(harness.session, "p").runs, [interlinkRun(targetID)])
        try await assertConsistent(harness, localCommands: 4)
    }

    func testSlashLinkPageBarrierFallbackWhenInlineObjectFollowsCaret() async throws {
        let existingID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let pickedID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let source = SourceBox()
        source.pageLinks = [makeDocument(id: pickedID, title: "Roadmap")]

        let seedDoc = YDoc(clientID: UInt(Self.seedClientID))
        defer { seedDoc.destroy() }
        try seedDoc.applyUpdate(
            YUpdateDecoder.decode(BlockNoteYjs.encode([paragraph("p", "/link ")], clientID: Self.seedClientID)),
            origin: .localUser)
        let seedEngine = DocumentEngine(doc: seedDoc)
        defer { seedEngine.detach() }
        let existingChip = NativeInlineObject.interlink(
            docID: existingID.uuidString.lowercased(), blockID: "", title: nil, disabled: false, trigger: "/")
        _ = try seedEngine.applyStructural(
            NativeEditCommand(
                id: UUID(), baseRevision: seedEngine.revision, blockID: "p",
                kind: .insertInlineObject(existingChip, replacing: 6..<6))
        ) { _ in }
        let state = try YStateEncoder.encodeStateAsUpdate(seedDoc)
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        try caret(harness, "p", 5)
        yes(await harness.run { harness.input.applySlashItem(linkPageSlashItem) })

        guard case .pageLink(let picker)? = harness.input.inlinePicker else {
            return XCTFail("expected slash page-link picker even when barrier path replaces `/link`")
        }
        XCTAssertEqual(picker.query, "")

        yes(await harness.run { harness.input.selectPageLink(source.pageLinks[0]) })
        XCTAssertEqual(
            try block(harness.session, "p").runs,
            [interlinkRun(pickedID), InlineRun(" "), interlinkRun(existingID)])
        try await assertConsistent(harness, localCommands: 2)
    }

    func testSlashPageLinkEscapeKeepsLiteralTextAndEmptyBackspaceCancelsViaDeleteKeyAndReplace() async throws {
        let targetID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let source = SourceBox()
        source.pageLinks = [makeDocument(id: targetID, title: "Alpha")]

        let harness = try await makeHarness([paragraph("p1", "Lead"), paragraph("p2", "")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        // 1. Escape keeps literal query text and ends the slash session.
        try caret(harness, "p2", 0)
        type(harness, "/link")
        await harness.settle()
        yes(await harness.run { harness.input.applySlashItem(linkPageSlashItem) })
        type(harness, "abc")
        await harness.settle()

        XCTAssertTrue(harness.input.handleInlinePickerKey(.escape))
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertEqual(try block(harness.session, "p2").runs, [InlineRun("abc")])

        // 2. Empty Backspace via `deleteKey()` cancels session without joining blocks.
        XCTAssertTrue(
            harness.input.replace(
                range: NSRange(location: try location(harness.session, "p2", 0), length: 3), with: "/link"))
        await harness.settle()
        yes(await harness.run { harness.input.applySlashItem(linkPageSlashItem) })
        XCTAssertNotNil(harness.input.inlinePicker)

        harness.input.deleteKey()
        await harness.settle()
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["p1", "p2"])

        // 3. Empty Backspace via `replace(range:with:)` (`shouldChangeTextIn` path) also cancels cleanly.
        try caret(harness, "p2", 0)
        type(harness, "/link")
        await harness.settle()
        yes(await harness.run { harness.input.applySlashItem(linkPageSlashItem) })
        XCTAssertNotNil(harness.input.inlinePicker)

        let p2Start = try location(harness.session, "p2", 0)
        XCTAssertFalse(harness.input.replace(range: NSRange(location: p2Start - 1, length: 1), with: ""))
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["p1", "p2"])
    }

    // MARK: - `@` mention lazy fetch, states, permissions, failure, commit

    func testMentionLazyFetchLoadingSuppressionAndCommit() async throws {
        let ada = MentionCandidate(userID: "user-ada", fullName: "Ada Lovelace", shortName: "Ada", email: nil)
        let grace = MentionCandidate(userID: "user-grace", fullName: "Grace Hopper", shortName: "Grace", email: nil)
        let source = SourceBox()
        source.mentionState = .idle
        source.isOffline = true

        let harness = try await makeHarness([paragraph("p", "cc ")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        try caret(harness, "p", 3)
        type(harness, "@")
        await harness.settle()

        let expectedKey = InlineTriggerKey(blockID: "p", kind: .mention, anchor: 3)
        XCTAssertTrue(source.requestedMentionKeys.isEmpty)
        XCTAssertNil(harness.input.inlinePicker, "offline idle with no fetch result shows nothing")

        // Back online: requests once and transitions to loading, suppressing Up/Down/Return.
        source.isOffline = false
        harness.input.refreshInlinePicker()
        type(harness, "a")
        await harness.settle()
        XCTAssertEqual(source.requestedMentionKeys, [expectedKey], "requests once per opener without re-fetching")
        guard case .mention(let loadingState)? = harness.input.inlinePicker else {
            return XCTFail("expected loading mention picker")
        }
        XCTAssertTrue(loadingState.isLoading)
        XCTAssertNil(loadingState.highlighted)
        XCTAssertTrue(harness.input.claimsInlinePickerKey(.escape))
        XCTAssertFalse(harness.input.claimsInlinePickerKey(.up))
        XCTAssertFalse(harness.input.claimsInlinePickerKey(.down))
        XCTAssertFalse(harness.input.commitHighlightedInlinePicker())

        // Loaded: ranks candidates and commits via Return.
        source.mentionState = .loaded([grace, ada])
        harness.input.refreshInlinePicker()
        type(harness, "da")
        await harness.settle()

        guard case .mention(let loadedState)? = harness.input.inlinePicker else {
            return XCTFail("expected loaded mention picker")
        }
        XCTAssertFalse(loadedState.isLoading)
        XCTAssertEqual(loadedState.matches.map(\.userID), ["user-ada"])
        XCTAssertEqual(loadedState.highlighted?.userID, "user-ada")

        let committed = await harness.run {
            harness.input.insertNewline()
        }
        XCTAssertTrue(committed)
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(harness.session, "p", 4), length: 0))
        XCTAssertEqual(
            try block(harness.session, "p").runs,
            [InlineRun("cc "), mentionRun(userID: "user-ada", fullName: "Ada Lovelace")])
        try await assertConsistent(harness, localCommands: 4)
    }

    func testMentionPermissionGateAndFailureStaysSilentUntilOpenerRetyped() async throws {
        let source = SourceBox()
        source.canMention = false

        let harness = try await makeHarness([paragraph("p", "Hi ")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        try caret(harness, "p", 3)
        type(harness, "@ada")
        await harness.settle()
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertTrue(source.requestedMentionKeys.isEmpty)

        // Enable mentions and fail on that opener -> silent hide and no repeat fetch for same opener.
        source.canMention = true
        let failedKey = InlineTriggerKey(blockID: "p", kind: .mention, anchor: 3)
        source.mentionState = .failed(failedKey)
        harness.input.refreshInlinePicker()
        XCTAssertNil(harness.input.inlinePicker)

        type(harness, "x")
        await harness.settle()
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertTrue(source.requestedMentionKeys.isEmpty)

        // Remove `@...` opener -> failure cleared; typing new `@` retries cleanly.
        let pStart = try location(harness.session, "p", 3)
        XCTAssertTrue(harness.input.replace(range: NSRange(location: pStart, length: 5), with: ""))
        await harness.settle()
        XCTAssertEqual(source.clearedFailures, 1)

        source.mentionState = .loaded([MentionCandidate(userID: "u1", fullName: "Ada", shortName: nil, email: nil)])
        type(harness, "@")
        await harness.settle()
        guard case .mention(let recovered)? = harness.input.inlinePicker else {
            return XCTFail("expected mention picker after removing and retyping opener")
        }
        XCTAssertEqual(recovered.matches.map(\.userID), ["u1"])
    }

    // MARK: - Keyboard precedence, Up/Down wrap, Escape suppression, IME & selection

    func testKeyboardPrecedenceWithTableAndTextViewCommands() async throws {
        let docA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let docB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let source = SourceBox()
        source.pageLinks = [
            makeDocument(id: docB, title: "Altitude"),
            makeDocument(id: docA, title: "Alpinist"),
        ]

        let harness = try await makeHarness([paragraph("p", "")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        var tableMoves: [NativeInputCoordinator.TableMove] = []
        var exitCount = 0
        harness.input.tableMove = { direction in
            tableMoves.append(direction)
            return true
        }
        harness.input.onExit = { exitCount += 1 }

        try caret(harness, "p", 0)
        type(harness, "[[al")
        await harness.settle()

        let escapeCommand = try XCTUnwrap(keyCommand(harness.view, input: UIKeyCommand.inputEscape))
        let upCommand = try XCTUnwrap(keyCommand(harness.view, input: UIKeyCommand.inputUpArrow))
        let downCommand = try XCTUnwrap(keyCommand(harness.view, input: UIKeyCommand.inputDownArrow))
        let returnCommand = try XCTUnwrap(keyCommand(harness.view, input: "\r"))

        // Down moves 0 -> 1, Down wraps 1 -> 0, Up wraps 0 -> 1.
        harness.view.perform(downCommand.action)
        guard case .pageLink(let s1)? = harness.input.inlinePicker else { return XCTFail() }
        XCTAssertEqual(s1.highlightedIndex, 1)

        harness.view.perform(downCommand.action)
        guard case .pageLink(let s2)? = harness.input.inlinePicker else { return XCTFail() }
        XCTAssertEqual(s2.highlightedIndex, 0)

        harness.view.perform(upCommand.action)
        guard case .pageLink(let s3)? = harness.input.inlinePicker else { return XCTFail() }
        XCTAssertEqual(s3.highlightedIndex, 1)

        // Query change resets highlight to 0.
        type(harness, "p")
        await harness.settle()
        guard case .pageLink(let resetState)? = harness.input.inlinePicker else { return XCTFail() }
        XCTAssertEqual(resetState.highlightedIndex, 0)
        XCTAssertEqual(resetState.matches.map(\.id), [docA])

        // Escape dismisses picker without delegating to `tableMove(.exit)` or `onExit`.
        harness.view.perform(escapeCommand.action)
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertTrue(tableMoves.isEmpty)
        XCTAssertEqual(exitCount, 0)

        // Opener stays dismissed until edited/retyped; Escape now delegates to `tableMove(.exit)`.
        type(harness, "s")
        await harness.settle()
        XCTAssertNil(harness.input.inlinePicker)
        harness.view.perform(escapeCommand.action)
        XCTAssertEqual(tableMoves, [.exit])

        // Return when dismissed falls through to `tableMove(.below)` rather than committing.
        XCTAssertTrue(harness.input.insertNewline())
        XCTAssertEqual(tableMoves, [.exit, .below])

        // Clear the dismissed opener first, then test no-matches key claims and Return commit.
        let end = try location(harness.session, "p", 6)
        XCTAssertTrue(harness.input.replace(range: NSRange(location: 0, length: end), with: ""))
        await harness.settle()
        type(harness, "[[zzzz")
        await harness.settle()
        XCTAssertNotNil(harness.input.inlinePicker)
        XCTAssertNil(keyCommand(harness.view, input: UIKeyCommand.inputUpArrow))
        XCTAssertNil(keyCommand(harness.view, input: UIKeyCommand.inputDownArrow))
        XCTAssertNil(keyCommand(harness.view, input: "\r"))
        XCTAssertNotNil(keyCommand(harness.view, input: UIKeyCommand.inputEscape))

        // Return commits when visible and highlighted.
        XCTAssertTrue(harness.input.replace(range: NSRange(location: 0, length: 6), with: "[[alp"))
        await harness.settle()
        harness.view.perform(returnCommand.action)
        await harness.settle()
        XCTAssertEqual(try block(harness.session, "p").runs, [interlinkRun(docA)])
    }

    func testIMEMarkedTextCaretMoveRangeAndBlurSuppression() async throws {
        let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let source = SourceBox()
        source.pageLinks = [makeDocument(id: docID, title: "Alpha")]

        let harness = try await makeHarness([paragraph("p", "See ")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        try caret(harness, "p", 4)
        type(harness, "[[al")
        await harness.settle()
        XCTAssertNotNil(harness.input.inlinePicker)

        // IME composition suppresses picker & key claims.
        harness.view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNil(harness.input.inlinePicker)
        XCTAssertFalse(harness.input.claimsInlinePickerKey(.escape))
        XCTAssertNil(keyCommand(harness.view, input: "\r"))
        harness.view.unmarkText()
        await harness.settle()

        // Caret moved before anchor hides picker; returning caret restores it.
        try caret(harness, "p", 2)
        XCTAssertNil(harness.input.inlinePicker)
        try caret(harness, "p", 8)
        XCTAssertNotNil(harness.input.inlinePicker)

        // Ranged selection hides picker.
        setSelection(harness, NSRange(location: try location(harness.session, "p", 4), length: 4))
        XCTAssertNil(harness.input.inlinePicker)

        // Blur clears active slash page-link session cleanly.
        try caret(harness, "p", 0)
        let end = harness.view.textStorage.length
        XCTAssertTrue(harness.input.replace(range: NSRange(location: 0, length: end), with: "/link"))
        await harness.settle()
        yes(await harness.run { harness.input.applySlashItem(linkPageSlashItem) })
        XCTAssertNotNil(harness.input.inlinePicker)
        harness.input.textViewDidEndEditing(harness.view)
        XCTAssertNil(harness.input.inlinePicker)
    }

    // MARK: - Undo/Redo & Live Peer Anchors

    func testUndoAndRedoRestoreReplacedQueryAndSlashFilterInOneStep() async throws {
        let docID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let source = SourceBox()
        source.pageLinks = [makeDocument(id: docID, title: "Spec")]

        let harness = try await makeHarness([paragraph("p", "See [[spec here")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        try caret(harness, "p", 10)
        XCTAssertNotNil(harness.input.inlinePicker)
        yes(await harness.run { harness.input.commitHighlightedInlinePicker() })
        XCTAssertEqual(
            try block(harness.session, "p").runs,
            [InlineRun("See "), interlinkRun(docID), InlineRun(" here")])

        yes(await harness.run { harness.input.undo() })
        XCTAssertEqual(try block(harness.session, "p").runs, [InlineRun("See [[spec here")])

        yes(await harness.run { harness.input.redo() })
        XCTAssertEqual(
            try block(harness.session, "p").runs,
            [InlineRun("See "), interlinkRun(docID), InlineRun(" here")])
        try await assertConsistent(harness, localCommands: 3)
    }

    func testLivePeerEditBeforeAnchorAdjustsSlashPageLinkSessionAndDoubleBracketAnchor() async throws {
        let docID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let source = SourceBox()
        source.pageLinks = [makeDocument(id: docID, title: "Spec")]

        let seed = [paragraph("p", "/link")]
        let seedState = BlockNoteYjs.encode(seed, clientID: Self.seedClientID)
        let harness = try await makeHarness(state: seedState)
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        let peerDoc = YDoc(clientID: 77)
        defer { peerDoc.destroy() }
        try peerDoc.applyUpdate(YUpdateDecoder.decode(seedState), origin: .remote)
        let peerEngine = DocumentEngine(doc: peerDoc)

        // Start slash page-link session ("/link" -> "") and type "sp".
        try caret(harness, "p", 5)
        yes(await harness.run { harness.input.applySlashItem(linkPageSlashItem) })
        type(harness, "sp")
        await harness.settle()
        XCTAssertEqual(harness.input.activeInlineTrigger?.trigger.anchor, 0)
        XCTAssertEqual(harness.input.activeInlineTrigger?.trigger.query, "sp")

        // Peer inserts "Hey " before the session anchor -> anchor shifts 0 -> 4 cleanly.
        let encodedDelta = await harness.session.replicaDoc { try? YStateEncoder.encodeStateAsUpdate($0) }
        let fullDelta = try XCTUnwrap(encodedDelta ?? nil)
        try peerDoc.applyUpdate(YUpdateDecoder.decode(fullDelta), origin: .remote)
        let peerEdit = try peerEngine.replaceText(block: "p", range: 0..<0, with: "Hey ")
        harness.session.replica?.mailbox.post(.integrate(peerEdit, reply: nil))
        await harness.settle()

        XCTAssertEqual(harness.input.activeInlineTrigger?.trigger.anchor, 4)
        XCTAssertEqual(harness.input.activeInlineTrigger?.trigger.query, "sp")

        yes(await harness.run { harness.input.commitHighlightedInlinePicker() })
        XCTAssertEqual(
            try block(harness.session, "p").runs,
            [InlineRun("Hey "), interlinkRun(docID)])
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 3)
        let writeFailed = await harness.engine { $0.nativeWriteFailed }
        XCTAssertEqual(writeFailed, false)
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: harness.session.surface.blocks, traits: harness.session.surface.traits,
            labels: harness.session.surface.labels, geometry: harness.session.surface.attachmentGeometry)
        XCTAssertTrue(harness.view.textStorage.isEqual(to: fresh))
    }

    func testSelectMentionRejectsUnpastableCandidateBeforeWritingToYjs() async throws {
        let source = SourceBox()
        let oversized = MentionCandidate(
            userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            fullName: String(repeating: "x", count: NativeInlineObject.maxLabelUTF16 + 200),
            shortName: nil, email: nil)
        let bidiBearing = MentionCandidate(
            userID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            fullName: "Ada\u{202E}Lovelace\nAdmin",
            shortName: nil, email: nil)
        source.mentionState = .loaded([oversized, bidiBearing])

        let harness = try await makeHarness([paragraph("p", "Hi @")])
        addTeardownBlock { await harness.close() }
        attach(harness, source: source)

        try caret(harness, "p", 4)
        XCTAssertNotNil(harness.input.inlinePicker)

        let insertedOversized = await harness.run { harness.input.selectMention(oversized) }
        XCTAssertFalse(insertedOversized)
        let insertedBidi = await harness.run { harness.input.selectMention(bidiBearing) }
        XCTAssertFalse(insertedBidi)
        XCTAssertEqual(try block(harness.session, "p").runs, [InlineRun("Hi @")])
        XCTAssertTrue(harness.log.commands.isEmpty)
    }

    func testUndoingPageLinkOrMentionPickDoesNotReopenPickerUntilOpenerIsCleared() async throws {
        let docID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let ada = MentionCandidate(
            userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            fullName: "Ada Lovelace", shortName: "Ada", email: "ada@example.com")
        let source = SourceBox()
        source.pageLinks = [makeDocument(id: docID, title: "Spec")]
        source.mentionState = .loaded([ada])

        // 1. Page-link pick + Undo keeps picker closed until `[[` is removed and retyped.
        let pageHarness = try await makeHarness([paragraph("p", "See ")])
        addTeardownBlock { await pageHarness.close() }
        attach(pageHarness, source: source)
        try caret(pageHarness, "p", 4)
        type(pageHarness, "[[sp")
        await pageHarness.settle()
        XCTAssertNotNil(pageHarness.input.inlinePicker)

        yes(await pageHarness.run { pageHarness.input.commitHighlightedInlinePicker() })
        XCTAssertNil(pageHarness.input.inlinePicker)

        yes(await pageHarness.run { pageHarness.input.undo() })
        XCTAssertEqual(try block(pageHarness.session, "p").runs, [InlineRun("See [[sp")])
        XCTAssertNil(pageHarness.input.inlinePicker, "Undoing a page-link pick must not reopen the picker")

        // Deleting the restored opener clears dismissal so typing `[[` reopens it.
        let end = try location(pageHarness.session, "p", 8)
        let start = try location(pageHarness.session, "p", 4)
        XCTAssertTrue(pageHarness.input.replace(range: NSRange(location: start, length: end - start), with: ""))
        await pageHarness.settle()
        type(pageHarness, "[[")
        await pageHarness.settle()
        XCTAssertNotNil(pageHarness.input.inlinePicker)

        // 2. Mention pick + Undo keeps picker closed as well.
        let mentionHarness = try await makeHarness([paragraph("m", "Hi ")])
        addTeardownBlock { await mentionHarness.close() }
        attach(mentionHarness, source: source)
        try caret(mentionHarness, "m", 3)
        type(mentionHarness, "@ada")
        await mentionHarness.settle()
        XCTAssertNotNil(mentionHarness.input.inlinePicker)

        yes(await mentionHarness.run { mentionHarness.input.commitHighlightedInlinePicker() })
        XCTAssertNil(mentionHarness.input.inlinePicker)

        yes(await mentionHarness.run { mentionHarness.input.undo() })
        XCTAssertEqual(try block(mentionHarness.session, "m").runs, [InlineRun("Hi @ada")])
        XCTAssertNil(mentionHarness.input.inlinePicker, "Undoing a mention pick must not reopen the picker")
    }
}
