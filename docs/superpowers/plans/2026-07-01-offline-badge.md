# Offline Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User-requested follow-up to the Offline Document Cache plan — instead of relying solely on the existing red error-banner text to signal that the Home screen is showing previously-synced (stale) documents, show a visible "Offline" tag/chip in the header next to the "Docs" title.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including a Simulator screenshot with a real simulated network failure and a pre-seeded cache, run on an isolated Simulator device so as not to disturb the user's own signed-in session.

- **Reuses the existing `Badge` component** (`DocsIOS/DesignSystem/Components/Badge.swift`, from the DesignSystem Primitives plan) as the "tag/chip" the user asked for — no new component needed. `Badge(text: "Offline", tone: .warning, icon: "wifi.slash")` matches the existing `tone`/`icon` API exactly.
- **`NavBar` gains a new `titleBadge: Badge? = nil` parameter**, rendered inline next to the title text in the large-title block only (the compact/small-title branch is unused by the Home screen and left untouched). Defaulting to `nil` means every other existing `NavBar` call site (Editor, Connect, etc.) is unaffected — this is a purely additive, backward-compatible change.
- **A dedicated `HomeViewModel.isOffline: Bool`, distinct from the generic `errorMessage`** — set specifically when the document-list `load()` call fails, reset to `false` at the top of every `load()` attempt (mirroring the existing `errorMessage = nil` reset). This was a deliberate design decision, not an oversight: `errorMessage` is also set by `search()` and `toggleFavorite()` failures, which are unrelated to "am I showing stale offline data" — tying the badge to the generic `errorMessage` would have shown "Offline" after e.g. a failed favorite-toggle while still fully connected. A test (`testToggleFavoriteFailureDoesNotSetIsOffline`) asserts this scoping explicitly.
- **No changes to `DocumentCacheStore`** — this plan is UI-only, layered directly on top of the already-merged Offline Document Cache plan's `pinnedDocuments`/`recentDocuments`/cache-write logic.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `NavBar.titleBadge` must default to `nil` and only render inside the `largeTitle` branch — do not add it to the compact/small-title branch, and do not change any existing `NavBar` call site's behavior.
- `HomeViewModel.isOffline` must only be set by `load()`'s success/failure paths — never by `search()` or `toggleFavorite()`.
- This plan has no new XCTest files by design for the `NavBar` change (UI glue, verified by build-check and a Simulator screenshot); `HomeViewModel`'s `isOffline` logic **does** get new tests, since it's testable business logic, matching the established pattern of this codebase (view-model logic is unit-tested, pure UI wiring is screenshot-verified).
- If `RootView.swift` is temporarily swapped for screenshots, it MUST be reverted to the real auth-gated version before committing — never commit a temporary version.

## File Structure

```
DocsIOS/
├── DesignSystem/
│   └── Components/
│       └── NavBar.swift                              — MODIFY: titleBadge parameter (Task 1)
└── Features/
    └── Home/
        ├── HomeViewModel.swift                        — MODIFY: isOffline flag (Task 2)
        └── DocumentListView.swift                     — MODIFY: pass titleBadge to NavBar (Task 2)

DocsIOSTests/
└── Features/
    └── Home/
        └── HomeViewModelTests.swift                    — MODIFY: isOffline tests (Task 2)
```

---

### Task 1: NavBar titleBadge parameter

**Files:**
- Modify: `DocsIOS/DesignSystem/Components/NavBar.swift`

**Interfaces:**
- Consumes: `Badge` (DesignSystem Primitives plan).
- Produces: `NavBar` gains `var titleBadge: Badge? = nil`, rendered inline next to the large title.

This task has no new XCTest files — see Global Constraints for why.

- [ ] **Step 1: Write the implementation**

In `DocsIOS/DesignSystem/Components/NavBar.swift`, change:
```swift
struct NavBar: View {
    let title: String
    var subtitle: String? = nil
    var largeTitle: Bool = false
    var backTitle: String? = nil
    var onBack: (() -> Void)? = nil
    var trailingActions: [NavBarAction] = []
    var translucent: Bool = true
    var showsBorder: Bool = true
```
to:
```swift
struct NavBar: View {
    let title: String
    var subtitle: String? = nil
    var largeTitle: Bool = false
    var titleBadge: Badge? = nil
    var backTitle: String? = nil
    var onBack: (() -> Void)? = nil
    var trailingActions: [NavBarAction] = []
    var translucent: Bool = true
    var showsBorder: Bool = true
```

And change:
```swift
            if largeTitle {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(DocsFont.largeTitle)
                        .foregroundStyle(DocsColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceXS)
            }
```
to:
```swift
            if largeTitle {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Text(title)
                            .font(DocsFont.largeTitle)
                            .foregroundStyle(DocsColor.textPrimary)
                        if let titleBadge {
                            titleBadge
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceXS)
            }
```

