import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelMoveTests: HomeViewModelTestCase {
    private static func movedDocument(id: UUID, title: String = "Moved", depth: Int = 1) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil, isFavorite: false,
            depth: depth, numchild: 0, path: String(repeating: "0", count: 4 * depth),
            createdAt: Date(), updatedAt: Date(), userRole: .owner, creator: nil)
    }

    /// A document filed under a parent has left the top level this screen lists.
    func testADocumentMovedUnderAParentLeavesTheRecentList() async {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let fixture = Self.paginatedFixture(id: id.uuidString, title: "Q3 Planning", isFavorite: false)
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: path.contains("favorite_list") ? empty : fixture, error: nil)
        }
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertTrue(viewModel.recentDocuments.contains { $0.id == id }, "precondition")

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(
                documentID: id, row: Self.movedDocument(id: id), newParentID: UUID()))

        XCTAssertFalse(viewModel.recentDocuments.contains { $0.id == id })
    }

    /// **The pinned row stays.** A favorite is a per-user annotation the server keeps across a
    /// move, so dropping it here would hide a document the next `favorite_list/` fetch returns
    /// — and hiding is the harmful direction.
    func testADocumentMovedUnderAParentKeepsItsPinnedRow() async {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let fixture = Self.paginatedFixture(id: id.uuidString, title: "Q3 Planning", isFavorite: true)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: fixture, error: nil) }
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertTrue(viewModel.pinnedDocuments.contains { $0.id == id }, "precondition")

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(
                documentID: id, row: Self.movedDocument(id: id), newParentID: UUID()))

        XCTAssertTrue(viewModel.pinnedDocuments.contains { $0.id == id })
    }

    /// A promotion puts the row on screen without waiting for a fetch — the same hand-back a
    /// migration makes, and it must survive `recentDocuments`' memo.
    func testAPromotedDocumentAppearsInRecentWithoutAFetch() async {
        MockURLProtocol.stubHandler = { [empty = Self.emptyFixture] _ in
            .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertTrue(viewModel.recentDocuments.isEmpty, "precondition")
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(
                documentID: id, row: Self.movedDocument(id: id), newParentID: nil))

        XCTAssertEqual(viewModel.recentDocuments.map(\.id), [id])
    }

    /// **Invariant 0b.** A list fetch issued before the move lands after it and still names the
    /// document at the top level; it must not put the row back — into the array or the cache.
    func testAListFetchInFlightWhenAMoveLandsCannotPutTheRowBack() async {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let fixture = Self.paginatedFixture(id: id.uuidString, title: "Q3 Planning", isFavorite: false)
        let empty = Self.emptyFixture
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: path.contains("favorite_list") ? empty : fixture, error: nil, releasedBy: gate)
        }
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)

        async let load: Void = viewModel.load()
        // The fetch is in the stub's hands but has not been answered yet — that is the window
        // the move has to land in for this to be the race at all.
        await waitUntil { MockURLProtocol.deferredDeliveryCount > 0 }
        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(
                documentID: id, row: Self.movedDocument(id: id), newParentID: UUID()))
        gate.open()
        await load

        XCTAssertFalse(
            viewModel.recentDocuments.contains { $0.id == id },
            "the fetch predates the move and cannot know")
        XCTAssertFalse(
            (cache.loadRecentDocuments() ?? []).contains { $0.id == id },
            "and it must not be written to the cache either")
    }

    /// The override protects fetches that were in flight when the move landed, and no others —
    /// so a later load is believed whatever it says, and a document moved back to the top
    /// level (from here or from the web) can be listed again.
    func testALaterLoadSupersedesTheMoveOverrideSoTheDocumentCanBeListedAgain() async {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let withDocument = Self.paginatedFixture(id: id.uuidString, title: "Q3 Planning", isFavorite: false)
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: path.contains("favorite_list") ? empty : withDocument, error: nil)
        }
        let viewModel = makeViewModel()

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(
                documentID: id, row: Self.movedDocument(id: id), newParentID: UUID()))
        await viewModel.load()

        XCTAssertTrue(
            viewModel.recentDocuments.contains { $0.id == id },
            "this fetch was issued after the move, so its answer is the truth")
    }

    /// Home's feed is unfiltered, so a promoted document may already be in it. A duplicate id
    /// in the `ForEach` is undefined row identity.
    func testAPromotionOfADocumentAlreadyOnHomeDoesNotDuplicateItsRow() async {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let fixture = Self.paginatedFixture(id: id.uuidString, title: "Q3 Planning", isFavorite: false)
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: path.contains("favorite_list") ? empty : fixture, error: nil)
        }
        let viewModel = makeViewModel()
        await viewModel.load()
        XCTAssertTrue(viewModel.recentDocuments.contains { $0.id == id }, "precondition")

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(documentID: id, row: Self.movedDocument(id: id), newParentID: nil))

        XCTAssertEqual(viewModel.recentDocuments.filter { $0.id == id }.count, 1)
    }

    /// **A promotion override carries its own stored row**, so it re-inserts from itself rather
    /// than from the fetch — which means `deletedSinceLoad`, which filters the *fetch*, cannot
    /// stop it putting a deleted document back on Home and into the recents cache.
    ///
    /// The generation bounds how long an override lives, so this needs the one window where it
    /// is still live: a fetch issued **before** the move, landing after both the move and the
    /// deletion. Dropping the override on the deletion is what closes it.
    func testADocumentDeletedAfterBeingPromotedIsNotResurrectedByItsMoveOverride() async {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let empty = Self.emptyFixture
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: empty, error: nil, releasedBy: gate)
        }
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)

        // This fetch predates both announcements, so the override below really does apply to it.
        async let load: Void = viewModel.load()
        await waitUntil { MockURLProtocol.deferredDeliveryCount > 0 }
        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(documentID: id, row: Self.movedDocument(id: id), newParentID: nil))
        XCTAssertTrue(viewModel.recentDocuments.contains { $0.id == id }, "precondition: on screen")
        viewModel.saveCoordinator.announceDocumentDeletedForTesting(id)
        gate.open()
        await load

        XCTAssertFalse(
            viewModel.recentDocuments.contains { $0.id == id },
            "the override must not re-insert a document that has since been deleted")
        XCTAssertFalse(
            (cache.loadRecentDocuments() ?? []).contains { $0.id == id },
            "and it must not be written back to the cache either")
    }
}
