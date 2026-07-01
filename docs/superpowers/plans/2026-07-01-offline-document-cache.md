# Offline Document Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User-requested feature — the Home screen's document list must still show the documents that were already synced before the app was closed, even with no internet connection, across a full app close/reopen cycle (not just within the same in-memory session).

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including a Simulator screenshot with a real network failure and a pre-seeded cache, run on a separate Simulator device so as not to disturb the user's own signed-in session on their primary Simulator.

- **A real, pre-existing gap confirmed by reading the code, not by guessing:** `HomeViewModel.pinnedDocuments`/`.recentDocuments` are plain in-memory `@Observable` properties, reset to `[]` on every fresh process launch. `load()`'s `catch` block already correctly leaves them untouched on a failed reload *within the same running process* (so pull-to-refresh while offline already preserved whatever was in memory) — but a brand-new app launch has nothing in memory yet, so the very first failed load left the list empty regardless of what had been fetched in a *previous* app session. This plan closes exactly that gap: persist the last-synced snapshot to disk and seed it back in at `HomeViewModel` construction time, before the first network call even starts.
- **New `DocumentCacheStore`** (`DocsIOS/Features/Home/`, mirroring `RecentServersStore`'s existing lightweight `UserDefaults` + `Codable` pattern from the Connect screen plan — not a new persistence framework) stores the last-successfully-fetched `pinnedDocuments` and `recentDocuments` arrays as JSON blobs in `UserDefaults`, keyed separately. `Document` is already `Codable` (required for JSON API decoding), so this is a direct reuse, with a plain `.iso8601` date strategy since this is a pure local round-trip (encode-then-decode of our own data), not a wire format that needs to match the backend's custom `JSONDecoder.docsAPI` formatter.
- **`pinnedDocuments` is filter-independent** (`client.favoriteDocuments()` takes no filter-dependent parameters) so it is cached unconditionally on every successful load. **`recentDocuments` varies by `selectedFilter`** (All/Shared/Pinned each send different query parameters), so it is only cached when `selectedFilter == .all` — caching a Shared- or Pinned-filtered subset under the same key would silently corrupt the "all documents" offline snapshot the next time the app launches into the default `.all` filter. This was a real design decision made during scratch validation, not an afterthought: the plan's own tests assert the non-`.all` case does *not* overwrite the cache.
- **Scope is deliberately the Home document list only** — not document content/editing offline, not search results. The user's request was specifically "show all the documents that already sync," i.e. the browsing list; document content already has its own error/empty-state handling from the Polish plan, and extending offline support to full content caching is a materially larger feature not covered by this request. If broader offline support (reading/editing cached content) is wanted later, it should be scoped separately.
- **No new UI.** The existing error banner ("Couldn't load documents. Pull to refresh to try again.") already communicates a failed refresh; this plan makes the list underneath that banner show real, previously-synced data instead of nothing, which is exactly the reported gap. No new "offline" indicator was requested or added.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `DocumentCacheStore` must take an injectable `UserDefaults` (defaulting to `.standard`), matching `RecentServersStore`'s existing constructor pattern — tests must use an isolated `UserDefaults(suiteName:)`, never `.standard`, to avoid cross-test pollution.
- `HomeViewModel.init` must seed `pinnedDocuments`/`recentDocuments` from the cache synchronously, before any network call — this is what makes the cached list visible immediately on a fresh launch, not just after a failed load completes.
- `recentDocuments` must only be written to the cache when `selectedFilter == .all`; `pinnedDocuments` is cached unconditionally on every successful load.
- Any `MockURLProtocol.stubHandler` closure that references a `@MainActor`-isolated `static let`/`static func` test fixture must capture it into a local `let` constant first — referencing it directly inside the `@Sendable` closure is a Swift 6 strict-concurrency compile error (a standing, previously-documented constraint in this codebase).

## File Structure

```
DocsIOS/
└── Features/
    └── Home/
        ├── DocumentCacheStore.swift                      — DocumentCacheStore (Task 1)
        └── HomeViewModel.swift                            — MODIFY: cache seeding + writes (Task 2)

DocsIOSTests/
└── Features/
    └── Home/
        ├── DocumentCacheStoreTests.swift                  — Task 1
        └── HomeViewModelTests.swift                        — MODIFY: cache-integration tests (Task 2)
```

---

### Task 1: DocumentCacheStore

**Files:**
- Create: `DocsIOS/Features/Home/DocumentCacheStore.swift`
- Test: `DocsIOSTests/Features/Home/DocumentCacheStoreTests.swift`

**Interfaces:**
- Consumes: `Document` (earlier plans).
- Produces: `final class DocumentCacheStore` (`init(userDefaults:)`, `loadPinnedDocuments() -> [Document]`, `loadRecentDocuments() -> [Document]`, `savePinnedDocuments(_:)`, `saveRecentDocuments(_:)`) — consumed by Task 2's `HomeViewModel`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Home/DocumentCacheStoreTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocumentCacheStoreTests: XCTestCase {
    private func makeStore() -> DocumentCacheStore {
        let suiteName = "DocumentCacheStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return DocumentCacheStore(userDefaults: userDefaults)
    }

    private func makeDocument(id: String, title: String) -> Document {
        Document(
            id: UUID(uuidString: id)!,
            title: title,
            excerpt: nil,
            abilities: DocumentAbilities(),
            linkReach: .restricted,
            linkRole: .reader,
            computedLinkReach: nil,
            computedLinkRole: nil,
            isFavorite: false,
            depth: 1,
            numchild: 0,
            path: "0001",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            userRole: .owner,
            creator: nil
        )
    }

    func testLoadPinnedDocumentsReturnsEmptyArrayWhenNoCacheExists() {
        let store = makeStore()

        XCTAssertTrue(store.loadPinnedDocuments().isEmpty)
    }

    func testLoadRecentDocumentsReturnsEmptyArrayWhenNoCacheExists() {
        let store = makeStore()

        XCTAssertTrue(store.loadRecentDocuments().isEmpty)
    }

    func testSaveAndLoadPinnedDocumentsRoundTrips() {
        let store = makeStore()
        let document = makeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc")

        store.savePinnedDocuments([document])

        XCTAssertEqual(store.loadPinnedDocuments(), [document])
    }

    func testSaveAndLoadRecentDocumentsRoundTrips() {
        let store = makeStore()
        let document = makeDocument(id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc")

        store.saveRecentDocuments([document])

        XCTAssertEqual(store.loadRecentDocuments(), [document])
    }

    func testPinnedAndRecentCachesAreIndependent() {
        let store = makeStore()
        let pinned = makeDocument(id: "33333333-3333-4333-8333-333333333333", title: "Pinned")
        let recent = makeDocument(id: "44444444-4444-4444-8444-444444444444", title: "Recent")

        store.savePinnedDocuments([pinned])
        store.saveRecentDocuments([recent])

        XCTAssertEqual(store.loadPinnedDocuments(), [pinned])
        XCTAssertEqual(store.loadRecentDocuments(), [recent])
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentCacheStoreTests`
Expected: FAIL — `cannot find 'DocumentCacheStore' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Home/DocumentCacheStore.swift`:
```swift
import Foundation

final class DocumentCacheStore {
    private static let pinnedKey = "dev.llun.DocsIOS.cachedPinnedDocuments"
    private static let recentKey = "dev.llun.DocsIOS.cachedRecentDocuments"

    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadPinnedDocuments() -> [Document] {
        load(forKey: Self.pinnedKey)
    }

    func loadRecentDocuments() -> [Document] {
        load(forKey: Self.recentKey)
    }

    func savePinnedDocuments(_ documents: [Document]) {
        save(documents, forKey: Self.pinnedKey)
    }

    func saveRecentDocuments(_ documents: [Document]) {
        save(documents, forKey: Self.recentKey)
    }

    private func load(forKey key: String) -> [Document] {
        guard let data = userDefaults.data(forKey: key),
              let documents = try? decoder.decode([Document].self, from: data) else {
            return []
        }
        return documents
    }

    private func save(_ documents: [Document], forKey key: String) {
        guard let data = try? encoder.encode(documents) else { return }
        userDefaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentCacheStoreTests`
Expected: PASS — `Executed 5 tests, with 0 failures`. Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 226 tests, with 0 failures` (221 from before this plan + 5 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Home/DocumentCacheStore.swift DocsIOSTests/Features/Home/DocumentCacheStoreTests.swift
git commit -m "Add DocumentCacheStore for offline document list persistence"
```

---

### Task 2: Wire DocumentCacheStore into HomeViewModel

**Files:**
- Modify: `DocsIOS/Features/Home/HomeViewModel.swift`
- Modify: `DocsIOSTests/Features/Home/HomeViewModelTests.swift`

**Interfaces:**
- Consumes: `DocumentCacheStore` (Task 1).
- Produces: `HomeViewModel.init(client:cache:)` gains a `cache: DocumentCacheStore = DocumentCacheStore()` parameter and seeds `pinnedDocuments`/`recentDocuments` from it; `load()` writes fresh results back to the cache on success.

- [ ] **Step 1: Write the failing tests**

In `DocsIOSTests/Features/Home/HomeViewModelTests.swift`, change the existing helper:
```swift
    private func makeViewModel() -> HomeViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return HomeViewModel(client: client)
    }
```
to:
```swift
    private func makeCache() -> DocumentCacheStore {
        let suiteName = "HomeViewModelTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return DocumentCacheStore(userDefaults: userDefaults)
    }

    private func makeViewModel(cache: DocumentCacheStore? = nil) -> HomeViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return HomeViewModel(client: client, cache: cache ?? makeCache())
    }
```

Then add these new test methods at the end of the class, immediately before the closing `}`:
```swift
    func testInitSeedsPinnedAndRecentDocumentsFromCache() {
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(id: "55555555-5555-4555-8555-555555555555", title: "Cached Pinned", isFavorite: true)
        let recentBody = Self.paginatedFixture(id: "66666666-6666-4666-8666-666666666666", title: "Cached Recent", isFavorite: false)
        let pinnedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody).results[0]
        let recentDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: recentBody).results[0]
        cache.savePinnedDocuments([pinnedDocument])
        cache.saveRecentDocuments([recentDocument])

        let viewModel = makeViewModel(cache: cache)

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Cached Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Cached Recent"])
    }

    func testLoadWithAllFilterSavesResultsToCache() async {
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)
        let pinnedBody = Self.paginatedFixture(id: "77777777-7777-4777-8777-777777777777", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(id: "88888888-8888-4888-8888-888888888888", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(cache.loadPinnedDocuments().map(\.title), ["Pinned Doc"])
        XCTAssertEqual(cache.loadRecentDocuments().map(\.title), ["Recent Doc"])
    }

    func testLoadWithNonAllFilterDoesNotOverwriteRecentCache() async {
        let cache = makeCache()
        let staleRecentBody = Self.paginatedFixture(id: "99999999-9999-4999-8999-999999999999", title: "Stale All Doc", isFavorite: false)
        let staleRecentDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: staleRecentBody).results[0]
        cache.saveRecentDocuments([staleRecentDocument])
        let viewModel = makeViewModel(cache: cache)
        let sharedBody = Self.paginatedFixture(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Shared Doc", isFavorite: false)
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: empty, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: sharedBody, error: nil)
        }

        await viewModel.selectFilter(.shared)

        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Shared Doc"])
        XCTAssertEqual(cache.loadRecentDocuments().map(\.title), ["Stale All Doc"])
    }

    func testLoadFailureKeepsCachedDocumentsVisible() async {
        let cache = makeCache()
        let cachedPinnedBody = Self.paginatedFixture(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title: "Offline Pinned", isFavorite: true)
        let cachedRecentBody = Self.paginatedFixture(id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", title: "Offline Recent", isFavorite: false)
        let cachedPinnedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: cachedPinnedBody).results[0]
        let cachedRecentDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: cachedRecentBody).results[0]
        cache.savePinnedDocuments([cachedPinnedDocument])
        cache.saveRecentDocuments([cachedRecentDocument])
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Offline Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
        XCTAssertNotNil(viewModel.errorMessage)
    }
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HomeViewModelTests`
Expected: FAIL — `extra argument 'cache' in call` (or similar — `HomeViewModel.init` doesn't yet accept a `cache` parameter)

- [ ] **Step 3: Write the minimal implementation**

In `DocsIOS/Features/Home/HomeViewModel.swift`, change:
```swift
    let client: DocsAPIClient

    init(client: DocsAPIClient) {
        self.client = client
    }
