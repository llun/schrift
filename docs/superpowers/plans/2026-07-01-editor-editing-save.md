# Editor Editing and Save Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the Editor screen (design spec Phase 7): editing and saving a document's content, using the temp-document conversion technique the design spec's Authentication section describes (serialize the edit → `POST /documents/` with a `file` field to create a temp document that gets converted to Yjs → `GET` the temp document's raw content → `PATCH` the real document's content with those bytes → `DELETE` the temp document, guaranteed even if an earlier step fails). Adds an Edit/Save/Cancel flow to `EditorView` and the underlying `DocsAPIClient` capability the app has never had: multipart file uploads and raw (non-JSON) response handling.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including a Simulator screenshot of the editing UI — and the exact request/response shapes were read directly from the real `suitenumerique/docs` backend source, not assumed. This plan surfaced more backend detail than any prior plan, and two of those details changed the design meaningfully:

- **`PATCH /documents/{id}/content/` and `GET /documents/{id}/content/` are not a matched pair on the same shape.** `@drf.decorators.action(detail=True, methods=["patch"])` defines `content` (PATCH only, JSON body `{"content": "<base64>"}`, confirmed via `DocumentContentSerializer`, returns `204 No Content`), and a *separate* `@content.mapping.get` decorator maps `content_retrieve` onto `GET` of the same URL — but `content_retrieve` "retrieve[s] the raw content file from s3 and stream[s] it": **the GET response is raw bytes, not JSON.** `DocsAPIClient` gained `getRawData(_:) async throws -> Data`, a sibling to `send`/`sendVoid` that returns the response body untouched rather than attempting `JSONDecoder.docsAPI.decode`.
- **`POST /documents/` with a `file` field is real, but it is `DocumentViewSet.perform_create` → `_apply_uploaded_file_conversion`, not the `ServerCreateDocumentSerializer` (a different, server-to-server-only endpoint requiring OIDC `sub`/`email` fields that looked superficially similar during research but is unrelated).** The real mechanism: the uploaded file's bytes are converted via the backend's `Converter` service using the file's `Content-Type` to pick the source format, and — importantly — **the uploaded file's *filename* becomes the created document's title** (`serializer.validated_data["title"] = uploaded_file.name`), so `createDocumentFromMarkdown` names the uploaded part `"{title}.md"` with `Content-Type: text/markdown` (confirmed against `mime_types.MARKDOWN = "text/markdown"`). `DocsAPIClient` gained multipart/form-data request support: `send`/`sendVoid`/`performRequest` all gained an optional `contentType` parameter (default `"application/json"`, preserving every existing caller's behavior unchanged) so this plan's multipart POST can override it to `"multipart/form-data; boundary=..."`.
- **Editing operates on the raw fetched Markdown string directly, not on a block-to-Markdown re-serialization of `EditorViewModel.blocks`.** The read-only Editor Screen plan already fetches and holds the raw Markdown (`FormattedDocumentContent.content`) before parsing it into blocks for display — this plan simply keeps that raw string around (`EditorViewModel.rawMarkdown`) and lets a native `TextEditor` bind to it directly. This sidesteps an entire category of bugs a real "blocks → Markdown" serializer would risk (imperfectly reconstructing original formatting/escaping) and is a direct, deliberate scope reduction from the design spec's block-level "floating formatting toolbar" description — justified by the design spec's own **Goal** wording, which says only "Edit a document's text and save changes back to the server," not block-level rich editing. The Non-goals section doesn't rule out richer editing, but nothing in the stated Goals requires it either, and the toolbar description itself hedges ("subset implemented based on what the native editor supports"). A plain-text Markdown editor is the responsible v1 scope; a richer block editor is a natural, isolated future enhancement (it would only need to change how `rawMarkdown` gets edited, not the save mechanism this plan builds).
- **The save orchestration's cleanup guarantee uses an explicit `do`/`catch` with `await`ed cleanup calls, not `defer`.** `defer` bodies in Swift are synchronous closures — they cannot `await` an async cleanup call directly, and wrapping the cleanup in an un-awaited `Task { }` inside `defer` would let the function return or rethrow *before* cleanup actually finishes, which is not a real guarantee. The validated pattern:
  ```swift
  func saveDocumentContent(documentID: UUID, title: String, markdown: String) async throws {
      let tempDocument = try await createDocumentFromMarkdown(title: title, markdown: markdown)
      do {
          let raw = try await rawContent(documentID: tempDocument.id)
          try await setContent(documentID: documentID, rawContent: raw)
      } catch {
          try? await deleteDocument(documentID: tempDocument.id)
          throw error
      }
      try? await deleteDocument(documentID: tempDocument.id)
  }
  ```
  Both the failure path and the success path `await` the DELETE before the function returns. Both use `try?` (not `try`) for the cleanup call specifically — a cleanup failure must never mask the *original* error (on the failure path) or turn a *successful* content save into a reported failure (on the success path) just because the best-effort temp-document cleanup itself didn't succeed.
