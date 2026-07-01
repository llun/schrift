# Home Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Home screen (design spec Phase 5): document list wired to real list/search/favorite APIs, with a NavBar (large title "Docs", subtitle = server host), SearchField, SegmentedControl (All/Shared/Pinned), Pinned + Recent sections of `DocRow`, and a TabBar. Adds the Document-list endpoint methods `DocsAPIClient` has never had, fixes a real URL-construction bug found while adding them, and resolves the accessibility-traits item carried forward from Plan 6's final review (DocRow becomes this screen's primary interactive element). Wires `RootView` to show this screen whenever `SessionStore.isAuthenticated` is true, replacing the placeholder that has stood in since Plan 1.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including a real build+run+screenshot in the iOS Simulator with both a successful-looking and a failed-network-call state, and cross-checking the exact endpoint contract against the real `suitenumerique/docs` backend source (`viewsets.py`, `filters.py`) rather than trusting the design spec's endpoint table alone. Key decisions:

- **`DocsAPIClient.send`/`get` had a real, previously-undetected URL-construction bug: `baseURL.appendingPathComponent(path)` percent-encodes a literal `?` into `%3F`, silently corrupting any path that includes a query string.** Verified directly: `base.appendingPathComponent("documents/?is_favorite=true")` produces `.../documents/%3Fis_favorite=true` — a URL Django would treat as one opaque path segment, not a filtered list request. Nothing in the prior Networking Foundation plan's endpoints used a query string, so this went unnoticed until this plan's list/search endpoints needed one. Fixed by switching to `URL(string: path, relativeTo: baseURL)`, which correctly treats `?` as a query delimiter while producing byte-identical URLs for the existing query-free paths (verified for both cases). This is a one-line, backward-compatible fix to already-merged code — Task 1 must apply it and confirm the full existing `DocsAPIClientTests` suite (from the Networking Foundation plan) still passes unchanged.
- **`DocsAPIClient` gained `sendVoid(path:method:body:) async throws` for endpoints with no meaningful response body to decode** — specifically the favorite toggle, which returns `200`/`201` with a small `{"detail": "..."}` object on success or `204 No Content` (empty body) on unfavorite. Attempting to `JSONDecoder.decode` an empty body throws, so a decode-free path was necessary. `send`/`sendVoid` were refactored to share a private `performRequest` that does everything except decoding — validated by confirming the full existing test suite still passes after the refactor.
- **`PaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable`** mirrors the real backend's DRF `PageNumberPagination` response shape (`count`/`next`/`previous`/`results`), confirmed against `Pagination(PageNumberPagination)` in `viewsets.py` (`page_size_query_param = "page_size"`, default `page` param, `max_page_size = 200`). The explicit `Sendable` constraint on `T` is required, not decorative — without it, a plain `PaginatedResponse<Document>` return value from an `actor`-isolated method fails to compile under this project's Swift 6 strict concurrency settings.
- **Document list/search/favorite query parameter names were taken from the real `ListDocumentFilter`/`DocumentFilter` classes in `filters.py`, not guessed**: `is_favorite`, `is_creator_me`, `title`, `q` (search), `ordering` (DRF `OrderingFilter`, fields `created_at`/`updated_at`/`title`). `GET /documents/favorite_list/` and `GET /documents/search/?q=` both return the same paginated shape as the list endpoint (confirmed in `viewsets.py`). `POST`/`DELETE /documents/{id}/favorite/` is a detail route with no request body.
- **The SegmentedControl's "All/Shared/Pinned" semantics are a documented interpretation, not something the design spec or backend spells out directly**: the real backend's `ListDocumentFilter` only exposes `is_creator_me` and `is_favorite` as boolean filters — there is no server-side "shared with me" flag. This plan maps **All → no filter, Shared → `is_creator_me=false`, Pinned → `is_favorite=true`**, and additionally shows a "Pinned" section (from `favorite_list`) above the filtered "Recent" list whenever the current filter is not already "Pinned" and at least one favorite exists (`shouldShowPinnedSection`) — avoiding a redundant "Pinned" section while the Pinned tab itself is selected. If the actual UX intent differs once the original design mockups are available, this mapping is a single, isolated function (`homeFilterQueryParameters`) to change.
- **`HomeViewModel` is `@MainActor`**, matching `ConnectViewModel`'s precedent from the Connect Screen plan — the same "an `@Observable` class is not implicitly `@MainActor`" constraint applies here since `load()`/`search()`/`toggleFavorite()` are all `async`.
- **A real gap was found and fixed during this plan's own Simulator verification**: the first `HomeView` draft had no loading indicator and never displayed `viewModel.errorMessage` — a failed network call rendered as a silently blank screen. This is not "polish" (Phase 10 in the design spec's build sequence, which covers *styling* empty/loading/error states) but a baseline correctness gap — the screen must never fail silently. Fixed by adding a minimal (unstyled) `ProgressView` and an inline error `Text`; confirmed via two Simulator screenshots (one before the fix showing a blank body under a failed load, one after showing "Couldn't load documents. Pull to refresh to try again.").
- **Favorite/pin toggling is reachable from `DocRow`'s existing trailing "more options" button**, via a `.confirmationDialog` offering "Pin"/"Unpin" (label depends on `document.isFavorite`) that calls `HomeViewModel.toggleFavorite`. The design spec's build sequence explicitly calls Home "wired to real document list/search/favorite APIs," so favorite toggling must be reachable from this screen now, not deferred to the Options sheet plan (Phase 8) — but inventing a new gesture (e.g. swipe actions, which require a real SwiftUI `List` and would be inconsistent with this project's custom `ListSection`/`ListRow`/`DocRow` component vocabulary) ahead of that dedicated plan was avoided in favor of reusing the row's existing affordance.
- **A real, subtle Foundation quirk was found and worked around in this plan's own tests, not in production code**: `URLRequest.url?.path` silently drops a trailing slash (`/api/v1.0/documents/favorite` instead of `/api/v1.0/documents/favorite_list/`), while `.absoluteString` does not. This only affects test assertions that inspect a mocked request's URL — production requests are unaffected (confirmed: `.absoluteString`, which is what actually gets sent over the wire, retains the trailing slash correctly). Tests in this plan assert against `.absoluteString`, never `.path`, when the exact path matters.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `DocsAPIClient`'s URL construction must use `URL(string: path, relativeTo: baseURL)`, never `baseURL.appendingPathComponent(path)` — the latter percent-encodes `?` and breaks every query-parameterized endpoint. Do not revert this as part of any later cleanup.
- `PaginatedResponse<T>` must constrain `T: Decodable & Sendable` and itself conform to `Sendable` — omitting this fails to compile wherever an actor-isolated `DocsAPIClient` method returns it.
- Test assertions on a mocked request's target path must use `request.url?.absoluteString`, never `request.url?.path` — `.path` silently drops trailing slashes in this Foundation version, `.absoluteString` does not.
- `HomeViewModel` must be `@MainActor`; any test file constructing one must also be `@MainActor` (same constraint validated in the Connect Screen plan for `ConnectViewModel`).
- `HomeView` must render both a loading state (`viewModel.isLoading`) and an error state (`viewModel.errorMessage`) — a failed load must never render as a silently blank screen. Full visual polish of these states is out of scope (Phase 10 of the design spec's build sequence); their presence is not.
- Reuse `MockURLProtocol` from `DocsIOSTests/Core/Networking/MockURLProtocol.swift` for all new networking-dependent tests in this plan — do not create a second mock URLProtocol.
- Do not build the Options sheet, Share sheet, or a real Editor screen in this plan — `DocRow.onOpen` in `HomeView` is a no-op placeholder until the Editor screen plan exists.

## File Structure

```
DocsIOS/
├── App/
│   └── RootView.swift                                       — MODIFY: show HomeView when authenticated (Task 4)
├── Core/
│   └── Networking/
│       ├── DocsAPIClient.swift                               — MODIFY: fix URL construction, add sendVoid (Task 1)
│       ├── PaginatedResponse.swift                           — PaginatedResponse (Task 1)
│       └── DocumentEndpoints.swift                           — documentsListPath/documentsSearchPath, DocsAPIClient document endpoints (Task 1)
├── DesignSystem/
│   └── Components/
│       ├── DocRow.swift                                       — MODIFY: docRowAccessibilityLabel, accessibility modifiers (Task 2)
│       ├── LinkReachPill.swift                                — MODIFY: accessibility modifiers (Task 2)
│       ├── ShareMemberRow.swift                                — MODIFY: accessibility modifiers on role button (Task 2)
│       ├── SegmentedControl.swift                              — MODIFY: accessibility traits per segment (Task 2)
│       └── TabBar.swift                                        — MODIFY: accessibility label/traits per item (Task 2)
└── Features/
    └── Home/
        ├── HomeFilter.swift                                   — HomeFilter, homeFilterQueryParameters, shouldShowPinnedSection (Task 3)
        ├── HomeViewModel.swift                                 — HomeViewModel (Task 3)
        └── HomeView.swift                                      — documentRowDate, HomeView (Task 4)

DocsIOSTests/
├── Core/
│   └── Networking/
│       └── DocumentEndpointsTests.swift                       — Task 1
├── DesignSystem/
│   └── Components/
│       └── DocRowTests.swift                                  — MODIFY: add accessibility label tests (Task 2)
└── Features/
    └── Home/
        ├── HomeFilterTests.swift                               — Task 3
        └── HomeViewModelTests.swift                            — Task 3
```

---

### Task 1: DocsAPIClient URL fix + document endpoints

**Files:**
- Modify: `DocsIOS/Core/Networking/DocsAPIClient.swift`
- Create: `DocsIOS/Core/Networking/PaginatedResponse.swift`
- Create: `DocsIOS/Core/Networking/DocumentEndpoints.swift`
- Test: `DocsIOSTests/Core/Networking/DocumentEndpointsTests.swift`

**Interfaces:**
- Consumes: `Document` (Networking Foundation plan), `MockURLProtocol` (Networking Foundation plan's test helper).
- Produces: `struct PaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable`, `func documentsListPath(...) -> String`, `func documentsSearchPath(query:) -> String`, `DocsAPIClient.sendVoid(path:method:body:)`, `DocsAPIClient.listDocuments(...)`, `.favoriteDocuments()`, `.searchDocuments(query:)`, `.setFavorite(documentID:isFavorite:)` — all consumed by Task 3's `HomeViewModel`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/DocumentEndpointsTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocumentEndpointsPathTests: XCTestCase {
    func testListPathWithNoFiltersHasNoQueryString() {
        XCTAssertEqual(documentsListPath(), "documents/")
    }

    func testListPathWithIsFavoriteTrue() {
        XCTAssertEqual(documentsListPath(isFavorite: true), "documents/?is_favorite=true")
    }

    func testListPathWithMultipleFilters() {
        let path = documentsListPath(isFavorite: false, title: "roadmap", ordering: "-updated_at", page: 2, pageSize: 20)
        XCTAssertTrue(path.hasPrefix("documents/?"))
        XCTAssertTrue(path.contains("is_favorite=false"))
        XCTAssertTrue(path.contains("title=roadmap"))
        XCTAssertTrue(path.contains("ordering=-updated_at") || path.contains("ordering=-updated_at".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!))
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
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
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
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil) }
        let client = makeClient()

        let page = try await client.listDocuments(isFavorite: true, ordering: "-updated_at")

        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page.results.first?.title, "Q3 Planning")
        let requestedURL = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(requestedURL.hasPrefix("https://docs.example.org/api/v1.0/documents/?"))
        XCTAssertTrue(requestedURL.contains("is_favorite=true"))
    }

    func testFavoriteDocumentsRequestsFavoriteListPath() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil) }
        let client = makeClient()

        let page = try await client.favoriteDocuments()

        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/favorite_list/")
    }

    func testSearchDocumentsEncodesQueryInURL() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil) }
        let client = makeClient()

        _ = try await client.searchDocuments(query: "Q3 Planning")

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/search/?q=Q3%20Planning")
    }

    func testSetFavoriteTrueSendsPostToFavoriteRoute() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: #"{"detail": "Document marked as favorite"}"#.data(using: .utf8)!, error: nil) }
        let client = makeClient()
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        try await client.setFavorite(documentID: id, isFavorite: true)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/favorite/")
    }

    func testSetFavoriteFalseSendsDeleteAndToleratesEmptyBody() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        try await client.setFavorite(documentID: id, isFavorite: false)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentEndpointsPathTests -only-testing:DocsIOSTests/DocumentEndpointsClientTests`
Expected: FAIL — `cannot find 'documentsListPath' in scope`

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

    func send<T: Decodable>(path: String, method: String, body: Data?) async throws -> T {
        let data = try await performRequest(path: path, method: method, body: body)
        do {
            return try JSONDecoder.docsAPI.decode(T.self, from: data)
        } catch {
            throw DocsAPIError.decoding("\(error)")
        }
    }

    func sendVoid(path: String, method: String, body: Data?) async throws {
        _ = try await performRequest(path: path, method: method, body: body)
    }

    private func performRequest(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DocsAPIError.network("Invalid path: \(path)")
        }
        var request = URLRequest(url: url)
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

        return data
    }
}
```

