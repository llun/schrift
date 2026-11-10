import UIKit
import XCTest

@testable import Schrift

/// IME composition through the engine: UIKit owns the marked range, the
/// replica sees exactly one durable write at commit, and storage reconciles to
/// the projection once. Every case is deterministic — synthetic
/// `setMarkedText`/`unmarkText` on a real `NativeTextView`, no sleeps.
@MainActor
final class NativeCompositionTests: DocumentEngineTestCase {
    private final class WriteLog: Sendable {
        private let state = Locked<(commands: [NativeEditCommand], blocks: [[BlockSnapshot]])>(([], []))
        var commands: [NativeEditCommand] { state.value.commands }
        var blocksAtPersist: [[BlockSnapshot]] { state.value.blocks }
        func record(_ command: NativeEditCommand, blocks: [BlockSnapshot]) {
            state.update {
                $0.commands.append(command)
                $0.blocks.append(blocks)
            }
        }
    }

    @MainActor
    private struct Harness {
        let session: NativeEditorSession
        let store: ReplicaStore
        let scope: ReplicaScope
        let log: WriteLog
        let directory: URL

        func settle(file: StaticString = #filePath, line: UInt = #line) async {
            let drained = await session.settle()
            XCTAssertTrue(drained, "the session settled", file: file, line: line)
        }

        func close() async {
            await session.close().value
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated private static func displayedBlocks(_ session: NativeEditorSession?) -> [BlockSnapshot] {
        guard let session else { return [] }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { session.surface.blocks } }
    }

