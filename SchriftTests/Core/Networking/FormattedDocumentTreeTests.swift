import XCTest

@testable import Schrift

/// `formatted-content/?content_format=json` — the BlockNote tree the leaf-nesting overlay reads.
/// Decoding is deliberately minimal and defensive, and its nesting is bounded.
final class FormattedDocumentTreeDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> FormattedDocumentTree {
        try JSONDecoder.docsAPI.decode(FormattedDocumentTree.self, from: Data(json.utf8))
    }

    /// A verbatim-shaped response (BlockNote 0.51.4's `yDocToBlocks` for a checklist item with
    /// a photo and a file nested under it): only type, url, showPreview and children are kept,
    /// and every other field — inline content, the other props — is ignored.
    func testDecodesTheBlockTreeAndIgnoresEverythingElse() throws {
        let tree = try decode(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": [
              {"id": "a", "type": "checkListItem",
               "props": {"backgroundColor": "default", "textColor": "default", "textAlignment": "left", "checked": false},
               "content": [{"type": "text", "text": "Task", "styles": {}}],
               "children": [
                 {"id": "b", "type": "image", "props": {"textAlignment": "left", "backgroundColor": "default",
                  "name": "p.png", "url": "https://d.example/m.png", "caption": "", "showPreview": true}, "children": []},
                 {"id": "c", "type": "file", "props": {"backgroundColor": "default", "name": "r.pdf",
                  "url": "https://d.example/r.pdf", "caption": ""}, "children": []}]},
              {"id": "d", "type": "checkListItem", "props": {"checked": false},
               "content": [{"type": "text", "text": "Next", "styles": {}}], "children": []}],
             "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
            """)

        XCTAssertEqual(
            tree.content,
            [
                BlockNoteTreeNode(
                    type: "checkListItem",
                    children: [
                        BlockNoteTreeNode(type: "image", url: "https://d.example/m.png", showPreview: true),
                        BlockNoteTreeNode(type: "file", url: "https://d.example/r.pdf"),
                    ]),
                BlockNoteTreeNode(type: "checkListItem"),
            ])
        XCTAssertEqual(tree.updatedAt, ISO8601DateFormatter().date(from: "2026-01-15T10:30:00Z"))
    }

    /// Every field is optional in practice: no props, mistyped props, no children, no type.
    /// None of that may fail the decode — a missing piece only means a node that anchors
    /// nothing.
    func testMissingAndMistypedFieldsDecodeAsAbsent() throws {
        let tree = try decode(
            """
            {"content": [
              {"type": "paragraph"},
              {"type": "image", "props": {"url": 42, "showPreview": "yes"}},
              {"props": null, "children": []}
            ]}
            """)

        XCTAssertEqual(
            tree.content,
            [BlockNoteTreeNode(type: "paragraph"), BlockNoteTreeNode(type: "image"), BlockNoteTreeNode(type: "")])
        XCTAssertNil(tree.updatedAt)
    }

    func testANullContentIsAnEmptyTree() throws {
        XCTAssertEqual(try decode(#"{"content": null}"#).content, [])
    }

    /// A server that ignored the format and answered markdown is not a tree.
    func testAStringContentIsNotATree() {
        assertDecodingFails { try self.decode(#"{"content": "* [ ] Task"}"#) }
    }

    /// Depth is input, not structure (the `Lib0Decoder.readAny` lesson): a tree nested past the
    /// cap is refused rather than recursed into, and one at the cap still decodes.
    func testNestingIsBoundedAtTheCap() throws {
        func nested(_ levels: Int) -> String {
            var node = #"{"type": "bulletListItem"}"#
            for _ in 0..<levels {
                node = #"{"type": "bulletListItem", "children": ["# + node + "]}"
            }
            return #"{"content": ["# + node + "]}"
        }

        XCTAssertNoThrow(try decode(nested(BlockNoteTreeNode.maxNestingDepth - 1)))
        assertDecodingFails { try self.decode(nested(BlockNoteTreeNode.maxNestingDepth)) }
        assertDecodingFails { try self.decode(nested(1_000)) }
    }

    private func assertDecodingFails(
        _ body: () throws -> FormattedDocumentTree, file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try body()
            XCTFail("Expected a decoding error", file: file, line: line)
        } catch is DecodingError {
            // expected
        } catch {
            XCTFail("Expected DecodingError, got \(error)", file: file, line: line)
        }
    }
}

final class FormattedDocumentTreeClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private var documentID: UUID { UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")! }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func testRequestsTheJSONFormatOfTheFormattedContentRoute() async throws {
        let body = Data(
            #"{"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "content": [{"type": "checkListItem", "children": []}]}"#
                .utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        let tree = try await makeClient().formattedContentTree(documentID: documentID)

        XCTAssertEqual(tree.content, [BlockNoteTreeNode(type: "checkListItem")])
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/formatted-content/?content_format=json"
        )
    }

    /// The decode's refusal surfaces as the client's own `.decoding`, never a raw error.
    func testAnOverDeepTreeIsADecodingError() async {
        var node = #"{"type": "bulletListItem"}"#
        for _ in 0..<BlockNoteTreeNode.maxNestingDepth {
            node = #"{"type": "bulletListItem", "children": ["# + node + "]}"
        }
        let body = Data((#"{"content": ["# + node + "]}").utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        do {
            _ = try await makeClient().formattedContentTree(documentID: documentID)
            XCTFail("Expected decoding")
        } catch let error as DocsAPIError {
            guard case .decoding = error else { return XCTFail("Expected decoding, got \(error)") }
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
    }

    /// A server already proven to lack `formatted-content/` is not asked again: the tree read
    /// answers `.routeNotFound` without a request, and never tries the legacy route.
    func testAServerWithoutTheFormattedRouteIsNotAskedForTheTree() async throws {
        let log = RequestRecorder()
        let legacyBody = Data(
            #"{"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "body", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}"#
                .utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.path.contains("formatted-content") == true {
                return .init(
                    statusCode: 404, headers: ["Content-Type": "text/html"], body: Data("<html></html>".utf8),
                    error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: legacyBody, error: nil)
        }
        let client = makeClient()
        _ = try await client.formattedContent(documentID: documentID)  // detects the legacy server
        let before = log.count(ofMethod: "GET")

        do {
            _ = try await client.formattedContentTree(documentID: documentID)
            XCTFail("Expected routeNotFound")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .routeNotFound)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.count(ofMethod: "GET"), before, "no request at all")
    }

    /// A server that answered the tree read itself with a missing route or a 400 (a
    /// `formatted-content/` without the `json` format) is not asked again by this client.
    func testAServerThatRefusesTheJSONFormatIsAskedOnlyOnce() async {
        let refusals: [(status: Int, headers: [String: String], expected: DocsAPIError)] = [
            (404, ["Content-Type": "text/html"], .routeNotFound),
            (400, ["Content-Type": "application/json"], .server(statusCode: 400)),
        ]
        for refusal in refusals {
            let log = RequestRecorder()
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                return .init(
                    statusCode: refusal.status, headers: refusal.headers, body: Data(#"{"detail": "no"}"#.utf8),
                    error: nil)
            }
            let client = makeClient()

            for attempt in 0..<3 {
                do {
                    _ = try await client.formattedContentTree(documentID: documentID)
                    XCTFail("Expected a refusal")
                } catch let error as DocsAPIError {
                    // The first answer is the server's own; later ones are the memoized refusal.
                    XCTAssertEqual(error, attempt == 0 ? refusal.expected : .routeNotFound, "\(refusal.status)")
                } catch {
                    XCTFail("Expected DocsAPIError, got \(error)")
                }
            }
            XCTAssertEqual(log.count(ofMethod: "GET"), 1, "\(refusal.status): asked once, then never again")
            MockURLProtocol.reset()
        }
    }

    /// Nothing but a format refusal is memoized: a transient failure, or a 404 about the
    /// document itself, is asked again next time.
    func testOtherFailuresAreAskedAgain() async {
        let failures: [(status: Int, headers: [String: String])] = [
            (500, [:]),
            (503, [:]),
            (403, ["Content-Type": "application/json"]),
            (404, ["Content-Type": "application/json"]),
        ]
        for failure in failures {
            let log = RequestRecorder()
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                return .init(
                    statusCode: failure.status, headers: failure.headers, body: Data(#"{"detail": "x"}"#.utf8),
                    error: nil)
            }
            let client = makeClient()

            for _ in 0..<2 {
                _ = try? await client.formattedContentTree(documentID: documentID)
            }
            XCTAssertEqual(log.count(ofMethod: "GET"), 2, "\(failure.status) is asked again")
            MockURLProtocol.reset()
        }
    }
}