No other part of the file changes.

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 230 tests, with 0 failures` (no new tests in this task; confirms the additive `titleBadge` parameter doesn't break any existing `NavBar` call site).

- [ ] **Step 3: Commit**

```bash
git add DocsIOS/DesignSystem/Components/NavBar.swift
git commit -m "Add titleBadge parameter to NavBar"
```

---

### Task 2: Wire isOffline badge into HomeViewModel and DocumentListView

**Files:**
- Modify: `DocsIOS/Features/Home/HomeViewModel.swift`
- Modify: `DocsIOS/Features/Home/DocumentListView.swift`
- Modify: `DocsIOSTests/Features/Home/HomeViewModelTests.swift`

**Interfaces:**
- Consumes: `NavBar.titleBadge` (Task 1).
- Produces: `HomeViewModel.isOffline: Bool` (new observable property, set/reset by `load()`); `DocumentListView`'s `NavBar` call passes `titleBadge: viewModel.isOffline ? Badge(text: "Offline", tone: .warning, icon: "wifi.slash") : nil`.

- [ ] **Step 1: Write the failing tests**

In `DocsIOSTests/Features/Home/HomeViewModelTests.swift`, add these new test methods at the end of the class, immediately before the closing `}`:
```swift
    func testLoadFailureSetsIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertTrue(viewModel.isOffline)
    }

    func testLoadSuccessKeepsIsOfflineFalse() async {
        let viewModel = makeViewModel()
        let pinnedBody = Self.paginatedFixture(id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
    }

    func testLoadSuccessAfterFailureClearsIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertTrue(viewModel.isOffline)

        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: empty, error: nil) }
        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
    }

    func testToggleFavoriteFailureDoesNotSetIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let documentBody = Self.paginatedFixture(id: "ffffffff-ffff-4fff-8fff-ffffffffffff", title: "Doc", isFavorite: false)
        let document = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: documentBody).results[0]

        await viewModel.toggleFavorite(document)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isOffline)
    }
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HomeViewModelTests`
Expected: FAIL — `value of type 'HomeViewModel' has no member 'isOffline'`

- [ ] **Step 3: Write the minimal implementation**

In `DocsIOS/Features/Home/HomeViewModel.swift`, change:
```swift
    var isLoading = false
    var errorMessage: String?
```
to:
```swift
    var isLoading = false
    var errorMessage: String?
    var isOffline = false
```

And change:
```swift
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
            cache.savePinnedDocuments(pinnedDocuments)
            if selectedFilter == .all {
                cache.saveRecentDocuments(recentDocuments)
            }
        } catch {
            errorMessage = "Couldn't load documents. Pull to refresh to try again."
        }

        isLoading = false
    }
```
to:
```swift
    func load() async {
        isLoading = true
        errorMessage = nil
        isOffline = false

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
            cache.savePinnedDocuments(pinnedDocuments)
            if selectedFilter == .all {
                cache.saveRecentDocuments(recentDocuments)
            }
        } catch {
            errorMessage = "Couldn't load documents. Pull to refresh to try again."
            isOffline = true
        }

        isLoading = false
    }
```

In `DocsIOS/Features/Home/DocumentListView.swift`, change:
```swift
            NavBar(title: "Docs", subtitle: serverHost, largeTitle: true)
```
to:
```swift
            NavBar(
                title: "Docs",
                subtitle: serverHost,
                largeTitle: true,
                titleBadge: viewModel.isOffline ? Badge(text: "Offline", tone: .warning, icon: "wifi.slash") : nil
            )
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HomeViewModelTests`
Expected: PASS — `Executed 14 tests, with 0 failures` (10 pre-existing + 4 new). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 234 tests, with 0 failures` (230 from Task 1 + 4 new).

- [ ] **Step 5: Visually verify in the Simulator**

Temporarily point `RootView.body` at a `HomeView` whose `HomeViewModel` is backed by (a) a stub `URLProtocol` that fails every request and (b) a `DocumentCacheStore` pre-seeded with sample pinned/recent documents (matching this plan's own validation, and the identical technique already used for the Offline Document Cache plan's own screenshot — see Architecture). **Use a separate Simulator device from whichever one the user is actively signed in on.** Screenshot, then revert `RootView.swift` back to the real auth-gated version **before committing**.
Expected: the screenshot shows an "Offline" chip (warning-toned, wifi-slash icon) immediately to the right of the "Docs" large title, with the Pinned/Recent sections still showing the sample cached documents below the existing error banner.

- [ ] **Step 6: Commit**

```bash
git add DocsIOS/Features/Home/HomeViewModel.swift DocsIOS/Features/Home/DocumentListView.swift DocsIOSTests/Features/Home/HomeViewModelTests.swift
git commit -m "Show Offline badge in Home header when showing cached documents"
```

## Self-Review Notes

- **Spec coverage:** Implements exactly what the user asked as a follow-up to the Offline Document Cache plan — a visible "Offline" tag/chip in the header, reusing the existing `Badge` component, instead of relying solely on the pre-existing error-banner text.
- **Real design decision, not an oversight:** `isOffline` is intentionally scoped to `load()` failures only, not the generic `errorMessage` (which is also set by unrelated `search()`/`toggleFavorite()` failures) — verified with a dedicated test (`testToggleFavoriteFailureDoesNotSetIsOffline`) so a future change to `errorMessage`'s usage doesn't silently make this scoping incorrect.
- **Placeholder scan:** No TBD/TODO. Both tasks are fully implemented and tested (Task 2's business logic) or screenshot-verified (Task 1's UI glue).
- **Type consistency:** `NavBar.titleBadge` is a single new optional parameter, defaulting to `nil` — every other existing `NavBar` call site (Editor, Connect) is verified unaffected by the full test suite passing unchanged at 230 tests after Task 1.
- **Cross-file validation:** All code in this plan (both tasks, including the `isOffline` scoping tests and a Simulator screenshot showing the "Offline" badge alongside real cached documents, run on an isolated Simulator device to avoid disturbing the user's own signed-in session) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 234 tests, with 0 failures` plus a passing Simulator screenshot of the "Offline" badge.
