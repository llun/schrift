# Connect Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Amendment (2026-07-07):** Two parts of the login flow built here were later
> superseded. (1) Login-complete detection is no longer `didFinish`-only: commit
> `ca0f951` (PR #32, 2026-07-03) routes **both** `didCommit` and `didFinish`
> through a shared `Coordinator.handleNavigation(to:)` (with an injectable
> `captureCookies` seam), because a 2FA sign-in plus the docs SPA's client-side
> redirect can drop the final `didFinish`, leaving the sheet stuck open — see
> `docs/superpowers/plans/2026-07-03-fix-2fa-weblogin-detection.md` and
> `Schrift/Features/Connect/WebLoginView.swift`. (2) `WebLoginView` is now also
> reused by the re-login sheet (`ReauthenticationSheetView`/`ReauthenticationViewModel`)
> added by `2026-07-04-persist-session-cookies-and-reauth.md`, and the cookies
> synced at login are additionally persisted to the Keychain by
> `SessionStore.signIn`. Retained as a dated record.

**Goal:** Build the Connect screen (design spec Phase 4): server URL entry, recent servers list, and a "Sign in to {host}" flow that presents a real `WKWebView` login sheet, detects completion via the prior plan's `isLoginNavigationComplete`, syncs cookies, positively confirms via a native `GET /api/v1.0/users/me/` call through `DocsAPIClient`, then calls `SessionStore.signIn`. Wires `RootView` to show this screen whenever `SessionStore.isAuthenticated` is false. This is the first plan with actual screen UI (`Features/` did not exist before this plan) and the first to combine `Core/Networking` (Plan 7) and `Core/Auth` (Plan 8).

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including a real build+run+screenshot in the iOS Simulator, not just `xcodebuild test`, since this plan (unlike the prior two) ships actual SwiftUI/UIKit UI. Key decisions:

- **Three-layer split, matching the pure/orchestration/glue separation used throughout this project:** `normalizedServerURL`/`addingRecentServer`/`RecentServersStore` (pure + DI-testable, Task 1) → `ConnectViewModel` (orchestration, fully unit-tested by reusing Plan 7's `MockURLProtocol` to drive a real `DocsAPIClient` with no network, Task 2) → `WebLoginView`/`ConnectView`/`RootView` wiring (UI glue, verified by build-check + a real Simulator screenshot rather than XCTest, Task 3, matching how this project has never unit-tested a SwiftUI view's body directly).
- **`normalizedServerURL(from input: String) -> URL?` treats a bare hostname as `https://`, preserves an explicitly-typed scheme (rejecting anything except `http`/`https`), trims whitespace, and strips path/query/fragment** — validated with 10 edge cases including trailing slashes, ports, and invalid hosts. `RecentServersStore` reuses the same injectable-`UserDefaults` pattern as `SessionStore` (Plan 8); `addingRecentServer` is a pure move-to-front-with-dedup-and-cap function, independently testable from persistence.
- **`ConnectViewModel` is `@MainActor` — this was not optional.** Without it, an `error: sending 'self.viewModel' risks causing data races` compile failure occurs the moment an `async` method (`handleLoginComplete()`) on a plain `@Observable final class` is called from a `Task { }` inside SwiftUI view code, because `@Observable` does not imply `@MainActor` and the method is otherwise inferred `nonisolated`. `ConnectViewModelTests` must also be `@MainActor` for the same reason (calling `@MainActor`-isolated methods/properties from synchronous or async test bodies).
- **`WebLoginView`'s and `Coordinator`'s `onLoginComplete` closure type is `@MainActor () -> Void`, not a plain `() -> Void`.** The closure is invoked from inside `WKWebsiteDataStore...getAllCookies`'s completion handler, wrapped in `Task { @MainActor in self.onLoginComplete() }` — a plain closure type here does not statically guarantee the call happens on the main actor (GCD's `DispatchQueue.main.async`, used to hop back before this, is not recognized by the Swift concurrency checker as establishing `@MainActor` isolation), and the mismatch is exactly what produced the "sending" error above before both fixes were applied together. Do not revert either half of this fix independently.
- **Login-complete detection reuses Plan 8's `isLoginNavigationComplete(url:serverHost:)` verbatim inside `WKNavigationDelegate.webView(_:didFinish:)`**, guarded by a `didComplete` flag so it only fires once per WebView session. On firing: `WKWebsiteDataStore.default().httpCookieStore.getAllCookies` retrieves the WebView's cookie jar, `syncCookies(_:into:)` (Plan 8) copies them into `HTTPCookieStorage.shared`, then `onLoginComplete()` runs on the main actor.
- **`ConnectViewModel.handleLoginComplete()` does the positive-confirmation step this plan's predecessor deliberately deferred**: after cookies are synced, it constructs a `DocsAPIClient` for the just-entered server (via an injectable `apiClientFactory: (URL) -> DocsAPIClient` — production default builds a real client at `{server}/api/v1.0/`, tests inject a `MockURLProtocol`-backed one) and calls `client.get("users/me/")`. Success → `SessionStore.signIn(serverURL:)` + `RecentServersStore.addServer(_:)`. Failure (any thrown `DocsAPIError`) → `errorMessage` is set, `SessionStore` is left untouched — the user sees an inline error rather than being silently signed in on a false-positive navigation.
- **A real Simulator crash during validation turned out to be transient, not a code defect** — worth recording so it isn't mistaken for a real bug if seen again: an early build+test run produced a `SIGSEGV` inside SwiftUI's `initializeWithCopy for RootView` at app launch. Bisection (reverting `RootView` to its pre-plan placeholder, then re-adding pieces one at a time) showed the exact same final code passed cleanly on the next run and on a full `DerivedData` wipe + rebuild, with `Executed 136 tests, with 0 failures` both times. Treat one-off `initializeWithCopy`/`AG::Graph` crashes at app launch as a simulator/build-cache flake worth one clean-rebuild retry before treating it as a real regression.

