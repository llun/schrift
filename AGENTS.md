# AGENTS.md

Guidance for every AI agent and new contributor working in this repository.
Read this before making changes. It captures the conventions the existing code
already follows and the safety rules that must never be broken.

The full architecture/design rationale lives in
[`docs/architecture.md`](docs/architecture.md).
This file is the shorter, operational "how we write code here" companion.

## What Schrift is

- A native **SwiftUI iOS/iPadOS client** for
  [La Suite Numérique Docs](https://github.com/suitenumerique/docs), talking to a
  self-hosted instance (`docs.llun.dev`).
- **Swift 6**, minimum deployment **iOS 26.0**, universal (iPhone + iPad). The
  floor is 26 so the app can use the current system components unconditionally
  — they render Liquid Glass when built against that SDK — with no
  `#available` fallbacks to keep visually in sync.
- **Zero third-party runtime dependencies.** Everything — including the Yjs CRDT
  encoder used to save documents — is hand-written on Apple frameworks. Keep it
  that way (see [Safety](#safety--never-add-anything-dangerous)).
- Architecture is MVVM-ish: SwiftUI views + `@Observable` view models + an
  `actor`-based async/await networking layer.

## Safety — never add anything dangerous

This repository has deliberate security hygiene (secrets git-ignored and supplied
only via env / GitHub Actions secrets; Keychain-backed auth; correct Django CSRF
`Origin`/`Referer` handling; standard TLS validation; zero third-party
dependencies; the app only ever talks to the user's own server). **Preserve it.**
Do **not** do any of the following without explicit human sign-off:

- **Never commit secrets or signing material.** No `*.p8`, `*.p12`,
  `*.mobileprovision`, `*.cer`, SSH/deploy private keys, signing passphrases, or App
  Store Connect API keys. Never remove or narrow the "Signing secrets — NEVER
  commit these" rules in `.gitignore`, and never `git add -f` an ignored file.
- **Never hardcode credentials, API keys, team ids, passphrases, or server URLs**
  in source, tests, CI, or the Fastfile. Secrets come from env / Actions secrets;
  the server URL is always user-supplied at runtime (`normalizedServerURL`) — do
  not bake in a default host or token in app code, in **any** build
  configuration. (Deterministic host literals in test fixtures and `#Preview`
  blocks — `docs.llun.dev`, `example.com` — are fine and are the existing
  convention; that carve-out is the sole exception.) This file and any doc you
  write must use placeholders, never real secret values.
- **Never weaken or disable TLS validation.** Do not add a `URLSession` or
  `WKWebView` auth-challenge handler that trusts arbitrary `serverTrust`, and
  never add an `NSAppTransportSecurity` / `NSAllowsArbitraryLoads` exception in
  `project.yml`.
- **Never remove or blank the CSRF protection.** Keep the `X-CSRFToken` header and
  the matching `Origin` + `Referer` headers on every non-GET request, and keep the
  `csrftoken` cookie lookup in `CSRF.swift`. Route new mutating endpoints through
  `send`/`sendVoid`.
- **Never log, print, serialize, or transmit** session cookies, the CSRF token,
  request/response headers, Keychain data, or any Apple signing secret. There is
  no such logging today — keep it that way (no `print`/`os_log`/`NSLog` of
  sensitive values).
- **Keep session/auth state in the Keychain** (`KeychainStore`). Never move it to
  UserDefaults, a plist, or a plaintext file. Don't add `kSecAttrSynchronizable`
  (iCloud sync) or weaken `kSecAttrAccessible` without sign-off. The current
  baseline is **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**, applied on every
  `save` — the `ThisDeviceOnly` half keeps a live session out of encrypted backups
  and device transfers (a restored backup must not carry someone's session onto
  another device; the cost is one re-login after a migration), and because `save`
  is delete-then-add, the attribute must be re-applied on **every** write or an
  overwrite silently downgrades to the default. `KeychainStoreTests` reads the
  stored attributes back rather than trusting the save query.
- **Never make a `WKWebView` inspectable outside `#if DEBUG`.** `makeLoginWebView()` is
  the only place that sets `isInspectable`, so Release (TestFlight) builds never expose
  the login page or its cookies to an attached Web Inspector.
- **Never loosen server-URL or login-host validation.** Keep `normalizedServerURL`
  restricted to `http`/`https` (rejecting `javascript:`/`file:`/`data:`) and keep
  `isLoginNavigationComplete` bound to the exact `serverHost`, so a captured
  session cookie stays scoped to the server the user chose.
- **Never commit the generated `Schrift.xcodeproj`/`.xcworkspace`** — it is
  produced from `project.yml` by `xcodegen generate` and is git-ignored.
- **Never add telemetry, analytics, crash reporting, or any network call to a
  third-party host.** The app only talks to the user's self-hosted server; no
  beacons, remote logging, or hardcoded external endpoints.
- **Never upload a photo's original metadata.** `preparedJPEGData` re-encodes from a
  bare `CGImage` so EXIF — **including GPS coordinates** — is stripped. Copying the
  source properties into `CGImageDestinationAddImage` would silently geotag every
  upload; `ImagePreparationTests.testStripsGPSAndIdentifyingMetadata` locks it.
- **Never turn a server-supplied string into a request URL or an embedded document
  URL without pinning it to the server origin.** `URL(string:relativeTo:)` does not
  do this: `//evil.com/x` resolves to `https://evil.com/x`. `checkMedia(path:)` and
  `absoluteServerURL(for:)` are the only two such places — keep their guards.
- **Preserve the zero-third-party-dependency posture.** No new SPM / CocoaPods /
  Carthage packages. Get explicit sign-off before adding any dependency, and never
  add one from an unvetted or arbitrary source.
- **In CI/scripts, never expose secrets.** Keep the `printf '%s' | gh secret set`
  stdin pattern (no secrets in argv/`--body`), never `set -x` or echo secrets,
  never widen `upload-artifact` paths to catch keys/keychains/`.p8`, keep the CI
  1Password service account read-only and scoped to the `Schrift` vault, and never print values read from 1Password (`scripts/fetch-signing.sh` masks them). Never add a
  `pull_request`/`pull_request_target` trigger to `testflight.yml` (it would
  expose signing secrets to fork PRs), and conversely never add a secret or a
  `pull_request_target` trigger to `pr-checks.yml` — the PR-check workflow stays
  secret-free on its fork-safe triggers (`pull_request`, plus a `push` trigger
  restricted to `main`, which only ever runs already-merged code).
- **Never introduce arbitrary code execution or destructive shell/git
  operations** — no `eval` of remote input, `curl | bash`, `rm -rf`,
  `git push --force` to shared branches, force-adding ignored files, or history
  rewrites. Keep `set -euo pipefail`, `umask 077` and the
  token-via-stdin handling (`gh secret set` fed by `printf`) in `scripts/bootstrap-testflight.sh`.

When a requested change would require crossing one of these lines, stop and ask a
human first.

## Task workflow — start here

The rest of this file is reference; this is the order to work in. Each step
names the section with the details.

1. **Orient.** Skim this file's headings, then read the sections your task
   touches in full. Architecture rationale lives in the design spec
   ([`docs/architecture.md`](docs/architecture.md)).
2. **Set up and baseline.** `brew install xcodegen`, `xcodegen generate`, then
   run the full test suite ([Build, run, test](docs/build-and-test.md#build-run-test)) so you start
   from a known-green state.
3. **Copy the closest exemplar.** New code must read like the code around it
   ([Coding standards](#coding-standards)) — start from the nearest existing
   example and its tests:

   | Adding | Start from |
   |---|---|
   | An API endpoint | `Schrift/Core/Networking/ShareEndpoints.swift` (+ its `…ClientTests`) |
   | A Codable API model | `Schrift/Core/Networking/ShareModels.swift` |
   | A design-system component | `Schrift/DesignSystem/Components/Badge.swift` (style resolver) |
   | A screen + view model | `Schrift/Features/Shared/` (cached list) or `Schrift/Features/Options/` (sheet) |
   | A UserDefaults store | `Schrift/Features/Search/RecentSearchesStore.swift` |
   | An offline cache store | `Schrift/Features/Editor/DocumentChildrenCacheStore.swift` |
   | A new localized string | `Schrift/Core/Localization/L10nKey.swift` + `Strings+en.swift` (English only — see [Localization & appearance](docs/standards/localization-and-appearance.md#localization--appearance)) |

4. **Work test-first.** Every behavior change lands with tests in the same
   change ([Testing conventions](docs/standards/testing.md#testing-conventions)); iterate with
   `-only-testing:`, finish with the full suite.
5. **Verify by change type**, beyond the tests themselves:
   - `Core/Yjs`: the golden hex tests must pass **unchanged** — if you think
     the bytes must change, stop and get human sign-off first.
   - Design system: update the component's `#Preview` catalog. Token values are
     visual and are not unit-tested; a new color token must be added to the
     relevant hand-listed invariant in `DocsColorTokenInvariantTests` (contrast
     pair, light-vs-dark relationship); the suite does not discover tokens itself.
   - Any change that alters the design: update the Sketch component library
     too ([Sketch source of truth](docs/standards/design-system.md#sketch-source-of-truth)).
   - Networking: assert method, path (trailing slash, lowercase UUID), and
     body via `MockURLProtocol`; mutating endpoints go through `send`/`sendVoid`.
   - View models: poll with `waitUntil`; cover the error path (friendly
     `errorKey`) and the cached-data silence rules.
   - Build/CI/release: update the living docs in the same change
     ([Docs convention](#docs-convention)).
6. **Definition of done** — a change is finished only when all of these hold
   (the PR template, `.github/PULL_REQUEST_TEMPLATE.md`, embeds this list):
   - `swift format --recursive --in-place Schrift SchriftTests SchriftUITests` has been run;
   - the full test suite passes locally;
     (on Linux the test suite cannot run, and the formatter only can when a
     Swift toolchain is available — see
     [Working without Xcode (Linux)](#working-without-xcode-linux);
     the `Build & Test` check stands in for whatever couldn't run, and it must
     be green)
   - new/changed behavior is covered by tests;
   - affected docs are updated in the same change;
   - the PR title is a Conventional Commit (it becomes the squash-commit
     subject that drives the release version);
   - the [PR review loop](#pr-review-loop--required-for-all-agent-work) has
     run and every thread is resolved;
   - **`Build & Test` is green on the latest pushed state.**

## Coding standards

These are conventions the codebase already follows consistently. Match them so
new code reads like the surrounding code. Each area has its own guide; read the
ones your change touches in full before editing, and only those.

| Area | Guide |
|---|---|
| Build, run, test | [`docs/build-and-test.md`](docs/build-and-test.md) |
| Repository layout | [`docs/repository-layout.md`](docs/repository-layout.md) |
| Concurrency (Swift 6) | [`docs/standards/concurrency.md`](docs/standards/concurrency.md) |
| Views & view models (MVVM) | [`docs/standards/views-and-view-models.md`](docs/standards/views-and-view-models.md) |
| Localization & appearance | [`docs/standards/localization-and-appearance.md`](docs/standards/localization-and-appearance.md) |
| Dependency injection & testability | [`docs/standards/dependency-injection.md`](docs/standards/dependency-injection.md) |
| Networking (`Core/Networking`) | [`docs/standards/networking.md`](docs/standards/networking.md) |
| Design system (`DesignSystem`) | [`docs/standards/design-system.md`](docs/standards/design-system.md) |
| The Yjs CRDT core (`Core/Yjs`) — the live replica | [`docs/standards/yjs-core.md`](docs/standards/yjs-core.md) |
| The document engine (`Features/Editor/Engine`, B6a/B6b) | [`docs/standards/document-engine.md`](docs/standards/document-engine.md) |
| Editor & the on-device save (`Core/Yjs`) | [`docs/standards/editor-save.md`](docs/standards/editor-save.md) |
| Persistence (`*Store` types) | [`docs/standards/persistence.md`](docs/standards/persistence.md) |
| Style & comments | [`docs/standards/style-and-comments.md`](docs/standards/style-and-comments.md) |
| Testing conventions | [`docs/standards/testing.md`](docs/standards/testing.md) |

## Working without Xcode (Linux)

Some environments (for example a Linux container) have **no Xcode**, no
`xcodebuild`, no iOS simulators and no Apple SDKs. In those environments:

- **Never attempt to build, test, or run the app.** UIKit/SwiftUI/XCTest and
  every Apple framework are unavailable; any `xcodebuild`/`xcrun` invocation
  will fail. The macOS **`Build & Test`** check on the PR
  ([`.github/workflows/pr-checks.yml`](.github/workflows/pr-checks.yml)) is
  the **source of truth for build and test results** — push the branch and
  read the check, don't try to reproduce it locally on Linux.
- **There are currently no Linux-testable targets.** The repo has no
  `Package.swift`; everything is built via XcodeGen + `xcodebuild` on macOS.
  (`Core/Yjs` and the other pure-logic layers are Foundation-only and could be
  extracted into a SwiftPM package to enable `swift test` on Linux, but that
  is a deliberate, separate change — don't do it as a side effect.)
- **Before every push, do what Linux allows:**
  - Formatting: if a Swift 6 toolchain is available, run
    `swift format --recursive --in-place Schrift SchriftTests SchriftUITests` and commit the
    result — the PR checks fail on any unformatted file. If no toolchain is
    available, match the surrounding style (`.swift-format`: 4-space indent,
    120 columns) and expect the CI formatting gate to be the arbiter.
  - `xcodegen generate` is unavailable too — treat `project.yml` edits as
    unverified until CI builds them.

## Commit conventions

- One logical change per commit; **Conventional Commit** messages (the PR
  title becomes the squash-commit subject that drives the release version —
  see [Build, run, test](docs/build-and-test.md#build-run-test)).
- When fixing a CI failure on your **own PR branch**, amend the previous
  commit and `git push --force-with-lease` instead of stacking fixup
  commits. This is compatible with the safety rule against force-pushing
  **shared** branches — a PR branch you authored is not shared; never
  force-push `main`. If the force-push is rejected, a normal follow-up
  commit is acceptable because PRs are squash-merged anyway. Don't amend
  commits that a [review](#pr-review-loop--required-for-all-agent-work)
  round has already commented on — line-anchored review threads pin to a
  `commit_id`, and rewriting it orphans them; review fixes are pushed
  as normal commits.

## Docs convention

- **Keep the docs in lockstep with the code, in the same change.** A change that
  affects how the project is **built, tested, released, or run** (`project.yml`
  build config, `.github/workflows/`, `ci_scripts/`, fastlane lanes, `scripts/`,
  tooling/toolchain versions, the test command) updates every doc that describes
  it: this `AGENTS.md`, `README.md`, the guides under `docs/`,
  `docs/testflight-setup.md` and `docs/ci.md`. Never land a workflow change while
  the docs still describe the old behavior.
- **Fix what your change made false; add nothing by default.** What a change
  teaches goes into the first place that fits: a test (with the reason in its
  failure message); a comment at the code it binds; an in-place edit to the
  area's guide under `docs/standards/` or a design doc; this file only for what
  every change needs. Edit or replace existing text rather than appending a new
  paragraph, don't restate what the code or a test already says, and leave
  history (PR numbers, phases, dates) in the PR and git.
- **Size and history are checked.** `context-budget.json` gives this file a byte
  ceiling that only comes down, and `node scripts/context-budget.mjs` (run by
  the `Context budget` check) fails when it goes over that ceiling or when an
  added line in it or a guide it links to carries a PR number, a phase number or
  "since <date>". When this file shrinks, run the script with `--update`.
- **Agent and contributor guidance lives in this file and the guides it links
  to.** Never duplicate it in a separate agent-specific file.
- **Design and architecture decisions live in the living docs under `docs/`**
  ([`docs/README.md`](docs/README.md) indexes them). When behavior changes,
  update the relevant doc **in place, in the same change** — never a new file
  per change — and keep its body current with the shipped app.
- **Do not commit plans, specs or task briefs.** Do not add a `docs/plans/` or
  `docs/specs/` folder, and do not commit per-feature dated plan files
  (`YYYY-MM-DD-<name>.md`); the repo deliberately has none. Fold lasting
  guidance into the living docs, rewritten as **current guidance**.
- **Local scratch stays out of git.** `.superpowers/` and `docs/superpowers/` are
  git-ignored scratch locations; never force-add anything from them.

## PR review loop — required for all agent work

Whenever an AI agent works on this repository, the resulting pull request must
go through the following review loop. Run it **every time** new work is pushed
to a PR that is ready for review — on the initial push and after every
follow-up push made outside an active loop. Pushes made while addressing
comments (step 2) do **not** start a new loop: the re-review that follows
them is simply the next round and counts toward the same round cap in step 3.

1. **Independent review.** Have a reviewer with a fresh context, who did not
   write the change, review **all** the code in the PR (the full diff, not
   just the latest commit) — correctness, the conventions in this file, test
   coverage, and the [Safety](#safety--never-add-anything-dangerous) rules.
   Post **everything it finds as review comments on the PR** — anchored to
   the relevant file and line when the finding maps to a line in the diff,
   otherwise as a top-level PR comment naming the file.
2. **Address every comment.** Fix each finding (or explain in the thread why
   no change is needed). Then push
   the fixes, **reply to each comment** describing what was done, and **mark
   the thread as resolved** (a top-level PR comment has no resolvable thread —
   a reply on the PR conversation recording the outcome counts as resolving
   it).
3. **Repeat** steps 1–2 until a full round surfaces **no new issues to
   address**, or **20 rounds** have run in the current loop — whichever
   comes first. A follow-up push outside an active loop starts a fresh cap.
   If the cap is hit with issues still open, say so explicitly on the PR
   instead of stopping silently.

If an automated review bot runs on PRs, treat its comments like any other
finding and give it up to 20 minutes to finish before the round ends. Re-request
its review only when there are commits newer than its last review, and never
re-request a bot that already timed out on the current pushed state. A round
ends only when every active bot has reviewed or timed out.

The loop — and the agent's work — is **not finished until the PR's `Build &
Test` check is green on the latest pushed state**. A CI failure on the PR is
an issue to address exactly like a review comment: diagnose it, push the fix,
and let the check re-run. Never leave a PR as "done" with failing or unrun
checks, and never merge around a red check.

**Mechanics (gh CLI).** The loop's steps map to these commands:

- Line-anchored review comment:
  `gh api repos/<owner>/<repo>/pulls/<n>/comments -f body='…' -f path='<file>'
  -F line=<line> -f side=RIGHT
  -f commit_id="$(gh pr view <n> --json headRefOid -q .headRefOid)"`.
  Top-level PR comment: `gh pr comment <n> --body '…'`. Reply in a thread: the
  same `pulls/<n>/comments` endpoint with `-F in_reply_to=<comment-id>`.
- Resolving a review thread needs **GraphQL** (REST cannot do it). List
  threads + ids:
  `gh api graphql -f query='query{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<n>){reviewThreads(first:100){nodes{id isResolved path comments(first:1){nodes{databaseId body}}}}}}}'`;
  resolve one:
  `gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<id>"}){thread{isResolved}}}'`.
