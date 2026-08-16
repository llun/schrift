import XCTest

@testable import Schrift

/// The race guard for a move made while a list fetch was in flight, plus the property that
/// separates it from `deletedSinceLoad`: these overrides **retire**.
final class MoveOverlayTests: XCTestCase {
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let parentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    private func document(id: UUID, title: String = "Q3 Planning") -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil, isFavorite: false,
            depth: 1, numchild: 0, path: "0001", createdAt: Date(), updatedAt: Date(),
            userRole: .owner, creator: nil)
    }

    func testNoOverridesLeavesTheFetchExactlyAsItArrived() {
        let fetched = [document(id: documentID), document(id: UUID(), title: "Other")]
        let overlay = applyMoveOverrides(recent: fetched, overrides: [:])
        XCTAssertEqual(overlay.recent, fetched)
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }

    /// The fetch predates the move and still lists the document at the top level; the override
    /// holds the row back rather than letting it flicker home.
    func testAFetchThatPredatesAMoveUnderAParentCannotPutTheRowBack() {
        let row = document(id: documentID)
        let overlay = applyMoveOverrides(
            recent: [row, document(id: UUID(), title: "Other")],
            overrides: [documentID: MoveOverride(newParentID: parentID, row: row)])

        XCTAssertFalse(overlay.recent.contains { $0.id == documentID })
        XCTAssertTrue(overlay.confirmed.isEmpty, "the server has not agreed yet")
    }

    func testAFeedThatHasDroppedTheSubPageConfirmsTheOverride() {
        let overlay = applyMoveOverrides(
            recent: [document(id: UUID(), title: "Other")],
            overrides: [documentID: MoveOverride(newParentID: parentID, row: document(id: documentID))])

        XCTAssertEqual(overlay.confirmed, [documentID])
    }

    /// **The property that makes retirement necessary.** A permanent set would veto the
    /// document's return to the top level — from here or from the web — for the life of the
    /// process, which is exactly the failure `applyFavoriteOverrides` documents for pins.
    func testARetiredOverrideNoLongerFiltersTheRowSoAMoveBackCanRelist() {
        let row = document(id: documentID)
        let overrides = [documentID: MoveOverride(newParentID: parentID, row: row)]
        let first = applyMoveOverrides(recent: [], overrides: overrides)
        XCTAssertEqual(first.confirmed, [documentID], "precondition: the fetch agrees")

        // The caller retires what the fetch confirmed; a later fetch listing the document
        // again — because it was moved back — must be believed.
        let second = applyMoveOverrides(recent: [row], overrides: [:])
        XCTAssertEqual(second.recent.map(\.id), [documentID])
    }

    func testAPromotionThatOutranTheFetchKeepsTheRowOnScreen() {
        let row = document(id: documentID)
        let overlay = applyMoveOverrides(
            recent: [document(id: UUID(), title: "Other")],
            overrides: [documentID: MoveOverride(newParentID: nil, row: row)])

        XCTAssertEqual(overlay.recent.first?.id, documentID, "inserted at the front")
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }

    func testAFeedThatAlreadyListsThePromotedDocumentConfirmsTheOverride() {
        let row = document(id: documentID)
        let overlay = applyMoveOverrides(
            recent: [row], overrides: [documentID: MoveOverride(newParentID: nil, row: row)])

        XCTAssertEqual(overlay.recent.map(\.id), [documentID], "not duplicated")
        XCTAssertEqual(overlay.confirmed, [documentID])
    }

    /// A mover without a row (the Options sheet) has nothing to re-insert. The move still
    /// landed; the fetch simply catches up on its own.
    func testAPromotionWithNoRowInsertsNothingAndWaitsForTheFetch() {
        let overlay = applyMoveOverrides(
            recent: [], overrides: [documentID: MoveOverride(newParentID: nil, row: nil)])

        XCTAssertTrue(overlay.recent.isEmpty)
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }
}