**Tech Stack:** Swift 6.0, SwiftUI, UIKit (`UIViewRepresentable`), WebKit (`WKWebView`), XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `ConnectViewModel` must be `@MainActor`; `ConnectViewModelTests` must also be `@MainActor`. Do not remove either annotation to "simplify" — both are required for the code to compile under this project's Swift 6 strict concurrency settings (see Architecture above for why).
- `WebLoginView.onLoginComplete` and `Coordinator.onLoginComplete` must both be typed `@MainActor () -> Void`, and the cookie-sync completion handler must call it via `Task { @MainActor in self.onLoginComplete() }`, not a bare `DispatchQueue.main.async` block calling a plain closure — this exact combination is what compiles under strict concurrency (see Architecture above).
- Task 3 (`WebLoginView`, `ConnectView`, `RootView` wiring) is UI glue verified by build-check and a real Simulator screenshot, not XCTest — consistent with this project's established pattern of never unit-testing a SwiftUI view's `body` directly. Do not write XCTest cases that instantiate `WebLoginView`/`ConnectView` and assert on their view hierarchy.
- Reuse `MockURLProtocol` from `DocsIOSTests/Core/Networking/MockURLProtocol.swift` (Plan 7) for `ConnectViewModelTests` — do not create a second mock URLProtocol.
- Reuse `FakeKeychainStore` from `DocsIOSTests/Core/Auth/FakeKeychainStore.swift` (Plan 8) and the isolated-`UserDefaults(suiteName:)` pattern for any test that constructs a `SessionStore` or `RecentServersStore`.

## File Structure

```
DocsIOS/
├── App/
│   └── RootView.swift                                       — MODIFY: show ConnectView when unauthenticated (Task 3)
└── Features/
    └── Connect/
        ├── ServerURLInput.swift                              — normalizedServerURL(from:) (Task 1)
        ├── RecentServersStore.swift                          — addingRecentServer(_:to:limit:), RecentServersStore (Task 1)
        ├── ConnectViewModel.swift                            — ConnectViewModel (Task 2)
        ├── WebLoginView.swift                                — WebLoginView, Coordinator (Task 3)
        └── ConnectView.swift                                 — ConnectView (Task 3)

DocsIOSTests/
└── Features/
    └── Connect/
        ├── ServerURLInputTests.swift                         — Task 1
        ├── RecentServersStoreTests.swift                     — Task 1
        └── ConnectViewModelTests.swift                       — Task 2
```

---

### Task 1: ServerURLInput + RecentServersStore

