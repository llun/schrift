import Observation
import XCTest

@testable import Schrift

@MainActor
final class DocumentPinStaleFetchTests: DocumentPinTestCase {
    private nonisolated static func page(_ rows: [Document]) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(rows)
        return Data(
            "{\"count\":\(rows.count),\"next\":null,\"previous\":null,\"results\":\(String(decoding: data, as: UTF8.self))}"
                .utf8)
    }

    func testAnAgreeingStaleFetchDoesNotConsumeUnsentIntent() {
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        _ = pins.resolve(
            pinned: [row(pinned: true)], recent: [row(pinned: true)], ownerUserID: owner, fetchedAt: pins.revision)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        XCTAssertEqual(
            pins.resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: pins.revision).pinned.map(\.id), [id])
    }

    func testOldFetchAfterSuccessIsOverlaidButFreshServerChangesAreAllowed() async {
        _ = stub()
        let pins = pins()
        let oldFetch = pins.revision
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(
            pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: oldFetch).pinned.map(\.id), [id])
        XCTAssertTrue(
            pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: pins.revision).pinned.isEmpty)
    }

    func testPendingPinSurvivesAnActualStaleHomeFetchAndAnAgreeingFetchCannotSettleIt() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        home.fetchedRecentDocuments = [row()]
        let oldPage = Self.page([row()])
        let empty = Self.page([])
        let log = RequestRecorder()
        let user = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") { return .init(statusCode: 200, headers: [:], body: user, error: nil) }
            if request.httpMethod == "POST" { return .init(statusCode: 503, headers: [:], body: Data(), error: nil) }
            return .init(
                statusCode: 200, headers: [:], body: url.contains("favorite") ? empty : oldPage, error: nil,
                releasedBy: url.contains("/documents/") ? gate : nil
            )
        }
        defaults.set(false, forKey: "schrift.workOffline")
        let loading = Task { await home.load() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 2 }
        let actions = DocumentActions(
            client: client(), saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults))
        _ = await actions.setFavorite(documentID: id, isFavorite: true, row: row(), isOffline: true)
        gate.open()
        await loading.value
        XCTAssertEqual(home.pinnedDocuments.map(\.id), [id])
        XCTAssertTrue(home.recentDocuments.isEmpty)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        XCTAssertFalse(home.isLoading)
        let agreeing = Self.page([row(pinned: true)])
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: agreeing, error: nil) }
        await home.load()
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testFreshMembershipIsIndependentOfRecentFlagsInBothDirections() async {
        for included in [true, false] {
            _ = stub()
            let pins = pins()
            XCTAssertTrue(queue(pins, pinned: true))
            await pins.sync(isBlocked: { _ in false })
            let revision = pins.revision
            let favorites = included ? [row(pinned: true)] : []
            let recent = [row(pinned: !included)]
            pins.didCacheFreshLists(pinned: favorites, recent: recent, ownerUserID: owner, fetchedAt: revision)
            let shown = pins.resolve(pinned: favorites, recent: recent, ownerUserID: owner, fetchedAt: revision)
            XCTAssertEqual(shown.pinned.map(\.id), included ? [id] : [])
            XCTAssertEqual(
                recentsExcludingPinned(recent: shown.recent, pinned: shown.pinned).map(\.id), included ? [] : [id])
            XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        }
    }

    func testAbsenceFromBothFirstPagesDoesNotUnpinOlderScreens() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        let revision = pins.revision
        pins.didCacheFreshLists(pinned: [], recent: [], ownerUserID: owner, fetchedAt: revision)
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        XCTAssertTrue(pins.resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: revision).pinned.isEmpty)
    }
}
