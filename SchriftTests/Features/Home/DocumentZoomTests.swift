import SwiftUI
import XCTest

@testable import Schrift

final class DocumentZoomTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func route(_ id: UUID) -> DocumentEditorRoute {
        DocumentEditorRoute(
            document: Document(
                id: id, title: "Doc", excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
                linkRole: .reader, isFavorite: false, depth: 1, numchild: 0, path: "0001",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                userRole: nil, creator: nil))
    }

    // MARK: - Transition style

    func testPushedWithASourceZoomsFromItsRow() {
        let source = DocumentZoomSourceID(documentID: first, surface: .home)
        XCTAssertEqual(documentTransitionStyle(source: source), .zoom(source))
    }

    func testPushWithoutASourceUsesTheDefaultTransition() {
        XCTAssertEqual(documentTransitionStyle(source: nil), .automatic)
    }

    // MARK: - Push helper

    func testPushFromARowRecordsItsSource() {
        let push = documentPush(for: route(first), from: .shared, reduceMotion: false)
        XCTAssertEqual(push.route, route(first))
        XCTAssertEqual(push.zoomSource, DocumentZoomSourceID(documentID: first, surface: .shared))
    }

    func testPushNotFromARowRecordsNoSource() {
        // Page chips, "new document" and anything else without a row.
        XCTAssertNil(documentPush(for: route(second), from: nil, reduceMotion: false).zoomSource)
    }

    func testReduceMotionRecordsNoSourceAtPushTime() {
        let push = documentPush(for: route(first), from: .home, reduceMotion: true)
        XCTAssertNil(push.zoomSource)
        XCTAssertEqual(documentTransitionStyle(source: push.zoomSource), .automatic)
    }

    func testEachPushKeepsItsOwnDecisionWhenReduceMotionChanges() {
        let zoomed = documentPush(for: route(first), from: .home, reduceMotion: false)
        let plain = documentPush(for: route(second), from: .home, reduceMotion: true)
        // The first push is unaffected by the later one: the value on the path is fixed.
        XCTAssertNotNil(zoomed.zoomSource)
        XCTAssertNil(plain.zoomSource)
    }

    func testTheSameDocumentFromDifferentRowsIsADifferentPathElement() {
        XCTAssertNotEqual(
            documentPush(for: route(first), from: .home, reduceMotion: false),
            documentPush(for: route(first), from: .search, reduceMotion: false))
        XCTAssertNotEqual(
            documentPush(for: route(first), from: .home, reduceMotion: false),
            documentPush(for: route(first), from: .home, reduceMotion: true))
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
}
