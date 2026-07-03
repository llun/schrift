# Shipping Schrift to TestFlight

This repo builds and uploads to TestFlight automatically via **fastlane** +
**GitHub Actions** (`.github/workflows/testflight.yml`). Almost all of the
setup is automated by [`scripts/bootstrap-testflight.sh`](../scripts/bootstrap-testflight.sh).

Everything is gated behind a **paid Apple Developer Program membership**
($99/yr). On a free Apple ID none of this works.

## Status of the local toolchain

Already done in this repo:

- Ruby **3.4.9** pinned via `.ruby-version` (local dev + CI use the same).
- fastlane installed (`bundle install`), `Gemfile.lock` committed.
- fastlane lanes `beta` (ship) and `bootstrap` (one-time setup) ready.
- CI reads signing assets from a private repo over SSH (a read-only deploy key,
  created for you by the bootstrap script — no manual GitHub token needed).

## Manual step 1: create an App Store Connect API key

Apple has no API to create the *first* API key, so this part must be done in the
web UI with your Apple ID. (First time only: click **Request Access** to enable
the App Store Connect API, then the **Team Keys** section appears.)

1. Sign in to <https://appstoreconnect.apple.com/access/integrations/api>
   → **Team Keys** → **＋**.
2. Name it e.g. `ci-testflight`, role **App Manager**, **Generate**.
3. Record:
   - **Key ID** (e.g. `2X9R4HXF34`)
   - **Issuer ID** (the UUID at the top of the page)
   - **Download the `.p8`** file (one download only — keep it safe).
4. Grab your **Team ID**: <https://developer.apple.com/account> → Membership →
   the 10-character string (e.g. `A1B2C3D4E5`).

That's everything only you can produce. Hand those four things off and the rest
is one command.

## Run the bootstrap (everything else, automated)

From the repo root:

```sh
ASC_KEY_ID=2X9R4HXF34 \
ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
ASC_KEY_P8=~/Downloads/AuthKey_2X9R4HXF34.p8 \
DEVELOPER_TEAM_ID=A1B2C3D4E5 \
./scripts/bootstrap-testflight.sh
```

This will:
1. create a private **`schrift-certificates`** repo (encrypted signing store),
2. generate a **read-only SSH deploy key** so CI can read it,
3. register the **App ID** `dev.llun.Schrift` on the Developer Portal,
4. generate the **Apple Distribution certificate + provisioning profile**,
5. set all seven **GitHub Actions secrets** on this repo.

It writes the generated `MATCH_PASSWORD` to `~/.schrift-testflight-secrets.txt`
(mode 600, never printed) — **save it to your password manager, then delete that
file** (you'll need the passphrase to renew certificates in about a year). Your
`.p8` is never printed or committed.

## Manual step 2: create the App Store Connect app record

Apple has no API to create an app record, so this one is done in the web UI
(the bundle id it needs is already registered by the bootstrap above):

1. <https://appstoreconnect.apple.com> → **Apps** → **＋** → **New App**
2. Platform **iOS**, Name **Schrift Docs** (the store listing name — the app
   still shows as *Schrift* on device via `CFBundleDisplayName`; "Schrift" alone
   was already taken on the App Store), Bundle ID **dev.llun.Schrift**, SKU
   `schrift-ios`.
3. Create. No screenshots/marketing are needed for TestFlight.

## Ship a build

**Just merge to `main`.** Every push to `main` runs the TestFlight workflow,
which:

1. computes the next version from the latest `v*` tag using Conventional
   Commits ([`scripts/next-version.sh`](../scripts/next-version.sh)) —
   `feat:` → minor, `feat!:` / `BREAKING CHANGE` → major, anything else → patch;
2. builds a signed Release archive and uploads it to TestFlight (build number =
   the workflow run number, which is monotonic), **waits for Apple to finish
   processing**, then attaches auto-generated **release notes** (the commit
   subjects since the last tag) and makes the build available to testers;
3. on a successful upload, pushes the `v<version>` tag and cuts a GitHub Release
   with auto-generated notes.

**Internal testers get every build automatically, with no review** — so once
you've added internal testers (below), merging is all it takes. External testing
still needs Apple's Beta App Review and is never auto-submitted. To also push
each build to specific TestFlight beta groups, set a repo **variable** (not a
secret) `TESTFLIGHT_GROUPS` to a comma-separated list of group names
(Settings → Secrets and variables → Actions → Variables).

> Because the upload now waits for Apple's processing (needed to attach notes +
> distribute), the job takes longer than a bare upload — the workflow timeout is
> 90 min. Release-note text comes from commit messages and is passed to fastlane
> via a file, never interpolated into the workflow, so a crafted commit message
> can't inject into CI.

