import Observation
import XCTest

@testable import Schrift

@MainActor
final class DocumentPinMoveTests: DocumentPinTestCase {
    func testPendingAndSettledUnpinCannotUndoLandedMoveEvenAfterRelaunch() async {
        for settled in [false, true] {
            defaults.set(true, forKey: "schrift.workOffline")
            let (coordinator, home, _, _, _) = environment()
            home.pinnedDocuments = [row(pinned: true)]
            await home.toggleFavorite(row(pinned: true))
            if settled {
                _ = stub()
                defaults.set(false, forKey: "schrift.workOffline")
                await coordinator.syncPendingPins()
                defaults.set(true, forKey: "schrift.workOffline")
            }
            coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: UUID())
            XCTAssertTrue(home.recentDocuments.isEmpty)
            let (_, relaunched, _, _, _) = environment()
            XCTAssertTrue(relaunched.recentDocuments.isEmpty)
            coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: nil)
            XCTAssertEqual(home.recentDocuments.map(\.id), [id])
            coordinator.completeImmediateDelete(documentID: id)
        }
    }

    func testMoveDuringUnpinRequestSurvivesSettlementAndRelaunch() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        _ = stub(gate: gate)
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        home.pinnedDocuments = [row(pinned: true)]
        await home.toggleFavorite(row(pinned: true))
        defaults.set(false, forKey: "schrift.workOffline")
        let syncing = Task { await coordinator.syncPendingPins() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: UUID())
        gate.open()
        await syncing.value
        XCTAssertTrue(home.recentDocuments.isEmpty)
        let (_, restored, _, _, _) = environment()
        XCTAssertTrue(restored.recentDocuments.isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testLaterServerFeedCanIncludeFiledUnpinnedDocument() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        home.pinnedDocuments = [row(pinned: true)]
        await home.toggleFavorite(row(pinned: true))
        coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: UUID())
        // Placement only prohibits synthetic fallback. A future server may include subpages.
        home.fetchedRecentDocuments = [row()]
        XCTAssertEqual(home.recentDocuments.map(\.id), [id])
    }
}
