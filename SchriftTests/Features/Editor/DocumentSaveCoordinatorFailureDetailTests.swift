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

    private func waitUntilFailed(_ coordinator: DocumentSaveCoordinator, _ ids: [UUID]) async {
        await waitUntil { ids.allSatisfy { self.isFailed(coordinator.state(for: $0)) } }
    }

    nonisolated private static func json(
        _ status: Int, _ detail: String, releasedBy gate: MockURLProtocol.ResponseGate? = nil
    ) -> MockURLProtocol.Stub {
        .init(
            statusCode: status, headers: ["Content-Type": "application/json"],
            body: Data(#"{"detail": "\#(detail)"}"#.utf8), error: nil, releasedBy: gate)
    }

    /// Docs 6 with no route memoized: the legacy content PATCH answers Django's HTML 404 (the
    /// expected cue to fall back), and the collaboration request is the one that fails.
    private func stubDocs6Fallback(collaboration: MockURLProtocol.Stub) {
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/collaboration/ydoc/") { return collaboration }
            if url.hasSuffix("/content/") {
                return .init(
                    statusCode: 404, headers: ["Content-Type": "text/html"], body: Data("<h1>Not Found</h1>".utf8),
                    error: nil)
            }
            // `config/` has no route either, so the fallback uses yhub's default org.
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
    }

    func testTheLegacyRouteFallbackIsNotTheReasonShown() async {
        let (coordinator, _) = makeLoggedCoordinator()
        stubDocs6Fallback(collaboration: Self.json(403, "Collaboration refused."))

        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# Mine")
        await waitUntilFailed(coordinator, [documentID])

        let failure = coordinator.failureDetail(for: documentID)
        XCTAssertEqual(failure?.method, "GET")
        XCTAssertEqual(failure?.displayPath, "/collaboration/ydoc/v1/docs/…")
        XCTAssertEqual(failure?.displayText, "HTTP 403: Collaboration refused.")
    }

    /// A save that fails without a response of its own (the collaboration state does not
    /// decode) has no detail, rather than quoting the fallback's 404.
    func testAFailureWithoutAResponseAfterTheFallbackHasNoDetail() async {
        let (coordinator, _) = makeLoggedCoordinator()
        stubDocs6Fallback(
            collaboration: .init(
                statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"doc": "%%%"}"#.utf8),
                error: nil))

        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# Mine")
        await waitUntilFailed(coordinator, [documentID])

        XCTAssertNil(coordinator.failureDetail(for: documentID))
    }

    /// Two documents fail while both saves are on the wire: each shows its own request, not the
    /// other's that the shared log recorded in between.
    func testInterleavedSavesEachShowTheirOwnFailure() async {
        let (coordinator, log) = makeLoggedCoordinator()
        let first = documentID.uuidString.lowercased()
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { request in
            (request.url?.absoluteString ?? "").contains(first)
                ? Self.json(403, "First refused.", releasedBy: gate) : Self.json(400, "Second refused.")
        }

        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# One")
        coordinator.enqueue(documentID: otherDocumentID, title: "T", markdown: "# Two")
        // The second document's failure is on record while the first save is still on the wire.
        await waitUntil { log.recentFailures.count == 1 }
        gate.open()
        await waitUntilFailed(coordinator, [documentID, otherDocumentID])

        XCTAssertEqual(coordinator.failureDetail(for: documentID)?.displayText, "HTTP 403: First refused.")
        XCTAssertEqual(coordinator.failureDetail(for: otherDocumentID)?.displayText, "HTTP 400: Second refused.")
    }

    func testDisplayPathElidesIDsAndDropsTheQuery() {
        let failure = RequestFailure(
            method: "PATCH", path: "documents/\(documentID.uuidString.lowercased())/content/?token=secret",
            statusCode: 404, body: Data())
        XCTAssertEqual(failure.displayPath, "documents/…/content/")
    }
}
