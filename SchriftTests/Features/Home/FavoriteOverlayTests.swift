import XCTest

@testable import Schrift

final class FavoriteOverlayTests: XCTestCase {
    private func document(_ id: UUID, isFavorite: Bool = false) -> Document {
        Document(
            id: id, title: "Doc", excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: isFavorite, depth: 1,
            numchild: 0, path: "0001", createdAt: Date(), updatedAt: Date(), userRole: nil,
            creator: nil)
    }

    private let a = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testNoOverridesIsTheIdentity() {
        let pinned = [document(a, isFavorite: true)]
        let recent = [document(b)]
        let overlay = applyFavoriteOverrides(pinned: pinned, recent: recent, overrides: [:])
        XCTAssertEqual(overlay.pinned, pinned)
        XCTAssertEqual(overlay.recent, recent)
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }

    /// A just-pinned document is simply **absent** from a `favorite_list/` issued before the
    /// POST, so flipping flags alone would leave the Pinned section without it.
    func testAPinIsInsertedIntoAPinnedListThatPredatesIt() {
        let overlay = applyFavoriteOverrides(
            pinned: [], recent: [document(a)], overrides: [a: true])
        XCTAssertEqual(overlay.pinned.map(\.id), [a])
        XCTAssertTrue(overlay.pinned[0].isFavorite)
        XCTAssertTrue(overlay.recent[0].isFavorite, "and the flag reaches the recents row too")
        XCTAssertTrue(overlay.confirmed.isEmpty, "the server has not caught up yet")
    }

    func testAnUnpinIsRemovedFromAPinnedListThatPredatesIt() {
        let overlay = applyFavoriteOverrides(
            pinned: [document(a, isFavorite: true)], recent: [document(a, isFavorite: true)],
            overrides: [a: false])
        XCTAssertTrue(overlay.pinned.isEmpty)
        XCTAssertFalse(overlay.recent[0].isFavorite)
    }

    /// **The property that makes this different from `deletedSinceLoad`.** Once the fetch
    /// agrees, the override has done its job and must be retired — kept, it would veto every
    /// later change made from another client for the life of the process.
    func testAnOverrideTheFetchAlreadyAgreesWithIsReportedAsConfirmed() {
        let overlay = applyFavoriteOverrides(
            pinned: [document(a, isFavorite: true)], recent: [document(a, isFavorite: true)],
            overrides: [a: true])
        XCTAssertEqual(overlay.confirmed, [a])
        XCTAssertEqual(overlay.pinned.map(\.id), [a], "and nothing is duplicated")
    }

    func testAnUnpinTheFetchAlreadyAgreesWithIsAlsoConfirmed() {
        let overlay = applyFavoriteOverrides(
            pinned: [], recent: [document(a)], overrides: [a: false])
        XCTAssertEqual(overlay.confirmed, [a])
    }

    /// Nothing to insert from: the document is in neither list. The next fetch brings it.
    func testAPinForADocumentAbsentFromBothListsInsertsNothing() {
        let overlay = applyFavoriteOverrides(pinned: [], recent: [], overrides: [a: true])
        XCTAssertTrue(overlay.pinned.isEmpty)
        XCTAssertTrue(overlay.confirmed.isEmpty)
    }

    func testSeveralOverridesAreAllApplied() {
        let overlay = applyFavoriteOverrides(
            pinned: [document(b, isFavorite: true)],
            recent: [document(a), document(b, isFavorite: true)],
            overrides: [a: true, b: false])
        XCTAssertEqual(overlay.pinned.map(\.id), [a])
        XCTAssertTrue(overlay.recent.first(where: { $0.id == a })!.isFavorite)
        XCTAssertFalse(overlay.recent.first(where: { $0.id == b })!.isFavorite)
    }

    func testApplyingTheFlagLeavesOtherRowsAlone() {
        let rows = [document(a), document(b)]
        let updated = applyingFavoriteFlag(rows, documentID: a, isFavorite: true)
        XCTAssertTrue(updated[0].isFavorite)
        XCTAssertFalse(updated[1].isFavorite)
    }
}