So **write PR titles as Conventional Commits** (they become the squash-commit
subject the bump is read from). A non-conforming title still ships — it just
falls back to a patch bump.

You can also ship on demand from **Actions → TestFlight → Run workflow**, and
skip a build by putting `[skip ci]` in the commit message. The build lands in
App Store Connect → **TestFlight** after a few minutes of Apple-side processing.

> **One owner of TestFlight.** GitHub Actions owns building + uploading. If you
> use Xcode Cloud, keep it build/test-only — do not let it archive/deploy on
> `main`, or the two pipelines double-build and collide on build numbers.

> **The `v*` tag is an output, not a trigger.** Don't push tags by hand to
> release — the pipeline creates them. (It pushes with `GITHUB_TOKEN`, which
> can't start another workflow run, so there's no release loop.)

### Adding testers
- **Internal** (you + up to 100 team members, no review): App Store Connect →
  TestFlight → Internal Testing → add testers.
- **External** (public link, up to 10,000): create an external group; the first
  build needs a quick Beta App Review.

## Running a build locally (optional)

After bootstrap, you can push a build from your Mac without CI:

```sh
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_CONTENT="$(base64 < AuthKey_XXXX.p8)"
export DEVELOPER_TEAM_ID=... \
       MATCH_GIT_URL=git@github.com:llun/schrift-certificates.git MATCH_PASSWORD=...
bundle exec fastlane beta
```

## Versioning

- **Marketing version** (`0.1.0`) lives in `project.yml` → `MARKETING_VERSION`.
  Bump it there for a new user-visible version.
- **Build number** is set to the GitHub Actions run number automatically, so
  every upload is unique and monotonic (Apple requires this).

## The GitHub Actions secrets (set for you by bootstrap)

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_CONTENT` | App Store Connect API key (auth, signing lookups, upload) |
| `DEVELOPER_TEAM_ID` | 10-char Developer Portal Team ID |
| `MATCH_GIT_URL` | SSH URL of the certificates repo |
| `MATCH_PASSWORD` | passphrase decrypting the certificates |
| `MATCH_SSH_PRIVATE_KEY` | read-only deploy key for the certificates repo |

## Troubleshooting

- **First CI run fails at archive/sign**: almost always a signing mismatch —
  re-check `DEVELOPER_TEAM_ID` and that the bootstrap actually populated the
  certs repo.
- **Xcode drift**: CI uses `latest-stable` Xcode. If a build compiles locally
  but not on CI, pin the runner's Xcode in the `setup-xcode` step to match yours.
- **Certificate renewal (~yearly)**: re-run
  `bundle exec fastlane match appstore` locally (with the env vars above) to
  refresh the certs repo; CI picks it up automatically.

## Xcode Cloud (alternative CI)

If you build with **Xcode Cloud** instead of (or alongside) the fastlane +
GitHub Actions pipeline, note that `Schrift.xcodeproj` is generated by XcodeGen
and **never committed** (`*.xcodeproj/` is git-ignored). Xcode Cloud clones the
GitHub repo verbatim, so out of the box the build fails with:

```
Project Schrift.xcodeproj does not exist at the root of the repository
```

The fix lives in [`ci_scripts/ci_post_clone.sh`](../ci_scripts/ci_post_clone.sh).
Xcode Cloud automatically runs any executable hooks in the repo-root
`ci_scripts/` directory; the `ci_post_clone.sh` hook runs right after the clone
and before `xcodebuild`, where it `brew install`s XcodeGen and runs
`xcodegen generate` — the same step the fastlane lane performs. Nothing else is
needed; keep the file executable (`chmod +x`) or Xcode Cloud silently skips it.
(Xcode Cloud manages signing itself, so the `match`/`Local.xcconfig` machinery
above does not apply to it.)

## Alternative: "remote" install without TestFlight (Ad Hoc)

To hand a build to a few specific devices without TestFlight: register each
device's UDID, export an **Ad Hoc** `.ipa`, host it with a `manifest.plist` on
any HTTPS URL, and install via an `itms-services://` link. Capped at 100
devices/type per year, no auto-update — TestFlight is preferred. Ask and this
pipeline can grow an `adhoc` lane.