    private func makeSession(_ blocks: [BlockNoteBlock] = seedBlocks()) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory)
        let state = BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)
        _ = try store.create(for: scope, checkpoint: state)
        let restored = try await NativeEditorSession.restore(store: store, scope: scope)
        let session = try XCTUnwrap(restored)
        let log = WriteLog()
        session.enableTyping(persist: { [weak session] command, update in
            log.record(command, blocks: Self.displayedBlocks(session))
            try store.append(
                update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        })
        return Harness(session: session, store: store, scope: scope, log: log, directory: directory)
    }

    private func assertMatches(
        _ session: NativeEditorSession, file: StaticString = #filePath, line: UInt = #line
    ) {
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels)
        XCTAssertTrue(session.textView.textStorage.isEqual(to: fresh), file: file, line: line)
        XCTAssertEqual(
            session.surface.rangeIndex.entries,
            ProjectionRangeIndex(blocks: session.surface.blocks, labels: session.surface.labels).entries,
            file: file, line: line)
    }

    /// The durable journal must project to exactly what the surface shows.
    private func assertDurableProjection(
        _ harness: Harness, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope), file: file, line: line)
        let replica = YDoc(clientID: 99)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates {
            try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        }
        XCTAssertEqual(harness.session.surface.blocks, projection(replica), file: file, line: line)
    }

    private func caret(_ session: NativeEditorSession, _ blockID: String, _ offset: Int) throws -> Int {
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: blockID))
        return entry.textRange.location + offset
    }

    private func text(_ session: NativeEditorSession, _ blockID: String) throws -> String {
        let position = try XCTUnwrap(session.surface.rangeIndex.position(for: blockID))
        return session.surface.blocks[position].runs.map(\.text).joined()
    }

    private func compose(
        _ session: NativeEditorSession, marked: [String], at location: Int, length: Int = 0
    ) async {
        session.textView.selectedRange = NSRange(location: location, length: length)
        for text in marked {
            session.textView.setMarkedText(
                text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        }
        await session.settle()
    }

    // MARK: - Insertion

    func testJapaneseInsertionAtStartMiddleAndEndCommitsOnce() async throws {
        let cases: [(offset: Int, expected: String)] = [
            (0, "日本First paragraph."),
            (6, "First 日本paragraph."),
            (16, "First paragraph.日本"),
        ]
        for (offset, expected) in cases {
            let harness = try await makeSession()
            addTeardownBlock { await harness.close() }
            let session = harness.session
            let location = try caret(session, Self.firstID, offset)
            await compose(session, marked: ["にほん", "日本"], at: location)

            XCTAssertNotNil(session.textView.markedTextRange, "UIKit owns the marked range")
            XCTAssertEqual(harness.log.commands.count, 0, "provisional text is never a write")
            let rev0 = await session.engine { $0.revision }
            XCTAssertEqual(rev0, 0)
            XCTAssertTrue(session.textView.textStorage.string.contains("日本"))

            session.textView.unmarkText()
            await harness.settle()

            XCTAssertNil(session.textView.markedTextRange)
            XCTAssertEqual(harness.log.commands.count, 1, "exactly one committed write")
            XCTAssertEqual(try text(session, Self.firstID), expected)
            let rev1 = await session.engine { $0.revision }
            XCTAssertEqual(rev1, 1)
            assertMatches(session)
            try assertDurableProjection(harness)
            XCTAssertEqual(try XCTUnwrap(harness.store.restore(for: harness.scope)).updates.count, 1)
            await harness.close()
        }
    }

    func testReplacingSelectedTextCommitsTheReplacementOnce() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let location = try caret(session, Self.firstID, 0)
        await compose(session, marked: ["さいしょ", "最初"], at: location, length: 5)

        XCTAssertEqual(harness.log.commands.count, 0)
        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(try text(session, Self.firstID), "最初 paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testCommitIsDurableBeforePublication() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let before = session.surface.blocks
        await compose(session, marked: ["日本"], at: try caret(session, Self.firstID, 0))

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.blocksAtPersist.count, 1)
        XCTAssertEqual(harness.log.blocksAtPersist.first, before, "the rebuild waits for the journal")
        XCTAssertNotEqual(session.surface.blocks, before)
        assertMatches(session)
    }

    // MARK: - Affinity

    func testPeerInsertionsAtEitherBoundaryStayOutsideTheReplacedRange() async throws {
        // Start affinity follows an insertion at the start; end affinity stays
        // before one at the end. Both survive the replacement.
        let cases: [(range: Range<Int>, insertAt: Int, inserted: String, expected: String)] = [
            (6..<9, 6, "Z", "First Z日本agraph."),
            (6..<9, 9, "Z", "First 日本Zagraph."),
            // A collapsed composition keeps left affinity: a peer insertion at
            // the caret stays after the composed text.
            (6..<6, 6, "Z", "First 日本Zparagraph."),
        ]
        for testCase in cases {
            let harness = try await makeSession()
            addTeardownBlock { await harness.close() }
            let session = harness.session
            let peer = try makeDoc(clientID: 2)
            defer { peer.destroy() }
            let peerSurface = HeadlessSurface(blocks: projection(peer))
            let peerEngine = DocumentEngine(doc: peer, surface: peerSurface)

            let location = try caret(session, Self.firstID, testCase.range.lowerBound)
            await compose(
                session, marked: ["日本"], at: location, length: testCase.range.count)
            try await session.integrateServerState(
                try peerEngine.replaceText(
                    block: Self.firstID, range: testCase.insertAt..<testCase.insertAt, with: testCase.inserted))
            XCTAssertEqual(harness.log.commands.count, 0)

            session.textView.unmarkText()
            await harness.settle()

            XCTAssertEqual(harness.log.commands.count, 1)
            XCTAssertEqual(try text(session, Self.firstID), testCase.expected)
            assertMatches(session)
            try assertDurableProjection(harness)
            await harness.close()
        }
    }

    // MARK: - Peer edits during composition

    func testPeerEditsBeforeInsideAndAfterTheMarkedRangeInTheSameBlock() async throws {
        let cases: [(insertAt: Int, inserted: String, expected: String)] = [
            (0, "A ", "A First 日本agraph."),
            (7, "X", "First 日本agraph."),
            (16, "!", "First 日本agraph.!"),
        ]
        for testCase in cases {
            let harness = try await makeSession()
            addTeardownBlock { await harness.close() }
            let session = harness.session
            let peer = try makeDoc(clientID: 2)
            defer { peer.destroy() }
            let peerEngine = DocumentEngine(doc: peer, surface: HeadlessSurface(blocks: projection(peer)))

            await compose(session, marked: ["日本"], at: try caret(session, Self.firstID, 6), length: 3)
            let displayed = session.textView.textStorage.string
            try await session.integrateServerState(
                try peerEngine.replaceText(
                    block: Self.firstID, range: testCase.insertAt..<testCase.insertAt, with: testCase.inserted))

            XCTAssertEqual(
                session.textView.textStorage.string, displayed,
                "no programmatic storage edit while text is marked")
            XCTAssertNotNil(session.textView.markedTextRange)

            session.textView.unmarkText()
            await harness.settle()

            XCTAssertEqual(harness.log.commands.count, 1)
            XCTAssertEqual(try text(session, Self.firstID), testCase.expected)
            assertMatches(session)
            try assertDurableProjection(harness)
            await harness.close()
        }
    }

    func testPeerEditInAnotherBlockIsBufferedAndAppliedOnReconcile() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let peerEngine = DocumentEngine(doc: peer, surface: HeadlessSurface(blocks: projection(peer)))

        await compose(session, marked: ["に"], at: try caret(session, Self.firstID, 6))
        let displayed = session.textView.textStorage.string
        try await session.integrateServerState(
            try peerEngine.replaceText(block: Self.thirdID, range: 0..<0, with: "Peer "))

        XCTAssertEqual(session.textView.textStorage.string, displayed)
        XCTAssertEqual(try text(session, Self.thirdID), "Third paragraph.", "the other block waits too")

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(try text(session, Self.firstID), "First にparagraph.")
        XCTAssertEqual(try text(session, Self.thirdID), "Peer Third paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    // MARK: - Cancel and loss

    func testCancelWritesNothingAndReconciles() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["にほん"], at: try caret(session, Self.firstID, 6))
        let before = await session.engine { $0.nativeSnapshot(for: Self.firstID) }

        session.textView.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        await harness.settle()

        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertEqual(harness.log.commands.count, 0)
        let rev = await session.engine { $0.revision }
        XCTAssertEqual(rev, 0)
        XCTAssertEqual(try text(session, Self.firstID), "First paragraph.")
        let after = await session.engine { $0.nativeSnapshot(for: Self.firstID) }
        XCTAssertEqual(after, before)
        assertMatches(session)
        let car = try caret(session, Self.firstID, 6)
        XCTAssertEqual(
            session.textView.selectedRange, NSRange(location: car, length: 0))
    }

    func testFocusLossWithoutUnmarkWritesNothingAndKeepsTheTextForRecovery() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["に"], at: try caret(session, Self.firstID, 0))

        session.input?.textViewDidEndEditing(session.textView)
        await harness.settle()

        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertEqual(harness.log.commands.count, 0)
        XCTAssertEqual(try text(session, Self.firstID), "First paragraph.")
        XCTAssertEqual(session.input?.composition.pendingRecoveries.map(\.text), ["に"])
        assertMatches(session)
    }

    // MARK: - Orphaned target

    func testTargetDeletedDuringCompositionKeepsTextAndWritesNowhere() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let peerEngine = DocumentEngine(doc: peer, surface: HeadlessSurface(blocks: projection(peer)))

        await compose(session, marked: ["にほん"], at: try caret(session, Self.secondID, 6))
        try await session.integrateServerState(try peerEngine.joinBlocks(block: Self.secondID))

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 0, "a deleted target never redirects the commit")
        let pending = try XCTUnwrap(session.input?.composition.pendingRecoveries)
        XCTAssertEqual(pending.map(\.text), ["にほん"], "the text is kept, never written")
        XCTAssertEqual(pending.map(\.state), [.orphaned])
        XCTAssertFalse(session.surface.blocks.contains { $0.runs.map(\.text).joined().contains("にほん") })
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    // MARK: - Unsupported compositions

    func testMultiBlockSelectionKeepsTheReadOnlyRefusal() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let start = try caret(session, Self.firstID, 10)
        let end = try caret(session, Self.secondID, 5)
        session.textView.selectedRange = NSRange(location: start, length: end - start)
        let original = session.textView.textStorage.string

        session.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        await harness.settle()

        XCTAssertEqual(session.input?.noticeKey, .native_editor_marked_unavailable)
        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(harness.log.commands.count, 0)
    }

    func testOpaqueTargetKeepsTheReadOnlyRefusal() async throws {
        let harness = try await makeSession([
            BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Body")], id: Self.firstID),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.textView.selectedRange = NSRange(location: 0, length: 0)

        session.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        await harness.settle()

        XCTAssertEqual(session.input?.noticeKey, .native_editor_marked_unavailable)
        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertEqual(harness.log.commands.count, 0)
    }

    // MARK: - Restart and presentation

    func testRestartAfterCommitWritesOncePerComposition() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["あ"], at: try caret(session, Self.firstID, 0))
        session.textView.unmarkText()
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 1)

        await compose(session, marked: ["い"], at: try caret(session, Self.firstID, 1))
        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 2)
        XCTAssertEqual(try text(session, Self.firstID), "あいFirst paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testReentrantRestartKeepsDeferralContinuous() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let view = NativeTextView()
        let surface = NativeTextSurface(blocks: projection(doc), storage: view.textStorage)
        let wrapper = RestartingSurface(surface)
        let engine = DocumentEngine(doc: doc, surface: wrapper)
        wrapper.onFirstPatch = { try? engine.compositionBegan(blockID: Self.thirdID, at: 0) }

        try engine.compositionBegan(blockID: Self.firstID, at: 0)
        try engine.compositionCancelled()

        XCTAssertTrue(engine.isComposing, "the restart began inside the rebuild delivery")
        XCTAssertEqual(wrapper.deferrals, [true], "deferral stays continuous across the restart")

        try engine.compositionCommitted(text: "あ")

        XCTAssertFalse(engine.isComposing)
        XCTAssertEqual(wrapper.deferrals, [true, false])
        XCTAssertEqual(text(of: surface.blocks[2]), "あThird paragraph.")
        XCTAssertEqual(surface.blocks, projection(doc))
        XCTAssertTrue(
            view.textStorage.isEqual(
                to: AttributedDocumentProjection.attributedString(
                    blocks: surface.blocks, traits: surface.traits, labels: surface.labels)))
    }

    func testThemeChangeDuringCompositionIsDeferredUntilReconcile() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        // A character in the last block, away from the marked range.
        let probe = session.textView.textStorage.length - 2
        let originalFont = try XCTUnwrap(
            session.textView.textStorage.attribute(.font, at: probe, effectiveRange: nil) as? UIFont)
        await compose(session, marked: ["に"], at: try caret(session, Self.firstID, 0))

        session.surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .extraExtraLarge),
            labels: session.surface.labels)

        XCTAssertNotNil(session.textView.markedTextRange, "a restyle must not cancel marked text")
        XCTAssertEqual(
            session.textView.textStorage.attribute(.font, at: probe, effectiveRange: nil) as? UIFont, originalFont)

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(session.surface.traits.preferredContentSizeCategory, .extraExtraLarge)
        let restyled = try XCTUnwrap(
            session.textView.textStorage.attribute(.font, at: probe, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(restyled.pointSize, originalFont.pointSize, "the deferred restyle lands on reconcile")
        XCTAssertEqual(try text(session, Self.firstID), "にFirst paragraph.")
        assertMatches(session)
    }

    // MARK: - Other scripts and commit shapes

    func testChineseCandidateCommitThroughInsertTextWritesOnlyTheCandidate() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["n", "ni", "ni h", "ni hao"], at: try caret(session, Self.firstID, 6))
        XCTAssertEqual(harness.log.commands.count, 0)

        // Pinyin keyboards commit by inserting the chosen candidate over the marked text.
        session.textView.insertText("你好")
        await harness.settle()

        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertEqual(harness.log.commands.map(\.replacement), ["你好"])
        XCTAssertEqual(try text(session, Self.firstID), "First 你好paragraph.")
        let loc = try caret(session, Self.firstID, 8)
        XCTAssertEqual(
            session.textView.selectedRange, NSRange(location: loc, length: 0))
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testCandidateReplacingTheMarkedRangeCommitsOnceAndOtherRangesAreRefused() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["zhong", "zhongwen"], at: try caret(session, Self.firstID, 0))
        let view = session.textView
        let elsewhere = try XCTUnwrap(
            view.textRange(
                from: view.endOfDocument, to: view.endOfDocument))
        view.replace(elsewhere, withText: "x")
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 0, "stale offsets outside the marked text are refused")

        view.replace(try XCTUnwrap(view.markedTextRange), withText: "中文")
        await harness.settle()

        XCTAssertEqual(harness.log.commands.map(\.replacement), ["中文"])
        XCTAssertEqual(try text(session, Self.firstID), "中文First paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testKoreanSyllableCompositionCommitsOnce() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["ㅎ", "하", "한"], at: try caret(session, Self.thirdID, 16))

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.map(\.replacement), ["한"])
        XCTAssertEqual(try text(session, Self.thirdID), "Third paragraph.한")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testEmptyParagraphAcceptsAComposition() async throws {
        var blocks = Self.seedBlocks()
        blocks.insert(
            BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [], id: "empty"), at: 1)
        let harness = try await makeSession(blocks)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["にほん", "日本"], at: try caret(session, "empty", 0))

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(try text(session, "empty"), "日本")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testBackspaceEditsOnlyTheMarkedTextAndAnEmptiedCompositionCancels() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["にほん"], at: try caret(session, Self.firstID, 6))

        session.textView.deleteBackward()
        XCTAssertTrue(session.textView.textStorage.string.hasPrefix("First にほparagraph."))
        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.map(\.replacement), ["にほ"], "what UIKit displayed is committed")
        XCTAssertEqual(try text(session, Self.firstID), "First にほparagraph.")
        assertMatches(session)

        await compose(session, marked: ["あ"], at: try caret(session, Self.thirdID, 0))
        session.textView.deleteBackward()
        await harness.settle()

        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertFalse(session.input?.composition.isActive ?? true)
        XCTAssertEqual(harness.log.commands.count, 1, "an emptied composition writes nothing")
        XCTAssertEqual(try text(session, Self.thirdID), "Third paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testAttributedMarkedTextFromTheSystemKeyboardTakesTheSamePath() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.textView.selectedRange = NSRange(location: try caret(session, Self.firstID, 6), length: 0)
        // The system Japanese keyboard marks segmented, attributed text.
        for marked in ["n", "に", "にほ", "にほん"] {
            session.textView.setAttributedMarkedText(
                NSAttributedString(string: marked, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
                selectedRange: NSRange(location: marked.utf16.count, length: 0))
        }
        await harness.settle()
        XCTAssertNotNil(session.textView.markedTextRange)
        XCTAssertEqual(harness.log.commands.count, 0)

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.map(\.replacement), ["にほん"])
        XCTAssertEqual(try text(session, Self.firstID), "First にほんparagraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testAStorageChangeThatBypassedTheCommandPathIsRestored() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "stray")

        session.input?.textViewDidChange(session.textView)
        await harness.settle()

        XCTAssertEqual(session.input?.noticeKey, .native_editor_input_unavailable)
        XCTAssertEqual(harness.log.commands.count, 0)
        assertMatches(session)
    }

    func testBackspaceWithNoMarkedTextLeftCancelsInsteadOfThrowing() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        await compose(session, marked: ["に"], at: try caret(session, Self.firstID, 6))
        // UIKit can drop its marked range (dictation, a keyboard switch) while
        // the composition is still open; `rangeOfComposedCharacterSequence(at:)`
        // on the empty string would throw.
        session.textView.dropMarkedText()

        session.textView.deleteBackward()
        await harness.settle()

        XCTAssertFalse(session.input?.composition.isActive ?? true)
        XCTAssertEqual(harness.log.commands.count, 0)
        XCTAssertEqual(try text(session, Self.firstID), "First paragraph.")
        assertMatches(session)
    }

    func testDirectCharactersFromAComposingKeyboardAreJournaledNotReverted() async throws {
        // Space, a digit and the ideographic full stop arrive on a Japanese
        // keyboard without marked text: UIKit writes them itself after the
        // delegate allowed the keystroke.
        for character in [" ", "1", "。", "　"] {
            let harness = try await makeSession()
            addTeardownBlock { await harness.close() }
            let session = harness.session
            let input = try XCTUnwrap(session.input)
            input.inputLanguage = { "ja-JP" }
            let range = NSRange(location: try caret(session, Self.firstID, 6), length: 0)
            session.textView.selectedRange = range

            XCTAssertTrue(
                input.textView(
                    session.textView, shouldChangeTextInRanges: [NSValue(range: range)],
                    replacementText: character))
            session.textView.textStorage.replaceCharacters(in: range, with: character)
            input.textViewDidChange(session.textView)
            await harness.settle()

            XCTAssertNil(input.noticeKey, character)
            XCTAssertEqual(harness.log.commands.map(\.replacement), [character])
            XCTAssertEqual(try text(session, Self.firstID), "First \(character)paragraph.")
            XCTAssertEqual(session.textView.selectedRange, NSRange(location: range.location + 1, length: 0))
            assertMatches(session)
            try assertDurableProjection(harness)
            await harness.close()
        }
    }

    func testADirectKeystrokeOverAMultiBlockSelectionNeverCorruptsStorage() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let input = try XCTUnwrap(session.input)
        input.inputLanguage = { "ja-JP" }
        let start = try caret(session, Self.firstID, 10)
        let range = NSRange(location: start, length: try caret(session, Self.secondID, 5) - start)
        session.textView.selectedRange = range

        let allowed = input.textView(
            session.textView, shouldChangeTextInRanges: [NSValue(range: range)], replacementText: " ")
        if allowed {
            // What UIKit does once the delegate lets it write: across the separator.
            session.textView.textStorage.replaceCharacters(in: range, with: " ")
            input.textViewDidChange(session.textView)
        }
        await harness.settle()

        XCTAssertFalse(allowed, "UIKit is never allowed to write across a separator")
        // The keystroke is one range command over the selection (PR04b).
        XCTAssertEqual(harness.log.commands.count, 1)
        guard case .range(let range)? = harness.log.commands.first?.kind else {
            return XCTFail("a range command")
        }
        XCTAssertEqual(range.endBlockID, Self.secondID)
        XCTAssertNil(input.noticeKey)
        XCTAssertEqual(try text(session, Self.firstID), "First para d paragraph has bold words inside it.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testEndingEditingDropsAnUnusedDirectKeystrokeAllowance() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let input = try XCTUnwrap(session.input)
        input.inputLanguage = { "ja-JP" }
        let range = NSRange(location: try caret(session, Self.firstID, 6), length: 0)
        session.textView.selectedRange = range
        XCTAssertTrue(
            input.textView(session.textView, shouldChangeTextInRanges: [NSValue(range: range)], replacementText: " "))

        input.textViewDidEndEditing(session.textView)
        // A stale change after editing ended is not the keystroke that was allowed.
        session.textView.textStorage.replaceCharacters(in: range, with: " ")
        input.textViewDidChange(session.textView)
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 0)
        XCTAssertEqual(input.noticeKey, .native_editor_input_unavailable)
        assertMatches(session)
    }

    func testAnAllowedKeystrokeThatStartsMarkedTextStillCommitsOnce() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let input = try XCTUnwrap(session.input)
        input.inputLanguage = { "ja-JP" }
        let range = NSRange(location: try caret(session, Self.firstID, 6), length: 0)
        session.textView.selectedRange = range
        XCTAssertTrue(
            input.textView(session.textView, shouldChangeTextInRanges: [NSValue(range: range)], replacementText: "n"))

        await compose(session, marked: ["n", "に"], at: range.location)
        input.textViewDidChange(session.textView)
        session.textView.unmarkText()
        input.textViewDidChange(session.textView)
        await harness.settle()

        XCTAssertNil(input.noticeKey)
        XCTAssertEqual(harness.log.commands.map(\.replacement), ["に"])
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    // MARK: - Dictation

    func testDictationResultIsOneDurableCommand() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.textView.selectedRange = NSRange(location: try caret(session, Self.firstID, 6), length: 0)

        session.textView.insertDictationResult([DictatedPhrase("spoken ")])
        await harness.settle()

        XCTAssertEqual(harness.log.commands.map(\.replacement), ["spoken "])
        XCTAssertEqual(try text(session, Self.firstID), "First spoken paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    func testDictationResultOverItsMarkedHypothesisCommitsAndUnfreezes() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let peerEngine = DocumentEngine(doc: peer, surface: HeadlessSurface(blocks: projection(peer)))
        await compose(session, marked: ["おん"], at: try caret(session, Self.firstID, 0))

        session.textView.insertDictationResult([DictatedPhrase("音声")])
        await harness.settle()

        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertFalse(session.input?.composition.isActive ?? true)
        XCTAssertEqual(harness.log.commands.map(\.replacement), ["音声"])
        // The surface is no longer frozen: a peer edit lands immediately.
        try await session.integrateServerState(try peerEngine.replaceText(block: Self.thirdID, range: 0..<0, with: "P"))
        XCTAssertEqual(try text(session, Self.thirdID), "PThird paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    // MARK: - Suspended commands

    func testOffsetCommandsAndEngineInputAreSuspendedUntilReconciliation() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let input = try XCTUnwrap(session.input)
        await compose(session, marked: ["に"], at: try caret(session, Self.firstID, 0))
        let third = try caret(session, Self.thirdID, 0)

        XCTAssertFalse(input.replace(range: NSRange(location: third, length: 0), with: "x"), "unrelated block too")
        let error = await session.engine { engine -> DocumentEngineError? in
            do {
                try engine.replaceText(block: Self.firstID, range: 0..<0, with: "x")
                return nil
            } catch {
                return error as? DocumentEngineError
            }
        }
        XCTAssertEqual(error, .composingBlock)
        XCTAssertEqual(harness.log.commands.count, 0)

        session.textView.unmarkText()
        await harness.settle()
        XCTAssertTrue(
            input.replace(range: NSRange(location: try caret(session, Self.thirdID, 0), length: 0), with: "x"))
        await harness.settle()

        XCTAssertEqual(harness.log.commands.map(\.replacement), ["に", "x"])
        XCTAssertEqual(try text(session, Self.thirdID), "xThird paragraph.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }

    // MARK: - Structural peer change

    func testPeerSplitOfAnotherBlockDuringCompositionReconcilesOnce() async throws {
        let harness = try await makeSession()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let peerEngine = DocumentEngine(doc: peer, surface: HeadlessSurface(blocks: projection(peer)))

        await compose(session, marked: ["日本"], at: try caret(session, Self.secondID, 6))
        let displayed = session.textView.textStorage.string
        try await session.integrateServerState(
            try peerEngine.splitBlock(block: Self.thirdID, at: 5, newID: "b0000000-0000-4000-8000-000000000004"))
        XCTAssertEqual(session.textView.textStorage.string, displayed, "a structural patch waits too")
        XCTAssertEqual(session.surface.blocks.count, 3)

        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(session.surface.blocks.count, 4)
        XCTAssertEqual(try text(session, Self.secondID), "Second日本 paragraph has bold words inside it.")
        assertMatches(session)
        try assertDurableProjection(harness)
    }
}

@MainActor
private final class RestartingSurface: @preconcurrency EditorSurface {
    let surface: NativeTextSurface
    var onFirstPatch: (() -> Void)?
    private(set) var deferrals: [Bool] = []
    private var didRestart = false

    init(_ surface: NativeTextSurface) { self.surface = surface }

    func applyPatch(_ patch: BlockPatch) {
        surface.applyPatch(patch)
        guard !didRestart else { return }
        didRestart = true
        onFirstPatch?()
    }

    func setCompositionDeferred(_ deferred: Bool) {
        deferrals.append(deferred)
        surface.setCompositionDeferred(deferred)
    }
}

private final class DictatedPhrase: UIDictationPhrase {
    private let phrase: String
    init(_ phrase: String) {
        self.phrase = phrase
        super.init()
    }
    override var text: String { phrase }
}