`DocsIOS/Core/Networking/PaginatedResponse.swift`:
```swift
import Foundation

struct PaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [T]
}
```

`DocsIOS/Core/Networking/DocumentEndpoints.swift`:
```swift
import Foundation

func documentsListPath(
    isFavorite: Bool? = nil,
    isCreatorMe: Bool? = nil,
    title: String? = nil,
    ordering: String? = nil,
    page: Int? = nil,
    pageSize: Int? = nil
) -> String {
    var items: [URLQueryItem] = []
    if let isFavorite { items.append(URLQueryItem(name: "is_favorite", value: isFavorite ? "true" : "false")) }
    if let isCreatorMe { items.append(URLQueryItem(name: "is_creator_me", value: isCreatorMe ? "true" : "false")) }
    if let title { items.append(URLQueryItem(name: "title", value: title)) }
    if let ordering { items.append(URLQueryItem(name: "ordering", value: ordering)) }
    if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
    if let pageSize { items.append(URLQueryItem(name: "page_size", value: String(pageSize))) }
    return "documents/" + queryStringSuffix(items)
}

func documentsSearchPath(query: String) -> String {
    "documents/search/" + queryStringSuffix([URLQueryItem(name: "q", value: query)])
}

private func queryStringSuffix(_ items: [URLQueryItem]) -> String {
    guard !items.isEmpty else { return "" }
    var components = URLComponents()
    components.queryItems = items
    return "?" + (components.percentEncodedQuery ?? "")
}

extension DocsAPIClient {
    func listDocuments(
        isFavorite: Bool? = nil,
        isCreatorMe: Bool? = nil,
        title: String? = nil,
        ordering: String? = nil,
        page: Int? = nil,
        pageSize: Int? = nil
    ) async throws -> PaginatedResponse<Document> {
        try await get(documentsListPath(
            isFavorite: isFavorite,
            isCreatorMe: isCreatorMe,
            title: title,
            ordering: ordering,
            page: page,
            pageSize: pageSize
        ))
    }

    func favoriteDocuments() async throws -> PaginatedResponse<Document> {
        try await get("documents/favorite_list/")
    }

    func searchDocuments(query: String) async throws -> PaginatedResponse<Document> {
        try await get(documentsSearchPath(query: query))
    }

    func setFavorite(documentID: UUID, isFavorite: Bool) async throws {
        let path = "documents/\(documentID.uuidString.lowercased())/favorite/"
        try await sendVoid(path: path, method: isFavorite ? "POST" : "DELETE", body: nil)
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentEndpointsPathTests -only-testing:DocsIOSTests/DocumentEndpointsClientTests`
Expected: PASS — `Executed 9 tests, with 0 failures` (4 path tests + 5 client tests). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 145 tests, with 0 failures` (136 from the prior nine plans + 9 new). This full-suite run is the proof that the `DocsAPIClient` refactor did not break any of the Networking Foundation plan's existing `DocsAPIClientTests`.

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/DocsAPIClient.swift DocsIOS/Core/Networking/PaginatedResponse.swift DocsIOS/Core/Networking/DocumentEndpoints.swift DocsIOSTests/Core/Networking/DocumentEndpointsTests.swift
git commit -m "Fix DocsAPIClient URL construction and add document list/search/favorite endpoints"
```

