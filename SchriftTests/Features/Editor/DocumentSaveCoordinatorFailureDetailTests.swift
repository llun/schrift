import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorFailureDetailTests: DocumentSaveCoordinatorTestCase {
    private func makeLoggedCoordinator() -> (DocumentSaveCoordinator, APIDiagnosticsLog) {
        let log = APIDiagnosticsLog()
        let client = DocsAPIClient(
            baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] },
            onRequestFailure: { log.record($0) })
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!),
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), backgroundTasks: .noop,
            diagnostics: log)
        return (coordinator, log)
    }

    func testAFailedSaveKeepsTheRejectingRequestAndServerMessage() async {
        let (coordinator, _) = makeLoggedCoordinator()
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 403, headers: [:], body: Data(#"{"detail": "CSRF Failed: CSRF token missing."}"#.utf8),
                error: nil)
        }

        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# Mine")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }

        let failure = coordinator.failureDetail(for: documentID)
        XCTAssertEqual(failure?.statusCode, 403)
        let detail = failure?.saveFailureDetail ?? ""
        XCTAssertTrue(detail.contains("HTTP 403: CSRF Failed: CSRF token missing."), detail)
        XCTAssertFalse(detail.lowercased().contains(documentID.uuidString.lowercased()), "ids are elided")
        XCTAssertFalse(detail.contains("?"), "no query string")
    }

    func testDisplayPathElidesIDsAndDropsTheQuery() {
        let failure = RequestFailure(
            method: "PATCH", path: "documents/\(documentID.uuidString.lowercased())/content/?token=secret",
            statusCode: 404, body: Data())
        XCTAssertEqual(failure.displayPath, "documents/…/content/")
    }
}
