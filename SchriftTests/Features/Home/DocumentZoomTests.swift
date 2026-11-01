import SwiftUI
import XCTest

@testable import Schrift

final class DocumentZoomTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Transition style

    func testRowOpenedDocumentZoomsFromItsRow() {
        let source = DocumentZoomSourceID(documentID: first, surface: .home)
        XCTAssertEqual(documentTransitionStyle(source: source, reduceMotion: false), .zoom(source))
    }

    func testPushWithoutARowUsesTheDefaultTransition() {
        XCTAssertEqual(documentTransitionStyle(source: nil, reduceMotion: false), .automatic)
    }

    func testReduceMotionFallsBackToTheDefaultTransition() {
        let source = DocumentZoomSourceID(documentID: first, surface: .shared)
        XCTAssertEqual(documentTransitionStyle(source: source, reduceMotion: true), .automatic)
        XCTAssertEqual(documentTransitionStyle(source: nil, reduceMotion: true), .automatic)
    }

    func testSurfacesGiveTheSameDocumentDistinctSourceIDs() {
        XCTAssertNotEqual(
            DocumentZoomSourceID(documentID: first, surface: .home),
            DocumentZoomSourceID(documentID: first, surface: .search))
    }

    // MARK: - Source style

    func testSourceShapeUsesTheDesignSystemRadius() {
        XCTAssertEqual(DocumentZoomSourceStyle.row.cornerRadius, DocsRadius.lg)
        XCTAssertEqual(DocumentZoomSourceStyle.card.cornerRadius, DocsRadius.lg)
    }

    // MARK: - Tracker

    func testTrackerReportsTheRowAnEditorWasOpenedFrom() {
        var tracker = DocumentZoomTracker()
        let source = DocumentZoomSourceID(documentID: first, surface: .home)
        tracker.push(source)
        XCTAssertEqual(tracker.source(for: first), source)
        XCTAssertNil(tracker.source(for: second))
    }

    func testTrackerHasNoSourceForPushesThatDidNotComeFromARow() {
        var tracker = DocumentZoomTracker()
        tracker.push(DocumentZoomSourceID(documentID: first, surface: .home))
        // A page chip inside the first editor opens the second.
        tracker.push(nil)
        XCTAssertNil(tracker.source(for: second))
        XCTAssertNotNil(tracker.source(for: first))
    }

    func testTrackerForgetsPoppedRoutes() {
        var tracker = DocumentZoomTracker()
        tracker.push(nil)  // Search
        tracker.push(DocumentZoomSourceID(documentID: first, surface: .search))
        tracker.trim(to: 1)
        XCTAssertNil(tracker.source(for: first))
        XCTAssertEqual(tracker.entries.count, 1)
        tracker.trim(to: 0)
        XCTAssertTrue(tracker.entries.isEmpty)
    }

    func testTrimIgnoresAnOversizedOrNegativeCount() {
        var tracker = DocumentZoomTracker()
        tracker.push(DocumentZoomSourceID(documentID: first, surface: .home))
        tracker.trim(to: 5)
        XCTAssertEqual(tracker.entries.count, 1)
        tracker.trim(to: -1)
        XCTAssertEqual(tracker.entries.count, 1)
    }

    func testReopeningFromARowAfterAPopZoomsAgain() {
        var tracker = DocumentZoomTracker()
        tracker.push(DocumentZoomSourceID(documentID: first, surface: .home))
        tracker.trim(to: 0)
        let search = DocumentZoomSourceID(documentID: first, surface: .search)
        tracker.push(nil)
        tracker.push(search)
        XCTAssertEqual(tracker.source(for: first), search)
    }
}
