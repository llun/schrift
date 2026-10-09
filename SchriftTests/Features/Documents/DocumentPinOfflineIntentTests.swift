import Observation
import XCTest

@testable import Schrift

@MainActor
final class DocumentPinOfflineIntentTests: DocumentPinTestCase {
    func testOfflinePinAndUnpinImmediatelyChangeMembershipWithoutChangingRawCaches() async {
        let log = stub(error: URLError(.notConnectedToInternet))
        let cache = DocumentCacheStore(userDefaults: defaults)
        cache.savePinnedDocuments([])
        cache.saveRecentDocuments([row()])
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        var shown = pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1)
        XCTAssertEqual(shown.pinned.map(\.id), [id])
        XCTAssertTrue(recentsExcludingPinned(recent: shown.recent, pinned: shown.pinned).isEmpty)
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/favorite/"), 1)
        XCTAssertEqual(cache.loadPinnedDocuments(), [], "pending intent must not leak through unscoped metadata")
        XCTAssertTrue(queue(pins, pinned: false))
        shown = pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1)
        XCTAssertTrue(shown.pinned.isEmpty)
        XCTAssertEqual(shown.recent.map(\.id), [id])
        XCTAssertFalse(shown.recent[0].isFavorite)
    }

    func testRepeatedTogglesCoalesceAndSurviveRelaunch() {
        let original = pins()
        for value in [true, false, true, false] { XCTAssertTrue(queue(original, pinned: value)) }
        let records = PendingDocumentPinStore(userDefaults: defaults).allPins()
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].isPinned)
        let relaunched = pins()
        let shown = relaunched.resolve(
            pinned: [row(pinned: true)], recent: [row(pinned: true)], ownerUserID: owner, fetchedAt: -1)
        XCTAssertTrue(shown.pinned.isEmpty)
        XCTAssertFalse(shown.recent[0].isFavorite)
    }

    func testReconnectSendsLatestIntentAndSettlesDurably() async {
        let log = stub()
        let pins = pins()
        for value in [true, false, true] { XCTAssertTrue(queue(pins, pinned: value)) }
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/favorite/"), 1)
        XCTAssertEqual(log.count(ofMethod: "DELETE", urlContaining: "/favorite/"), 0)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testUnpinUsesDeleteAndKeepsRowAvailableInRecent() async {
        let log = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: false, row: row(pinned: true)))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "DELETE", urlContaining: "/favorite/"), 1)
        let shown = pins.resolve(pinned: [row(pinned: true)], recent: [], ownerUserID: owner, fetchedAt: -1)
        XCTAssertTrue(shown.pinned.isEmpty)
        XCTAssertEqual(shown.recent.map(\.id), [id], "an unpin hands a pinned-only row back immediately")
    }

    func testOldMutationSuccessCannotSettleANewerToggle() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = stub(gate: gate)
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(queue(pins, pinned: false))
        gate.open()
        await syncing.value
        XCTAssertEqual(log.count(ofMethod: "DELETE", urlContaining: "/favorite/"), 1)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        XCTAssertTrue(
            pins.resolve(pinned: [row(pinned: true)], recent: [], ownerUserID: owner, fetchedAt: -1).pinned.isEmpty)
    }

    func testWorkOfflineMakesNoRequestsAndKeepsIntent() async {
        let log = stub()
        defaults.set(true, forKey: "schrift.workOffline")
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertTrue(log.methods.isEmpty)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testRetryableFailuresAndSessionExpiryRetainIntent() async {
        for status in [401, 429, 500, 503] {
            _ = stub(status: status)
            let pins = pins()
            XCTAssertTrue(queue(pins, pinned: true))
            await pins.sync(isBlocked: { _ in false })
            XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1, "status \(status)")
        }
    }

    func testTerminalRejectionRestoresPriorStateAndReportsPinError() async {
        for status in [400, 403, 404, 405] {
            _ = stub(status: status)
            let pins = pins()
            XCTAssertTrue(queue(pins, pinned: true))
            await pins.sync(isBlocked: { _ in false })
            XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
            XCTAssertFalse(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
            XCTAssertEqual(pins.failure(for: id, ownerUserID: owner), .options_error_toggle_favorite)
        }
    }

    func testSuccessThenStaleCacheAndRelaunchKeepsScopedSettledProjection() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        let cache = DocumentCacheStore(userDefaults: defaults)
        cache.savePinnedDocuments([])
        cache.saveRecentDocuments([row()])
        let restored = self.pins()
        XCTAssertEqual(
            restored.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1).pinned.map(\.id), [id])
        XCTAssertTrue(restored.resolve(pinned: [], recent: [row()], ownerUserID: UUID(), fetchedAt: -1).pinned.isEmpty)
        restored.didCacheFreshLists(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: restored.revision)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allSettled().count, 1)
        XCTAssertFalse(self.pins().value(for: id, fallback: true, ownerUserID: owner, fetchedAt: -1))
        XCTAssertFalse(
            restored.value(for: id, fallback: true, ownerUserID: owner, fetchedAt: -1),
            "a fresh web unpin reaches older screens")
    }

    func testSupersededSuccessThenLatestRejectionRestoresWhatActuallyLanded() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = RequestRecorder()
        let userBody = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "GET" { return .init(statusCode: 200, headers: [:], body: userBody, error: nil) }
            return .init(
                statusCode: request.httpMethod == "POST" ? 204 : 403, headers: [:], body: Data(), error: nil,
                releasedBy: gate
            )
        }
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(queue(pins, pinned: false))
        gate.open()
        await syncing.value
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        XCTAssertEqual(pins.failure(for: id, ownerUserID: owner), .options_error_toggle_favorite)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testSettledValueWinsOverStaleMetadataForTerminalRollback() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        _ = stub(status: 403)
        XCTAssertTrue(queue(pins, pinned: false, row: row(pinned: false)))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
    }
}
