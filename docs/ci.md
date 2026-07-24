# CI: PR checks & the merge guard

Schrift has two CI concerns, deliberately kept in **separate workflows**:

| Workflow | Trigger | Purpose | Secrets |
|---|---|---|---|
| [`.github/workflows/pr-checks.yml`](../.github/workflows/pr-checks.yml) | `pull_request` → `main`, `push` → `main`, `workflow_dispatch` | Build + run the full XCTest suite | **None — and it must stay that way** |
| [`.github/workflows/testflight.yml`](../.github/workflows/testflight.yml) | `push` → `main`, `workflow_dispatch` | Signed Release build → TestFlight → tag + GitHub Release | Signing/ASC secrets |

Never merge the two: `testflight.yml` must never gain a `pull_request` /
`pull_request_target` trigger (it would expose signing secrets to fork PRs), and
`pr-checks.yml` must never gain a secret or a `pull_request_target` trigger (PRs
run on the fork-safe `pull_request` trigger, and its `push` trigger fires only
for `main` — code that has already been reviewed and merged — so it stays safe
by construction). See the Safety section in [`CLAUDE.md`](../CLAUDE.md).

## What runs on every PR and every push to `main`

`pr-checks.yml` runs one job on `macos-latest`. It runs on every PR targeting
`main` **and on every push to `main`**: PRs are squash-merged with no "branch
up to date" requirement, so when `main` has moved since the PR's last CI run,
the squash commit's tree was never built (a `pull_request` run builds the
branch merged into `main` *as of run time*, which can be stale by merge) —
the push run is the post-merge verification of the real `main` history
(`testflight.yml` builds Release but runs no tests). The job is:

1. Formatting gate — runs Apple's `swift-format` (bundled with the Xcode
   toolchain; config in [`.swift-format`](../.swift-format)) over `Schrift/`
   and `SchriftTests/` and fails on any resulting diff, prettier-style. Fix
   locally with `swift format --recursive --in-place Schrift SchriftTests`.
2. `xcodegen generate` — the `.xcodeproj` is generated from `project.yml` and
   not committed, so CI must regenerate it before any `xcodebuild` call.
3. Pick an iPhone simulator — prefers the documented **iPhone 17**, falls back
   to the first available iPhone on the runner image (image lineups change).
4. `xcodebuild test -project Schrift.xcodeproj -scheme Schrift` on that
   simulator — the same suite as the documented local test command. Simulator
   builds **ad-hoc sign** (no certificates, Team ID, or secrets involved);
   don't disable code signing — the Keychain tests need the test host's
   ad-hoc entitlements and fail with `errSecMissingEntitlement (-34018)` in a
   fully unsigned host.

On failure the `TestResults.xcresult` bundle is uploaded as a run artifact
(7-day retention) for debugging.

Runs are per-PR concurrency-cancelled: a new push cancels the in-flight run
for that PR, so a "cancelled" Build & Test run right after a push is normal —
the new run supersedes it. Push runs on `main` share one concurrency group
the same way: two quick merges cancel the first squash commit's run, so only
the newest `main` state gets verified — the post-merge check is cumulative,
not per-commit. It is also observe-only: a red push run does **not** gate
`testflight.yml`, which ships the same commit independently (coupling the two
would tie the secret-free workflow to the secret-bearing one). The job also
has a 30-minute timeout to convert hangs into failures; normal runs finish
well under it.

### Toolchain drift

The formatting gate uses whatever swift-format ships with the runner's
`latest-stable` Xcode, and **CI's toolchain is the canonical formatter** — the
tree was last formatted with swift-format 6.3.3. swift-format output can
change between toolchain releases, so a runner-image Xcode bump can make the
gate fail on files a PR never touched. The remedy is a standalone tree-wide
reformat commit (`ci: reformat for swift-format X.Y`): run
`swift format --recursive --in-place Schrift SchriftTests` with the same
toolchain CI uses (the gate logs `swift format --version` at the top of the
step) and land it on its own. Local formatting with a different toolchain
version may disagree with CI — trust the gate's diff output.

The job surfaces as the status check **`Build & Test`**. That exact name is
what the merge guard requires — renaming the job in `pr-checks.yml` breaks the
guard until the ruleset below is updated to match.

Xcode Cloud (optional, via [`ci_scripts/ci_post_clone.sh`](../ci_scripts/ci_post_clone.sh))
is an alternative build/test runner and is unaffected by this workflow; if
enabled, keep it build/test-only per `docs/testflight-setup.md`.

### Action pinning

Every `uses:` in both workflows is pinned to a **full commit SHA**, not a
mutable tag, with the human-readable version in a trailing comment
(`actions/checkout@<sha> # v7.0.1`). A tag can be moved to point at new code; a
SHA cannot, so a compromised or retargeted upstream tag can't silently change
what runs — this matters most in `testflight.yml`, which holds the signing
secrets, so its third-party actions (`maxim-lobanov/setup-xcode`,
`ruby/setup-ruby`) are the highest-value pins.

[`.github/dependabot.yml`](../.github/dependabot.yml) opens a monthly PR when a
pinned action has a newer release, updating both the SHA and the comment; the
PR still has to pass **`Build & Test`** before it can land, so a bump is never
unverified. To bump a pin by hand, resolve the tag to its commit SHA
(`gh api repos/<owner>/<repo>/git/ref/tags/<tag>`, dereferencing an annotated
tag to `.object.sha`) and update the `# vX.Y.Z` comment to match. Dependabot is
**actions-only**: the app keeps its zero-third-party-runtime-dependency posture,
and Ruby/fastlane are bumped intentionally with `bundle update`, never
automatically.

## Making the check required (the guard)

Enforcement is repository configuration, not code — a repo **admin** must turn
it on once. Use a **ruleset** (Settings → Rules → Rulesets; rulesets apply to
admins by default and are inspectable by anyone with read access, unlike
classic branch protection).

**UI path:** Settings → Rules → Rulesets → *New branch ruleset* →
- Name: `main: require PR checks`; Enforcement: **Active**
- Target branches: *Include default branch*
- Enable **Require status checks to pass** → *Add checks* → `Build & Test`
  (source: GitHub Actions). Leave "Require branches to be up to date" **off**
  so the merge → auto-TestFlight flow stays low-friction.

**CLI equivalent** (repo admin, with `gh` authenticated):

```sh
gh api repos/llun/schrift/rulesets -X POST --input - <<'JSON'
{
  "name": "main: require PR checks",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "Build & Test", "integration_id": 15368 }
        ]
      }
    }
  ]
}
JSON
```

Notes:

- `integration_id` 15368 is the GitHub Actions app — it pins the required
  check to Actions so nothing else can satisfy it.
- `strict_required_status_checks_policy: false` = no "branch up to date"
  requirement (matching the UI advice above).
- The **UI** check picker only lists check names it has already seen, so use
  the UI path **after** the first `Build & Test` run has completed on a PR.
  The `gh api` call above accepts an arbitrary context string and works
  before any run.
- The required check effectively blocks **direct pushes to `main` too**: a
  ruleset `required_status_checks` rule rejects any ref update unless the
  check has passed on the pushed commit *before* the push — and a freshly
  authored commit never carries one (the workflow's `push` trigger only fires
  *after* a push is accepted, so it can't satisfy the rule). All changes must
  land via a PR (worth knowing before hotfixing `main`).