---

### Task 2: Accessibility traits for DocRow, LinkReachPill, ShareMemberRow, SegmentedControl, TabBar

**Files:**
- Modify: `DocsIOS/DesignSystem/Components/DocRow.swift`
- Modify: `DocsIOS/DesignSystem/Components/LinkReachPill.swift`
- Modify: `DocsIOS/DesignSystem/Components/ShareMemberRow.swift`
- Modify: `DocsIOS/DesignSystem/Components/SegmentedControl.swift`
- Modify: `DocsIOS/DesignSystem/Components/TabBar.swift`
- Modify: `DocsIOSTests/DesignSystem/Components/DocRowTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `func docRowAccessibilityLabel(title:reach:date:pinned:) -> String` (new), accessibility modifiers on all five components' existing views (no new public types) — consumed directly by Task 4's `HomeView`, which is the first screen to actually render `DocRow`/`SegmentedControl`/`TabBar` live (they previously only appeared in the component catalog).

- [ ] **Step 1: Write the failing tests**

Append to `DocsIOSTests/DesignSystem/Components/DocRowTests.swift` (the existing three tests stay unchanged; add these):
```swift
    func testAccessibilityLabelForRestrictedUnpinnedDocument() {
        XCTAssertEqual(
            docRowAccessibilityLabel(title: "Q3 Planning", reach: .restricted, date: "3 days ago", pinned: false),
            "Q3 Planning, 3 days ago"
        )
    }

    func testAccessibilityLabelIncludesPinned() {
        XCTAssertEqual(
            docRowAccessibilityLabel(title: "Q3 Planning", reach: .restricted, date: "3 days ago", pinned: true),
            "Q3 Planning, Pinned, 3 days ago"
        )
    }

    func testAccessibilityLabelIncludesAuthenticatedReach() {
        XCTAssertEqual(
            docRowAccessibilityLabel(title: "Roadmap", reach: .authenticated, date: "Yesterday", pinned: false),
            "Roadmap, Shared with organization, Yesterday"
        )
    }

    func testAccessibilityLabelIncludesPublicReach() {
        XCTAssertEqual(
            docRowAccessibilityLabel(title: "Public notes", reach: .public, date: "Last week", pinned: false),
            "Public notes, Public, Last week"
        )
    }

    func testAccessibilityLabelOmitsEmptyDate() {
        XCTAssertEqual(
            docRowAccessibilityLabel(title: "Untitled document", reach: .restricted, date: "", pinned: false),
            "Untitled document"
        )
    }
