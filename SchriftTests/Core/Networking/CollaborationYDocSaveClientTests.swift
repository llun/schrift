import XCTest

@testable import Schrift

/// Every request a stub saw, with its body drained (URLSession moves bodies into a stream).
private final class CapturedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(request: URLRequest, body: Data?)] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((request, bodyData(from: request)))
    }

    var all: [(request: URLRequest, body: Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// `METHOD path` for each request, the query dropped — the sequence a save made.
    var trail: [String] {
        all.map { "\($0.request.httpMethod ?? "") \(requestPath($0.request))" }
    }
}

/// The request's path with any trailing slash kept (`URL.path` drops it, and Django's routes
/// are distinguished by it).
private func requestPath(_ request: URLRequest) -> String {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true)?.path } ?? ""
}

private func jsonStub(_ object: [String: Any], status: Int = 200) -> MockURLProtocol.Stub {
    .init(
        statusCode: status, headers: ["Content-Type": "application/json"],
        body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), error: nil)
}

private let html404 = MockURLProtocol.Stub(
    statusCode: 404, headers: ["Content-Type": "text/html; charset=utf-8"],
    body: Data("<html><body>Not Found</body></html>".utf8), error: nil)

/// The Docs 6 save route (`ContentSaveRoute`): which route a save takes, the exact requests
/// the collaboration route makes, and that `saveDocumentContent`'s half-land contract holds on
/// it. The update a save sends is checked at the document level — applied to a replica of the
/// served state, it must read exactly like the saved markdown.
final class CollaborationYDocSaveClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "ABCDEF12-1111-4111-8111-111111111111")!
    private let yDocPath = "/collaboration/ydoc/v1/docs/abcdef12-1111-4111-8111-111111111111"
    private let legacyPath = "/api/v1.0/documents/abcdef12-1111-4111-8111-111111111111/content/"
    private let titlePath = "/api/v1.0/documents/abcdef12-1111-4111-8111-111111111111/"
    private let idA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let idB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private var baseProps: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    /// "One" / "Two" as the collaboration server would hold them.
    private var servedState: Data {
        BlockNoteYjs.encode(
            [
                BlockNoteBlock(node: "paragraph", props: baseProps, runs: [InlineRun("One")], id: idA),
                BlockNoteBlock(node: "paragraph", props: baseProps, runs: [InlineRun("Two")], id: idB),
            ],
            clientID: 1)
    }

    /// A Docs 6 server: config says 6.0.0, the legacy content route is gone, the collaboration
    /// route serves `state` and accepts PATCHes, and `titleStatus` answers the title PATCH.
    private func stubDocs6(
        log: CapturedRequests, state: Data, version: String? = "6.0.0", updateStatus: Int = 200,
        titleStatus: Int = 200
    ) {
        let yDocPath = yDocPath
        let legacyPath = legacyPath
        let docBody = state.base64EncodedString()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            switch (request.httpMethod ?? "", requestPath(request)) {
            case ("GET", "/api/v1.0/config/"):
                let config: [String: Any] = version.map { ["RELEASE_VERSION": $0] } ?? [:]
                return jsonStub(config)
            case ("GET", yDocPath):
                return jsonStub(["doc": docBody])
            case ("PATCH", yDocPath):
                return jsonStub(["success": true], status: updateStatus)
            case ("PATCH", legacyPath):
                return html404
            default:
                return jsonStub(["id": "x"], status: titleStatus)
            }
        }
    }

    private func sentUpdate(_ log: CapturedRequests) throws -> Data {
        let patch = try XCTUnwrap(
            log.all.first { $0.request.httpMethod == "PATCH" && requestPath($0.request) == yDocPath })
        let body = try XCTUnwrap(patch.body)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["update"], "the body is exactly {\"update\": base64}")
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["update"])))
    }

    private func projectServed(after update: Data) throws -> ProjectedDocument {
        let doc = YDoc(clientID: 999)
        defer { doc.destroy() }
        try doc.applyUpdate(try YUpdateDecoder.decode(servedState))
        try doc.applyUpdate(try YUpdateDecoder.decode(update))
        return YBlockProjection.project(doc)
    }

    // MARK: - Route choice

    func testADocs6ConfigSendsTheSaveToTheCollaborationServer() async throws {
        let log = CapturedRequests()
        stubDocs6(log: log, state: servedState)
        let client = makeClient()
        _ = try await client.serverConfig()

        let titleFailure = try await client.saveDocumentContent(
            documentID: documentID, title: "Notes", markdown: "One\n\nTwo, edited")

        XCTAssertNil(titleFailure)
        XCTAssertEqual(
            log.trail, ["GET /api/v1.0/config/", "GET \(yDocPath)", "PATCH \(yDocPath)", "PATCH \(titlePath)"],
            "never the removed legacy route")
    }

    /// The GET asks for the gc'd JSON representation, and the PATCH is a JSON incremental
    /// update to the same app-authored, same-origin path.
    func testTheCollaborationRequestsHaveTheExactShape() async throws {
        let log = CapturedRequests()
        stubDocs6(log: log, state: servedState)
        let client = makeClient()
        _ = try await client.serverConfig()

        _ = try await client.saveDocumentContent(documentID: documentID, title: "Notes", markdown: "One\n\nTwo, edited")

        let get = try XCTUnwrap(log.all.first { $0.request.httpMethod == "GET" && requestPath($0.request) == yDocPath })
        XCTAssertEqual(
            get.request.url?.absoluteString, "https://docs.example.org\(yDocPath)?gc=true&awareness=false")
        XCTAssertEqual(get.request.value(forHTTPHeaderField: "Accept"), "application/json")
        let patch = try XCTUnwrap(
            log.all.first { $0.request.httpMethod == "PATCH" && requestPath($0.request) == yDocPath })
        XCTAssertEqual(patch.request.url?.absoluteString, "https://docs.example.org\(yDocPath)")
        XCTAssertEqual(patch.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(patch.request.value(forHTTPHeaderField: "Origin"), "https://docs.example.org")
        _ = try sentUpdate(log)
    }

    func testAPreDocs6ConfigKeepsTheLegacyRoute() async throws {
        let log = CapturedRequests()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if requestPath(request) == "/api/v1.0/config/" {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"5.7.0"}"#.utf8), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()
        _ = try await client.serverConfig()

        _ = try await client.saveDocumentContent(documentID: documentID, title: "Notes", markdown: "One")

        XCTAssertEqual(log.trail, ["GET /api/v1.0/config/", "PATCH \(legacyPath)", "PATCH \(titlePath)"])
    }

    /// With nothing known, the save tries the legacy route; Django's HTML 404 for it means
    /// nothing was written, so it falls back once — and the next save goes straight there.
    func testAnUnknownServerFallsBackOnTheLegacyRoutes404AndRemembersIt() async throws {
        let log = CapturedRequests()
        stubDocs6(log: log, state: servedState)
        let client = makeClient()

        _ = try await client.saveDocumentContent(documentID: documentID, title: "Notes", markdown: "One\n\nTwo, edited")
        _ = try await client.saveDocumentContent(documentID: documentID, title: "Notes", markdown: "One\n\nTwo, again")

        XCTAssertEqual(
            log.trail,
            [
                "PATCH \(legacyPath)", "GET \(yDocPath)", "PATCH \(yDocPath)", "PATCH \(titlePath)",
                "GET \(yDocPath)", "PATCH \(yDocPath)", "PATCH \(titlePath)",
            ])
    }

    /// A JSON 404 is an answer about the document (deleted), not the route: no fallback.
    func testALegacyNotFoundDoesNotFallBack() async {
        let log = CapturedRequests()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
        }

        do {
            _ = try await makeClient().saveDocumentContent(documentID: documentID, title: "Notes", markdown: "One")
            XCTFail("a deleted document must throw")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.trail, ["PATCH \(legacyPath)"])
    }

    /// A server with neither route must not be pinned to the collaboration one.
    func testAFallbackThatCannotAnswerIsNotRemembered() async {
        let log = CapturedRequests()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return html404
        }
        let client = makeClient()

        for _ in 0..<2 {
            do {
                _ = try await client.saveDocumentContent(documentID: documentID, title: "Notes", markdown: "One")
                XCTFail("no route answered")
            } catch let error as DocsAPIError {
                XCTAssertEqual(error, .routeNotFound)
            } catch {
                XCTFail("expected DocsAPIError, got \(error)")
            }
        }
        XCTAssertEqual(
            log.trail, ["PATCH \(legacyPath)", "GET \(yDocPath)", "PATCH \(legacyPath)", "GET \(yDocPath)"])
    }

    // MARK: - What the collaboration route sends

    /// Applied to the served state, the update reads exactly like the saved markdown, and the
    /// untouched block keeps its id (it was not rewritten).
    func testTheUpdateMakesTheServerReadLikeTheMarkdown() async throws {
        let log = CapturedRequests()
        stubDocs6(log: log, state: servedState)
        let client = makeClient()
        _ = try await client.serverConfig()
        let markdown = "One\n\nTwo, **edited**\n\nThree"

        _ = try await client.saveDocumentContent(documentID: documentID, title: "Notes", markdown: markdown)

        let after = try projectServed(after: try sentUpdate(log))
        let expected = MarkdownYjs.blockNoteBlocks(from: markdown, serverOrigin: "https://docs.example.org")
        XCTAssertEqual(after.blocks.map(\.node), expected.map(\.node))
        XCTAssertEqual(after.blocks.map(\.runs), expected.map(\.runs))
        XCTAssertEqual(Array(after.blocks.map(\.id).prefix(2)), [idA, idB])
    }

    func testAnUnchangedSaveSendsNoContentPatch() async throws {
        let log = CapturedRequests()
        stubDocs6(log: log, state: servedState)
        let client = makeClient()
        _ = try await client.serverConfig()

        let titleFailure = try await client.saveDocumentContent(
            documentID: documentID, title: "Renamed", markdown: "One\n\nTwo")

        XCTAssertNil(titleFailure)
        XCTAssertEqual(log.trail, ["GET /api/v1.0/config/", "GET \(yDocPath)", "PATCH \(titlePath)"])
    }

    func testMalformedServerStateIsADecodingFailureAndPatchesNothing() async {
        let log = CapturedRequests()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if requestPath(request) == "/api/v1.0/config/" {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(#"{"doc":"not base64!"}"#.utf8), error: nil)
        }
        let client = makeClient()
        _ = try? await client.serverConfig()

        do {
            _ = try await client.saveDocumentContent(documentID: documentID, title: "Notes", markdown: "One")
            XCTFail("unreadable server state must throw")
        } catch let error as DocsAPIError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("expected DocsAPIError, got \(error)")
        }
        XCTAssertFalse(log.all.contains { $0.request.httpMethod == "PATCH" })
    }

    // MARK: - The half-land contract, on the collaboration route

    func testATitleOnlyFailureReturnsTheErrorInsteadOfThrowing() async throws {
        let log = CapturedRequests()
        stubDocs6(log: log, state: servedState, titleStatus: 500)
        let client = makeClient()
        _ = try await client.serverConfig()

        let titleFailure = try await client.saveDocumentContent(
            documentID: documentID, title: "Notes", markdown: "One\n\nTwo, edited")

        XCTAssertEqual(titleFailure, .server(statusCode: 500), "the body landed — report the title, do not throw")
    }

    func testAnUpdateFailureThrowsAndNeverAttemptsTheTitle() async throws {
        let log = CapturedRequests()
        stubDocs6(log: log, state: servedState, updateStatus: 500)
        let client = makeClient()
        _ = try await client.serverConfig()

        do {
            _ = try await client.saveDocumentContent(
                documentID: documentID, title: "Notes", markdown: "One\n\nTwo, edited")
            XCTFail("a failed update PATCH must throw")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .server(statusCode: 500))
        } catch {
            XCTFail("expected DocsAPIError, got \(error)")
        }
        XCTAssertFalse(log.trail.contains("PATCH \(titlePath)"))
    }
}
