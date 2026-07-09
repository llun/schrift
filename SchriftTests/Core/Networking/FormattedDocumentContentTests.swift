import XCTest

@testable import Schrift

final class FormattedDocumentContentDecodingTests: XCTestCase {
    func testDecodesFullFixture() throws {
        let json = """
            {
                "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
                "title": "Q3 Planning",
                "content": "# Heading\\n\\nBody text",
                "created_at": "2026-01-15T10:30:00Z",
                "updated_at": "2026-01-16T11:00:00Z"
            }
            """.data(using: .utf8)!

        let result = try JSONDecoder.docsAPI.decode(FormattedDocumentContent.self, from: json)
        XCTAssertEqual(result.title, "Q3 Planning")
        XCTAssertEqual(result.content, "# Heading\n\nBody text")
    }

    func testDecodesNullContentForEmptyDocument() throws {
        let json = """
            {
                "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
                "title": null,
                "content": null,
                "created_at": "2026-01-15T10:30:00Z",
                "updated_at": "2026-01-15T10:30:00Z"
            }
            """.data(using: .utf8)!

        let result = try JSONDecoder.docsAPI.decode(FormattedDocumentContent.self, from: json)
        XCTAssertNil(result.title)
        XCTAssertNil(result.content)
    }
}

final class FormattedDocumentContentClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testFormattedContentRequestsCorrectURLWithMarkdownFormat() async throws {
        let body = """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        let result = try await client.formattedContent(documentID: id)

        XCTAssertEqual(result.content, "text")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/formatted-content/?content_format=markdown"
        )
    }

    // MARK: - Legacy backends have no formatted-content route

    private static let contentBody = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# md", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!

    private static let htmlHeaders = ["Content-Type": "text/html; charset=utf-8"]
    private static let jsonHeaders = ["Content-Type": "application/json"]

    private nonisolated static func htmlNotFound() -> MockURLProtocol.Stub {
        .init(statusCode: 404, headers: htmlHeaders, body: Data("<html>Not Found</html>".utf8), error: nil)
    }

    private nonisolated static func jsonNotFound() -> MockURLProtocol.Stub {
        .init(statusCode: 404, headers: jsonHeaders, body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
    }

    private nonisolated static func ok() -> MockURLProtocol.Stub {
        .init(statusCode: 200, headers: jsonHeaders, body: contentBody, error: nil)
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private var documentID: UUID { UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")! }

    /// Older docs releases expose the markdown projection at `content/?content_format=…` and
    /// have no `formatted-content/` route at all — it answers Django's HTML 404. Every 404
    /// used to map to `.notFound`, which the editor reads as "this document was deleted", so
    /// an entire server's documents rendered as "This document is no longer available."
    func testFallsBackToTheContentRouteWhenTheFormattedRouteIsAbsent() async throws {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            // The route is absent for *every* id, including the confirmation probe.
            return request.url?.path.contains("formatted-content") == true ? Self.htmlNotFound() : Self.ok()
        }

        let result = try await makeClient().formattedContent(documentID: documentID)

        XCTAssertEqual(result.content, "# md")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/content/?content_format=markdown"
        )
        // modern route, confirmation probe, then the legacy route.
        XCTAssertEqual(log.count(ofMethod: "GET"), 3)
    }

    /// The dangerous case. A proxy in front of a server that *does* have the route can answer
    /// HTML for a path it swallowed. `FormattedDocumentContent.content` is a plain `String?`,
    /// so a base64 Yjs body from `content/` would decode into it silently — and the
    /// full-overwrite save would push that blob back as the document's markdown. The
    /// confirmation probe, which a present route answers with DRF's JSON 404, must stop that.
    func testAProxyHTML404OnAServerThatHasTheRouteNeverReadsTheContentRoute() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            guard let path = request.url?.path else { return Self.jsonNotFound() }
            if path.contains("formatted-content") {
                // The probe id proves the route is registered; the real id was swallowed.
                return path.contains("00000000") ? Self.jsonNotFound() : Self.htmlNotFound()
            }
            return Self.ok()  // content/ would happily hand back a body — we must not ask.
        }

        do {
            _ = try await makeClient().formattedContent(documentID: documentID)
            XCTFail("Expected routeNotFound")
        } catch let error as DocsAPIError {
            // Never `.notFound`: that is read everywhere as "this document was deleted", and
            // would tear the editor down and purge the cache over a proxy hiccup.
            XCTAssertEqual(error, .routeNotFound)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/content/?"), 0, "must never read content/")
        XCTAssertEqual(log.count(ofMethod: "GET"), 2)
    }

    /// An ACL that checks permission before existence answers the probe with 403 — about a
    /// document the user never opened. Letting it escape would hit the editor's
    /// `.notFound || .forbidden` teardown and purge the cache for the document on screen.
    func testAForbiddenProbeNeverEscapesAndNeverFallsBack() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            guard let path = request.url?.path else { return Self.jsonNotFound() }
            if path.contains("00000000") { return .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
            return path.contains("formatted-content") ? Self.htmlNotFound() : Self.ok()
        }

        do {
            _ = try await makeClient().formattedContent(documentID: documentID)
            XCTFail("Expected routeNotFound")
        } catch let error as DocsAPIError {
            XCTAssertNotEqual(error, .forbidden, "the probe's 403 must not be reported as the document's")
            XCTAssertEqual(error, .routeNotFound)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/content/?"), 0)
    }

    /// The route's absence is a fact about the server, proved by the probe. A first document
    /// that happens to be deleted must not make every later load re-run the detection.
    func testTheRouteIsRememberedEvenIfTheFirstLegacyFetchFails() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.path.contains("formatted-content") == true { return Self.htmlNotFound() }
            return Self.jsonNotFound()  // the document itself is gone
        }
        let client = makeClient()

        do {
            _ = try await client.formattedContent(documentID: documentID)
            XCTFail("Expected notFound")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
        // A second load goes straight to the legacy route: no modern request, no probe.
        _ = try? await client.formattedContent(documentID: documentID)

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 2, "detection ran once")
        XCTAssertEqual(log.count(ofMethod: "GET"), 4)
    }

    /// Once the route's absence is confirmed, stop paying for detection on every load.
    func testTheLegacyRouteIsRememberedForSubsequentLoads() async throws {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return request.url?.path.contains("formatted-content") == true ? Self.htmlNotFound() : Self.ok()
        }
        let client = makeClient()

        _ = try await client.formattedContent(documentID: documentID)
        _ = try await client.formattedContent(documentID: documentID)

        // 3 for the first load (modern + probe + legacy), 1 for the second.
        XCTAssertEqual(log.count(ofMethod: "GET"), 4)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 2)
    }

    /// A deleted document 404s as a missing *object* (JSON). It must surface `.notFound`,
    /// which the editor's teardown path depends on — and must not probe or fall back.
    func testADeletedDocumentStillThrowsNotFoundWithoutFallingBack() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return Self.jsonNotFound()
        }

        do {
            _ = try await makeClient().formattedContent(documentID: documentID)
            XCTFail("Expected notFound")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.count(ofMethod: "GET"), 1)
    }

    /// An unlabelled 404 carries no evidence of a missing route, so it stays `.notFound`.
    func testAnUnlabelled404DoesNotFallBack() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }

        do {
            _ = try await makeClient().formattedContent(documentID: documentID)
            XCTFail("Expected notFound")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.count(ofMethod: "GET"), 1)
    }

    /// A 403 is revoked access, not a missing route. It must not probe or fall back.
    func testForbiddenDoesNotFallBack() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }

        do {
            _ = try await makeClient().formattedContent(documentID: documentID)
            XCTFail("Expected forbidden")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.count(ofMethod: "GET"), 1)
    }

    /// "I couldn't ask" must never read as "the route isn't there": a transport failure
    /// during the confirmation probe propagates instead of silently diverting to `content/`.
    func testATransportFailureDuringTheProbePropagates() async {
        MockURLProtocol.stubHandler = { request in
            guard let path = request.url?.path else { return Self.jsonNotFound() }
            if path.contains("00000000") {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            return path.contains("formatted-content") ? Self.htmlNotFound() : Self.ok()
        }

        do {
            _ = try await makeClient().formattedContent(documentID: documentID)
            XCTFail("Expected a network error")
        } catch let error as DocsAPIError {
            guard case .network = error else { return XCTFail("Expected .network, got \(error)") }
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
    }
}