```
(Close the final `}` of the `DocRowTests` class after these, same as the existing file.)

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocRowTests`
Expected: FAIL — `cannot find 'docRowAccessibilityLabel' in scope`

- [ ] **Step 3: Write the minimal implementation**

In `DocsIOS/DesignSystem/Components/DocRow.swift`, add this function directly after `docRowReachIndicatorSystemImage`:
```swift
func docRowAccessibilityLabel(title: String, reach: LinkReach, date: String, pinned: Bool) -> String {
    var parts = [title]
    if pinned {
        parts.append("Pinned")
    }
    switch reach {
    case .restricted:
        break
    case .authenticated:
        parts.append("Shared with organization")
    case .public:
        parts.append("Public")
    }
    if !date.isEmpty {
        parts.append(date)
    }
    return parts.joined(separator: ", ")
}
```

Then change `DocRow`'s body's final modifiers from:
```swift
        .padding(.horizontal, DocsSpacing.gutterGrouped)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }
}
```
to:
```swift
        .padding(.horizontal, DocsSpacing.gutterGrouped)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityLabel(docRowAccessibilityLabel(title: title, reach: reach, date: date, pinned: pinned))
        .accessibilityAddTraits(.isButton)
    }
}
```

In `DocsIOS/DesignSystem/Components/LinkReachPill.swift`, change the body's final modifiers from:
```swift
        .foregroundStyle(Color(hex: style.foregroundHex))
        .background(Color(hex: style.backgroundHex))
        .clipShape(Capsule())
    }
}
```
to:
```swift
        .foregroundStyle(Color(hex: style.foregroundHex))
        .background(Color(hex: style.backgroundHex))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.label)
        .accessibilityHint(showsHint ? style.hint : "")
    }
}
```

