# Auto-release to TestFlight on merge to `main`

**Date:** 2026-07-03
**Status:** Implemented

## Problem

TestFlight only shipped when someone pushed a `v*` tag by hand
(`testflight.yml` triggered on `push: tags: v*`). The last (and only) tag,
`v0.1.0` (`6561599`, cut 2026-07-02), predated the editor header redesign
(PR #27, `2451d82`) by ~10 hours, so testers were stuck on an old build while
`main` moved 7 PRs ahead. Xcode Cloud *was* building `main` but only ran an
**Archive** action with no TestFlight distribution, so it never produced tester
builds either.

Goal: **every merge to `main` should bump the version, tag it, and ship to
TestFlight automatically.**

## Decisions

- **Versioning:** Conventional Commits. `feat:` → minor, `feat!:` /
  `BREAKING CHANGE` → major, anything else (incl. non-conforming subjects) →
  patch, so every merge ships at least a patch.
- **Trigger:** replace the `v*` tag trigger with `push: branches: [main]` (plus
  `workflow_dispatch` as a manual fallback).
- **TestFlight owner:** GitHub Actions. Xcode Cloud's archive-on-`main` workflow
  was deactivated by the owner so the two don't double-build or collide on build
  numbers. `ci_scripts/ci_post_clone.sh` stays so Xcode Cloud can be re-enabled
  for build/test-only PR checks later.
- **Version source of truth:** git tags, not a file. Nothing is committed back to
  `main`, which avoids a push→build→commit→push loop and keeps the version
  stateless.

## Design

1. **`scripts/next-version.sh`** — self-contained (no third-party tagging
   action, matching the repo's zero-dependency / auditable-CI posture). Reads the
   latest `v*` tag (`--sort=-v:refname`, `0.0.0` if none), scans commit subjects
   (`%s`) for `feat:` / `type!:` and bodies (`%B`) for `BREAKING CHANGE` since
   that tag, prints the next `X.Y.Z`.
2. **`.github/workflows/testflight.yml`** — trigger on push to `main` +
   `workflow_dispatch`; `permissions: contents: write`; checkout with
   `fetch-depth: 0` (needs tags); compute version → build+upload with
   `MARKETING_VERSION=<computed>` and `CURRENT_PROJECT_VERSION=github.run_number`
   → **on success** push `v<version>` (via `GITHUB_TOKEN`) and `gh release
   create --generate-notes`. `concurrency: testflight-release`,
   `cancel-in-progress: false` serializes racing merges.
3. **`fastlane/Fastfile`** (`beta` lane) — inject `MARKETING_VERSION` into
   `xcargs` alongside `CURRENT_PROJECT_VERSION` when the env var is set; local
   runs (no env) keep `project.yml`'s default.
4. **Docs** — `CLAUDE.md`, `README.md`, `docs/testflight-setup.md` updated to the
   auto-on-merge flow.

## Safety / loop analysis

- No commit to `main` from CI → the push trigger can't loop.
- Tag pushed with `GITHUB_TOKEN`; GitHub does not start workflow runs from
  `GITHUB_TOKEN` pushes → the (now-removed) tag path couldn't loop even if kept.
- Tag/Release steps run only after a successful upload → a failed build burns no
  version number; the next merge retries the same computed version.
- Build number is `github.run_number` (globally monotonic). **Do not rename or
  move the workflow file** — that resets `run_number` and TestFlight rejects a
  lower build number.
- No `pull_request` / `pull_request_target` trigger (would leak signing secrets
  to fork PRs) — per the repo safety rules.

## Gotchas / follow-ups

- Existing squash-commit titles are **not** Conventional Commits (`Fix …`,
  `Add …`). Until PR titles adopt `feat:` / `fix:`, every release is a patch bump.
  This is intentional (never blocks a release) but means minor/major bumps need
  conforming titles.
- First auto-release from current `main` will be **`v0.1.1`** (latest tag
  `v0.1.0`; commits since are non-conventional → patch).
- Escape hatch: `[skip ci]` in a commit message skips the build (native GitHub
  behavior, no extra code).
