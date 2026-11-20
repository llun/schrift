# Dependency injection & testability

- Inject every collaborator through the initializer as a **protocol or closure
  type with a production default value**: `keychain: KeychainStoring =
  KeychainStore()`, `session: URLSession = .shared`, `userDefaults: UserDefaults =
  .standard`, `cookieProvider:`, `apiClientFactory:`, `backgroundTasks: .uiApplication`
  (tests pass `.noop`). No singletons or service locators.
- Wrap platform seams (Keychain, cookie storage, `UIApplication` background
  tasks) behind a minimal protocol or a small closure struct so tests inject a
  fake / `.noop`. To make a system type testable, declare a tiny protocol of just
  the methods you use and add a retroactive empty conformance
  (`extension HTTPCookieStorage: CookieStoring {}`).
- Extract branching / formatting / parsing logic into **top-level pure free
  functions** (or caseless-enum `static` funcs) that return `Equatable` value
  types, so it is unit-testable without SwiftUI, UIKit, or the network. This is
  why the design-system "style resolvers" return raw hex, not `Color`.