In `DocsIOS/DesignSystem/Components/ShareMemberRow.swift`, change the role `Button` from:
```swift
            Button(action: { onTapRole?() }) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(role)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
```
to:
```swift
            Button(action: { onTapRole?() }) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(role)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
            .accessibilityLabel("Role: \(role)")
            .accessibilityHint("Double tap to change role")
```

In `DocsIOS/DesignSystem/Components/SegmentedControl.swift`, change the segment `Text` from:
```swift
                        Text(segment)
                            .font(DocsFont.subhead)
                            .foregroundStyle(index == selectedIndex ? DocsColor.textPrimary : DocsColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedIndex = index }
```
to:
```swift
                        Text(segment)
                            .font(DocsFont.subhead)
                            .foregroundStyle(index == selectedIndex ? DocsColor.textPrimary : DocsColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedIndex = index }
                            .accessibilityAddTraits(index == selectedIndex ? [.isButton, .isSelected] : .isButton)
```

In `DocsIOS/DesignSystem/Components/TabBar.swift`, change the item body from:
```swift
                    .foregroundStyle(isSelected ? DocsColor.brandFill : DocsColor.textTertiary)
                    .frame(maxWidth: .infinity)
                }
            }
```
to:
```swift
                    .foregroundStyle(isSelected ? DocsColor.brandFill : DocsColor.textTertiary)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocRowTests`
Expected: PASS — `Executed 8 tests, with 0 failures` (3 existing + 5 new). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 150 tests, with 0 failures` (145 from Task 1 + 5 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/DocRow.swift DocsIOS/DesignSystem/Components/LinkReachPill.swift DocsIOS/DesignSystem/Components/ShareMemberRow.swift DocsIOS/DesignSystem/Components/SegmentedControl.swift DocsIOS/DesignSystem/Components/TabBar.swift DocsIOSTests/DesignSystem/Components/DocRowTests.swift
git commit -m "Add accessibility labels and traits to DocRow, LinkReachPill, ShareMemberRow, SegmentedControl, and TabBar"
```

---

### Task 3: HomeFilter + HomeViewModel

**Files:**
- Create: `DocsIOS/Features/Home/HomeFilter.swift`
- Create: `DocsIOS/Features/Home/HomeViewModel.swift`
- Test: `DocsIOSTests/Features/Home/HomeFilterTests.swift`
- Test: `DocsIOSTests/Features/Home/HomeViewModelTests.swift`

