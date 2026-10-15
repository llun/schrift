# Shipping Schrift to TestFlight

This repo builds and uploads to TestFlight automatically via **fastlane** +
**GitHub Actions** (`.github/workflows/testflight.yml`). Almost all of the
setup is a 1Password vault plus one GitHub secret
([`scripts/bootstrap-testflight.sh`](../scripts/bootstrap-testflight.sh) sets it).

Everything is gated behind a **paid Apple Developer Program membership**
($99/yr). On a free Apple ID none of this works.

## Status of the local toolchain

Already done in this repo:

- Ruby **3.4.9** pinned via `.ruby-version` (local dev + CI use the same).
- fastlane installed (`bundle install`), `Gemfile.lock` committed.
- fastlane lanes `beta` (ship) and `bootstrap` (one-time setup) ready.
- CI reads signing assets and App Store Connect credentials from a 1Password
  vault (`Schrift`) via `scripts/fetch-signing.sh`; fastlane match and the
  private certificates repo are gone.
- Local on-device dev signing is separate from all of this: `project.yml` points
  both configurations at the committed `Signing.xcconfig`, which optionally
  includes a git-ignored `Local.xcconfig` holding your personal
  `DEVELOPMENT_TEAM` (copy `Local.xcconfig.example`, fill in your Team ID,
  re-run `xcodegen generate`). CI ignores this — the `beta` lane overrides
  signing with the 1Password-sourced profile.

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

Store these in 1Password (next section); nothing else is needed from the web UI.

## The 1Password `Schrift` vault

All signing material and credentials live in one vault named `Schrift`. The
item names are fixed — `scripts/fetch-signing.sh` reads them verbatim:

| Item (type) | Contents |
| --- | --- |
| `Schrift Distribution Certificate` (Document) | the Apple Distribution identity as a `.p12` |
| `Schrift Distribution Certificate Password` (Password) | field `password` = the `.p12` password |
| `Schrift App Store Profile` (Document) | the App Store `.mobileprovision`; its profile *name* stays `match AppStore dev.llun.Schrift` (the `PROFILE_NAME` constant in the Fastfile) |
| `Schrift App Store Connect API Key` (API Credential) | text fields `key_id`, `issuer_id`, `team_id` (Developer Team ID) plus the attached file `AuthKey.p8` |
| `Schrift Match Passphrase` (Password) | archival only (the old match repo passphrase); nothing reads it |

### CI access

1. In 1Password, create a **service account** with **read-only** access to the
   `Schrift` vault and nothing else.
2. Store its token as the repo's single secret:
   `OP_TOKEN_REF='op://…' ./scripts/bootstrap-testflight.sh` (the script reads
   the token with `op read`, so it never appears on the command line).

`testflight.yml` installs the `op` CLI and runs `scripts/fetch-signing.sh`, which
writes the files under `$RUNNER_TEMP/signing`, masks every value and exports
`DIST_CERT_P12`, `DIST_CERT_PASSWORD`, `PROVISIONING_PROFILE`, `ASC_KEY_P8`,
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `DEVELOPER_TEAM_ID` for fastlane.

## Manual step 2: create the App Store Connect app record

Apple has no API to create an app record, so this one is done in the web UI
(the bundle id it needs is registered by the `bootstrap` lane — see Troubleshooting):

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
   the workflow run number, floored by whatever TestFlight already holds);
3. on a successful upload, pushes the `v<version>` tag and cuts a GitHub Release
   with auto-generated notes;
4. **last, and best-effort**, waits for Apple to finish processing so it can
   attach auto-generated **release notes** (the commit subjects since the last
   tag) and make the build available to testers.

**That order is deliberate.** Step 4 is a wait with no upper bound, and by the
time it runs the binary is already on App Store Connect — so it must not be able
to cost the release record. If it times out you lose the release notes on that
build, nothing else. Running it before the tag (as this pipeline used to) means a
cancel or a job timeout during the wait leaves a shipped build with no tag and no
Release, which is exactly the incident described below.

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

### When the upload fails

Two things can go wrong, and they need opposite treatment.

**A failure before the binary lands** is worth retrying: App Store Connect returns
5xx and gateway timeouts routinely, and the archive is already built by then, so a
bare `Server error got 500` used to mean a merged, fully-tested commit shipped
nothing. Build 95 (v0.57.0) is the worked example. The `beta` lane retries such an
upload up to **three times** (30s then 60s).

