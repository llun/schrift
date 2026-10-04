import XCTest

@testable import Schrift

final class DocumentEndpointsPathTests: XCTestCase {
    func testListPathWithNoFiltersHasNoQueryString() {
        XCTAssertEqual(documentsListPath(), "documents/")
    }

    func testListPathWithIsFavoriteTrue() {
        XCTAssertEqual(documentsListPath(isFavorite: true), "documents/?is_favorite=true")
    }

    func testListPathWithMultipleFilters() {
        let path = documentsListPath(
            isFavorite: false, title: "roadmap", ordering: "-updated_at", page: 2, pageSize: 20)
        XCTAssertTrue(path.hasPrefix("documents/?"))
        XCTAssertTrue(path.contains("is_favorite=false"))
        XCTAssertTrue(path.contains("title=roadmap"))
        XCTAssertTrue(
            path.contains("ordering=-updated_at")
                || path.contains("ordering=-updated_at".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
        )
        XCTAssertTrue(path.contains("page=2"))
        XCTAssertTrue(path.contains("page_size=20"))
    }

    func testSearchPathEncodesQuery() {
        XCTAssertEqual(documentsSearchPath(query: "Q3 Planning"), "documents/search/?q=Q3%20Planning")
    }
}

final class DocumentEndpointsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private static let paginatedFixture = """
        {
            "count": 1,
            "next": null,
            "previous": null,
            "results": [
                {
                    "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
                    "title": "Q3 Planning",
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
                    "path": "0001",
                    "updated_at": "2026-01-15T10:30:00Z",
                    "user_role": "owner",
                    "is_favorite": true
                }
            ]
        }
        """.data(using: .utf8)!