**Interfaces:**
- Consumes: `Document`, `PaginatedResponse`, `DocsAPIClient` document endpoints (Task 1).
- Produces: `enum HomeFilter: Int, CaseIterable`, `struct HomeFilterQueryParameters: Equatable`, `func homeFilterQueryParameters(_:) -> HomeFilterQueryParameters`, `func shouldShowPinnedSection(filter:pinnedCount:) -> Bool`, `@MainActor @Observable final class HomeViewModel` (`init(client:)`, `selectedFilter`, `searchQuery`, `pinnedDocuments`, `recentDocuments`, `searchResults`, `isLoading`, `errorMessage`, `showsPinnedSection` computed, `func load() async`, `func selectFilter(_:) async`, `func search() async`, `func toggleFavorite(_:) async`) — consumed by Task 4's `HomeView`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Home/HomeFilterTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class HomeFilterTests: XCTestCase {
    func testAllFilterHasNoQueryParameters() {
        XCTAssertEqual(homeFilterQueryParameters(.all), HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: nil))
    }

    func testSharedFilterExcludesDocumentsCreatedByMe() {
        XCTAssertEqual(homeFilterQueryParameters(.shared), HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: false))
    }

    func testPinnedFilterOnlyIncludesFavorites() {
        XCTAssertEqual(homeFilterQueryParameters(.pinned), HomeFilterQueryParameters(isFavorite: true, isCreatorMe: nil))
    }

    func testPinnedSectionHiddenWhenFilterIsPinned() {
        XCTAssertFalse(shouldShowPinnedSection(filter: .pinned, pinnedCount: 3))
    }

    func testPinnedSectionHiddenWhenNoPinnedDocuments() {
        XCTAssertFalse(shouldShowPinnedSection(filter: .all, pinnedCount: 0))
    }

    func testPinnedSectionShownForAllFilterWithPinnedDocuments() {
        XCTAssertTrue(shouldShowPinnedSection(filter: .all, pinnedCount: 2))
    }

    func testPinnedSectionShownForSharedFilterWithPinnedDocuments() {
        XCTAssertTrue(shouldShowPinnedSection(filter: .shared, pinnedCount: 1))
    }
}
```

`DocsIOSTests/Features/Home/HomeViewModelTests.swift`:
```swift
import XCTest
@testable import DocsIOS

private final class RequestLog: @unchecked Sendable {
    var urls: [String] = []
}