- **A real Foundation/URLProtocol quirk was found and worked around in this plan's own tests, not in production code**: a mocked `URLRequest`'s `.httpBody` reads back as `nil` after passing through `MockURLProtocol` — the body is silently moved to `.httpBodyStream` instead. Tests that need to inspect a sent request's JSON body (this plan's PATCH-content test) read from `.httpBodyStream` with a small helper, falling back to `.httpBody` first for robustness. This is a test-infrastructure detail; production requests are sent via the real `URLSession`, which is unaffected.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies — multipart/form-data construction is hand-built (`multipartFormData`), not a networking package.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `DocsAPIClient.saveDocumentContent`'s temp-document cleanup (`deleteDocument`) must be attempted on both the failure path (inside the `catch`) and the success path (after the `do`/`catch`), and both calls must use `try?`, not `try` — see Architecture for why. Do not "simplify" this to a single `defer` block; that was tried and does not actually guarantee cleanup completes before the function returns (see Architecture).
- `getRawData(_:)` must not attempt JSON decoding — `GET /documents/{id}/content/` returns raw bytes, not JSON, confirmed against the real backend's `content_retrieve` action.
- The uploaded file's filename in `createDocumentFromMarkdown` must be `"{title}.md"` with `Content-Type: text/markdown` — the backend derives the created temp document's title from the filename, and derives the conversion source format from the Content-Type.
- Do not build a block-level rich-text editor or a floating formatting toolbar in this plan — editing is a plain `TextEditor` bound to the raw Markdown string, a deliberate, documented scope decision (see Architecture).
- Reuse `MockURLProtocol` from `DocsIOSTests/Core/Networking/MockURLProtocol.swift` for all new networking-dependent tests — do not create a second mock URLProtocol. Tests that need to inspect a mocked request's JSON body must read `.httpBodyStream` as a fallback when `.httpBody` is `nil` (see Architecture) — a small local test helper is provided in this plan's Task 1 test file.

## File Structure

```
DocsIOS/
├── Core/
│   └── Networking/
│       ├── DocsAPIClient.swift                               — MODIFY: add getRawData, contentType parameter on send/sendVoid (Task 1)
│       └── DocumentSave.swift                                 — multipartFormData, DocsAPIClient.createDocumentFromMarkdown/rawContent/setContent/deleteDocument/saveDocumentContent (Task 1)
└── Features/
    └── Editor/
        ├── EditorViewModel.swift                               — MODIFY: rawMarkdown, isEditing, isSaving, startEditing/cancelEditing/save (Task 2)
        └── EditorView.swift                                    — MODIFY: TextEditor editing mode, dynamic NavBar trailing actions (Task 3)

DocsIOSTests/
├── Core/
│   └── Networking/
│       └── DocumentSaveTests.swift                            — Task 1
└── Features/
    └── Editor/
        └── EditorViewModelTests.swift                          — MODIFY: append editing/saving tests (Task 2)
```

---

### Task 1: DocsAPIClient save orchestration

**Files:**
- Modify: `DocsIOS/Core/Networking/DocsAPIClient.swift`
- Create: `DocsIOS/Core/Networking/DocumentSave.swift`
- Test: `DocsIOSTests/Core/Networking/DocumentSaveTests.swift`

**Interfaces:**
- Consumes: `Document`, `DocsAPIError`, `MockURLProtocol` (earlier plans).
- Produces: `DocsAPIClient.getRawData(_:) async throws -> Data`, `DocsAPIClient.send`/`sendVoid` gain an optional `contentType` parameter, `func multipartFormData(boundary:fieldName:filename:contentType:content:) -> Data`, `DocsAPIClient.createDocumentFromMarkdown(title:markdown:) async throws -> Document`, `.rawContent(documentID:) async throws -> Data`, `.setContent(documentID:rawContent:) async throws`, `.deleteDocument(documentID:) async throws`, `.saveDocumentContent(documentID:title:markdown:) async throws` — the last one consumed by Task 2's `EditorViewModel`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/DocumentSaveTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class MultipartFormDataTests: XCTestCase {
    func testBuildsExpectedWireFormat() throws {
        let body = multipartFormData(
            boundary: "TestBoundary",
            fieldName: "file",
            filename: "Doc.md",
            contentType: "text/markdown",
            content: "# Hi".data(using: .utf8)!
        )
        let string = String(data: body, encoding: .utf8)!
        XCTAssertEqual(string, "--TestBoundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Doc.md\"\r\nContent-Type: text/markdown\r\n\r\n# Hi\r\n--TestBoundary--\r\n")
    }
}

