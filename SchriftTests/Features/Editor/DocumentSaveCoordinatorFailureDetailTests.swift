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

    /// The editor's sub-page list read (`GET documents/{id}/children/`, whose failure it
    /// swallows) 404s while the save is on the wire; it is not the save's reason, so a save that
    /// fails without a response of its own shows none.
    func testAChildrenReadFailingDuringTheSaveIsNotItsReason() async {
        let (coordinator, log) = makeLoggedCoordinator()
        let id = documentID.uuidString.lowercased()
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/collaboration/ydoc/") {
                log.record(
                    RequestFailure(method: "GET", path: "documents/\(id)/children/", statusCode: 404, body: Data()))
                return .init(
                    statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"doc": "%%%"}"#.utf8),
                    error: nil)
            }
            return .init(
                statusCode: 404, headers: ["Content-Type": "text/html"], body: Data("<h1>Not Found</h1>".utf8),
                error: nil)
        }

        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# Mine")
        await waitUntilFailed(coordinator, [documentID])

        XCTAssertNil(coordinator.failureDetail(for: documentID))
    }

    func testOnlyTheSavesOwnRequestsAreRelevant() {
        let id = documentID.uuidString.lowercased()
        func relevant(_ method: String, _ path: String) -> Bool {
            saveFailureIsRelevant(
                RequestFailure(method: method, path: path, statusCode: 403, body: Data()), documentID: documentID,
                error: nil)
        }
        XCTAssertTrue(relevant("PATCH", "documents/\(id)/content/"))
        XCTAssertTrue(relevant("PATCH", "documents/\(id)/"))
        XCTAssertTrue(relevant("GET", "/collaboration/ydoc/v1/docs/\(id)?gc=true&awareness=false"))
        XCTAssertTrue(relevant("PATCH", "/collaboration/ydoc/v1/docs/\(id)"))
        XCTAssertFalse(relevant("GET", "documents/\(id)/children/"))
        XCTAssertFalse(relevant("GET", "documents/\(id)/"))
        XCTAssertFalse(relevant("GET", "documents/\(id)/content/?content_format=markdown"))
        XCTAssertFalse(relevant("PATCH", "documents/\(otherDocumentID.uuidString.lowercased())/content/"))
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

    // MARK: - The reason shown even without an HTTP response

    private func failedReport(_ coordinator: DocumentSaveCoordinator) -> String {
        coordinator.failureReport(for: documentID) ?? "<nil>"
    }

    /// The owner's case: the save fails on a response that arrives but does not decode, so the log
    /// holds no request to quote. The alert still says what failed, and where in the payload.
    func testADecodingFailureHasAReasonButNoRequest() async {
        let (coordinator, _) = makeLoggedCoordinator()
        stubDocs6Fallback(
            collaboration: .init(
                statusCode: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"doc": 987654321}"#.utf8), error: nil))

        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# Secret body")
        await waitUntilFailed(coordinator, [documentID])

        XCTAssertNil(coordinator.failureDetail(for: documentID))
        let report = failedReport(coordinator)
        XCTAssertEqual(report, "Save failed: DocsAPIError.decoding: typeMismatch(String) at doc")
        XCTAssertFalse(report.contains("Secret body"))
        XCTAssertFalse(report.contains("987654321"), "no payload value")
    }

    func testAnHTTPFailureShowsTheReasonAndTheRequest() async {
        let (coordinator, _) = makeLoggedCoordinator()
        stubDocs6Fallback(collaboration: Self.json(403, "Collaboration refused."))

        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# Mine")
        await waitUntilFailed(coordinator, [documentID])

        let report = failedReport(coordinator)
        XCTAssertEqual(
            report,
            "Save failed: DocsAPIError.forbidden\n\nGET /collaboration/ydoc/v1/docs/…\nHTTP 403: Collaboration refused."
        )
        XCTAssertFalse(report.lowercased().contains(documentID.uuidString.lowercased()))
    }

    /// `enqueueReplica` refuses another account's scope; the native session reports that refusal
    /// through `noteReplicaCaptureFailure`, which has no HTTP request at all.
    func testALocalGuardRefusalNamesTheGuard() throws {
        let (coordinator, _, _) = makeCoordinator()
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example.org", ownerUserID: UUID(), org: "docs", documentID: documentID)
        let adapter = ReplicaSaveAdapter(store: coordinator.replicaStore, scope: scope)
        XCTAssertThrowsError(try coordinator.enqueueReplica(adapter: adapter, title: "T")) { error in
            coordinator.noteReplicaCaptureFailure(documentID: documentID, error: error)
        }
        XCTAssertEqual(
            failedReport(coordinator), "Native capture refused: ReplicaSaveError.otherServerOrAccount")

        coordinator.noteReplicaCaptureFailure(documentID: otherDocumentID, error: ReplicaSaveError.quarantinedDrafts)
        XCTAssertEqual(
            coordinator.failureReport(for: otherDocumentID),
            "Native capture refused: ReplicaSaveError.quarantinedDrafts")
    }

    func testASuccessfulSaveClearsTheReason() async {
        let (coordinator, _) = makeLoggedCoordinator()
        MockURLProtocol.stubHandler = { _ in Self.json(403, "Refused.") }
        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# One")
        await waitUntilFailed(coordinator, [documentID])
        XCTAssertNotNil(coordinator.failureReport(for: documentID))

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        coordinator.enqueue(documentID: documentID, title: "T", markdown: "# Two")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.failureReport(for: documentID))
    }

    func testDisplayPathElidesIDsAndDropsTheQuery() {
        let failure = RequestFailure(
            method: "PATCH", path: "documents/\(documentID.uuidString.lowercased())/content/?token=secret",
            statusCode: 404, body: Data())
        XCTAssertEqual(failure.displayPath, "documents/…/content/")
    }
}
