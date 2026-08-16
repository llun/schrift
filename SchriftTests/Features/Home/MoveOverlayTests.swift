import XCTest

@testable import Schrift

/// The race guard for a move made while a list fetch was in flight — and the property that
/// makes it safe: it retires on **fetch ordering**, never on what a fetch says.
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
        let overlay = applyMoveOverrides(recent: fetched, overrides: [:], generation: 1)
        XCTAssertEqual(overlay.recent, fetched)
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }

    /// The fetch was in flight when the move landed, so it still lists the document at the top
    /// level and must not be allowed to put the row back.
    func testAFetchThatPredatesAMoveUnderAParentCannotPutTheRowBack() {
        let row = document(id: documentID)
        let overlay = applyMoveOverrides(
            recent: [row, document(id: UUID(), title: "Other")],
            overrides: [documentID: MoveOverride(newParentID: parentID, row: row, generation: 3)],
            generation: 3)

        XCTAssertFalse(overlay.recent.contains { $0.id == documentID })
        XCTAssertTrue(overlay.confirmed.isEmpty, "this fetch could not have known")
    }

    func testAPromotionThatOutranTheFetchKeepsTheRowOnScreen() {
        let row = document(id: documentID)
        let overlay = applyMoveOverrides(
            recent: [document(id: UUID(), title: "Other")],
            overrides: [documentID: MoveOverride(newParentID: nil, row: row, generation: 3)],
            generation: 3)

        XCTAssertEqual(overlay.recent.first?.id, documentID, "inserted at the front")
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }

    /// **The rule that keeps this safe.** A fetch issued after the move has asked the server
    /// since, so whatever it returns is the truth — the override applies nothing and retires,
    /// whichever way the answer goes.
    func testAFetchIssuedAfterTheMoveSupersedesTheOverrideWhateverItSays() {
        let row = document(id: documentID)

        // The feed still lists a document we filed under a parent — which is the server's
        // answer to give, since Home's feed is fetched without a parent filter.
        let filed = applyMoveOverrides(
            recent: [row],
            overrides: [documentID: MoveOverride(newParentID: parentID, row: row, generation: 3)],
            generation: 4)
        XCTAssertEqual(filed.recent.map(\.id), [documentID], "believed, not filtered")
        XCTAssertEqual(filed.confirmed, [documentID])

        // …and the mirror: the feed does not list a document we promoted.
        let promoted = applyMoveOverrides(
            recent: [],
            overrides: [documentID: MoveOverride(newParentID: nil, row: row, generation: 3)],
            generation: 4)
        XCTAssertTrue(promoted.recent.isEmpty, "believed, not re-inserted")
        XCTAssertEqual(promoted.confirmed, [documentID])
    }

    /// **Why retirement may not key on content.** A promoted document that is then *deleted*
    /// looks exactly like "the fetch has not caught up", so a content-keyed override would go
    /// on re-inserting its own stored row — putting a deleted document back on Home, and into
    /// the recents cache, on every load for the life of the process. `deletedSinceLoad` cannot
    /// catch it, because the row comes from the override rather than from the fetch it filters.
    func testAPromotionOverrideCannotResurrectADeletedDocumentOnALaterFetch() {
        let row = document(id: documentID)
        let overrides = [documentID: MoveOverride(newParentID: nil, row: row, generation: 3)]

        // The document has since been deleted, so no later fetch will ever list it again.
        let overlay = applyMoveOverrides(recent: [], overrides: overrides, generation: 4)

        XCTAssertTrue(overlay.recent.isEmpty)
        XCTAssertEqual(overlay.confirmed, [documentID], "and the override is spent")
    }

    /// The same rule from the other side: a document filed under a parent and then moved back
    /// to the top level from the web must be believed, not vetoed for the life of the process.
    func testAnOverrideNeverVetoesADocumentsReturnToTheTopLevel() {
        let row = document(id: documentID)
        let overrides = [documentID: MoveOverride(newParentID: parentID, row: row, generation: 3)]

        let overlay = applyMoveOverrides(recent: [row], overrides: overrides, generation: 9)

        XCTAssertEqual(overlay.recent.map(\.id), [documentID])
        XCTAssertEqual(overlay.confirmed, [documentID])
    }

    /// A mover without a row (the Options sheet) has nothing to re-insert. The move still
    /// landed; the fetch simply catches up on its own.
    func testAPromotionWithNoRowInsertsNothingAndWaitsForTheFetch() {
        let overlay = applyMoveOverrides(
            recent: [],
            overrides: [documentID: MoveOverride(newParentID: nil, row: nil, generation: 3)],
            generation: 3)

        XCTAssertTrue(overlay.recent.isEmpty)
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }

    func testAPromotionIsNotDuplicatedWhenTheFetchAlreadyListsIt() {
        let row = document(id: documentID)
        let overlay = applyMoveOverrides(
            recent: [row],
            overrides: [documentID: MoveOverride(newParentID: nil, row: row, generation: 3)],
            generation: 3)

        XCTAssertEqual(overlay.recent.filter { $0.id == documentID }.count, 1)
    }
}