private final class RequestLog: @unchecked Sendable {
    var requests: [URLRequest] = []
}

private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let bytesRead = stream.read(&buffer, maxLength: bufferSize)
        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)
        } else {
            break
        }
    }
    return data
}

final class DocumentSaveClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let realDocumentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let tempDocumentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private func tempDocumentFixture() -> Data {
        """
        {
            "id": "22222222-2222-4222-8222-222222222222",
            "title": "Doc.md",
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

    func testCreateDocumentFromMarkdownSendsMultipartRequest() async throws {
        let fixture = tempDocumentFixture()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: fixture, error: nil) }
        let client = makeClient()

        let document = try await client.createDocumentFromMarkdown(title: "Doc", markdown: "# Hi")

        XCTAssertEqual(document.id, tempDocumentID)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/")
        let contentType = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
    }

    func testRawContentReturnsUndecodedBytes() async throws {
        let rawBytes = Data([0x01, 0x02, 0x03, 0xFF])
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: rawBytes, error: nil) }
        let client = makeClient()

        let result = try await client.rawContent(documentID: tempDocumentID)

        XCTAssertEqual(result, rawBytes)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/22222222-2222-4222-8222-222222222222/content/")
    }

    func testSetContentSendsBase64EncodedJSONBody() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let rawBytes = Data([0x01, 0x02, 0x03])

        try await client.setContent(documentID: realDocumentID, rawContent: rawBytes)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/content/")
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["content"], rawBytes.base64EncodedString())
    }

    func testDeleteDocumentSendsDeleteRequest() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()

        try await client.deleteDocument(documentID: tempDocumentID)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/22222222-2222-4222-8222-222222222222/")
    }

    func testSaveDocumentContentHappyPathCallsAllFourStepsInOrder() async throws {
        let fixture = tempDocumentFixture()
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: fixture, error: nil)
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, headers: [:], body: Data([0xAA, 0xBB]), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        try await client.saveDocumentContent(documentID: realDocumentID, title: "Doc", markdown: "# Hi")

        XCTAssertEqual(log.requests.map(\.httpMethod), ["POST", "GET", "PATCH", "DELETE"])
        XCTAssertTrue(log.requests[1].url?.absoluteString.contains("22222222") ?? false)
        XCTAssertTrue(log.requests[2].url?.absoluteString.contains("11111111") ?? false)
        XCTAssertTrue(log.requests[3].url?.absoluteString.contains("22222222") ?? false)
    }

    func testSaveDocumentContentDeletesTempDocumentEvenWhenGetContentFails() async throws {
        let fixture = tempDocumentFixture()
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: fixture, error: nil)
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        do {
            try await client.saveDocumentContent(documentID: realDocumentID, title: "Doc", markdown: "# Hi")
            XCTFail("Expected error to be thrown")
        } catch {
            // expected
        }

        XCTAssertEqual(log.requests.map(\.httpMethod), ["POST", "GET", "DELETE"])
    }

    func testSaveDocumentContentDeletesTempDocumentEvenWhenPatchContentFails() async throws {
        let fixture = tempDocumentFixture()
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: fixture, error: nil)
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, headers: [:], body: Data([0xAA]), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        do {
            try await client.saveDocumentContent(documentID: realDocumentID, title: "Doc", markdown: "# Hi")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        }

        XCTAssertEqual(log.requests.map(\.httpMethod), ["POST", "GET", "PATCH", "DELETE"])
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/MultipartFormDataTests -only-testing:DocsIOSTests/DocumentSaveClientTests`
Expected: FAIL — `cannot find 'multipartFormData' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Networking/DocsAPIClient.swift` — replace entirely with:
```swift
import Foundation

actor DocsAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let cookieProvider: @Sendable () -> [HTTPCookie]

    init(
        baseURL: URL,
        session: URLSession = .shared,
        cookieProvider: (@Sendable () -> [HTTPCookie])? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieProvider = cookieProvider ?? { HTTPCookieStorage.shared.cookies(for: baseURL) ?? [] }
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "GET", body: nil)
    }

    func getRawData(_ path: String) async throws -> Data {
        try await performRequest(path: path, method: "GET", body: nil, contentType: nil)
    }

    func send<T: Decodable>(path: String, method: String, body: Data?, contentType: String? = "application/json") async throws -> T {
        let data = try await performRequest(path: path, method: method, body: body, contentType: contentType)
        do {
            return try JSONDecoder.docsAPI.decode(T.self, from: data)
        } catch {
            throw DocsAPIError.decoding("\(error)")
        }
    }

    func sendVoid(path: String, method: String, body: Data?, contentType: String? = "application/json") async throws {
        _ = try await performRequest(path: path, method: method, body: body, contentType: contentType)
    }

    private func performRequest(path: String, method: String, body: Data?, contentType: String?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DocsAPIError.network("Invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let body {
            request.httpBody = body
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        if method != "GET" {
            if let token = csrfToken(from: cookieProvider()) {
                request.setValue(token, forHTTPHeaderField: "X-CSRFToken")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DocsAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DocsAPIError.network("Response was not an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            throw DocsAPIErrorMapper.map(statusCode: httpResponse.statusCode, headers: headers)
        }

        return data
    }
}
```

`DocsIOS/Core/Networking/DocumentSave.swift`:
```swift
import Foundation

func multipartFormData(boundary: String, fieldName: String, filename: String, contentType: String, content: Data) -> Data {
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
    body.append(content)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    return body
}

extension DocsAPIClient {
    func createDocumentFromMarkdown(title: String, markdown: String) async throws -> Document {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = multipartFormData(
            boundary: boundary,
            fieldName: "file",
            filename: "\(title).md",
            contentType: "text/markdown",
            content: markdown.data(using: .utf8) ?? Data()
        )
        return try await send(
            path: "documents/",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    func rawContent(documentID: UUID) async throws -> Data {
        try await getRawData("documents/\(documentID.uuidString.lowercased())/content/")
    }

    func setContent(documentID: UUID, rawContent: Data) async throws {
        let body = try JSONEncoder().encode(["content": rawContent.base64EncodedString()])
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/content/", method: "PATCH", body: body)
    }

    func deleteDocument(documentID: UUID) async throws {
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/", method: "DELETE", body: nil)
    }

    func saveDocumentContent(documentID: UUID, title: String, markdown: String) async throws {
        let tempDocument = try await createDocumentFromMarkdown(title: title, markdown: markdown)
        do {
            let raw = try await rawContent(documentID: tempDocument.id)
            try await setContent(documentID: documentID, rawContent: raw)
        } catch {
            try? await deleteDocument(documentID: tempDocument.id)
            throw error
        }
        try? await deleteDocument(documentID: tempDocument.id)
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/MultipartFormDataTests -only-testing:DocsIOSTests/DocumentSaveClientTests`
Expected: PASS — `Executed 8 tests, with 0 failures` (1 multipart format + 7 client). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 189 tests, with 0 failures` (181 from the prior eleven plans + 8 new). This full-suite run also proves the `contentType` parameter addition to `send`/`sendVoid` is backward compatible with every existing caller.

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/DocsAPIClient.swift DocsIOS/Core/Networking/DocumentSave.swift DocsIOSTests/Core/Networking/DocumentSaveTests.swift
git commit -m "Add DocsAPIClient save orchestration with guaranteed temp-document cleanup"
```

---

### Task 2: EditorViewModel editing/saving state

**Files:**
- Modify: `DocsIOS/Features/Editor/EditorViewModel.swift`
- Modify: `DocsIOSTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Consumes: `DocsAPIClient.saveDocumentContent` (Task 1).
- Produces: `EditorViewModel` gains `rawMarkdown: String`, `isEditing: Bool`, `isSaving: Bool`, `func startEditing()`, `func cancelEditing()`, `func save() async` — consumed by Task 3's `EditorView`.

- [ ] **Step 1: Write the failing tests**

Append to `DocsIOSTests/Features/Editor/EditorViewModelTests.swift` (the existing four `testLoad*` tests stay unchanged; add these before the file's closing `}`):
```swift
    func testStartEditingSetsIsEditingTrue() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertTrue(viewModel.isEditing)
    }

    func testCancelEditingRevertsUnsavedChanges() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.rawMarkdown = "Edited but not saved"

        viewModel.cancelEditing()

        XCTAssertEqual(viewModel.rawMarkdown, "Original text")
        XCTAssertFalse(viewModel.isEditing)
    }

    func testSaveSuccessUpdatesBlocksAndExitsEditingMode() async {
        let viewModel = makeViewModel()
        let loadBody = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        let tempDocBody = """
        {"id": "22222222-2222-4222-8222-222222222222", "title": "Doc.md", "excerpt": null, "abilities": {}, "computed_link_reach": "restricted", "computed_link_role": null, "created_at": "2026-01-15T10:30:00Z", "creator": null, "depth": 1, "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "0002", "updated_at": "2026-01-15T10:30:00Z", "user_role": "owner", "is_favorite": false}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            switch request.httpMethod {
            case "POST": return .init(statusCode: 201, headers: [:], body: tempDocBody, error: nil)
            case "GET" where request.url?.absoluteString.contains("formatted-content") == true:
                return .init(statusCode: 200, headers: [:], body: loadBody, error: nil)
            case "GET": return .init(statusCode: 200, headers: [:], body: Data([0xAA]), error: nil)
            default: return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.rawMarkdown = "# New Heading"

        await viewModel.save()

        XCTAssertEqual(viewModel.blocks, [.heading(level: 1, text: "New Heading")])
        XCTAssertFalse(viewModel.isEditing)
        XCTAssertFalse(viewModel.isSaving)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSaveFailureSetsErrorMessageAndStaysInEditingMode() async {
        let viewModel = makeViewModel()
        let loadBody = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("formatted-content") == true {
                return .init(statusCode: 200, headers: [:], body: loadBody, error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.rawMarkdown = "# New Heading"

        await viewModel.save()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertFalse(viewModel.isSaving)
    }
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/EditorViewModelTests`
Expected: FAIL — `value of type 'EditorViewModel' has no member 'startEditing'`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Editor/EditorViewModel.swift` — replace entirely with:
```swift
import Foundation

@MainActor
@Observable
final class EditorViewModel {
    var title: String
    var blocks: [MarkdownBlock] = []
    var rawMarkdown: String = ""
    var isEditing = false
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private let client: DocsAPIClient
    private let documentID: UUID
    private var savedMarkdown: String = ""

    init(client: DocsAPIClient, documentID: UUID, title: String) {
        self.client = client
        self.documentID = documentID
        self.title = title
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            if let fetchedTitle = formatted.title {
                title = fetchedTitle
            }
            savedMarkdown = formatted.content ?? ""
            rawMarkdown = savedMarkdown
            blocks = parseMarkdownBlocks(savedMarkdown)
        } catch {
            errorMessage = "Couldn't load this document. Pull to refresh to try again."
        }
        isLoading = false
    }

    func startEditing() {
        isEditing = true
        errorMessage = nil
    }

    func cancelEditing() {
        rawMarkdown = savedMarkdown
        isEditing = false
        errorMessage = nil
    }

    func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await client.saveDocumentContent(documentID: documentID, title: title, markdown: rawMarkdown)
            savedMarkdown = rawMarkdown
            blocks = parseMarkdownBlocks(rawMarkdown)
            isEditing = false
        } catch {
            errorMessage = "Couldn't save changes. Please try again."
        }
        isSaving = false
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/EditorViewModelTests`
Expected: PASS — `Executed 8 tests, with 0 failures` (4 existing `testLoad*` + 4 new). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 193 tests, with 0 failures` (189 from Task 1 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Editor/EditorViewModel.swift DocsIOSTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Add editing and saving state to EditorViewModel"
```

---

### Task 3: EditorView editing UI

**Files:**
- Modify: `DocsIOS/Features/Editor/EditorView.swift`

**Interfaces:**
- Consumes: `EditorViewModel`'s new editing/saving properties (Task 2).
- Produces: no new public types — `EditorView`'s body now switches between the existing read-only `MarkdownBlockView` rendering and a `TextEditor` bound to `viewModel.rawMarkdown` based on `viewModel.isEditing`, and its `NavBar` trailing actions switch between Share/Edit/Options and Cancel/Save.

This task has no XCTest steps — see the Home Screen and Editor Screen plans' precedent and this plan's Global Constraints for why (UI glue verified by build-check and a Simulator screenshot, not XCTest).

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Editor/EditorView.swift` — replace entirely with:
```swift
import SwiftUI

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    var onBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: viewModel.title,
                backTitle: "Docs",
                onBack: onBack,
                trailingActions: trailingActions
            )

            HStack(spacing: DocsSpacing.spaceXS) {
                Text(viewModel.title)
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
                LinkReachPill(reach: reach)
                Spacer()
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.top, DocsSpacing.spaceSM)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .padding(.horizontal, DocsSpacing.gutter)
            }

            if viewModel.isLoading {
                ProgressView()
                    .padding(DocsSpacing.spaceBase)
                Spacer()
            } else if viewModel.isEditing {
                TextEditor(text: $viewModel.rawMarkdown)
                    .font(DocsFont.body)
                    .padding(.horizontal, DocsSpacing.spaceXS)
                    .disabled(viewModel.isSaving)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                        ForEach(Array(viewModel.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                        }
                    }
                    .padding(DocsSpacing.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
    }

    private var trailingActions: [NavBarAction] {
        if viewModel.isEditing {
            return [
                NavBarAction(systemImage: "xmark", label: "Cancel", action: { viewModel.cancelEditing() }),
                NavBarAction(systemImage: "checkmark", label: "Save", action: { Task { await viewModel.save() } }),
            ]
        }
        return [
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {}),
            NavBarAction(systemImage: "pencil", label: "Edit", action: { viewModel.startEditing() }),
            NavBarAction(systemImage: "ellipsis", label: "Options", action: {}),
        ]
    }
}

#Preview {
    EditorView(
        viewModel: EditorViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            title: "Q3 Planning"
        ),
        reach: .restricted
    )
}
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 193 tests, with 0 failures` (no new tests in this task; confirms Task 3's changes didn't regress anything).

- [ ] **Step 3: Visually verify in the Simulator**

Temporarily point `RootView.body` at an `EditorView` constructed with a view model whose `isEditing` is forced `true` and `rawMarkdown` pre-populated with sample Markdown (matching this plan's own validation — see Architecture), screenshot, then revert `RootView.swift` back to the real auth-gated version **before committing**:

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'
APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/DocsIOS-*/Build/Products/Debug-iphonesimulator/DocsIOS.app | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted dev.llun.DocsIOS
xcrun simctl io booted screenshot /tmp/editor-editing-verify.png
```
Expected: the screenshot shows the NavBar's Cancel (X) and Save (checkmark) icons in place of Share/Edit/Options, and a `TextEditor` displaying and allowing editing of the pre-populated raw Markdown text.

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Editor/EditorView.swift
git commit -m "Add editing UI to EditorView"
```

## Self-Review Notes

- **Spec coverage:** Implements the design spec's Phase 7 ("Editor screen — editing + save") and the full 5-step temp-document conversion technique from the Authentication/Editing section, including its explicitly required test ("verifying the create → fetch-content → patch → delete call sequence, including the delete happening even if a later step fails"). Deliberately implements plain-text Markdown editing rather than block-level rich editing with a floating formatting toolbar — a documented, spec-informed scope decision (see Architecture), not an oversight.
- **Real-backend cross-check:** The exact shapes and mechanics of `GET`/`PATCH /documents/{id}/content/` (a mismatched pair — PATCH is JSON, GET is raw bytes) and `POST /documents/` with a `file` field (filename becomes the created document's title; the correct serializer is `perform_create`'s upload-conversion path, not the superficially similar `ServerCreateDocumentSerializer`) were both read directly from the real `suitenumerique/docs` backend source. Both findings changed the implementation from what a spec-only reading would have produced.
- **Placeholder scan:** No TBD/TODO. Share/Options buttons remain the pre-existing placeholders from the read-only Editor Screen plan, unchanged by this plan.
- **Type consistency:** `multipartFormData`, `DocsAPIClient.getRawData/createDocumentFromMarkdown/rawContent/setContent/deleteDocument/saveDocumentContent` are each defined once. `EditorViewModel`'s new editing state reuses the existing `blocks`/`parseMarkdownBlocks` rather than introducing a second content representation for the read path.
- **Cross-file validation:** All code in this plan (all three tasks, including the guaranteed-cleanup save orchestration verified under two distinct partial-failure scenarios, the multipart wire-format byte-for-byte test, the `.httpBody`-vs-`.httpBodyStream` test-infrastructure fix, and the Simulator screenshot of the editing UI) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 193 tests, with 0 failures` plus a passing Simulator screenshot of the Editor screen's editing mode.
