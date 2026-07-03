# CI: PR checks & the merge guard

Schrift has two CI concerns, deliberately kept in **separate workflows**:

| Workflow | Trigger | Purpose | Secrets |
|---|---|---|---|
| [`.github/workflows/pr-checks.yml`](../.github/workflows/pr-checks.yml) | `pull_request` → `main`, `workflow_dispatch` | Build + run the full XCTest suite | **None — and it must stay that way** |
| [`.github/workflows/testflight.yml`](../.github/workflows/testflight.yml) | `push` → `main`, `workflow_dispatch` | Signed Release build → TestFlight → tag + GitHub Release | Signing/ASC secrets |

Never merge the two: `testflight.yml` must never gain a `pull_request` /
`pull_request_target` trigger (it would expose signing secrets to fork PRs), and
`pr-checks.yml` must never gain a secret or a `pull_request_target` trigger (it
runs on fork-safe `pull_request`, so it is safe by construction). See the
Safety section in [`CLAUDE.md`](../CLAUDE.md).

## What runs on every PR

`pr-checks.yml` runs one job on `macos-latest`:

1. `xcodegen generate` — the `.xcodeproj` is generated from `project.yml` and
   not committed, so CI must regenerate it before any `xcodebuild` call.
2. Pick an iPhone simulator — prefers the documented **iPhone 17**, falls back
   to the first available iPhone on the runner image (image lineups change).
3. `xcodebuild test -project Schrift.xcodeproj -scheme Schrift` on that
   simulator — the same suite as the documented local test command. No code
   signing (`CODE_SIGNING_ALLOWED=NO`); simulator tests don't need it.

On failure the `TestResults.xcresult` bundle is uploaded as a run artifact
(7-day retention) for debugging.

The job surfaces as the status check **`Build & Test`**. That exact name is
what the merge guard requires — renaming the job in `pr-checks.yml` breaks the
guard until the ruleset below is updated to match.

Xcode Cloud (optional, via [`ci_scripts/ci_post_clone.sh`](../ci_scripts/ci_post_clone.sh))
is an alternative build/test runner and is unaffected by this workflow; if
enabled, keep it build/test-only per `docs/testflight-setup.md`.

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
- GitHub's check picker only lists check names it has already seen, so create
  the ruleset **after** the first `Build & Test` run has completed on a PR.
- The check only runs on PRs targeting `main`, which is exactly where the
  ruleset requires it — direct pushes to `main` are not blocked by this rule
  (add a "Restrict pushes"/PR-required rule to the same ruleset if you want
  that too).
