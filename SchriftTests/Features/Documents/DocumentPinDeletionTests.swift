import Observation
import XCTest

@testable import Schrift

@MainActor
final class DocumentPinDeletionTests: DocumentPinTestCase {
    func testDeletionHoldsPinReplayAndUndoReleasesIt() async {
        let log = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in true })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 1)
    }

    func testCompletedDeletionDropsIntentAndAnySettledOverlay() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertTrue(queue(pins, pinned: false))
        pins.remove(documentID: id)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        XCTAssertTrue(pins.resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: -1).pinned.isEmpty)
    }

    func testActionsNeverAddressLocalUUIDOrPendingDeletion() async {
        let log = stub()
        let (coordinator, _, _, _, _) = environment()
        let actions = DocumentActions(
            client: client(), saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults))
        let local = coordinator.createLocalDocument(title: "Local", parentID: nil, ownerUserID: owner)
        let localResult = await actions.setFavorite(documentID: local.id, isFavorite: true)
        XCTAssertEqual(localResult, .failed)
        coordinator.recordPendingDelete(documentID: id, ownerUserID: owner)
        let deletedResult = await actions.setFavorite(documentID: id, isFavorite: true)
        XCTAssertEqual(deletedResult, .failed)
        XCTAssertTrue(log.methods.isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testRealCoordinatorDeletionHoldUndoAndCompletionProtectPinIntent() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let log = stub()
        let (coordinator, home, _, _, _) = environment()
        await home.toggleFavorite(row())
        coordinator.recordPendingDelete(documentID: id, ownerUserID: owner)
        defaults.set(false, forKey: "schrift.workOffline")
        await coordinator.syncPendingPins()
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        coordinator.cancelPendingDelete(documentID: id)
        await coordinator.syncPendingPins()
        XCTAssertEqual(log.count(ofMethod: "POST"), 1)
        defaults.set(true, forKey: "schrift.workOffline")
        await home.toggleFavorite(home.pinnedDocuments[0])
        coordinator.completeImmediateDelete(documentID: id)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allSettled().isEmpty)
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertTrue(home.recentDocuments.isEmpty)
    }

    func testDeleteCompletingDuringPinRequestCannotResurrectTheRowOrIntent() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = stub(gate: gate)
        let (coordinator, home, _, _, _) = environment()
        await home.toggleFavorite(row())
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        coordinator.completeImmediateDelete(documentID: id)
        gate.open()
        await coordinator.syncPendingPins()
        await waitUntil { !coordinator.pins.isSyncing }
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertTrue(home.recentDocuments.isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allSettled().isEmpty)
    }

    func testDeletionDoesNotClearAnotherServersSameUUIDSettlement() async {
        _ = stub()
        let other = self.pins(origin: "https://other.example.org")
        XCTAssertTrue(queue(other, pinned: true))
        await other.sync(isBlocked: { _ in false })
        let local = pins()
        XCTAssertTrue(queue(local, pinned: true))
        await local.sync(isBlocked: { _ in false })
        local.remove(documentID: id)
        XCTAssertEqual(
            PendingDocumentPinStore(userDefaults: defaults).allSettled().map(\.serverOrigin),
            ["https://other.example.org"])
        XCTAssertTrue(
            self.pins(origin: "https://other.example.org").value(
                for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
    }
}
