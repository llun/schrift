import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// A writable page with no blocks is not an empty state: it mounts the canvas
/// with the first line's hint, and only a page the user cannot edit shows the
/// "Empty document" card.
@MainActor
final class NativeEmptyPageHintTests: NativeEditingTestCase {
    private static let emptyUpdate = Data([0, 0])

    /// Mounts `view` in an active window so focus and layout are real, and
    /// returns a cleanup closure for `defer`.
    private func mountInWindow(_ view: NativeTextView) -> () -> Void {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return {
            view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
        }
    }

    func testWritableEmptyPageShowsTheCanvasInReadingAndEditingMode() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.setEditing(false)
        await harness.settle()
        XCTAssertTrue(session.surface.blocks.isEmpty)
        XCTAssertTrue(session.isWritable)

        let reading = NativeEditorView(
            session: session, title: "Empty", serverOrigin: "https://example.test", externalIsEditing: false)
        XCTAssertFalse(reading.showsEmptyState, "a writable empty page shows the canvas in reading mode")
        let editing = NativeEditorView(
            session: session, title: "Empty", serverOrigin: "https://example.test", externalIsEditing: true)
        XCTAssertFalse(editing.showsEmptyState, "a writable empty page shows the canvas in editing mode")
    }

    func testReadOnlyEmptyPageShowsTheCard() async throws {
        let session = try await NativeEditorSession.inspect(state: Self.emptyUpdate)
        addTeardownBlock { await session.close().value }
        XCTAssertNil(session.input)
        XCTAssertFalse(session.isWritable)
        XCTAssertTrue(session.surface.blocks.isEmpty)

        let view = NativeEditorView(
            session: session, title: "Empty", serverOrigin: "https://example.test", externalIsEditing: false)
        XCTAssertTrue(view.showsEmptyState, "a page the user cannot edit keeps the empty card")
    }

    func testHintShowsWithNoBlocksAndHidesOnceABlockExists() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.setEditing(false)
        await harness.settle()
        let view = session.textView
        let unmount = mountInWindow(view)
        defer { unmount() }

        XCTAssertTrue(view.showsEmptyHint)
        XCTAssertFalse(view.emptyHintLabel.isHidden)
        XCTAssertEqual(view.emptyHintLabel.frame.minY, view.textContainerInset.top, accuracy: 0.5)
        XCTAssertEqual(
            view.emptyHintLabel.frame.minX, view.textContainerInset.left + view.textContainer.lineFragmentPadding,
            accuracy: 0.5)
        XCTAssertEqual(view.accessibilityValue, "Type '/' for commands")

        // The seed writes the first paragraph: the hint goes with it.
        session.setEditing(true)
        session.requestBodyFocusWhenReady()
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.count, 1, "focusing the empty body seeds one paragraph")
        view.layoutIfNeeded()
        XCTAssertFalse(view.showsEmptyHint)
        XCTAssertTrue(view.emptyHintLabel.isHidden)
        XCTAssertNotEqual(view.accessibilityValue, "Type '/' for commands")
    }

    /// Marked text needs focus, and focus seeds a paragraph, so the clause is
    /// locked here rather than through a state the app cannot reach.
    func testHintHidesForContentMarkedTextReadOnlyPagesAndScopedSurfaces() {
        func shows(_ length: Int, marked: Bool = false, canEdit: Bool = true, root: Bool = true) -> Bool {
            NativeTextView.showsEmptyHint(
                storageLength: length, hasMarkedText: marked, canEdit: canEdit, isRootDocumentSurface: root)
        }
        XCTAssertTrue(shows(0))
        XCTAssertFalse(shows(1))
        XCTAssertFalse(shows(0, marked: true))
        XCTAssertFalse(shows(0, canEdit: false))
        XCTAssertFalse(shows(0, root: false), "a table, column or source surface never shows the hint")
    }

    /// The card's "Start writing" went with the card: VoiceOver gets it on the
    /// text view instead, since a double-tap on its centre hits the footer.
    func testVoiceOverCanStartWritingOnAWritableEmptyPage() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        harness.session.setEditing(false)
        await harness.settle()
        let view = harness.view
        let unmount = mountInWindow(view)
        defer { unmount() }
        var editRequests = 0
        view.onRequestEdit = { editRequests += 1 }

        let action = try XCTUnwrap(startWriting(view), "a writable empty page offers Start writing")
        XCTAssertTrue(action.actionHandler?(action) == true)
        XCTAssertEqual(editRequests, 1, "the action requests editing like a tap on the line")
    }

    func testStartWritingIsOnlyOfferedOnAnEmptyPageTheUserCanEdit() async throws {
        let harness = try await makeHarness([paragraph("p", "Text")])
        addTeardownBlock { await harness.close() }
        harness.session.setEditing(false)
        await harness.settle()
        harness.view.onRequestEdit = {}
        XCTAssertNil(startWriting(harness.view), "a page with content has no Start writing")

        let reader = try await NativeEditorSession.inspect(state: Self.emptyUpdate)
        addTeardownBlock { await reader.close().value }
        reader.textView.onRequestEdit = {}
        XCTAssertNil(startWriting(reader.textView), "a page the user cannot edit has no Start writing")
    }

    func testStartWritingIsLocalized() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let loc = LocalizationStore(userDefaults: defaults)
        loc.language = .german
        XCTAssertEqual(NativeEditorLabels.document(loc).startWriting, Strings_de.table[.editor_start_writing])
    }

    /// Only the root document seeds an empty paragraph, so a source, table or
    /// column surface is never marked as one (the predicate then hides the hint).
    func testOnlyTheRootDocumentSurfaceShowsTheHint() async throws {
        let math = BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [], id: "mx")
        let harness = try await makeHarness([paragraph("p", "Text"), math])
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.view.isRootDocumentSurface)
        let source = try unwrapped(await harness.session.openSource(.block(blockID: "mx")), "the source opens")
        addTeardownBlock { await source.close().value }
        XCTAssertFalse(source.textView.isRootDocumentSurface)

        let tables = try await makeHarness(
            state: try decoded(BlockNoteTableCaptures.fixtures.first { $0.name == "styled" }?.update))
        addTeardownBlock { await tables.close() }
        let table = try unwrapped(await tables.session.openTable("tbl"), "the table opens")
        addTeardownBlock { await table.close().value }
        XCTAssertFalse(table.textView.isRootDocumentSurface)

        let columns = try await makeHarness(
            state: try decoded(BlockNoteColumnCaptures.fixtures.first { $0.name == "two" }?.update))
        addTeardownBlock { await columns.close() }
        let column = try unwrapped(await columns.session.openColumn(group: "cl", column: "c1"), "the column opens")
        addTeardownBlock { await column.close().value }
        XCTAssertFalse(column.textView.isRootDocumentSurface)
    }

    /// A hint wrapped past the text's height (a narrow page, large Dynamic
    /// Type) pushes the footer down: the inset must still reach its bottom.
    func testTheFooterStaysReachableBelowAWrappedHint() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        harness.session.setEditing(false)
        await harness.settle()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let editor = NativeEditorView(
            session: harness.session, title: "Empty", serverOrigin: "https://example.test",
            showsStandaloneChrome: false, footerContent: { AnyView(Color.clear.frame(height: 120)) },
            externalIsEditing: false, onRequestEdit: {})
        let host = UIHostingController(rootView: editor.environment(LocalizationStore(userDefaults: defaults)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 120, height: 700))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let view = harness.view
        await waitUntil(timeout: 5) {
            host.view.layoutIfNeeded()
            return view.footerAccessoryView != nil && !view.emptyHintLabel.isHidden
        }
        let footer = try XCTUnwrap(view.footerAccessoryView)
        XCTAssertGreaterThan(view.emptyHintBottom, view.contentSize.height, "the narrow page wraps the hint")
        XCTAssertEqual(footer.frame.minY, view.emptyHintBottom, accuracy: 0.5, "the footer starts below the hint")
        XCTAssertGreaterThanOrEqual(
            view.contentSize.height + view.contentInset.bottom, footer.frame.maxY - 0.5,
            "the furthest scroll shows the footer's last line")
    }

    private func startWriting(_ view: NativeTextView) -> UIAccessibilityCustomAction? {
        view.accessibilityCustomActions?.first { $0.name == NativeEditorLabels().startWriting }
    }

    private func decoded(_ base64: String?) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(base64)))
    }

    func testHintFollowsTheTextDirection() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.setEditing(false)
        await harness.settle()
        let view = session.textView
        let unmount = mountInWindow(view)
        defer { unmount() }

        view.semanticContentAttribute = .forceRightToLeft
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(
            view.emptyHintLabel.frame.maxX,
            view.bounds.width - view.textContainerInset.right - view.textContainer.lineFragmentPadding,
            accuracy: 0.5)
    }
}
