# Testing conventions

- **A test asserts behavior or an invariant that can regress.** Never restate a
  constant, default, enum raw value or lookup-table line for line, and never check
  visual-only values (colors, glyphs, the app icon/logo); fold per-case mirrors
  into one invariant or table-driven test, and split a test file when it mixes
  unrelated concerns.
- **XCTest only** — never Swift Testing (no `import Testing` / `@Test` / `#expect`).
  `final class <Type>Tests: XCTestCase`, `@testable import Schrift`, mirroring the
  source tree. Add `@MainActor` to test classes whose subject is `@MainActor`.
- **Splitting a test class across files** uses a shared base: a non-final
  `@MainActor class <Name>TestCase: XCTestCase` in its own file holds the shared
  `setUp`/`tearDown` and helpers (`internal`, not `private`, and no `test…`
  methods), and each file is a `final class <Concern>Tests: <Name>TestCase`. Never
  inherit test methods from another test class (XCTest would run them twice).
- Fake HTTP with **`MockURLProtocol`** (`makeSession()` + `stubHandler`; inspect
  `lastRequest` for single-request tests). Call **`MockURLProtocol.reset()`** in
  `tearDown` — not just `stubHandler = nil`. It also drains deferred deliveries:
  one outliving its test reports into a torn-down `URLSession` and kills the test
  *process*, blaming whichever unrelated test was running at the time. It further
  **retires every session token `makeSession()` handed out** (each session tags its
  requests via `httpAdditionalHeaders`), so a coordinator's unstructured save `Task`
  that outlives its test has its leaked request **rejected in `startLoading`**
  instead of recording a phantom `PATCH …/content/` into a **later** test's
  `RequestRecorder` and flaking its `waitAndConfirmNever` / `savesInFlight`
  assertions (`MockURLProtocolIsolationTests` pins this deterministically). It does
  **not** invalidate the session: a new task on an invalidated `URLSession` raises an
  uncatchable ObjC `NSException` that crashes the whole test process — the exact
  failure mode `reset()` exists to prevent, and one the leaked task would hit
  because its `session.data(for:)` runs on the `DocsAPIClient` actor concurrently
  with the main-actor `reset()`.
  For multi-request flows (VM loads, the two-PATCH save, coalescing), pass the
  shared thread-safe `RequestRecorder` (`SchriftTests/Support/AsyncTestHelpers.swift`)
  into the `stubHandler` (`log.record(request)`) and assert on `methods` /
  `count(ofMethod:urlContaining:)`. Never hit the real network.
- To hold a response open, return `Stub(..., delay:)` — **not** `Thread.sleep`
  inside the handler. Stubs are delivered on URLSession's single protocol thread,
  so sleeping there stalls every other in-flight request and silently serializes
  the very overlap a concurrent test exists to exercise (`Stub.delay` defers
  delivery instead; `delay: 0` keeps the original synchronous path). And when a
  test overlaps two requests, **pin their order explicitly** — gate the second on
  a `RequestRecorder` count. "Which request reached the stub first" and "which
  caller ran first" are different questions, and `async let` answers neither.