**A failure after the binary lands must not fail the release at all.** Build 96
(v0.57.0) is that worked example: the upload logged `Successfully uploaded the new
binary to App Store Connect`, then the job spent 30 minutes waiting for Apple to
process it and died on `FastlaneCore::BuildWatcher exceeded the '1800' seconds`. The
build was on TestFlight; `main` was red, with no tag and no GitHub Release.

So the lane splits the two:

| Step | Can fail the release? | Why |
|---|---|---|
| Upload the binary (`fastlane beta` → `upload_build`) | yes | irreversible, and returns as soon as Apple has the package |
| Tag + GitHub Release | yes | cheap, fast, and the durable record that the version shipped |
| Wait for processing → release notes → distribute (`fastlane distribute`) | **no** | the build has already shipped; a timeout costs the changelog only |

and **after any upload error the first question is asked of App Store Connect, not
of the error message** — `build_on_app_store_connect?` looks up the latest build
number for the version being shipped, and if that is *exactly* our build number
the upload succeeded no matter what it reported. (Equality, not `>=`: a build
numbered above ours is not evidence that ours landed.) Only a genuinely absent
binary reaches `transient_upload_failure?`:

| Outcome | Examples |
|---|---|
| Retried | `Server error got 500`, a 5xx given as a status, gateway timeout, connection reset/refused/failed, DNS failure, Apple 429 rate limiting, altool exit `-1` ("try retrying") |
| **Never** retried | `already exists`, `redundant binary`, `duplicate`, credential/authorisation failures, invalid provisioning |
| Not retried (fails loudly) | anything unrecognised |

A 5xx only counts when the number is presented *as a status*: matching a bare
`500`/`502` anywhere in the message would let a build number (ours are climbing
towards 500), a duration like `'1500' seconds`, or a byte count reclassify a
terminal rejection as transient.

Error wording cannot distinguish a 5xx thrown before the upload landed from one
thrown after it, and retrying the latter walks straight into a duplicate rejection
— which is why the lookup, not the wording, leads. The terminal phrases remain as a
backstop for when App Store Connect itself cannot be reached.

A red `TestFlight` run therefore means the binary is genuinely **not** on App Store
Connect — check TestFlight before doing anything else, but expect it to be absent.

### What a green run does and does not promise

Green means *the binary reached App Store Connect and the release was recorded*.
Three things it deliberately does not promise:

- **Apple accepted it.** A build Apple marks `INVALID` or `FAILED` during
  processing still counts as "processed" to fastlane (`processed?` is
  `processing_state != PROCESSING`), so the run stays green and the tag is
  pushed while no tester ever gets the build. Apple emails you about these;
  the pipeline cannot currently tell you.
- **A marketing version identifies one commit.** It does not. A run that fails
  before the tag leaves the version untagged, so the next run — of a *different*
  commit — recomputes the same version. TestFlight then lists e.g. 0.57.0 (95)
  and 0.57.0 (96) from different sources. The build number is the only
  unambiguous identifier; the tag records only the commit that finally shipped.
- **Named beta groups were served.** pilot matches `TESTFLIGHT_GROUPS` by exact
  name and silently no-ops on a name that resolves to nothing, so a rename on
  Apple's side yields a green run with nobody added.

> **One load-bearing build setting.** Step 4 is only cosmetic because the binary
> answers export compliance itself, via `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`
> in `project.yml`. Without it, pilot's `set_export_compliance_if_needed` — which
> lives *on that best-effort path* — becomes the thing that sets it, and a failure
> there would silently leave builds undistributable. The `distribute` lane also
> passes `uses_non_exempt_encryption: false` so the answer never depends on the
> plist alone; keep both.

### Re-running a failed release

Re-running is safe, and the pipeline is built to let you: the `v*` tag is pushed
only on success, the tag and GitHub Release steps skip themselves when they already
exist, and the build number is the run number **floored by whatever TestFlight
already holds**.

That floor is load-bearing. `github.run_number` is stable across re-runs of the
same run, so before this a re-run of a run whose upload had landed rebuilt under a
build number Apple had already seen and was rejected — for ever, with no way out
but pushing an empty commit. That was the second half of the build-96 incident.