@MainActor
final class HomeViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel() -> HomeViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return HomeViewModel(client: client)
    }

    private static func paginatedFixture(id: String, title: String, isFavorite: Bool) -> Data {
        """
        {
            "count": 1,
            "next": null,
            "previous": null,
            "results": [
                {
                    "id": "\(id)",
                    "title": "\(title)",
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
                    "is_favorite": \(isFavorite)
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private static let emptyFixture: Data = #"{"count": 0, "next": null, "previous": null, "results": []}"#.data(using: .utf8)!

    func testLoadPopulatesPinnedAndRecentDocuments() async {
        let viewModel = makeViewModel()
        let pinnedBody = Self.paginatedFixture(id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Pinned Doc"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Recent Doc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSelectFilterUpdatesQueryParametersForRecentList() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if !path.contains("favorite_list") {
                log.urls.append(request.url?.absoluteString ?? "")
            }
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }

        await viewModel.selectFilter(.shared)

        XCTAssertEqual(viewModel.selectedFilter, .shared)
        XCTAssertTrue(log.urls.last?.contains("is_creator_me=false") ?? false)
    }

    func testSearchWithEmptyQueryClearsResults() async {
        let viewModel = makeViewModel()
        viewModel.searchResults = []
        viewModel.searchQuery = "   "

        await viewModel.search()

        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testSearchWithQueryPopulatesResults() async {
        let viewModel = makeViewModel()
        viewModel.searchQuery = "Q3"
        let body = Self.paginatedFixture(id: "33333333-3333-4333-8333-333333333333", title: "Q3 Planning", isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.search()

        XCTAssertEqual(viewModel.searchResults.map(\.title), ["Q3 Planning"])
    }

    func testToggleFavoriteCallsSetFavoriteThenReloads() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            log.urls.append(url)
            if url.contains("/favorite/") && !url.contains("favorite_list") {
                return .init(statusCode: 201, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }

        let documentBody = Self.paginatedFixture(id: "44444444-4444-4444-8444-444444444444", title: "Doc", isFavorite: false)
        let document = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: documentBody).results[0]

        await viewModel.toggleFavorite(document)

        XCTAssertTrue(log.urls.contains { $0.contains("/favorite/") && !$0.contains("favorite_list") })
        XCTAssertTrue(log.urls.contains { $0.contains("favorite_list") })
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HomeFilterTests`
Expected: FAIL — `cannot find 'homeFilterQueryParameters' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Home/HomeFilter.swift`:
```swift
import Foundation

enum HomeFilter: Int, CaseIterable {
    case all = 0
    case shared = 1
    case pinned = 2

    var title: String {
        switch self {
        case .all: return "All"
        case .shared: return "Shared"
        case .pinned: return "Pinned"
        }
    }
}

struct HomeFilterQueryParameters: Equatable {
    let isFavorite: Bool?
    let isCreatorMe: Bool?
}

func homeFilterQueryParameters(_ filter: HomeFilter) -> HomeFilterQueryParameters {
    switch filter {
    case .all:
        return HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: nil)
    case .shared:
        return HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: false)
    case .pinned:
        return HomeFilterQueryParameters(isFavorite: true, isCreatorMe: nil)
    }
}

func shouldShowPinnedSection(filter: HomeFilter, pinnedCount: Int) -> Bool {
    filter != .pinned && pinnedCount > 0
}
```

`DocsIOS/Features/Home/HomeViewModel.swift`:
```swift
import Foundation

@MainActor
@Observable
final class HomeViewModel {
    var selectedFilter: HomeFilter = .all
    var searchQuery: String = ""
    var pinnedDocuments: [Document] = []
    var recentDocuments: [Document] = []
    var searchResults: [Document] = []
    var isLoading = false
    var errorMessage: String?

    private let client: DocsAPIClient

    init(client: DocsAPIClient) {
        self.client = client
    }

    var showsPinnedSection: Bool {
        shouldShowPinnedSection(filter: selectedFilter, pinnedCount: pinnedDocuments.count)
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        let params = homeFilterQueryParameters(selectedFilter)
        do {
            async let pinnedPage = client.favoriteDocuments()
            async let recentPage = client.listDocuments(
                isFavorite: params.isFavorite,
                isCreatorMe: params.isCreatorMe,
                ordering: "-updated_at"
            )
            pinnedDocuments = try await pinnedPage.results
            recentDocuments = try await recentPage.results
        } catch {
            errorMessage = "Couldn't load documents. Pull to refresh to try again."
        }

        isLoading = false
    }

    func selectFilter(_ filter: HomeFilter) async {
        selectedFilter = filter
        await load()
    }

    func search() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        do {
            let page = try await client.searchDocuments(query: trimmed)
            searchResults = page.results
        } catch {
            errorMessage = "Search failed. Please try again."
        }
    }

    func toggleFavorite(_ document: Document) async {
        do {
            try await client.setFavorite(documentID: document.id, isFavorite: !document.isFavorite)
            await load()
        } catch {
            errorMessage = "Couldn't update favorite. Please try again."
        }
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HomeFilterTests -only-testing:DocsIOSTests/HomeViewModelTests`
Expected: PASS — `Executed 13 tests, with 0 failures` (7 HomeFilterTests + 6 HomeViewModelTests). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 163 tests, with 0 failures` (150 from Task 2 + 13 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Home/HomeFilter.swift DocsIOS/Features/Home/HomeViewModel.swift DocsIOSTests/Features/Home/HomeFilterTests.swift DocsIOSTests/Features/Home/HomeViewModelTests.swift
git commit -m "Add HomeFilter and HomeViewModel"
```

---

### Task 4: HomeView and RootView wiring

**Files:**
- Create: `DocsIOS/Features/Home/HomeView.swift`
- Modify: `DocsIOS/App/RootView.swift`

**Interfaces:**
- Consumes: `HomeViewModel`, `HomeFilter` (Task 3), `NavBar`, `SearchField`, `SegmentedControl`, `ListSection`, `DocRow` (DesignSystem, Task 2 added their accessibility traits), `TabBar`, `DocsAPIClient`, `SessionStore`.
- Produces: `func documentRowDate(_:) -> String`, `struct HomeView: View` — `RootView` is modified to construct and show `HomeView` when `sessionStore.isAuthenticated && sessionStore.serverURL != nil`.

This task has no XCTest steps — see the Connect Screen plan's precedent and this plan's Global Constraints for why (UI glue verified by build-check and a Simulator screenshot, not XCTest).

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Home/HomeView.swift`:
```swift
import SwiftUI

func documentRowDate(_ document: Document) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: document.updatedAt, relativeTo: Date())
}

struct HomeView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String

    @State private var selectedTab = "docs"
    @State private var documentPendingFavoriteChoice: Document?

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Docs", subtitle: serverHost, largeTitle: true)

            VStack(spacing: DocsSpacing.spaceSM) {
                SearchField(text: $viewModel.searchQuery, placeholder: "Search documents")

                SegmentedControl(
                    segments: HomeFilter.allCases.map(\.title),
                    selectedIndex: Binding(
                        get: { viewModel.selectedFilter.rawValue },
                        set: { newValue in
                            let filter = HomeFilter(rawValue: newValue) ?? .all
                            Task { await viewModel.selectFilter(filter) }
                        }
                    )
                )
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.vertical, DocsSpacing.spaceSM)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .padding(.horizontal, DocsSpacing.gutter)
            }

            ScrollView {
                if viewModel.isLoading {
                    ProgressView()
                        .padding(DocsSpacing.spaceBase)
                } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    documentSection(title: "Search Results", documents: viewModel.searchResults)
                } else {
                    if viewModel.showsPinnedSection {
                        documentSection(title: "Pinned", documents: viewModel.pinnedDocuments)
                    }
                    documentSection(title: "Recent", documents: viewModel.recentDocuments)
                }
            }

            TabBar(items: [
                TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
            ], selection: $selectedTab)
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
        .onChange(of: viewModel.searchQuery) {
            Task { await viewModel.search() }
        }
        .confirmationDialog(
            "Document Options",
            isPresented: Binding(
                get: { documentPendingFavoriteChoice != nil },
                set: { if !$0 { documentPendingFavoriteChoice = nil } }
            ),
            presenting: documentPendingFavoriteChoice
        ) { document in
            Button(document.isFavorite ? "Unpin" : "Pin") {
                Task { await viewModel.toggleFavorite(document) }
            }
        }
    }

    @ViewBuilder
    private func documentSection(title: String, documents: [Document]) -> some View {
        if !documents.isEmpty {
            ListSection(header: title) {
                VStack(spacing: 0) {
                    ForEach(documents) { document in
                        DocRow(
                            emoji: nil,
                            title: document.title ?? "Untitled document",
                            pinned: document.isFavorite,
                            reach: document.linkReach,
                            date: documentRowDate(document),
                            onOpen: {},
                            onMore: { documentPendingFavoriteChoice = document }
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)), serverHost: "docs.llun.dev")
}
```

`DocsIOS/App/RootView.swift` — replace entirely with:
```swift
import SwiftUI

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated, let serverURL = sessionStore.serverURL {
            HomeView(
                viewModel: HomeViewModel(client: DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))),
                serverHost: serverURL.host ?? ""
            )
        } else {
            ConnectView(viewModel: ConnectViewModel(sessionStore: sessionStore, recentServers: recentServers))
        }
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 163 tests, with 0 failures` (no new tests in this task; confirms Task 4's changes didn't regress anything).

- [ ] **Step 3: Visually verify in the Simulator**

`RootView`'s default (unauthenticated) state shows `ConnectView`, already verified in the Connect Screen plan. To verify `HomeView` itself, temporarily point `RootView.body` at `HomeView(...)` directly (matching this plan's own validation — see Architecture), screenshot, then revert `RootView.swift` back to the real auth-gated version from Step 1 before committing:

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'
APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/DocsIOS-*/Build/Products/Debug-iphonesimulator/DocsIOS.app | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted dev.llun.DocsIOS
xcrun simctl io booted screenshot /tmp/home-screen-verify.png
```
Expected: the screenshot shows the NavBar large title "Docs" with subtitle "docs.llun.dev", a "Search documents" field, the All/Shared/Pinned segmented control, and (since this Simulator has no real backend to reach) either a loading spinner or the red "Couldn't load documents. Pull to refresh to try again." error text — **not** a silently blank content area. Seeing the error text (rather than a hang) confirms the error-state fix from Architecture is in place.

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Home/HomeView.swift DocsIOS/App/RootView.swift
git commit -m "Add HomeView, wire RootView to show Home screen when authenticated"
```

## Self-Review Notes

- **Spec coverage:** Implements the design spec's Home screen description and the build sequence's "Home screen, wired to real document list/search/favorite APIs" requirement. Also resolves the Plan 6 final review's carried-forward accessibility-traits item, specifically flagged as needing resolution before/alongside this plan since `DocRow` is now genuinely on-screen for the first time (previously only in the component catalog).
- **Real-backend cross-check:** Query parameter names (`is_favorite`, `is_creator_me`, `title`, `q`, `ordering`) and the paginated response shape (`count`/`next`/`previous`/`results`) were taken from the real `suitenumerique/docs` backend's `filters.py`/`viewsets.py`, not the design spec's endpoint table alone — this is also what surfaced the `appendingPathComponent` URL bug, since building real query strings was what first required a query-string-bearing path.
- **Placeholder scan:** No TBD/TODO. `DocRow.onOpen` is an intentional no-op (documented in Global Constraints) pending the Editor screen plan, not a forgotten placeholder.
- **Type consistency:** `PaginatedResponse`, `documentsListPath`, `documentsSearchPath`, `docRowAccessibilityLabel`, `HomeFilter`, `HomeFilterQueryParameters`, `homeFilterQueryParameters`, `shouldShowPinnedSection`, `HomeViewModel`, `documentRowDate`, `HomeView` are each defined once. `HomeViewModel` correctly reuses `Document`/`DocsAPIClient` from earlier plans rather than reimplementing document fetching.
- **Cross-file validation:** All code in this plan (all four tasks, including the `DocsAPIClient` URL-construction fix verified against the full pre-existing `DocsAPIClientTests` suite, the `PaginatedResponse` Sendable-conformance fix, the `.path`-vs-`.absoluteString` Foundation quirk worked around in tests, and the missing-error-state UI gap found and fixed via two Simulator screenshots) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 163 tests, with 0 failures` plus passing Simulator screenshots of both the Home screen's error state and (via the temporary-RootView-swap technique) its normal layout.
