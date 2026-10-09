import Observation
import XCTest

@testable import Schrift

@MainActor
final class DocumentPinIdentityTests: DocumentPinTestCase {
    func testOtherAccountAndServerNeitherSeeNorReplayIntent() async {
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let other = UUID()
        let log = stub(user: other)
        SignedInUserStore(userDefaults: defaults).remember(other)
        XCTAssertTrue(pins.resolve(pinned: [], recent: [row()], ownerUserID: other, fetchedAt: -1).pinned.isEmpty)
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        let otherServer = self.pins(origin: "https://other.example.org")
        XCTAssertTrue(
            otherServer.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1).pinned.isEmpty)
        await otherServer.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testServerAccountMustAgreeWithRememberedAccountBeforeReplay() async {
        let log = stub(user: UUID())
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testAccountChangeDuringReplayCannotSettleOrPublishOldIntent() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = stub(gate: gate)
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        let other = UUID()
        SignedInUserStore(userDefaults: defaults).remember(other)
        gate.open()
        await syncing.value
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        XCTAssertTrue(pins.resolve(pinned: [], recent: [row()], ownerUserID: other, fetchedAt: -1).pinned.isEmpty)
        XCTAssertTrue(DocumentCacheStore(userDefaults: defaults).loadPinnedDocuments().isEmpty)
    }

    func testUnknownIdentityRecoveryResumesPendingReplayOnLaunchAndReconnect() async {
        for reconnect in [false, true] {
            defaults.set(true, forKey: "schrift.workOffline")
            let (_, home, _, _, _) = environment()
            await home.toggleFavorite(row())
            SignedInUserStore(userDefaults: defaults).clear()
            let log = stub()
            defaults.set(false, forKey: "schrift.workOffline")
            if reconnect { await home.syncPendingDrafts() } else { await home.refreshSignedInUser() }
            XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/favorite/"), 1)
            XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        }
    }

    func testLearningIdentityInvalidatesProjectionEvenWhenReplayRemainsOffline() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        await home.toggleFavorite(row())
        SignedInUserStore(userDefaults: defaults).clear()
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        let revision = coordinator.pins.revision
        _ = stub(status: 503)
        defaults.set(false, forKey: "schrift.workOffline")
        await home.refreshSignedInUser()
        XCTAssertGreaterThan(coordinator.pins.revision, revision, "identity must invalidate observable list membership")
        XCTAssertEqual(home.pinnedDocuments.map(\.id), [id])
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testIdentityRecoveryInvalidatesEveryPreviouslyHiddenProjection() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, options, shared, search) = environment()
        home.fetchedRecentDocuments = [row()]
        shared.documents = [row()]
        search.results = [row()]
        await home.toggleFavorite(row())
        SignedInUserStore(userDefaults: defaults).clear()
        let changes = (0..<5).map { _ in Counter() }
        withObservationTracking {
            _ = home.pinnedDocuments
        } onChange: {
            _ = changes[0].next()
        }
        withObservationTracking {
            _ = options.isFavorite
        } onChange: {
            _ = changes[1].next()
        }
        withObservationTracking {
            _ = shared.documents
        } onChange: {
            _ = changes[2].next()
        }
        withObservationTracking {
            _ = search.results
        } onChange: {
            _ = changes[3].next()
        }
        withObservationTracking {
            _ = search.quickAccess
        } onChange: {
            _ = changes[4].next()
        }
        _ = stub(status: 503)
        defaults.set(false, forKey: "schrift.workOffline")
        await home.refreshSignedInUser()
        XCTAssertEqual(changes.map(\.current), [1, 1, 1, 1, 1])
        XCTAssertTrue(options.isFavorite)
        XCTAssertTrue(shared.documents[0].isFavorite)
        XCTAssertTrue(search.results[0].isFavorite)
        XCTAssertEqual(search.quickAccess.map(\.id), [id])
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testAccountChangeDuringVerificationPreservesRequestedReplayPass() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let other = UUID()
        let users = Counter()
        let log = RequestRecorder()
        let first = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        let next = Data("{\"id\":\"\(other.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "GET" {
                let isFirst = users.next() == 1
                return .init(
                    statusCode: 200, headers: [:], body: isFirst ? first : next,
                    error: nil, releasedBy: isFirst ? gate : nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        SignedInUserStore(userDefaults: defaults).remember(other)
        XCTAssertTrue(pins.queue(documentID: id, isPinned: true, row: row(), ownerUserID: other))
        await pins.sync(isBlocked: { _ in false })
        gate.open()
        await syncing.value
        XCTAssertEqual(log.count(ofMethod: "POST"), 1, "B replays without a further reconnect")
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().map(\.ownerUserID), [owner])
    }

    func testAccountChangeInsideCandidateLoopPreservesRequestedReplayPass() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let other = UUID()
        let users = Counter()
        let log = RequestRecorder()
        let first = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        let next = Data("{\"id\":\"\(other.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, headers: [:], body: users.next() == 1 ? first : next, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil, releasedBy: gate)
        }
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let secondID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        XCTAssertTrue(pins.queue(documentID: secondID, isPinned: true, row: nil, ownerUserID: owner))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        SignedInUserStore(userDefaults: defaults).remember(other)
        XCTAssertTrue(pins.queue(documentID: id, isPinned: true, row: row(), ownerUserID: other))
        await pins.sync(isBlocked: { _ in false })
        gate.open()
        await syncing.value
        XCTAssertEqual(log.count(ofMethod: "POST"), 2, "only A's in-flight request and B's new request")
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().allSatisfy { $0.ownerUserID == owner })
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 2)
    }
}
