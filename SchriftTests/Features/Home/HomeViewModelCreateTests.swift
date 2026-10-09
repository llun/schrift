import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelCreateTests: HomeViewModelTestCase {
    // `nonisolated`: both are read from inside the `@Sendable` stub handler, which does not
    // run on the main actor this test class is isolated to.
    private nonisolated static func emptyPageFixture() -> Data {
        #"{"count":0,"next":null,"previous":null,"results":[]}"#.data(using: .utf8)!
    }

    private nonisolated static func documentFixture() -> Data {
        """
        {
            "id": "17171717-1717-4171-8171-171717171717",
            "title": "Untitled document",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 1,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "0002",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner",
            "is_favorite": false
        }
        """.data(using: .utf8)!
    }

    /// **Work Offline now creates locally, and issues no request at all.** It used to POST
    /// even with the toggle on, which made a preference named "Work offline" emit traffic and
    /// left the user with nothing when the POST failed. The mode is a strict no-network
    /// contract on every read path; creating is now the same.
    ///
    /// Note what is asserted about the cache: **nothing goes into it.** A synthetic `Document`
    /// must never enter a persisted metadata cache, because a list load replaces its array and
    /// its cache entry wholesale, after which a cached synthetic would be indistinguishable
    /// from a real server document — with a client-minted id every fetch 404s on. The row
    /// reaches the screen through the read-time merge instead.
    func testCreateDocumentUnderWorkOfflineCreatesLocallyWithoutNetwork() async {
        let log = RequestRecorder()
        let cache = makeCache()
        preferences.set(true, forKey: "schrift.workOffline")
        let signedIn = makeSignedInUser()
        let viewModel = makeViewModel(cache: cache, signedInUser: signedIn)
        await viewModel.load()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let document = await viewModel.createDocument()

        XCTAssertEqual(log.methods.count, 0, "the toggle means no network, creation included")
        XCTAssertEqual(document?.title, "Untitled document")
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Untitled document"], "merged at read time")
        XCTAssertNil(cache.loadRecentDocuments(), "and never written into the metadata cache")
        XCTAssertTrue(viewModel.saveCoordinator.isPendingCreate(documentID: document!.id))
        XCTAssertNil(viewModel.errorKey)
    }

    func testFailedCreateDocumentSurfacesTheServersOwnReason() async {
        let diagnostics = APIDiagnosticsLog()
        let viewModel = makeViewModel(diagnostics: diagnostics)
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 403, headers: [:],
                body: #"{"detail":"CSRF Failed: CSRF token missing."}"#.data(using: .utf8)!, error: nil)
        }

        let document = await viewModel.createDocument()

        XCTAssertNil(document)
        XCTAssertEqual(viewModel.errorKey, .home_error_create)
        XCTAssertEqual(viewModel.errorDetail, "HTTP 403: CSRF Failed: CSRF token missing.")
    }

    /// Offline, there is no HTTP response to quote. Without the marker the catch would show
    /// the detail of whatever unrelated request failed last.
    /// **A transport failure now falls back to creating locally rather than reporting an
    /// error.** The document is kept on the device and replayed on the next reconnect, which
    /// is strictly better than the old "Couldn't create a document" with nothing to show for
    /// it. The classifier is the same one the save path uses, so what still errors is a
    /// rejection *on the merits* — see the test below.
    func testCreateDocumentFallsBackToALocalDocumentOnATransportError() async {
        let signedIn = makeSignedInUser()
        let viewModel = makeViewModel(signedInUser: signedIn)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let document = await viewModel.createDocument()

        XCTAssertNotNil(document)
        XCTAssertNil(viewModel.errorKey, "kept on the device, not reported as a failure")
        XCTAssertTrue(viewModel.saveCoordinator.isPendingCreate(documentID: document!.id))
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Untitled document"])
    }

    /// The other half: a server that answered and *declined*. Minting a local document there
    /// would promise a replay that will be declined again, so this keeps the error.
    func testCreateDocumentStillReportsARejectionOnTheMerits() async {
        let signedIn = makeSignedInUser()
        let viewModel = makeViewModel(signedInUser: signedIn)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }

        let document = await viewModel.createDocument()

        XCTAssertNil(document)
        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.recentDocuments.isEmpty, "nothing minted")
    }

    /// Nobody known to own it ⇒ no record. `createLocalDocument` takes a non-optional owner,
    /// and a record nothing can attribute is protected but listed to nobody and replayed
    /// never — so minting one would create a document the user can never see again.
    func testCreateDocumentWithNoKnownAccountReportsRatherThanMintingAnOrphan() async {
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: nil))
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let document = await viewModel.createDocument()

        XCTAssertNil(document)
        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.recentDocuments.isEmpty)
    }

    /// The reported bug: the message had no way out. `createDocument`'s failure path never
    /// reaches `load()`, which was the only thing that cleared it.
    func testDismissErrorClearsTheCreateFailureMessage() async {
        let diagnostics = APIDiagnosticsLog()
        let viewModel = makeViewModel(diagnostics: diagnostics)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        _ = await viewModel.createDocument()
        XCTAssertNotNil(viewModel.errorKey)

        viewModel.dismissError()

        XCTAssertNil(viewModel.errorKey)
        XCTAssertNil(viewModel.errorDetail)
    }

    func testRetryingCreateDocumentClearsThePreviousMessageBeforeSucceeding() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        _ = await viewModel.createDocument()
        XCTAssertNotNil(viewModel.errorKey)

        // Now the create succeeds, and the load() it triggers answers with an empty page.
        MockURLProtocol.stubHandler = { request in
            let isCreate = request.httpMethod == "POST"
            let body = isCreate ? Self.documentFixture() : Self.emptyPageFixture()
            return .init(statusCode: isCreate ? 201 : 200, headers: [:], body: body, error: nil)
        }

        let document = await viewModel.createDocument()

        XCTAssertNotNil(document)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertNil(viewModel.errorDetail)
    }
}
