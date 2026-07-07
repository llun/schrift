# Auth Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Amendment (2026-07-07):** The session-persistence model below was superseded
> on 2026-07-04 by commit `291aa48` (PR #41, "persist session cookies across app
> kills and re-login on real 401"). `SessionStore` no longer persists "exactly
> two things": it is now `@MainActor @Observable`, snapshots the server's cookies
> into the Keychain (`dev.llun.Schrift.sessionCookies`) on every `signIn`,
> restores them into `HTTPCookieStorage.shared` synchronously in `init`, and
> exposes a `needsReauthentication` flag that drives an app-level re-login sheet
> on a real 401 — the claim below that the `docs_sessionid` cookie lives *only*
> in the OS cookie store is exactly the bug that work fixed (session-only cookies
> are dropped when iOS kills the process). `CookieStoring` also gained
> `cookies(for:)` / `deleteCookie(_:)`. See
> `docs/superpowers/plans/2026-07-04-persist-session-cookies-and-reauth.md` and
> `Schrift/Core/Auth/SessionStore.swift` / `SessionCookies.swift`. Retained as a
> dated record.

**Goal:** Build the `Core/Auth` layer's testable foundation — `KeychainStore`/`SessionStore` (server URL + authenticated-flag persistence) and the pure decision logic a WKWebView-driven OIDC login flow needs (`authenticationURL`, `isLoginNavigationComplete`, cookie-sync). This is the second plan outside the DesignSystem layer, building on `Core/Networking` from the prior plan. Deliberately excludes the actual WKWebView `UIViewRepresentable`/SwiftUI sheet and the Connect screen itself — per the design spec's build sequence, those are Phase 4 ("Connect screen, wired to real auth"), consumed and visually verified together in the next plan, not built speculatively ahead of a screen that uses them.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan. The trickiest part — how a `WKWebView` navigation delegate can reliably detect "OIDC login just succeeded" using only observable navigation events — was **not guessed**: the actual `suitenumerique/docs` backend source was researched (it uses `django-lasuite`'s `oidc_login` module wrapping `mozilla-django-oidc`, not django-allauth) to confirm the real redirect chain: `GET /api/v1.0/authenticate/` → 302 to the external IdP's authorization endpoint → IdP 302s back to `/api/v1.0/callback/` → 302 to the site root (or `next`, rarely used by the reference frontend). Key decisions:

- **Login-complete detection is `url.host == serverHost && !url.path.hasPrefix("/api/v1.0/")`** — a pure function (`isLoginNavigationComplete`), not "landed back on server root" (too narrow — an SPA route also counts) and not "path no longer contains `authenticate`" (too broad — would also fire while still on the external IdP's login page, which is a *different host* and also doesn't contain `/api/v1.0/`, causing a false-positive dismissal before the user even authenticates). Both the host check and the path-prefix check are required together.
- **A native `GET /api/v1.0/users/me/` call (via the existing `DocsAPIClient`, not the WebView) is the positive confirmation step**, fired only after `isLoginNavigationComplete` returns true. The reference frontend's own `useAuthQuery` treats exactly this endpoint's 401-vs-200 as the authentication signal, and it requires no body/params. This positive-confirmation step happens in the next plan's Connect-screen glue (it needs a live `DocsAPIClient`, which needs `SessionStore.serverURL`, which needs the sign-in UI) — this plan only builds the pure detection function it depends on.
- **`KeychainStoring` is a protocol, `KeychainStore` (Security framework: `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete`) is its production implementation.** Unlike the `HTTPCookieStorage()` fragility found in the prior plan, a real Keychain read/write/delete round trip *was* validated directly in a real XCTest/iOS-Simulator run and works reliably with no special entitlements needed for a basic `kSecClassGenericPassword` item — but `SessionStore` still takes an injected `KeychainStoring` (production default `KeychainStore()`) so its tests use a plain in-memory fake and never touch the real Keychain, consistent with this project's established dependency-injection-for-testability pattern (`DocsAPIClient`'s `cookieProvider` closure, `Document`'s decoder).
- **`SessionStore` also takes an injected `UserDefaults`** (production default `.standard`); tests use `UserDefaults(suiteName:)` with a unique suite name, cleared in `setUp`/`tearDown` via `removePersistentDomain(forName:)` — this is a fully-supported, reliable pattern (unlike the non-supported `HTTPCookieStorage()` zero-arg initializer found before), so no further validation caveat is needed here.
- **`SessionStore` persists exactly two things**, matching the design spec's Authentication section verbatim: `serverURL: URL?` via `UserDefaults` (not sensitive), and `isAuthenticated: Bool` via Keychain (the spec explicitly calls out "Keychain for anything sensitive" for the authenticated flag). The actual session credential (the `docs_sessionid` cookie) is not duplicated into `SessionStore` — it lives in `HTTPCookieStorage.shared`, synced there from the WKWebView's cookie jar, which is a separate, OS-managed persistent store `URLSession` already reads from automatically.
- **Cookie sync is `syncCookies(_ cookies: [HTTPCookie], into storage: CookieStoring)` against a small `CookieStoring` protocol** (`func setCookie(_ cookie: HTTPCookie)`), not `HTTPCookieStorage` directly — `HTTPCookieStorage` conforms via a one-line extension (it already has a matching method), so production code passes `HTTPCookieStorage.shared` while tests pass an in-memory fake that records calls. This sidesteps the prior plan's `HTTPCookieStorage()`-instantiation fragility entirely by never constructing one in a test.
- **`@Observable final class SessionStore`**, not an actor — its Keychain/UserDefaults calls are synchronous, and SwiftUI views read its properties directly, matching the design spec's "SwiftUI views + `@Observable` view models" architecture statement.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies — Keychain access uses the Security framework directly (`Security` import), not a wrapper library.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `KeychainStoreTests` uses a real Keychain item under a test-only key (`dev.llun.DocsIOS.test.keychainSmokeTest`) and must delete it in `tearDownWithError`, so it never leaves stray state in the Simulator's Keychain across test runs.
- `SessionStoreTests` must never touch `UserDefaults.standard` or the real Keychain — always construct `SessionStore` with an isolated `UserDefaults(suiteName:)` (cleared via `removePersistentDomain(forName:)` in `setUp`/`tearDown`) and a fake `KeychainStoring`.
- Do not build the actual `WKWebView`/`UIViewRepresentable` login sheet or the Connect screen in this plan — that is explicitly the next plan's scope (Phase 4 of the design spec's build sequence), once there is a real screen to consume and visually verify it against.
- `isLoginNavigationComplete` must check both host and path prefix together — do not simplify it to a path-only or host-only check; both were shown necessary to avoid false positives against the external IdP's login page (see Architecture above).

## File Structure

```
DocsIOS/
└── Core/
    └── Auth/
        ├── KeychainStore.swift                              — KeychainStoring, KeychainError, KeychainStore (Task 1)
        ├── SessionStore.swift                                — SessionStore (Task 1)
        └── WebLogin.swift                                    — authenticationURL(server:), isLoginNavigationComplete(url:serverHost:apiPathPrefix:), CookieStoring, syncCookies(_:into:) (Task 2)

DocsIOSTests/
└── Core/
    └── Auth/
        ├── KeychainStoreTests.swift                          — Task 1
        ├── FakeKeychainStore.swift                            — Task 1 (test helper, not a test case)
        ├── SessionStoreTests.swift                            — Task 1
        └── WebLoginTests.swift                               — Task 2
```

---

### Task 1: KeychainStore + SessionStore

**Files:**
- Create: `DocsIOS/Core/Auth/KeychainStore.swift`
- Create: `DocsIOS/Core/Auth/SessionStore.swift`
- Test: `DocsIOSTests/Core/Auth/KeychainStoreTests.swift`
- Test: `DocsIOSTests/Core/Auth/FakeKeychainStore.swift` (test helper, not a test case)
- Test: `DocsIOSTests/Core/Auth/SessionStoreTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation + Security).
- Produces: `protocol KeychainStoring`, `enum KeychainError: Error, Equatable`, `struct KeychainStore: KeychainStoring`, `@Observable final class SessionStore` (`init(userDefaults:keychain:)`, `serverURL: URL?` read-only, `isAuthenticated: Bool` read-only, `func signIn(serverURL: URL) throws`, `func signOut() throws`) — `SessionStore` is consumed by the next plan's Connect screen and by every later screen that needs to know the current server/auth state.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Auth/FakeKeychainStore.swift`:
```swift
import Foundation
@testable import DocsIOS

final class FakeKeychainStore: KeychainStoring {
    private var storage: [String: Data] = [:]

    func save(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func load(forKey key: String) throws -> Data? {
        storage[key]
    }

    func delete(forKey key: String) throws {
        storage.removeValue(forKey: key)
    }
}
```

`DocsIOSTests/Core/Auth/KeychainStoreTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore()
    private let key = "dev.llun.DocsIOS.test.keychainSmokeTest"

    override func tearDownWithError() throws {
        try store.delete(forKey: key)
        try super.tearDownWithError()
    }

    func testSaveThenLoadRoundTripsInRealSimulatorKeychain() throws {
        let data = "hello-keychain".data(using: .utf8)!
        try store.save(data, forKey: key)
        let loaded = try store.load(forKey: key)
        XCTAssertEqual(loaded, data)
    }

    func testLoadMissingKeyReturnsNil() throws {
        let loaded = try store.load(forKey: "dev.llun.DocsIOS.test.doesNotExist")
        XCTAssertNil(loaded)
    }

    func testSaveOverwritesExistingValue() throws {
        try store.save("first".data(using: .utf8)!, forKey: key)
        try store.save("second".data(using: .utf8)!, forKey: key)
        let loaded = try store.load(forKey: key)
        XCTAssertEqual(loaded, "second".data(using: .utf8))
    }

    func testDeleteRemovesValue() throws {
        try store.save("temp".data(using: .utf8)!, forKey: key)
        try store.delete(forKey: key)
        let loaded = try store.load(forKey: key)
        XCTAssertNil(loaded)
    }

    func testDeleteOnMissingKeyDoesNotThrow() throws {
        XCTAssertNoThrow(try store.delete(forKey: "dev.llun.DocsIOS.test.neverExisted"))
    }
}
```

`DocsIOSTests/Core/Auth/SessionStoreTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class SessionStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.DocsIOS.tests.SessionStoreTests"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStartsUnauthenticatedWithNoServerURLWhenStorageEmpty() {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        XCTAssertNil(store.serverURL)
        XCTAssertFalse(store.isAuthenticated)
    }

    func testSignInPersistsServerURLAndAuthenticatedFlag() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        let url = URL(string: "https://docs.llun.dev")!
        try store.signIn(serverURL: url)
        XCTAssertEqual(store.serverURL, url)
        XCTAssertTrue(store.isAuthenticated)
    }

    func testSignOutClearsAuthenticatedFlagButKeepsServerURL() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        let url = URL(string: "https://docs.llun.dev")!
        try store.signIn(serverURL: url)
        try store.signOut()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertEqual(store.serverURL, url)
    }

    func testStateReloadsFromStorageOnFreshInit() throws {
        let keychain = FakeKeychainStore()
        let url = URL(string: "https://docs.llun.dev")!
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain)
        try first.signIn(serverURL: url)

        let second = SessionStore(userDefaults: userDefaults, keychain: keychain)
        XCTAssertEqual(second.serverURL, url)
        XCTAssertTrue(second.isAuthenticated)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/KeychainStoreTests -only-testing:DocsIOSTests/SessionStoreTests`
Expected: FAIL — `cannot find 'KeychainStore' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Auth/KeychainStore.swift`:
```swift
import Foundation
import Security

protocol KeychainStoring {
    func save(_ data: Data, forKey key: String) throws
    func load(forKey key: String) throws -> Data?
    func delete(forKey key: String) throws
}

enum KeychainError: Error, Equatable {
    case unhandled(status: OSStatus)
}

struct KeychainStore: KeychainStoring {
    func save(_ data: Data, forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
    }

    func load(forKey key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
        return result as? Data
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }
}
```

`DocsIOS/Core/Auth/SessionStore.swift`:
```swift
import Foundation

@Observable
final class SessionStore {
    private static let serverURLKey = "dev.llun.DocsIOS.serverURL"
    private static let authenticatedKeychainKey = "dev.llun.DocsIOS.isAuthenticated"

    private let userDefaults: UserDefaults
    private let keychain: KeychainStoring

    private(set) var serverURL: URL?
    private(set) var isAuthenticated: Bool

    init(userDefaults: UserDefaults = .standard, keychain: KeychainStoring = KeychainStore()) {
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.serverURL = userDefaults.url(forKey: Self.serverURLKey)
        self.isAuthenticated = (try? keychain.load(forKey: Self.authenticatedKeychainKey)) != nil
    }

    func signIn(serverURL: URL) throws {
        userDefaults.set(serverURL, forKey: Self.serverURLKey)
        try keychain.save(Data([1]), forKey: Self.authenticatedKeychainKey)
        self.serverURL = serverURL
        self.isAuthenticated = true
    }

    func signOut() throws {
        try keychain.delete(forKey: Self.authenticatedKeychainKey)
        self.isAuthenticated = false
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/KeychainStoreTests -only-testing:DocsIOSTests/SessionStoreTests`
Expected: PASS — `Executed 9 tests, with 0 failures` (5 KeychainStoreTests + 4 SessionStoreTests). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 106 tests, with 0 failures` (97 from the prior seven plans + 9 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Auth/KeychainStore.swift DocsIOS/Core/Auth/SessionStore.swift DocsIOSTests/Core/Auth/KeychainStoreTests.swift DocsIOSTests/Core/Auth/FakeKeychainStore.swift DocsIOSTests/Core/Auth/SessionStoreTests.swift
git commit -m "Add KeychainStore and SessionStore"
```

---

### Task 2: WebLoginController login-detection logic

**Files:**
- Create: `DocsIOS/Core/Auth/WebLogin.swift`
- Test: `DocsIOSTests/Core/Auth/WebLoginTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `func authenticationURL(server: URL) -> URL`, `func isLoginNavigationComplete(url: URL, serverHost: String, apiPathPrefix: String = "/api/v1.0/") -> Bool`, `protocol CookieStoring`, `extension HTTPCookieStorage: CookieStoring`, `func syncCookies(_ cookies: [HTTPCookie], into storage: CookieStoring)` — all four consumed by the next plan's actual `WKWebView`/`UIViewRepresentable` login sheet and Connect screen.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Auth/WebLoginTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class WebLoginTests: XCTestCase {
    func testAuthenticationURLAppendsAuthenticatePath() {
        let server = URL(string: "https://docs.llun.dev")!
        XCTAssertEqual(authenticationURL(server: server).absoluteString, "https://docs.llun.dev/api/v1.0/authenticate/")
    }

    func testAuthenticationURLHandlesTrailingSlashOnServer() {
        let server = URL(string: "https://docs.llun.dev/")!
        XCTAssertEqual(authenticationURL(server: server).absoluteString, "https://docs.llun.dev/api/v1.0/authenticate/")
    }

    func testInitialAuthenticateNavigationIsNotComplete() {
        let url = URL(string: "https://docs.llun.dev/api/v1.0/authenticate/")!
        XCTAssertFalse(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testExternalIdentityProviderNavigationIsNotComplete() {
        let url = URL(string: "https://idp.example.com/login?client_id=docs")!
        XCTAssertFalse(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testCallbackNavigationIsNotComplete() {
        let url = URL(string: "https://docs.llun.dev/api/v1.0/callback/?code=abc&state=xyz")!
        XCTAssertFalse(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testLandingOnSiteRootAfterLoginIsComplete() {
        let url = URL(string: "https://docs.llun.dev/")!
        XCTAssertTrue(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testLandingOnAnySPARouteOnServerHostIsComplete() {
        let url = URL(string: "https://docs.llun.dev/some/spa/route")!
        XCTAssertTrue(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testSyncCookiesForwardsEachCookieToStorage() {
        final class FakeCookieStoring: CookieStoring {
            private(set) var savedCookies: [HTTPCookie] = []
            func setCookie(_ cookie: HTTPCookie) { savedCookies.append(cookie) }
        }
        let sessionCookie = HTTPCookie(properties: [.domain: "docs.llun.dev", .path: "/", .name: "docs_sessionid", .value: "abc"])!
        let csrfCookie = HTTPCookie(properties: [.domain: "docs.llun.dev", .path: "/", .name: "csrftoken", .value: "xyz"])!
        let fake = FakeCookieStoring()

        syncCookies([sessionCookie, csrfCookie], into: fake)

        XCTAssertEqual(fake.savedCookies.count, 2)
        XCTAssertEqual(Set(fake.savedCookies.map(\.name)), Set(["docs_sessionid", "csrftoken"]))
    }

    func testSyncCookiesWithEmptyArrayDoesNothing() {
        final class FakeCookieStoring: CookieStoring {
            private(set) var savedCookies: [HTTPCookie] = []
            func setCookie(_ cookie: HTTPCookie) { savedCookies.append(cookie) }
        }
        let fake = FakeCookieStoring()
        syncCookies([], into: fake)
        XCTAssertTrue(fake.savedCookies.isEmpty)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/WebLoginTests`
Expected: FAIL — `cannot find 'authenticationURL' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Auth/WebLogin.swift`:
```swift
import Foundation

func authenticationURL(server: URL) -> URL {
    server.appendingPathComponent("api/v1.0/authenticate/")
}

func isLoginNavigationComplete(url: URL, serverHost: String, apiPathPrefix: String = "/api/v1.0/") -> Bool {
    url.host == serverHost && !url.path.hasPrefix(apiPathPrefix)
}

protocol CookieStoring {
    func setCookie(_ cookie: HTTPCookie)
}

extension HTTPCookieStorage: CookieStoring {}

func syncCookies(_ cookies: [HTTPCookie], into storage: CookieStoring) {
    for cookie in cookies {
        storage.setCookie(cookie)
    }
}
```

- [ ] **Step 4: Regenerate and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 115 tests, with 0 failures` (97 from the prior seven plans + 9 Task 1 + 9 Task 2 = 115)

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Auth/WebLogin.swift DocsIOSTests/Core/Auth/WebLoginTests.swift
git commit -m "Add WebLogin login-detection and cookie-sync logic"
```

## Self-Review Notes

- **Spec coverage:** Implements the persistence half ("Server URL + a flag that we're authenticated is persisted") and the detection/cookie-sync half ("WKNavigationDelegate watches for navigation back to a recognized 'logged in' location", "session cookie is read from WKWebsiteDataStore... and synced into HTTPCookieStorage.shared") of the design spec's Authentication section. Deliberately excludes the actual `WKWebView` SwiftUI sheet and Connect screen — those are the next plan's scope (Phase 4), which also needs to wire up the native `GET /api/v1.0/users/me/` confirmation call this plan intentionally leaves to it (that call needs a live `DocsAPIClient` pointed at the just-entered server, which only exists once the Connect screen's sign-in flow is running).
- **Real-backend cross-check:** The login-detection function's design was driven by researching the actual `suitenumerique/docs` backend source (confirmed it uses `django-lasuite`'s OIDC wrapper around `mozilla-django-oidc`, not django-allauth) rather than guessing at the redirect chain shape. This caught a real false-positive risk: a naive "path no longer contains `authenticate`" check would incorrectly fire while the WKWebView is still showing the external identity provider's own login page (a different host, whose paths also don't contain `/api/v1.0/`).
- **Placeholder scan:** No TBD/TODO.
- **Type consistency:** `KeychainStoring`, `KeychainError`, `KeychainStore`, `SessionStore`, `authenticationURL`, `isLoginNavigationComplete`, `CookieStoring`, `syncCookies` are each defined once.
- **Cross-file validation:** All code in this plan (both tasks, including the real-Keychain smoke test, the isolated-`UserDefaults`-suite pattern, and the host+path-prefix login-detection logic) was compiled and test-run end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 115 tests, with 0 failures`.