**Files:**
- Create: `DocsIOS/Features/Connect/ServerURLInput.swift`
- Create: `DocsIOS/Features/Connect/RecentServersStore.swift`
- Test: `DocsIOSTests/Features/Connect/ServerURLInputTests.swift`
- Test: `DocsIOSTests/Features/Connect/RecentServersStoreTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `func normalizedServerURL(from input: String) -> URL?`, `func addingRecentServer(_ url: URL, to existing: [URL], limit: Int = 5) -> [URL]`, `@Observable final class RecentServersStore` (`init(userDefaults:)`, `servers: [URL]` read-only, `func addServer(_ url: URL)`) — all three consumed by Task 2's `ConnectViewModel` and Task 3's `ConnectView`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Connect/ServerURLInputTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class ServerURLInputTests: XCTestCase {
    func testBareHostnameGetsHTTPSScheme() {
        XCTAssertEqual(normalizedServerURL(from: "docs.llun.dev")?.absoluteString, "https://docs.llun.dev")
    }

    func testAlreadyHasHTTPSSchemeIsPreserved() {
        XCTAssertEqual(normalizedServerURL(from: "https://docs.llun.dev")?.absoluteString, "https://docs.llun.dev")
    }

    func testTrailingSlashIsStripped() {
        XCTAssertEqual(normalizedServerURL(from: "https://docs.llun.dev/")?.absoluteString, "https://docs.llun.dev")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(normalizedServerURL(from: "  docs.llun.dev  ")?.absoluteString, "https://docs.llun.dev")
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: ""))
    }

    func testWhitespaceOnlyStringReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: "   "))
    }

    func testInvalidHostReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: "not a valid host???"))
    }

    func testDisallowedSchemeReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: "ftp://docs.llun.dev"))
    }

    func testHTTPSchemeWithPortIsPreserved() {
        XCTAssertEqual(normalizedServerURL(from: "http://localhost:8000")?.absoluteString, "http://localhost:8000")
    }

    func testPathQueryAndFragmentAreStripped() {
        XCTAssertEqual(normalizedServerURL(from: "https://docs.llun.dev/some/path?x=1#frag")?.absoluteString, "https://docs.llun.dev")
    }
}
```

`DocsIOSTests/Features/Connect/RecentServersStoreTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class RecentServersStoreTests: XCTestCase {
    func testAddingToEmptyListInsertsIt() {
        let url = URL(string: "https://docs.llun.dev")!
        XCTAssertEqual(addingRecentServer(url, to: []), [url])
    }

    func testAddingDuplicateMovesItToFront() {
        let a = URL(string: "https://a.example.com")!
        let b = URL(string: "https://b.example.com")!
        let result = addingRecentServer(a, to: [b, a])
        XCTAssertEqual(result, [a, b])
    }

    func testAddingBeyondLimitDropsOldest() {
        let urls = (0..<5).map { URL(string: "https://server\($0).example.com")! }
        let newURL = URL(string: "https://new.example.com")!
        let result = addingRecentServer(newURL, to: urls, limit: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first, newURL)
        XCTAssertFalse(result.contains(urls.last!))
    }

    func testOrderOfOthersIsPreserved() {
        let a = URL(string: "https://a.example.com")!
        let b = URL(string: "https://b.example.com")!
        let c = URL(string: "https://c.example.com")!
        XCTAssertEqual(addingRecentServer(c, to: [a, b]), [c, a, b])
    }
}

final class RecentServersStorePersistenceTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.DocsIOS.tests.RecentServersStoreTests"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStartsEmptyWhenNoStoredData() {
        let store = RecentServersStore(userDefaults: userDefaults)
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testAddServerPersistsAcrossFreshInit() {
        let url = URL(string: "https://docs.llun.dev")!
        let first = RecentServersStore(userDefaults: userDefaults)
        first.addServer(url)

        let second = RecentServersStore(userDefaults: userDefaults)
        XCTAssertEqual(second.servers, [url])
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ServerURLInputTests -only-testing:DocsIOSTests/RecentServersStoreTests -only-testing:DocsIOSTests/RecentServersStorePersistenceTests`
Expected: FAIL — `cannot find 'normalizedServerURL' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Connect/ServerURLInput.swift`:
```swift
import Foundation

func normalizedServerURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: candidate),
          let scheme = components.scheme, ["http", "https"].contains(scheme),
          let host = components.host, !host.isEmpty else {
        return nil
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url
}
```