```
to:
```swift
    let client: DocsAPIClient
    private let cache: DocumentCacheStore

    init(client: DocsAPIClient, cache: DocumentCacheStore = DocumentCacheStore()) {
        self.client = client
        self.cache = cache
        pinnedDocuments = cache.loadPinnedDocuments()
        recentDocuments = cache.loadRecentDocuments()
    }
```

And change the body of `load()` from:
```swift
            pinnedDocuments = try await pinnedPage.results
            recentDocuments = try await recentPage.results
        } catch {
```
to:
```swift
            pinnedDocuments = try await pinnedPage.results
            recentDocuments = try await recentPage.results
            cache.savePinnedDocuments(pinnedDocuments)
            if selectedFilter == .all {
                cache.saveRecentDocuments(recentDocuments)
            }
        } catch {
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HomeViewModelTests`
Expected: PASS — `Executed 10 tests, with 0 failures` (6 pre-existing + 4 new). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 230 tests, with 0 failures` (226 from Task 1 + 4 new).

- [ ] **Step 5: Visually verify in the Simulator**

Temporarily point `RootView.body` at a `HomeView` whose `HomeViewModel` is backed by (a) a stub `URLProtocol` that fails every request (`client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))`) and (b) a `DocumentCacheStore` pre-seeded with sample pinned/recent documents (matching this plan's own validation — see Architecture). **Use a separate Simulator device from whichever one the user is actively signed in on** (installing to the same bundle ID on the same device replaces the user's running app and its data), screenshot, then revert `RootView.swift` back to the real auth-gated version **before committing**.
Expected: the screenshot shows the existing "Couldn't load documents. Pull to refresh to try again." error banner AND, below it, the Pinned/Recent sections populated with the sample cached documents — not an empty list.

- [ ] **Step 6: Commit**

```bash
git add DocsIOS/Features/Home/HomeViewModel.swift DocsIOSTests/Features/Home/HomeViewModelTests.swift
git commit -m "Seed HomeViewModel from cached documents for offline viewing"
```

## Self-Review Notes

- **Spec coverage:** Implements exactly what the user asked — the Home document list survives a full app close/reopen and still shows previously-synced documents when offline. Scope was deliberately kept to the document list (not content/editing offline, not search), matching the literal request; noted explicitly in Architecture so this isn't mistaken for an oversight.
- **Real bug/gap confirmed by reading the code, not assumed:** `HomeViewModel`'s existing `load()` catch block already preserved in-memory state on a failed *reload* — the actual gap was specifically the very first load after a fresh process launch, when there was nothing in memory yet. This plan's fix (seed from disk at `init`, before any network call) targets that exact gap.
- **Placeholder scan:** No TBD/TODO. Both tasks are fully implemented and tested.
- **Type consistency:** `DocumentCacheStore` is defined once, follows the exact same constructor-injection pattern as the existing `RecentServersStore`. No duplication.
- **Cross-file validation:** All code in this plan (both tasks, including the filter-aware caching logic — `pinnedDocuments` unconditional, `recentDocuments` gated on `selectedFilter == .all` — and a Simulator screenshot with a real simulated network failure plus a pre-seeded cache, run on an isolated Simulator device to avoid disturbing the user's own signed-in session) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 230 tests, with 0 failures` plus a passing Simulator screenshot showing cached "Q3 Roadmap"/"Meeting Notes" documents alongside the error banner.