- **A delay expresses a duration; when the test means an *ordering*, say so with
  `Stub(..., releasedBy:)` instead.** `MockURLProtocol.ResponseGate` holds a
  response until the test calls `open()`, so "this stale snapshot may only land
  once the create has resolved" stops being a bet that the interval outlasts the
  machine — a bet a loaded runner wins. `PagesTreeViewModelTests` is the worked
  example, and the reason the rule exists: its two create-vs-in-flight-fetch
  tests held a 0.3 s GET and required the create to resolve first, which went red
  once on CI on a PR touching neither the view model nor its tests. Note what the
  slip costs is **not** uniform — one of the pair *failed*, the other kept passing
  while quietly exercising nothing, which is the worse half and invisible in a
  green run. Reach for a gate whenever the delay is standing in for a
  happens-before, and keep `delay:` for the case it really is a duration (a
  debounce window, a plausibly-slow server). Mechanics: a gate **latches** (a
  request arriving at an already-open gate is delivered rather than stranded);
  `reset()` drains gated deliveries exactly as it drains timed ones, so an
  unopened gate can no more fire into the next test than an unexpired timer can
  — poll **`MockURLProtocol.deferredDeliveryCount`**, never `lastRequest`, to
  know a deferred response is really in hand, because `lastRequest` is set
  before the handler runs and before anything is registered;
  and because a gate nothing opens stalls the test body past the `tearDown`
  that would have drained it — for a full minute, until URLSession's own
  request timeout releases it as an opaque `-1001` attributed to nothing — a
  30 s failsafe (`ResponseGate.defaultFailsafeTimeout`) pre-empts that with a
  failure naming the held request and the line the gate was built on. The
  failsafe is a stall detector, **never** part of an ordering:
  `ResponseGate(failsafeTimeout:)` exists so the failsafe itself can be tested
  (a backstop nothing exercises is one nobody knows is broken — the latch test
  found it silently carrying another test's whole regression coverage), not so
  a test can tune a deadline into an ordering, which is the bet the type exists
  to stop taking.
- Isolate UserDefaults per test (`UserDefaults(suiteName:)` +
  `removePersistentDomain` in setUp/tearDown); inject `FakeKeychainStore`, and
  for cookie-dependent subjects the shared in-memory `FakeCookieStorage`
  (`SchriftTests/Core/Auth/`) — never the real `HTTPCookieStorage.shared`;
  disable background tasks with `.noop`.
- Never disable code signing when running tests (e.g. `CODE_SIGNING_ALLOWED=NO`):
  simulator builds ad-hoc sign for free, and the Keychain tests require the test
  host's ad-hoc signature/entitlements — an unsigned host fails with
  `errSecMissingEntitlement (-34018)` (see `docs/ci.md`).
- **Never run two `xcodegen`/`xcodebuild` jobs at once in the same checkout.**
  Run tests one at a time, or give each run its own simulator and
  `-derivedDataPath` (see the next bullet).
- **Two `xcodebuild test` runs on the same simulator kill each other.** With
  several worktrees checked out, a concurrent run in
  another one aborts yours with `Test crashed with signal kill`/`signal term` and
  "Restarting after unexpected exit, crash, or test timeout" — blaming whichever
  slow test happened to be running, a different one each time. Suspect the
  environment before the code; the giveaway is a test name in your `.xcresult`
  that doesn't exist on your branch. Before concluding *anything* from a
  repeated-run soak, give it a dedicated device (`xcrun simctl create SchriftSoak
  com.apple.CoreSimulator.SimDeviceType.iPhone-17 <runtime>`, then
  `-destination "platform=iOS Simulator,id=<udid>"`) and a private
  `-derivedDataPath`, and soak the **base commit** the same way as a control. A
  red run proves causation no more than a green run proves correctness.
- Async tests are `func test...() async`; `await` the subject directly and assert
  on its published state. Poll eventual state with the shared `waitUntil { }`
  helper — **no `XCTestExpectation`, and never a sleep to wait for expected
  state**. `waitUntil` means "this must become true": it **fails the test on
  timeout**, so a stalled wait reports where it stalled rather than as a
  confusing assertion failure further down. For "assert nothing more happened",
  use its counterpart `waitAndConfirmNever { }`, which fails if the condition
  ever becomes true. A short `Task.sleep` is allowed only for the one case
  neither expresses: advancing real time inside a debounce window. Simulate a
  slow response with `Stub(delay:)`, not in the test body.
- **Never block a thread in an async test or on an actor**: no `NSCondition`,
  `DispatchSemaphore`/`DispatchGroup.wait()`, `Thread.sleep`/`usleep` or spin on a lock
  where async code or an actor runs. Swift concurrency's cooperative pool has one thread
  per CPU (three on the CI runner, one under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), so
  each parked thread is one fewer to run the work that would release it, and a park inside
  an actor also holds the actor. Instead: wait for state with `await waitUntil { }`; hold
  an actor at a point with a gate that suspends, `Latch.passing()` from an async hook
  (`DocumentReplicaSession.Hooks.beforeMessage`); hold an HTTP response with
  `Stub(..., releasedBy:)`; inject an async `sleep`/clock rather than sleeping. Two
  exceptions, each named in the test: `Latch.pass()` (blocking) inside a synchronous
  product hook that stands in for synchronous work (`ReplicaStore`'s interrupt in the
  journal's disk write, `Hooks.onReplicaWork`), with at most one such gate closed at a time
  and opened from the main actor; and holding the main thread on purpose when a busy main
  thread is the subject (`postHolding`). While a blocking gate holds a pool thread, the
  test resumes from an `await` (or finishes) only on another one, so open it before the
  test returns. Under a one-thread pool
  (`TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` on `xcodebuild test-without-building`)
  the tests that await with such a gate closed (the disk and attach gates in
  `NativeSessionRegistryTests`, `NativeEditorActivationTests` and some of
  `ReplicaSessionOrderingTests`) deadlock or race by construction; a test whose only gate
  suspends must pass there, so check a new one that way. A hang with
  every thread idle is a lost resume, not starvation: read the spindump before blaming a
  gate (the 2026-11 CI hang in `testPendingTypingIntentsAndTheMailboxAreBounded` was a
  dropped `.close`, and no thread was blocked).
- Assert thrown errors with a **typed do/catch** (`XCTFail` on the success path,
  match the concrete `DocsAPIError` case) — not `XCTAssertThrowsError`.
- Fixtures are **inline** JSON string literals; use deterministic repeating-digit
  UUIDs. Test method names describe the behavior and its outcome.
- Checklist projection and filtered-scroll UI tests establish filtering through
  the test host's `--initially-hide-completed` intent and verify switch value,
  hidden count, reveal availability and completed-row absence before the action
  under test. A synthesized switch tap can leave the fixture unfiltered, falsely
  blaming a later remote update or mode swap. Mixed/all-completed flows retain
  actual switch and reveal interactions; do not replace their interaction coverage
  with configured state or weaken scroll-return assertions. These interaction
  flows use one 200ms stationary press on the native switch and require its off-to-on value
  transition before continuing. CI captured a correctly targeted 50ms synthesized
  tap that left the switch off. Do not retry gestures until green or treat an
  unactivated filter as a mode-swap defect.
  When the switch does not turn on, the filter-enable step attaches the switch frame,
  hittability, a screenshot and the hierarchy so a failure is diagnosable from the `.xcresult`.
  Every hosted failure of that press was the UI bundle's first test (the first app
  launch after the unit tests). The simulator system log (`xcrun xcresulttool export
  diagnostics`, `system.logarchive`) shows `apsd` stuck reconnecting and starving the
  simulator, which makes three things late: (a) `backboardd` attaches the session's first
  XCUITest virtual digitizer 210-440ms late, flushing a 200ms press as a 10-49ms burst,
  and the iOS 26 switch (a `UILongPressGestureRecognizer` on `_UILiquidLensView`) ignores
  presses of 0.01s or less; (b) Accessibility lazily loads PDFKit on the app's main thread
  (~0.8s) mid-tap, and a row's `.onTapGesture` gives up on holds of ~0.9s or more; (c) the
  app can stay non-idle ~9s after a correct Edit/Done swap. Mitigations:
  `XCUIApplication.absorbFirstTouch(on:)` spends the first touch on inert text (not a
  retry), `setEditing`'s waiter is 15s, and CI boots out `apsd`. The press, the Edit/Done
  press and `ChecklistHitTests`' offset taps still wait for the target's frame to hold still
  (`waitForStableFrame`); that is a precondition, and the frame was stable in every captured
  failure. Read `docs/ci.md` before changing any of it.
- Other UI-test waits follow the same rule: wait for the state the next step needs, not for existence.
  `NativeEditorUITests` focuses through `focusFirstParagraph` (editor frame settled, then a settled
  keyboard), reads typed text with a waited predicate, and stops at its first failed step
  (`continueAfterFailure = false`). The all-completed checklist flows wait for the reveal's frame to
  settle before measuring or pressing it, and for the editing rows to exist. The reading-controls
  accessibility audit reruns once only when XCTest reports its `-56` "Audit failed to complete in time"
  budget error; findings are recorded as failures, never thrown, so they still fail the test.