`DocsIOS/Features/Connect/RecentServersStore.swift`:
```swift
import Foundation

func addingRecentServer(_ url: URL, to existing: [URL], limit: Int = 5) -> [URL] {
    var updated = existing.filter { $0 != url }
    updated.insert(url, at: 0)
    if updated.count > limit {
        updated = Array(updated.prefix(limit))
    }
    return updated
}

@Observable
final class RecentServersStore {
    private static let key = "dev.llun.DocsIOS.recentServers"

    private let userDefaults: UserDefaults
    private(set) var servers: [URL]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.array(forKey: Self.key) as? [String] {
            self.servers = raw.compactMap(URL.init(string:))
        } else {
            self.servers = []
        }
    }

    func addServer(_ url: URL) {
        servers = addingRecentServer(url, to: servers)
        userDefaults.set(servers.map(\.absoluteString), forKey: Self.key)
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ServerURLInputTests -only-testing:DocsIOSTests/RecentServersStoreTests -only-testing:DocsIOSTests/RecentServersStorePersistenceTests`
Expected: PASS — `Executed 16 tests, with 0 failures` (10 ServerURLInputTests + 4 RecentServersStoreTests + 2 RecentServersStorePersistenceTests). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 131 tests, with 0 failures` (115 from the prior eight plans + 16 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Connect/ServerURLInput.swift DocsIOS/Features/Connect/RecentServersStore.swift DocsIOSTests/Features/Connect/ServerURLInputTests.swift DocsIOSTests/Features/Connect/RecentServersStoreTests.swift
git commit -m "Add ServerURLInput and RecentServersStore"
```

---

### Task 2: ConnectViewModel

**Files:**
- Create: `DocsIOS/Features/Connect/ConnectViewModel.swift`
- Test: `DocsIOSTests/Features/Connect/ConnectViewModelTests.swift`

**Interfaces:**
- Consumes: `normalizedServerURL`, `RecentServersStore` (Task 1), `SessionStore` (Plan 8), `DocsAPIClient` (Plan 7).
- Produces: `@MainActor @Observable final class ConnectViewModel` (`init(sessionStore:recentServers:apiClientFactory:)`, `serverURLInput: String`, `isPresentingWebLogin: Bool`, `errorMessage: String?`, `pendingServerURL: URL?` read-only, `func startSignIn()`, `func selectRecentServer(_ url: URL)`, `func handleLoginComplete() async`) — consumed by Task 3's `ConnectView`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Connect/ConnectViewModelTests.swift`:
```swift
import XCTest
@testable import DocsIOS

@MainActor
final class ConnectViewModelTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.DocsIOS.tests.ConnectViewModelTests"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.stubHandler = nil
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.stubHandler = nil
        super.tearDown()
    }

    private func makeViewModel(stub: @escaping @Sendable (URLRequest) -> MockURLProtocol.Stub) -> ConnectViewModel {
        MockURLProtocol.stubHandler = stub
        let sessionStore = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        let recentServers = RecentServersStore(userDefaults: userDefaults)
        return ConnectViewModel(
            sessionStore: sessionStore,
            recentServers: recentServers,
            apiClientFactory: { serverURL in
                DocsAPIClient(
                    baseURL: serverURL.appendingPathComponent("api/v1.0/"),
                    session: MockURLProtocol.makeSession(),
                    cookieProvider: { [] }
                )
            }
        )
    }

    func testStartSignInWithValidInputPresentsWebLogin() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"

        viewModel.startSignIn()

        XCTAssertTrue(viewModel.isPresentingWebLogin)
        XCTAssertEqual(viewModel.pendingServerURL?.absoluteString, "https://docs.llun.dev")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testStartSignInWithInvalidInputShowsErrorAndDoesNotPresent() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "   "

        viewModel.startSignIn()

        XCTAssertFalse(viewModel.isPresentingWebLogin)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testHandleLoginCompleteSuccessSignsInAndRecordsRecentServer() async throws {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertFalse(viewModel.isPresentingWebLogin)
        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.sessionStore.serverURL?.absoluteString, "https://docs.llun.dev")
        XCTAssertEqual(viewModel.recentServers.servers.map(\.absoluteString), ["https://docs.llun.dev"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testHandleLoginCompleteFailureShowsErrorAndDoesNotSignIn() async throws {
        let viewModel = makeViewModel { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertFalse(viewModel.sessionStore.isAuthenticated)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.recentServers.servers.isEmpty)
    }

    func testSelectRecentServerPresentsWebLoginForThatServer() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        let url = URL(string: "https://old.example.com")!

        viewModel.selectRecentServer(url)

        XCTAssertTrue(viewModel.isPresentingWebLogin)
        XCTAssertEqual(viewModel.pendingServerURL, url)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ConnectViewModelTests`