    func testListDocumentsRequestsCorrectURLWithQueryString() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
        }
        let client = makeClient()

        let page = try await client.listDocuments(isFavorite: true, ordering: "-updated_at")

        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page.results.first?.title, "Q3 Planning")
        let requestedURL = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(requestedURL.hasPrefix("https://docs.example.org/api/v1.0/documents/?"))
        XCTAssertTrue(requestedURL.contains("is_favorite=true"))
    }

    func testFavoriteDocumentsRequestsFavoriteListPath() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
        }
        let client = makeClient()

        let page = try await client.favoriteDocuments()

        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/favorite_list/")
    }

    func testFavoriteDocumentsSelectsRouteFromServerVersion() async throws {
        let cases = [
            ("4.4.0", "favorite_list"),
            ("5.6.1", "favorite_list"),
            ("5.6.99", "favorite_list"),
            ("5.7.0", "favorites"),
            ("5.7.1", "favorites"),
            ("5.10.0", "favorites"),
            ("6.0.0", "favorites"),
            ("v5.7.0", "favorites"),
            ("5.7.0-rc.1", "favorites"),
            ("5.7.0+deployment.1", "favorites"),
        ]
        for (version, route) in cases {
            let log = RequestRecorder()
            let config = #"{"RELEASE_VERSION":"\#(version)"}"#.data(using: .utf8)!
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                if request.url?.absoluteString.hasSuffix("/config/") == true {
                    return .init(statusCode: 200, headers: [:], body: config, error: nil)
                }
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/\(route)/", version)
                return .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
            }

            let page = try await makeClient().favoriteDocuments()

            XCTAssertEqual(page.count, 1, version)
            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/config/"), 1, version)
        }
    }

    func testFavoriteDocumentsCachesAnAnsweringRoute() async throws {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let body =
                request.url?.absoluteString.hasSuffix("/config/") == true
                ? #"{"RELEASE_VERSION":"5.7.0"}"#.data(using: .utf8)! : Self.paginatedFixture
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
        let client = makeClient()

        _ = try await client.favoriteDocuments()
        _ = try await client.favoriteDocuments()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/config/"), 1)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorites/"), 2)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorite_list/"), 0)
    }

    func testUnknownVersionTriesLegacyThenNewRouteAndCachesSuccess() async throws {
        for config in ["{}", #"{"RELEASE_VERSION":"development"}"#, #"{"RELEASE_VERSION":"5.7"}"#] {
            let log = RequestRecorder()
            let configBody = Data(config.utf8)
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                switch request.url?.absoluteString {
                case "https://docs.example.org/api/v1.0/config/":
                    return .init(statusCode: 200, headers: [:], body: configBody, error: nil)
                case "https://docs.example.org/api/v1.0/documents/favorite_list/":
                    return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
                case "https://docs.example.org/api/v1.0/documents/favorites/":
                    return .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
                default:
                    XCTFail("Unexpected request")
                    return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
                }
            }
            let client = makeClient()

            _ = try await client.favoriteDocuments()
            _ = try await client.favoriteDocuments()

            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/config/"), 1)
            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorite_list/"), 1)
            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorites/"), 2)
            XCTAssertLessThan(
                log.indexOfFirstRequest(method: "GET", urlContaining: "/documents/favorite_list/")!,
                log.indexOfFirstRequest(method: "GET", urlContaining: "/documents/favorites/")!)
        }
    }

    func testUnavailableConfigStillLoadsLegacyFavorites() async throws {
        let stubs: [MockURLProtocol.Stub] = [
            .init(statusCode: 404, headers: [:], body: Data(), error: nil),
            .init(statusCode: 403, headers: [:], body: Data(), error: nil),
            .init(statusCode: 503, headers: [:], body: Data(), error: nil),
            .init(statusCode: 200, headers: [:], body: Data("not JSON".utf8), error: nil),
            .init(statusCode: 200, headers: [:], body: Data(), error: URLError(.timedOut)),
        ]
        for stub in stubs {
            MockURLProtocol.stubHandler = { request in
                if request.url?.absoluteString.hasSuffix("/config/") == true { return stub }
                XCTAssertEqual(
                    request.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/favorite_list/")
                return .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
            }

            let page = try await makeClient().favoriteDocuments()

            XCTAssertEqual(page.count, 1)
        }
    }

    func testConfigSessionExpiryDoesNotIssueAFavoritesRequest() async {
        let log = RequestRecorder()
        let expired = Counter()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 401, headers: [:], body: Data(), error: nil)
        }
        let client = DocsAPIClient(
            baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] },
            onSessionExpired: { _ = expired.next() })

        do {
            _ = try await client.favoriteDocuments()
            XCTFail("Expected session expiry")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .sessionExpired)
        } catch { XCTFail("Unexpected error: \(error)") }

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/config/"), 1)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/"), 0)
        XCTAssertEqual(expired.current, 1)
    }

    func testKnownVersionCanUseAlternateRouteOnJSONOrHTML404() async throws {
        for (version, initial, alternate, headers) in [
            ("5.6.1", "favorite_list", "favorites", ["Content-Type": "application/json"]),
            ("5.7.0", "favorites", "favorite_list", ["Content-Type": "text/html"]),
        ] {
            let log = RequestRecorder()
            let config = #"{"RELEASE_VERSION":"\#(version)"}"#.data(using: .utf8)!
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                if request.url?.absoluteString.hasSuffix("/config/") == true {
                    return .init(statusCode: 200, headers: [:], body: config, error: nil)
                }
                if request.url?.absoluteString.hasSuffix("/\(initial)/") == true {
                    return .init(statusCode: 404, headers: headers, body: Data(), error: nil)
                }
                return .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
            }
            let client = makeClient()

            _ = try await client.favoriteDocuments()
            _ = try await client.favoriteDocuments()

            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/\(initial)/"), 1)
            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/\(alternate)/"), 2)
        }
    }

    func testFavoritesFailuresOtherThan404NeverTryAlternateRoute() async {
        let failures: [(MockURLProtocol.Stub, DocsAPIError?)] = [
            (.init(statusCode: 401, headers: [:], body: Data(), error: nil), .sessionExpired),
            (.init(statusCode: 403, headers: [:], body: Data(), error: nil), .forbidden),
            (.init(statusCode: 429, headers: [:], body: Data(), error: nil), .rateLimited(retryAfter: nil)),
            (.init(statusCode: 503, headers: [:], body: Data(), error: nil), .server(statusCode: 503)),
            (.init(statusCode: 200, headers: [:], body: Data(), error: URLError(.timedOut)), nil),
        ]
        for (stub, expected) in failures {
            let log = RequestRecorder()
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                if request.url?.absoluteString.hasSuffix("/config/") == true {
                    return .init(
                        statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"5.7.0"}"#.utf8), error: nil)
                }
                return stub
            }

            do {
                _ = try await makeClient().favoriteDocuments()
                XCTFail("Expected favorites failure")
            } catch let error as DocsAPIError {
                if let expected {
                    XCTAssertEqual(error, expected)
                } else if case .network = error {
                } else {
                    XCTFail("Expected network error")
                }
            } catch { XCTFail("Unexpected error: \(error)") }

            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorites/"), 1)
            XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorite_list/"), 0)
        }
    }

    func testCachedLegacyRouteRecoversAfterAnInSessionServerUpgrade() async throws {
        let log = RequestRecorder()
        let client = makeClient()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("/config/") == true {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"5.6.1"}"#.utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
        }
        _ = try await client.favoriteDocuments()

        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("/favorite_list/") == true {
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
            }
            XCTAssertEqual(request.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/favorites/")
            return .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
        }
        _ = try await client.favoriteDocuments()
        _ = try await client.favoriteDocuments()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/config/"), 1)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorite_list/"), 2)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorites/"), 2)
    }

    func testAlternateRouteFailurePropagatesInsteadOfReportingEmptyFavorites() async {
        MockURLProtocol.stubHandler = { request in
            switch request.url?.absoluteString {
            case "https://docs.example.org/api/v1.0/config/":
                return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
            case "https://docs.example.org/api/v1.0/documents/favorite_list/":
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
            default:
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
        }

        do {
            _ = try await makeClient().favoriteDocuments()
            XCTFail("Expected permission failure from the alternate route")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testBothMissingRoutesDoNotCacheAnUnusableRoute() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("/config/") == true {
                return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        for _ in 0..<2 {
            do {
                _ = try await client.favoriteDocuments()
                XCTFail("Expected missing route")
            } catch let error as DocsAPIError {
                XCTAssertEqual(error, .notFound)
            } catch { XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/config/"), 2)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorite_list/"), 2)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/documents/favorites/"), 2)
    }

    func testSearchDocumentsEncodesQueryInURL() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil)
        }
        let client = makeClient()

        _ = try await client.searchDocuments(query: "Q3 Planning")

        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/search/?q=Q3%20Planning")
    }

    func testSetFavoriteTrueSendsPostToFavoriteRoute() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 201, headers: [:], body: #"{"detail": "Document marked as favorite"}"#.data(using: .utf8)!,
                error: nil)
        }
        let client = makeClient()
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        try await client.setFavorite(documentID: id, isFavorite: true)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/favorite/")
    }

    func testSetFavoriteFalseSendsDeleteAndToleratesEmptyBody() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        try await client.setFavorite(documentID: id, isFavorite: false)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }

    // MARK: - Retrieve

    /// The single-document body a `GET documents/{id}/` answers with. Unlike the list
    /// endpoints it carries no `content`, so resolving a link is cheap.
    private static let documentFixture = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "title": "Meeting notes",
            "excerpt": null,
            "abilities": {"update": true},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 2,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "00010001",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner",
            "is_favorite": false
        }
        """.data(using: .utf8)!

    func testDocumentGETsTheTrailingSlashLowercasedUUIDPath() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.documentFixture, error: nil)
        }
        let client = makeClient()
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        let document = try await client.document(documentID: id)

        XCTAssertEqual(document.title, "Meeting notes")
        XCTAssertEqual(document.linkReach, .restricted)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/")
    }

    func testDocumentThrowsForbiddenWhenAccessIsDenied() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        let client = makeClient()

        do {
            _ = try await client.document(documentID: UUID())
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDocumentThrowsNotFoundForAMissingDocument() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        let client = makeClient()

        do {
            _ = try await client.document(documentID: UUID())
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
