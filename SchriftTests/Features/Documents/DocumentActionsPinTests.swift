import XCTest

@testable import Schrift

@MainActor
final class DocumentActionsPinTests: DocumentActionsTestCase {
    private func stubPinReplay(_ log: RequestRecorder, status: Int = 204) {
        let userBody = Data("{\"id\":\"\(ownerID.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            return .init(statusCode: status, headers: [:], body: Data(), error: nil)
        }
    }

    func testPinningQueuesThenPostsTheNewState() async {
        let log = RequestRecorder()
        stubPinReplay(log)
        let env = makeEnvironment()
        let outcome = await env.actions.setFavorite(documentID: documentID, isFavorite: true)
        XCTAssertEqual(outcome, .queued(isFavorite: true))
        await env.coordinator.syncPendingPins()
        await waitUntil {
            log.count(ofMethod: "POST", urlContaining: "\(documentID.uuidString.lowercased())/favorite/") == 1
        }
        await waitUntil { !env.coordinator.pins.isSyncing }
        XCTAssertEqual(log.count(ofMethod: "POST"), 1)
    }

    func testUnpinningQueuesThenSendsADelete() async {
        let log = RequestRecorder()
        stubPinReplay(log)
        let env = makeEnvironment()
        let outcome = await env.actions.setFavorite(documentID: documentID, isFavorite: false)
        XCTAssertEqual(outcome, .queued(isFavorite: false))
        await env.coordinator.syncPendingPins()
        await waitUntil {
            log.count(ofMethod: "DELETE", urlContaining: "\(documentID.uuidString.lowercased())/favorite/") == 1
        }
        await waitUntil { !env.coordinator.pins.isSyncing }
        XCTAssertEqual(log.count(ofMethod: "DELETE"), 1)
    }

    func testARetryablePinFailureKeepsDurableIntent() async {
        let log = RequestRecorder()
        stubPinReplay(log, status: 500)
        let env = makeEnvironment()
        let outcome = await env.actions.setFavorite(documentID: documentID, isFavorite: true)
        XCTAssertEqual(outcome, .queued(isFavorite: true))
        await env.coordinator.syncPendingPins()
        await waitUntil { log.count(ofMethod: "POST") >= 1 && !env.coordinator.pins.isSyncing }
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: env.defaults).allPins().map(\.documentID), [documentID])
    }
}