Expected: FAIL — `cannot find 'ConnectViewModel' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Connect/ConnectViewModel.swift`:
```swift
import Foundation

@MainActor
@Observable
final class ConnectViewModel {
    var serverURLInput: String = ""
    var isPresentingWebLogin = false
    var errorMessage: String?
    private(set) var pendingServerURL: URL?

    let sessionStore: SessionStore
    let recentServers: RecentServersStore
    private let apiClientFactory: (URL) -> DocsAPIClient

    init(
        sessionStore: SessionStore,
        recentServers: RecentServersStore,
        apiClientFactory: @escaping (URL) -> DocsAPIClient = { serverURL in
            DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))
        }
    ) {
        self.sessionStore = sessionStore
        self.recentServers = recentServers
        self.apiClientFactory = apiClientFactory
    }

    func startSignIn() {
        guard let url = normalizedServerURL(from: serverURLInput) else {
            errorMessage = "Enter a valid server address."
            return
        }
        errorMessage = nil
        pendingServerURL = url
        isPresentingWebLogin = true
    }

    func selectRecentServer(_ url: URL) {
        errorMessage = nil
        pendingServerURL = url
        isPresentingWebLogin = true
    }

    func handleLoginComplete() async {
        isPresentingWebLogin = false
        guard let serverURL = pendingServerURL else { return }

        struct Me: Decodable {}
        let client = apiClientFactory(serverURL)
        do {
            let _: Me = try await client.get("users/me/")
            try sessionStore.signIn(serverURL: serverURL)
            recentServers.addServer(serverURL)
        } catch {
            errorMessage = "Sign-in could not be confirmed. Please try again."
        }
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ConnectViewModelTests`
Expected: PASS — `Executed 5 tests, with 0 failures`. Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 136 tests, with 0 failures` (131 from Task 1 + 5 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Connect/ConnectViewModel.swift DocsIOSTests/Features/Connect/ConnectViewModelTests.swift
git commit -m "Add ConnectViewModel"
```

---

### Task 3: WebLoginView, ConnectView, and RootView wiring

**Files:**
- Create: `DocsIOS/Features/Connect/WebLoginView.swift`
- Create: `DocsIOS/Features/Connect/ConnectView.swift`
- Modify: `DocsIOS/App/RootView.swift`

**Interfaces:**
- Consumes: `isLoginNavigationComplete`, `syncCookies` (Plan 8), `ConnectViewModel` (Task 2), `SessionStore`, `RecentServersStore` (Task 1/Plan 8), DesignSystem components (`DocsTextField`, `DocsButton`, `ListSection`, `ListRow`, `DocsColor`/`DocsFont`/`DocsSpacing`).
- Produces: `struct WebLoginView: UIViewRepresentable`, `struct ConnectView: View` — `RootView` is modified to construct and show `ConnectView` when `!sessionStore.isAuthenticated`.

This task has no XCTest steps — see Global Constraints for why (UI glue verified by build-check and a Simulator screenshot, not XCTest).

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Connect/WebLoginView.swift`:
```swift
import SwiftUI
import WebKit

struct WebLoginView: UIViewRepresentable {
    let url: URL
    let serverHost: String
    let onLoginComplete: @MainActor () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(serverHost: serverHost, onLoginComplete: onLoginComplete)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let serverHost: String
        private let onLoginComplete: @MainActor () -> Void
        private var didComplete = false

        init(serverHost: String, onLoginComplete: @escaping @MainActor () -> Void) {
            self.serverHost = serverHost
            self.onLoginComplete = onLoginComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didComplete,
                  let url = webView.url,
                  isLoginNavigationComplete(url: url, serverHost: serverHost) else { return }
            didComplete = true

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                syncCookies(cookies, into: HTTPCookieStorage.shared)
                Task { @MainActor in
                    self.onLoginComplete()
                }
            }
        }
    }
}
```

`DocsIOS/Features/Connect/ConnectView.swift`:
```swift
import SwiftUI

struct ConnectView: View {
    @Bindable var viewModel: ConnectViewModel

    var body: some View {
        VStack(spacing: DocsSpacing.spaceLG) {
            VStack(spacing: DocsSpacing.spaceXS) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(DocsColor.brandFill)
                Text("Welcome to Docs")
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
            }

            DocsTextField(label: "Server", text: $viewModel.serverURLInput, placeholder: "docs.example.com")

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
            }