One consequence worth knowing: a re-run ships a **new build of the same commit**
(one higher than the last), rather than adopting the build already uploaded.
Several builds sharing one marketing version is normal and harmless.

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

Signed in to the 1Password CLI (`op signin`), load the signing environment and
run the lane:

```sh
d="$(mktemp -d)"; eval "$(scripts/fetch-signing.sh "$d")"
bundle exec fastlane beta
rm -rf "$d"
```

The `.p12` is imported into your login keychain and the profile installed. Delete
the temp directory afterwards.

## Versioning

- **Marketing version** is computed on CI from the latest `v*` tag via
  Conventional Commits (`scripts/next-version.sh`) and injected into the build
  as a `MARKETING_VERSION` xcarg — `project.yml`'s `MARKETING_VERSION: 0.1.0`
  is only the fallback for local `bundle exec fastlane beta` runs and Xcode
  builds. To ship a new user-visible version, land a `feat:` (minor) or
  `feat!:`/`BREAKING CHANGE` (major) commit; editing `project.yml` does **not**
  change the released version.
- **Build number** is the GitHub Actions run number, **floored by the latest
  build number already on TestFlight** (`resolved_build_number` in the
  `Fastfile`), so every upload is unique and monotonic — which Apple requires.
  The floor covers the two ways the run number alone is not enough: it repeats
  across re-runs of one run, and it resets to 1 if you rename or move
  `.github/workflows/testflight.yml` (it is scoped to the workflow file's
  identity — still worth not doing, but no longer fatal). Local `fastlane beta`
  runs have no run number and use the latest TestFlight build number + 1, as
  before; there the lookup is the only source, so a failure to reach App Store
  Connect stops the run rather than guessing.

## The GitHub Actions secret

| Secret | What it is |
| --- | --- |
| `OP_SERVICE_ACCOUNT_TOKEN` | read-only 1Password service account token, scoped to the `Schrift` vault — the only secret `testflight.yml` uses |

## Troubleshooting

- **First CI run fails at archive/sign**: almost always a signing mismatch —
  re-check the vault items (`team_id`, the profile name, certificate expiry).
- **Xcode drift**: CI uses `latest-stable` Xcode. If a build compiles locally
  but not on CI, pin the runner's Xcode in the `setup-xcode` step to match yours.
- **Certificate renewal / first-time signing assets (~yearly)**: run the
  `bootstrap` lane locally with `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (path
  to the `.p8`) and `DEVELOPER_TEAM_ID` exported (when renewing, from the vault via
  `d="$(mktemp -d)"; eval "$(scripts/fetch-signing.sh "$d")"; …; rm -rf "$d"`;
  for the first-time bootstrap the certificate/profile items don't exist yet, so
  `fetch-signing.sh` can't be used — export `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_P8`
  by hand: `op read` the fields and `op read --out-file` the `.p8`) and optionally
  `SIGNING_OUT=<dir>`. It registers the App ID if missing, creates a distribution
  certificate (`cert`) in a throwaway keychain, exports it as `distribution.p12`
  with a generated password (written to `distribution.p12.password`, mode 600),
  creates the App Store profile (`sigh`) and prints the `op document create` /
  `op item create` commands to store them in the vault. Run them (or `op ... edit`
  when renewing), then delete the output directory.

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
(Xcode Cloud manages signing itself, so the 1Password/`Local.xcconfig` machinery
above does not apply to it.)

## Alternative: "remote" install without TestFlight (Ad Hoc)

To hand a build to a few specific devices without TestFlight: register each
device's UDID, export an **Ad Hoc** `.ipa`, host it with a `manifest.plist` on
any HTTPS URL, and install via an `itms-services://` link. Capped at 100
devices/type per year, no auto-update — TestFlight is preferred. Ask and this
pipeline can grow an `adhoc` lane.

## After migrating

Once CI ships from the vault:

- delete the old repo secrets: `for s in ASC_ISSUER_ID ASC_KEY_CONTENT ASC_KEY_ID DEVELOPER_TEAM_ID MATCH_GIT_URL MATCH_PASSWORD MATCH_SSH_PRIVATE_KEY; do gh secret delete "$s"; done`;
- revoke the previous App Store Connect API key in App Store Connect;
- delete the old match certificates repo.
