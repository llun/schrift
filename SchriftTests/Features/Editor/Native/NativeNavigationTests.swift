import UIKit
import XCTest

@testable import Schrift

/// PR10b: outline, find and "continue reading" on the native editor, over
/// the classic rules and sheet. Jumps go through generation-safe
/// `NativeBlockHandle`s checked on the replica session, unfold what hides
/// their target and never change content or the selection. Real
/// `NativeTextView`s hosted in windows over restored durable replicas.
@MainActor
final class NativeNavigationTests: NativeEditingTestCase {
    private var defaults: UserDefaults!
    private let suite = "NativeNavigationTests.\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    @discardableResult
    private func host(_ view: NativeTextView, width: CGFloat = 390, height: CGFloat = 500) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return window
    }

    private func long(_ count: Int = 60, headingAt: Int? = 45) -> [BlockNoteBlock] {
        (0..<count).map { index in
            index == headingAt
                ? heading("h\(index)", "Section \(index)")
                : paragraph("p\(index)", "Paragraph \(index) with enough words to wrap onto two lines here.")
        }
    }

    private func id(_ navigation: NativeDocumentNavigation, _ blockID: String) throws -> UUID {
        try XCTUnwrap(navigation.entries.first { $0.value.blockID == blockID }?.key, "\(blockID) is listed")
    }

    /// Content, journal and selection: what a jump must never change.
    private func untouched(_ harness: Harness) async throws -> String {
        let vector = try await unwrapped(
            harness.session.replicaDoc { YStateEncoder.encodeStateVector($0).base64EncodedString() })
        return "\(vector)|\(harness.log.commands.count)|\(texts(harness.session))|\(harness.view.selectedRange)"
    }

    // MARK: - Outline and find

    /// Native headings are outlined by level and their literal text: `**` and
    /// `#` are characters here, not markdown, and find matches them.
    func testOutlineAndFindReadNativeHeadingsLiterally() async throws {
        let harness = try await makeHarness([
            heading("h1", "Plan **draft** #1"), paragraph("p1", "Body with a needle"), heading("h2", "Next"),
            paragraph("p2", "Another needle"),
        ])
        let navigation = harness.session.navigation
        await navigation.refresh()
        let matches = findMatchingBlockIDs(in: navigation.blocks, query: "needle")
        let outline = buildOutline(blocks: navigation.blocks, matchingBlockIDs: matches)
        XCTAssertEqual(outline.map(\.title), ["Plan **draft** #1", "Next"])
        XCTAssertEqual(outline.map(\.matchCount), [1, 1])
        XCTAssertEqual(findMatchingBlockIDs(in: navigation.blocks, query: "**draft").first, try id(navigation, "h1"))
        await harness.close()
    }

    /// A heading jump puts it at the top of the view; content, the journal
    /// and the selection stay as they were.
    func testHeadingJumpScrollsWithoutChangingContentOrSelection() async throws {
        let harness = try await makeHarness(long())
        host(harness.view)
        setSelection(harness, NSRange(location: try location(harness.session, "p2", 3), length: 4))
        await harness.settle()
        let navigation = harness.session.navigation
        await navigation.refresh()
        let before = try await untouched(harness)
        let jumped = await navigation.jump(to: .block(try id(navigation, "h45")))
        XCTAssertTrue(jumped)
        XCTAssertEqual(harness.view.topVisibleBlockID(), "h45")
        await harness.settle()
        let after = try await untouched(harness)
        XCTAssertEqual(after, before)
        let back = await navigation.jump(to: .header)
        XCTAssertTrue(back)
        XCTAssertEqual(harness.view.topVisibleBlockID(), "p0")
        await harness.close()
    }

    /// A find match inside a collapsed toggle unfolds it (view state only)
    /// and lands there.
    func testFindJumpIntoFoldedContentRevealsIt() async throws {
        var blocks = long(40, headingAt: nil)
        blocks.insert(
            BlockNoteBlock(
                node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Folded")], id: "t",
                children: [paragraph("c1", "The hidden needle")]), at: 30)
        let harness = try await makeHarness(blocks)
        host(harness.view)
        XCTAssertTrue(harness.session.surface.isHidden(blockID: "c1"))
        let navigation = harness.session.navigation
        await navigation.refresh()
        let before = try await untouched(harness)
        let match = try XCTUnwrap(findMatchingBlockIDs(in: navigation.blocks, query: "hidden needle").first)
        let jumped = await navigation.jump(to: .block(match))
        XCTAssertTrue(jumped)
        XCTAssertTrue(harness.session.surface.isExpanded("t"))
        XCTAssertFalse(harness.session.surface.isHidden(blockID: "c1"))
        XCTAssertEqual(harness.view.topVisibleBlockID(), "c1")
        let after = try await untouched(harness)
        XCTAssertEqual(after, before, "unfolding is view state")
        await harness.close()
    }

    /// A handle read before its block was replaced (a move re-creates the
    /// container) does not jump to the new one; a fresh read does.
    func testAStaleHandleDoesNotJump() async throws {
        let harness = try await makeHarness(long())
        host(harness.view)
        let navigation = harness.session.navigation
        await navigation.refresh()
        let stale = try id(navigation, "h45")
        setSelection(harness, NSRange(location: try location(harness.session, "h45", 1), length: 0))
        let moved = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(moved)
        let jumpedStale = await navigation.jump(to: .block(stale))
        XCTAssertFalse(jumpedStale, "the moved heading is another item now")
        await navigation.refresh()
        XCTAssertEqual(try id(navigation, "h45"), stale, "the sheet's id survives a refresh")
        let jumped = await navigation.jump(to: .block(stale))
        XCTAssertTrue(jumped)
        XCTAssertEqual(harness.view.topVisibleBlockID(), "h45")
        await harness.close()
    }

    /// The outline follows edits: a refresh after a delivered patch, debounced.
    func testTheOutlineFollowsEdits() async throws {
        let harness = try await makeHarness([heading("h1", "Title"), paragraph("p1", "Body")])
        let navigation = harness.session.navigation
        await navigation.refresh()
        navigation.isOutlinePresented = true
        setSelection(harness, NSRange(location: try location(harness.session, "h1", 5), length: 0))
        let typed = await harness.run {
            harness.input.typeKey("!")
            return true
        }
        XCTAssertTrue(typed)
        await waitUntil { buildOutline(blocks: navigation.blocks).map(\.title) == ["Title!"] }
        await harness.close()
    }

    // MARK: - Continue reading

    /// Leaving at a block and reopening lands there again, at phone and
    /// tablet widths; "Back to top" is offered and goes back.
    func testReadingPositionRestoresAtPhoneAndTabletWidths() async throws {
        for width: CGFloat in [390, 1_024] {
            let documentID = UUID()
            let store = ReadingPositionStore(userDefaults: defaults)
            let first = try await makeHarness(long())
            host(first.view, width: width)
            let leaving = first.session.navigation
            leaving.enableReadingPosition(store: store, serverOrigin: "https://example.test", documentID: documentID)
            await leaving.refresh()
            leaving.restore()
            let jumped = await leaving.jump(to: .block(try id(leaving, "p40")))
            XCTAssertTrue(jumped)
            leaving.persist()
            XCTAssertNotNil(store.position(serverOrigin: "https://example.test", documentID: documentID))
            await first.close()

            let second = try await makeHarness(long())
            host(second.view, width: width)
            let reopened = second.session.navigation
            reopened.voiceOverEnabled = { false }
            reopened.enableReadingPosition(store: store, serverOrigin: "https://example.test", documentID: documentID)
            await reopened.refresh()
            reopened.restore()
            await waitUntil { second.view.topVisibleBlockID() == "p40" }
            XCTAssertEqual(reopened.reading?.offersBackToTop, true, "width \(width)")
            reopened.backToTop()
            second.view.layoutIfNeeded()
            XCTAssertEqual(second.view.topVisibleBlockID(), "p0")
            XCTAssertEqual(reopened.reading?.offersBackToTop, false)
            await second.close()
        }
    }

    /// Back at the top, leaving forgets the position.
    func testLeavingAtTheTopForgetsThePosition() async throws {
        let documentID = UUID()
        let store = ReadingPositionStore(userDefaults: defaults)
        store.save(
            blockID: UUID(), fingerprint: "x", blockIndex: 30, serverOrigin: "https://example.test",
            documentID: documentID)
        let harness = try await makeHarness(long())
        host(harness.view)
        let navigation = harness.session.navigation
        navigation.enableReadingPosition(store: store, serverOrigin: "https://example.test", documentID: documentID)
        await navigation.refresh()
        navigation.restore()
        navigation.persist()
        XCTAssertNil(store.position(serverOrigin: "https://example.test", documentID: documentID))
        await harness.close()
    }

    // MARK: - VoiceOver over collaborators

    /// Each caret and badge names the peer and what it is; the overlay keeps
    /// them together for VoiceOver instead of between the text's controls.
    func testPeerCaretsAndBadgesHaveVoiceOverLabelsAndAreGrouped() async throws {
        let harness = try await makeHarness([
            paragraph("intro", "Intro paragraph"),
            BlockNoteBlock(
                node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Title")], id: "t",
                children: [paragraph("c1", "Hidden child")]),
        ])
        host(harness.view)
        let awareness = NativeAwarenessController(replica: try XCTUnwrap(harness.session.replica))
        harness.session.showAwareness(awareness)
        func position(_ block: String, _ offset: Int) async throws -> YRelativePositionJSON {
            try await unwrapped(harness.engine { $0.awarenessPosition(EditorPosition(blockID: block, offset: offset)) })
        }
        func entry(_ id: UInt, _ name: String, _ anchor: YRelativePositionJSON, _ head: YRelativePositionJSON)
            -> AwarenessEntry
        {
            AwarenessEntry(
                clientID: id, clock: 1,
                stateJSON: LocalAwarenessState(
                    name: name, color: "#000000", cursor: AwarenessCursor(anchor: anchor, head: head)
                ).json(wireProtocol: .yWebSocket))
        }
        let caret = try await position("intro", 2)
        let from = try await position("intro", 6)
        let folded = try await position("c1", 2)
        awareness.receive([
            entry(7, "Ada", caret, caret), entry(8, "Bo", from, caret), entry(9, "Cy", folded, folded),
        ])
        await waitUntil { awareness.places.count == 3 }
        harness.view.layoutIfNeeded()
        let overlay = harness.view.cursorOverlay
        let labels = Dictionary(
            uniqueKeysWithValues: overlay.subviews.compactMap { view in
                view.accessibilityIdentifier.map { ($0, view.accessibilityLabel ?? "") }
            })
        XCTAssertEqual(labels["nativeEditor.peerCursor.7"], "Ada, cursor")
        XCTAssertEqual(labels["nativeEditor.peerCursor.8"], "Bo, selection")
        XCTAssertEqual(labels["nativeEditor.peerBadge.9"], "Cy, collaborator in folded content")
        XCTAssertTrue(overlay.shouldGroupAccessibilityChildren)
        XCTAssertFalse(overlay.isAccessibilityElement, "the overlay itself never covers the text")
        await harness.close()
    }

    // MARK: - Review fixes (PR #277)

    private func paragraphText(_ index: Int) -> String {
        "Paragraph \(index) with enough words to wrap onto two lines here."
    }

    private func savePosition(_ store: ReadingPositionStore, at index: Int, documentID: UUID) {
        store.save(
            blockID: UUID(),
            fingerprint: readingPositionFingerprint(of: EditorBlock(kind: .unknown, text: paragraphText(index))),
            blockIndex: index, serverOrigin: "https://example.test", documentID: documentID)
    }

    /// With the sheet closed, typing projects nothing for navigation.
    func testTypingWithTheSheetClosedReprojectsNothing() async throws {
        let harness = try await makeHarness([heading("h1", "Title"), paragraph("p1", "Body")])
        let navigation = harness.session.navigation
        await navigation.refresh()
        setSelection(harness, NSRange(location: try location(harness.session, "p1", 4), length: 0))
        for _ in 0..<5 {
            _ = await harness.run {
                harness.input.typeKey("x")
                return true
            }
        }
        await waitAndConfirmNever(timeout: 1) { navigation.refreshCount > 1 }
        await harness.close()
    }

    /// Leaving records the text shown now, not the outline's older copy.
    func testPersistReadsTheSurfaceNotAStaleOutline() async throws {
        let documentID = UUID()
        let store = ReadingPositionStore(userDefaults: defaults)
        let harness = try await makeHarness(long())
        host(harness.view)
        let navigation = harness.session.navigation
        navigation.enableReadingPosition(store: store, serverOrigin: "https://example.test", documentID: documentID)
        await navigation.refresh()
        navigation.restore()
        setSelection(harness, NSRange(location: try location(harness.session, "p40", 0), length: 0))
        let typed = await harness.run {
            harness.input.typeKey("Z")
            return true
        }
        XCTAssertTrue(typed)
        let jumped = await navigation.jump(to: .block(try id(navigation, "p40")))
        XCTAssertTrue(jumped)
        navigation.persist()
        let saved = try XCTUnwrap(store.position(serverOrigin: "https://example.test", documentID: documentID))
        XCTAssertEqual(
            saved.fingerprint,
            readingPositionFingerprint(of: EditorBlock(kind: .unknown, text: "Z" + paragraphText(40))))
        await harness.close()
    }

    /// A reader who tapped to type before the restore was decided keeps
    /// their place: no jump, no offer.
    func testRestoreNeverMovesAReaderWhoIsTyping() async throws {
        let documentID = UUID()
        let store = ReadingPositionStore(userDefaults: defaults)
        savePosition(store, at: 40, documentID: documentID)
        let harness = try await makeHarness(long())
        let window = host(harness.view)
        window.makeKeyAndVisible()
        XCTAssertTrue(harness.view.becomeFirstResponder())
        let navigation = harness.session.navigation
        navigation.enableReadingPosition(store: store, serverOrigin: "https://example.test", documentID: documentID)
        await navigation.refresh()
        navigation.restore()
        await waitAndConfirmNever { harness.view.topVisibleBlockID() != "p0" }
        XCTAssertEqual(navigation.reading?.offersBackToTop, false)
        await harness.close()
    }

    /// A restore decided before the view had a size is dropped when the
    /// reader starts typing before it can scroll.
    func testAPendingRestoreIsDroppedOnceTheReaderTypes() async throws {
        let documentID = UUID()
        let store = ReadingPositionStore(userDefaults: defaults)
        savePosition(store, at: 40, documentID: documentID)
        let harness = try await makeHarness(long())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.addSubview(harness.view)
        window.makeKeyAndVisible()
        harness.view.frame = CGRect(x: 0, y: 0, width: 390, height: 0)
        let navigation = harness.session.navigation
        navigation.enableReadingPosition(store: store, serverOrigin: "https://example.test", documentID: documentID)
        await navigation.refresh()
        navigation.restore()
        XCTAssertTrue(navigation.reading?.hasPendingRestoreScroll == true, "decided, waiting for a size")
        XCTAssertTrue(harness.view.becomeFirstResponder())
        harness.view.frame = window.bounds
        harness.view.layoutIfNeeded()
        await waitAndConfirmNever { harness.view.topVisibleBlockID() != "p0" }
        XCTAssertEqual(navigation.reading?.offersBackToTop, false)
        await harness.close()
    }
}