            DocsButton(title: signInTitle, fullWidth: true) {
                viewModel.startSignIn()
            }

            if !viewModel.recentServers.servers.isEmpty {
                ListSection(header: "Recent servers") {
                    ForEach(viewModel.recentServers.servers, id: \.self) { server in
                        ListRow(systemImage: "clock", title: server.host ?? server.absoluteString, action: {
                            viewModel.selectRecentServer(server)
                        })
                    }
                }
            }

            Spacer()
        }
        .padding(DocsSpacing.spaceBase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DocsColor.surfacePage)
        .sheet(isPresented: $viewModel.isPresentingWebLogin) {
            if let url = viewModel.pendingServerURL {
                WebLoginView(
                    url: authenticationURL(server: url),
                    serverHost: url.host ?? "",
                    onLoginComplete: {
                        Task { await viewModel.handleLoginComplete() }
                    }
                )
            }
        }
    }

    private var signInTitle: String {
        if let host = normalizedServerURL(from: viewModel.serverURLInput)?.host {
            return "Sign in to \(host)"
        }
        return "Sign in"
    }
}

#Preview {
    ConnectView(viewModel: ConnectViewModel(sessionStore: SessionStore(), recentServers: RecentServersStore()))
}
```

`DocsIOS/App/RootView.swift` — replace entirely with:
```swift
import SwiftUI

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated {
            VStack(spacing: DocsSpacing.spaceSM) {
                Text("Docs")
                    .font(DocsFont.largeTitle)
                    .foregroundStyle(DocsColor.textPrimary)
                Text("Connected to your documents")
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textSecondary)
            }
            .padding(DocsSpacing.spaceBase)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DocsColor.surfacePage)
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
Expected: `** BUILD SUCCEEDED **`. If you see a crash inside `initializeWithCopy`/`AG::Graph` symbols on the *next* step (running on the Simulator, not this build step), see the Architecture section's note on a transient flake found during this plan's own validation — retry once with a clean `DerivedData` (`rm -rf ~/Library/Developer/Xcode/DerivedData/DocsIOS-*`) before treating it as a real regression.

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 136 tests, with 0 failures` (no new tests in this task; confirms Task 3's changes didn't regress anything).

- [ ] **Step 3: Visually verify in the Simulator**

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/DocsIOS-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "DocsIOS.app")
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted dev.llun.DocsIOS
xcrun simctl io booted screenshot /tmp/connect-screen-verify.png
```
Expected: the screenshot shows the logo, "Welcome to Docs" title, a "Server" text field with placeholder "docs.example.com", and a "Sign in" button — matching the design spec's Connect screen description (logo, title, server URL field, sign-in button; recent servers list appears only once at least one server has been used, so an empty list is correctly absent on first launch).

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Connect/WebLoginView.swift DocsIOS/Features/Connect/ConnectView.swift DocsIOS/App/RootView.swift
git commit -m "Add WebLoginView and ConnectView, wire RootView to show Connect screen when unauthenticated"
```

## Self-Review Notes

- **Spec coverage:** Implements the design spec's Connect screen description ("logo, 'Welcome to Docs', server URL TextField, recent servers list, 'Sign in to {host}' button → WebView login") and the Authentication section's remaining unimplemented steps (presenting the WKWebView, detecting completion, syncing cookies, the native confirmation call, persisting sign-in state) on top of Plans 7 and 8's foundations. `RootView`'s "authenticated" branch is intentionally left as the pre-existing placeholder — building the real Home screen is Phase 5, a later plan.
- **Placeholder scan:** No TBD/TODO. The "Docs" / "Connected to your documents" placeholder in `RootView`'s authenticated branch is pre-existing from Plan 1, not new in this plan, and is expected to be replaced by the Home screen plan.
- **Type consistency:** `normalizedServerURL`, `addingRecentServer`, `RecentServersStore`, `ConnectViewModel`, `WebLoginView`, `WebLoginView.Coordinator`, `ConnectView` are each defined once. `ConnectViewModel` correctly reuses `SessionStore`/`DocsAPIClient` from the prior two plans rather than reimplementing session or networking logic.
- **Cross-file validation:** All code in this plan (all three tasks, including the two Swift 6 strict-concurrency fixes — `@MainActor` on `ConnectViewModel`/its tests, and the `@MainActor () -> Void` closure typing in `WebLoginView` — and the real Simulator screenshot verification) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 136 tests, with 0 failures` plus a passing Simulator screenshot of the Connect screen.
