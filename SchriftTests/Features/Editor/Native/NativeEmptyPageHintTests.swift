import Foundation
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
    func testHintHidesForContentMarkedTextAndReadOnlyPages() {
        XCTAssertTrue(NativeTextView.showsEmptyHint(storageLength: 0, hasMarkedText: false, canEdit: true))
        XCTAssertFalse(NativeTextView.showsEmptyHint(storageLength: 1, hasMarkedText: false, canEdit: true))
        XCTAssertFalse(NativeTextView.showsEmptyHint(storageLength: 0, hasMarkedText: true, canEdit: true))
        XCTAssertFalse(NativeTextView.showsEmptyHint(storageLength: 0, hasMarkedText: false, canEdit: false))
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
