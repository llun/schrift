# Networking Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `Core/Networking` layer's foundation — `DocsAPIError`, the Codable data model mirroring the backend's `ListDocumentSerializer`/`DocumentSerializer`, and `DocsAPIClient`'s generic request infrastructure (URLSession + async/await, CSRF header injection, status-code error mapping). This is the first plan outside the DesignSystem layer; it has no UI and no component catalog. Document/Sharing API endpoint methods and the edit-save temp-document flow are deliberately out of scope — a later plan builds on top of this foundation.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan, and the real backend's field/ability shape was cross-checked against `suitenumerique/docs`' `core/api/serializers.py`, `core/choices.py`, and `core/models.py` (`get_abilities`) on GitHub — not guessed from the design spec alone, since the spec's field list turned out to be a simplified subset of the real API surface. Key decisions:

- **`abilities` is decoded into a `DocumentAbilities` struct with named `Bool` fields (`update`, `partialUpdate`, `destroy`, `linkConfiguration`, `accessesManage`, `favorite`, `duplicate`, `childrenCreate`), not a raw `[String: Bool]` dictionary.** The real backend's `abilities` dict has ~25 keys and at least one (`link_select_options`) is not a `Bool` — it's a nested object. A `[String: Bool]` dictionary would throw a decoding error the first time it hit that key. `DocumentAbilities` only names the keys the app's v1 UI actually needs to gate on (matching the design spec's own examples plus `duplicate`/`children_create`, which map directly to endpoints in the spec's endpoint table); every other key, `Bool` or not, is silently ignored by `Decodable` since it's simply not in `CodingKeys`. This still honors the spec's "never hardcode permission logic client-side" rule — call sites read `document.abilities.update`, they don't derive it.
- **`DocumentAbilities`'s fields all default to `false` and use a custom `init(from:)` with `decodeIfPresent(...) ?? false` per key**, not relying on Swift's synthesized `Decodable` defaulting-from-stored-property-default-value behavior. That synthesis does not actually apply here — validated directly: a fixture with `"abilities": {}` threw `keyNotFound` against the synthesized initializer. The custom initializer was verified to fix this and is the only difference from the "obvious" first attempt.
- **`csrfToken(from cookies: [HTTPCookie]) -> String?` is a pure function over an array, not a method on `HTTPCookieStorage`.** Validated directly in a real XCTest/iOS-Simulator run (not a bare `swift` CLI script, which gave misleading results): `HTTPCookieStorage.shared` correctly round-trips a `setCookie`/`cookies(for:)` pair within a process, but a freshly-constructed `HTTPCookieStorage()` instance does not reliably retain a cookie even inside XCTest — it is not a fully-supported way to get an isolated cookie jar. Rather than depend on that fragile behavior for test isolation, `DocsAPIClient` takes an injectable `cookieProvider: () -> [HTTPCookie]` closure (production default reads `HTTPCookieStorage.shared`; tests supply a plain array). This makes CSRF logic fully unit-testable with zero dependency on real cookie storage in tests.
- **`DocsAPIClient` is an `actor`**, matching Swift 6 strict concurrency and the spec's async/await networking layer; it exposes `get<T: Decodable>(_:)` for reads and a lower-level `send<T: Decodable>(path:method:body:)` for mutating requests (used directly by later plans for POST/PATCH/DELETE).
- **`LinkReach` (already declared in `DesignSystem/Components/LinkReachPill.swift` as `enum LinkReach: String`) gains `Codable` conformance via an extension in `Document.swift`**, not by editing the original component file — Swift synthesizes `Codable` for a `String`-backed `RawRepresentable` enum via an extension declared anywhere in the same module, verified to compile. `DocumentRole` (backend `RoleChoices`: reader < commenter < editor < administrator < owner) and `LinkRole` (backend `LinkRoleChoices`: reader < commenter < editor) are new enums — two distinct types because the backend itself keeps them distinct (a link's role ceiling is lower than a member's).
- **Dates decode via a custom `JSONDecoder.docsAPI.dateDecodingStrategy`** trying `ISO8601DateFormatter` with fractional seconds first, then without — the real backend emits both formats depending on endpoint (confirmed via the fixture `created_at: "...123456Z"` vs `updated_at: "...00Z"`).
- **Optional fields match real Django model nullability**, checked against `core/models.py` rather than assumed: `title`/`excerpt` (`null=True`), `creator` (`null=True` — serializes as a bare UUID string via DRF's default `PrimaryKeyRelatedField`, not a nested user object), `user_role`/`computed_link_role`/`computed_link_reach` (`SerializerMethodField`s that can return `None`, e.g. `computed_link_role` is `None` when the computed reach is `restricted`). `link_reach`/`link_role`/`depth`/`numchild`/`path` are non-null (Django `CharField`/`IntegerField` defaults).

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies — `MockURLProtocol` (a `URLProtocol` subclass) is used for network mocking in tests, not a third-party library.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- Do not add `HTTPCookieStorage()` (a freshly-constructed, non-shared instance) anywhere in this plan's code or tests — it does not reliably retain cookies, even inside XCTest. Production code reads `HTTPCookieStorage.shared`; tests use the injectable `cookieProvider` closure and never touch real cookie storage at all.
- `DocumentAbilities`'s custom `init(from:)` is required, not a stylistic choice — do not "simplify" it back to relying on synthesized `Decodable` with default property values; that was tried and throws `keyNotFound` when a key is absent from the JSON.
- `MockURLProtocol` lives in `DocsIOSTests`, not the app target — it must never ship in `DocsIOS`.

## File Structure

```
DocsIOS/
└── Core/
    └── Networking/
        ├── DocsAPIError.swift                              — DocsAPIError, DocsAPIErrorMapper (Task 1)
        ├── DocumentRole.swift                               — DocumentRole, LinkRole (Task 2)
        ├── Document.swift                                    — JSONDecoder.docsAPI, LinkReach Codable extension, DocumentAbilities, Document (Task 2)
        ├── CSRF.swift                                        — csrfToken(from:) (Task 3)
        └── DocsAPIClient.swift                               — DocsAPIClient (Task 3)

DocsIOSTests/
└── Core/
    └── Networking/
        ├── DocsAPIErrorTests.swift                          — Task 1
        ├── DocumentRoleTests.swift                           — Task 2
        ├── DocumentDecodingTests.swift                       — Task 2
        ├── CSRFTests.swift                                   — Task 3
        ├── MockURLProtocol.swift                             — Task 3 (test helper, not itself a test case)
        └── DocsAPIClientTests.swift                          — Task 3
```

---

### Task 1: DocsAPIError

**Files:**
- Create: `DocsIOS/Core/Networking/DocsAPIError.swift`
- Test: `DocsIOSTests/Core/Networking/DocsAPIErrorTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `enum DocsAPIError: Error, Equatable` (cases: `sessionExpired`, `forbidden`, `notFound`, `rateLimited(retryAfter: TimeInterval?)`, `network(String)`, `decoding(String)`, `server(statusCode: Int)`), `enum DocsAPIErrorMapper { static func map(statusCode: Int, headers: [String: String]) -> DocsAPIError }` — both consumed by Task 3's `DocsAPIClient`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/DocsAPIErrorTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocsAPIErrorTests: XCTestCase {
    func testMapsUnauthorizedToSessionExpired() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 401, headers: [:]), .sessionExpired)
    }

    func testMapsForbiddenToForbidden() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 403, headers: [:]), .forbidden)
    }

    func testMapsNotFoundToNotFound() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 404, headers: [:]), .notFound)
    }

    func testMapsTooManyRequestsWithRetryAfter() {
        XCTAssertEqual(
            DocsAPIErrorMapper.map(statusCode: 429, headers: ["Retry-After": "30"]),
            .rateLimited(retryAfter: 30)
        )
    }

    func testMapsTooManyRequestsWithoutRetryAfter() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 429, headers: [:]), .rateLimited(retryAfter: nil))
    }

    func testMapsUnhandledStatusCodeToServer() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 500, headers: [:]), .server(statusCode: 500))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsAPIErrorTests`
Expected: FAIL — `cannot find 'DocsAPIErrorMapper' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Networking/DocsAPIError.swift`:
```swift
import Foundation

enum DocsAPIError: Error, Equatable {
    case sessionExpired
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case decoding(String)
    case server(statusCode: Int)
}

enum DocsAPIErrorMapper {
    static func map(statusCode: Int, headers: [String: String]) -> DocsAPIError {
        switch statusCode {
        case 401:
            return .sessionExpired
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 429:
            let retryAfter = headers["Retry-After"].flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(statusCode: statusCode)
        }
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsAPIErrorTests`
Expected: PASS — `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/DocsAPIError.swift DocsIOSTests/Core/Networking/DocsAPIErrorTests.swift
git commit -m "Add DocsAPIError type"
```

---

### Task 2: Codable models — DocumentRole, LinkRole, Document

**Files:**
- Create: `DocsIOS/Core/Networking/DocumentRole.swift`
- Create: `DocsIOS/Core/Networking/Document.swift`
- Test: `DocsIOSTests/Core/Networking/DocumentRoleTests.swift`
- Test: `DocsIOSTests/Core/Networking/DocumentDecodingTests.swift`

**Interfaces:**
- Consumes: `LinkReach` (from `DesignSystem/Components/LinkReachPill.swift`, an earlier plan).
- Produces: `enum DocumentRole: String, Codable`, `enum LinkRole: String, Codable`, `extension LinkReach: Codable`, `struct DocumentAbilities: Codable, Equatable`, `struct Document: Codable, Equatable, Identifiable`, `extension JSONDecoder { static let docsAPI: JSONDecoder }` — all consumed by Task 3's `DocsAPIClient` and by later plans' endpoint methods. `JSONDecoder.docsAPI` is defined here (not in Task 3) specifically so this task's own `DocumentDecodingTests` can use it without a forward reference to a file Task 3 hasn't created yet — every task in this plan must leave the full test target compiling and green, including this one.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/DocumentRoleTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocumentRoleTests: XCTestCase {
    func testDocumentRoleRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(DocumentRole.reader.rawValue, "reader")
        XCTAssertEqual(DocumentRole.commenter.rawValue, "commenter")
        XCTAssertEqual(DocumentRole.editor.rawValue, "editor")
        XCTAssertEqual(DocumentRole.administrator.rawValue, "administrator")
        XCTAssertEqual(DocumentRole.owner.rawValue, "owner")
    }

    func testLinkRoleRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(LinkRole.reader.rawValue, "reader")
        XCTAssertEqual(LinkRole.commenter.rawValue, "commenter")
        XCTAssertEqual(LinkRole.editor.rawValue, "editor")
    }
}
```

`DocsIOSTests/Core/Networking/DocumentDecodingTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocumentDecodingTests: XCTestCase {
    private let fixture = """
    {
        "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
        "title": "Q3 Planning",
        "excerpt": "Some excerpt text",
        "abilities": {
            "update": true,
            "partial_update": true,
            "destroy": false,
            "link_configuration": true,
            "accesses_manage": true,
            "favorite": true,
            "duplicate": true,
            "children_create": true,
            "link_select_options": {"restricted": null, "public": ["reader", "editor"]},
            "versions_list": true
        },
        "ancestors_link_reach": "restricted",
        "ancestors_link_role": null,
        "computed_link_reach": "authenticated",
        "computed_link_role": "reader",
        "created_at": "2026-01-15T10:30:00.123456Z",
        "creator": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
        "deleted_at": null,
        "depth": 1,
        "link_role": "reader",
        "link_reach": "restricted",
        "nb_accesses_ancestors": 2,
        "nb_accesses_direct": 3,
        "numchild": 0,
        "path": "0001",
        "updated_at": "2026-01-16T11:00:00Z",
        "user_role": "owner",
        "is_favorite": true
    }
    """.data(using: .utf8)!

    func testDecodesFullFixtureIgnoringUnmodeledKeys() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        XCTAssertEqual(document.title, "Q3 Planning")
        XCTAssertEqual(document.excerpt, "Some excerpt text")
        XCTAssertEqual(document.linkReach, .restricted)
        XCTAssertEqual(document.linkRole, .reader)
        XCTAssertEqual(document.computedLinkReach, .authenticated)
        XCTAssertEqual(document.computedLinkRole, .reader)
        XCTAssertTrue(document.isFavorite)
        XCTAssertEqual(document.depth, 1)
        XCTAssertEqual(document.numchild, 0)
        XCTAssertEqual(document.path, "0001")
        XCTAssertEqual(document.userRole, .owner)
        XCTAssertNotNil(document.creator)
    }

    func testDecodesAbilitiesIgnoringNonBooleanKeys() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        XCTAssertTrue(document.abilities.update)
        XCTAssertTrue(document.abilities.partialUpdate)
        XCTAssertFalse(document.abilities.destroy)
        XCTAssertTrue(document.abilities.linkConfiguration)
        XCTAssertTrue(document.abilities.accessesManage)
        XCTAssertTrue(document.abilities.favorite)
        XCTAssertTrue(document.abilities.duplicate)
        XCTAssertTrue(document.abilities.childrenCreate)
    }

    func testDecodesDatesWithAndWithoutFractionalSeconds() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        XCTAssertEqual(utc.component(.year, from: document.createdAt), 2026)
        XCTAssertEqual(utc.component(.minute, from: document.createdAt), 30)
        XCTAssertEqual(utc.component(.hour, from: document.updatedAt), 11)
    }

    func testDecodesNullTitleAndExcerptAsNil() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "title": null,
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": null,
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 0,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "0001",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": null,
            "is_favorite": false
        }
        """.data(using: .utf8)!

        let document = try JSONDecoder.docsAPI.decode(Document.self, from: json)
        XCTAssertNil(document.title)
        XCTAssertNil(document.excerpt)
        XCTAssertNil(document.creator)
        XCTAssertNil(document.userRole)
        XCTAssertNil(document.computedLinkReach)
        XCTAssertFalse(document.abilities.update)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentRoleTests -only-testing:DocsIOSTests/DocumentDecodingTests`
Expected: FAIL — `cannot find 'DocumentRole' in scope` / `cannot find 'docsAPI' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Networking/DocumentRole.swift`:
```swift
import Foundation

enum DocumentRole: String, Codable {
    case reader
    case commenter
    case editor
    case administrator
    case owner
}

enum LinkRole: String, Codable {
    case reader
    case commenter
    case editor
}
```

`DocsIOS/Core/Networking/Document.swift`:
```swift
import Foundation

extension JSONDecoder {
    static let docsAPI: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractionalSeconds.date(from: string) {
                return date
            }
            if let date = withoutFractionalSeconds.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO8601 date, got \(string)"
            )
        }
        return decoder
    }()
}

extension LinkReach: Codable {}

struct DocumentAbilities: Codable, Equatable {
    var update: Bool = false
    var partialUpdate: Bool = false
    var destroy: Bool = false
    var linkConfiguration: Bool = false
    var accessesManage: Bool = false
    var favorite: Bool = false
    var duplicate: Bool = false
    var childrenCreate: Bool = false

    enum CodingKeys: String, CodingKey {
        case update, partialUpdate, destroy, linkConfiguration, accessesManage, favorite, duplicate, childrenCreate
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        update = try container.decodeIfPresent(Bool.self, forKey: .update) ?? false
        partialUpdate = try container.decodeIfPresent(Bool.self, forKey: .partialUpdate) ?? false
        destroy = try container.decodeIfPresent(Bool.self, forKey: .destroy) ?? false
        linkConfiguration = try container.decodeIfPresent(Bool.self, forKey: .linkConfiguration) ?? false
        accessesManage = try container.decodeIfPresent(Bool.self, forKey: .accessesManage) ?? false
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        childrenCreate = try container.decodeIfPresent(Bool.self, forKey: .childrenCreate) ?? false
    }
}

struct Document: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String?
    var excerpt: String?
    let abilities: DocumentAbilities
    var linkReach: LinkReach
    var linkRole: LinkRole
    var computedLinkReach: LinkReach?
    var computedLinkRole: LinkRole?
    var isFavorite: Bool
    let depth: Int
    let numchild: Int
    let path: String
    let createdAt: Date
    let updatedAt: Date
    let userRole: DocumentRole?
    let creator: UUID?
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentRoleTests -only-testing:DocsIOSTests/DocumentDecodingTests`
Expected: PASS — `Executed 6 tests, with 0 failures` (2 DocumentRoleTests + 4 DocumentDecodingTests). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 89 tests, with 0 failures` (77 from the prior six plans + 6 DocsAPIError + 2 DocumentRoleTests + 4 DocumentDecodingTests).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/DocumentRole.swift DocsIOS/Core/Networking/Document.swift DocsIOSTests/Core/Networking/DocumentRoleTests.swift DocsIOSTests/Core/Networking/DocumentDecodingTests.swift
git commit -m "Add DocumentRole, LinkRole, and Document Codable models"
```

---

### Task 3: DocsAPIClient core

**Files:**
- Create: `DocsIOS/Core/Networking/CSRF.swift`
- Create: `DocsIOS/Core/Networking/DocsAPIClient.swift`
- Test: `DocsIOSTests/Core/Networking/CSRFTests.swift`
- Test: `DocsIOSTests/Core/Networking/MockURLProtocol.swift` (test helper, not a test case)
- Test: `DocsIOSTests/Core/Networking/DocsAPIClientTests.swift`

**Interfaces:**
- Consumes: `DocsAPIError`, `DocsAPIErrorMapper` (Task 1), `JSONDecoder.docsAPI` (Task 2, used directly by `send`'s decode step).
- Produces: `func csrfToken(from cookies: [HTTPCookie]) -> String?`, `actor DocsAPIClient` (`init(baseURL:session:cookieProvider:)`, `func get<T: Decodable>(_:) async throws -> T`, `func send<T: Decodable>(path:method:body:) async throws -> T`) — `get`/`send` are consumed by later plans' endpoint methods (document list/detail, content read/write, sharing).

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/CSRFTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class CSRFTests: XCTestCase {
    private func makeCookie(name: String, value: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: "docs.example.org", .path: "/", .name: name, .value: value])!
    }

    func testFindsCsrfTokenAmongMultipleCookies() {
        let cookies = [makeCookie(name: "docs_sessionid", value: "session-abc"), makeCookie(name: "csrftoken", value: "csrf-xyz")]
        XCTAssertEqual(csrfToken(from: cookies), "csrf-xyz")
    }

    func testReturnsNilWhenNoCsrfCookiePresent() {
        XCTAssertNil(csrfToken(from: [makeCookie(name: "docs_sessionid", value: "session-abc")]))
    }
}
```

`DocsIOSTests/Core/Networking/MockURLProtocol.swift` (not a test case — a shared test helper the other test files depend on):
```swift
import Foundation

final class MockURLProtocol: URLProtocol {
    struct Stub: @unchecked Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?
    }

    nonisolated(unsafe) static var stubHandler: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        guard let handler = MockURLProtocol.stubHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = handler(request)

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
```

`DocsIOSTests/Core/Networking/DocsAPIClientTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocsAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeClient(cookies: [HTTPCookie] = []) -> DocsAPIClient {
        DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { cookies }
        )
    }

    func testGetDecodesSuccessfulResponse() async throws {
        struct Config: Decodable, Equatable { let theme: String }
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: #"{"theme": "indigo"}"#.data(using: .utf8)!, error: nil)
        }

        let client = makeClient()
        let config: Config = try await client.get("config/")
        XCTAssertEqual(config, Config(theme: "indigo"))
    }

    func testUnauthorizedResponseThrowsSessionExpired() async {
        struct Config: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 401, headers: [:], body: Data(), error: nil)
        }

        let client = makeClient()
        do {
            let _: Config = try await client.get("users/me/")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRateLimitedResponseCarriesRetryAfter() async {
        struct Config: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 429, headers: ["Retry-After": "12"], body: Data(), error: nil)
        }

        let client = makeClient()
        do {
            let _: Config = try await client.get("documents/")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 12))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNetworkFailureMapsToNetworkError() async {
        struct Config: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let client = makeClient()
        do {
            let _: Config = try await client.get("config/")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            guard case .network = error else {
                return XCTFail("Expected .network, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testMutatingRequestAttachesCsrfTokenFromCookies() async throws {
        struct Empty: Decodable {}
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org",
            .path: "/",
            .name: "csrftoken",
            .value: "test-csrf-value",
        ])!
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let client = makeClient(cookies: [cookie])
        let _: Empty = try await client.send(path: "documents/1/", method: "PATCH", body: "{}".data(using: .utf8))

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-CSRFToken"), "test-csrf-value")
    }

    func testGetRequestDoesNotAttachCsrfToken() async throws {
        struct Empty: Decodable {}
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org",
            .path: "/",
            .name: "csrftoken",
            .value: "test-csrf-value",
        ])!
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let client = makeClient(cookies: [cookie])
        let _: Empty = try await client.get("documents/")

        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-CSRFToken"))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/CSRFTests`
Expected: FAIL — `cannot find 'csrfToken' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Networking/CSRF.swift`:
```swift
import Foundation

func csrfToken(from cookies: [HTTPCookie]) -> String? {
    cookies.first(where: { $0.name == "csrftoken" })?.value
}
```

`DocsIOS/Core/Networking/DocsAPIClient.swift`:
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

    func send<T: Decodable>(path: String, method: String, body: Data?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

        do {
            return try JSONDecoder.docsAPI.decode(T.self, from: data)
        } catch {
            throw DocsAPIError.decoding("\(error)")
        }
    }
}
```

- [ ] **Step 4: Regenerate and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 97 tests, with 0 failures` (77 from the prior six plans + 6 DocsAPIError + 2 DocumentRole + 4 DocumentDecoding + 2 CSRF + 6 DocsAPIClient = 97)

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/CSRF.swift DocsIOS/Core/Networking/DocsAPIClient.swift DocsIOSTests/Core/Networking/CSRFTests.swift DocsIOSTests/Core/Networking/MockURLProtocol.swift DocsIOSTests/Core/Networking/DocsAPIClientTests.swift
git commit -m "Add DocsAPIClient core with CSRF handling and error mapping"
```

## Self-Review Notes

- **Spec coverage:** Implements the "Networking & data model" section's `DocsAPIClient` foundation (base URL, generic request plumbing, CSRF header per the Authentication section's `X-CSRFToken` requirement) and the Codable model for the fields the spec's Networking section lists. Deliberately does not yet implement the endpoint table's 17 specific methods (document list/detail/create/update, content read/write, sharing, etc.) or the edit-save temp-document flow — both build directly on `DocsAPIClient.get`/`send` and are scoped to the next plan, per the design spec's build sequence (Networking foundation before endpoint methods).
- **Real-backend cross-check:** Rather than transcribing the design spec's field list as-is, the actual `suitenumerique/docs` backend source (`serializers.py`, `choices.py`, `models.py`) was fetched and read to confirm exact field nullability, the real (larger) shape of the `abilities` dict including its one non-`Bool` key, and the real `RoleChoices`/`LinkRoleChoices` string values. This caught two things the spec alone would not have: `abilities` cannot be decoded as `[String: Bool]` without a crash, and `computed_link_role`/`computed_link_reach`/`user_role`/`creator`/`title`/`excerpt` are all genuinely nullable.
- **Placeholder scan:** No TBD/TODO.
- **Type consistency:** `DocsAPIError`, `DocsAPIErrorMapper`, `DocumentRole`, `LinkRole`, `DocumentAbilities`, `Document`, `csrfToken`, `JSONDecoder.docsAPI`, and `DocsAPIClient` are each defined once. `Document` correctly reuses `LinkReach` from the DesignSystem layer (via a `Codable` extension, not a redeclaration) rather than introducing a second reach enum.
- **Cross-file validation:** All code in this plan (all three tasks, including the `DocumentAbilities` custom decoder, the `HTTPCookieStorage.shared`-vs-fresh-instance finding, and the full CSRF/error-mapping/decoding round trip through `MockURLProtocol`) was compiled and test-run end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 97 tests, with 0 failures`.
