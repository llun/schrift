# Schrift

Schrift is a native iOS/iPadOS client for [La Suite Numérique Docs](https://github.com/suitenumerique/docs), built against a self-hosted instance.

## Design spec

See [`docs/superpowers/specs/2026-06-30-docs-ios-design.md`](docs/superpowers/specs/2026-06-30-docs-ios-design.md) for the full architecture and design decisions.

## Architecture

Schrift is a SwiftUI app with **zero third-party dependencies** — SwiftUI views,
`@Observable` view models, and an `actor`-based async/await networking layer.

The one surprising piece: the Docs backend stores content as an opaque base64
**Yjs CRDT** blob and has no markdown write endpoint, so Schrift saves by
converting the editor's markdown to a Yjs update **on-device** — a hand-written
lib0/Yjs-v1 encoder in [`Schrift/Core/Yjs`](Schrift/Core/Yjs) — and `PATCH`ing the
bytes directly. See the design spec's "Editing & save mechanism" for details.

## Code standards

See [`CLAUDE.md`](CLAUDE.md) for the coding conventions, testing patterns, and
repo safety rules (written for AI agents and human contributors alike).

## Setup

Requires a recent Xcode with an **iOS 18 simulator** and the Swift 6 toolchain.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Generate the Xcode project: `xcodegen generate`
3. Open `Schrift.xcodeproj` in Xcode and run on a simulator or your own device.

The `.xcodeproj` is generated from `project.yml` and is not committed — regenerate it any time `project.yml` changes.

### Running on a physical device

On-device builds need a signing team, but a Team ID must never be committed
(and would be wiped on every `xcodegen generate` anyway). So:

1. Sign into your Apple ID in **Xcode ▸ Settings ▸ Accounts**.
2. Copy your git-ignored local signing file into place and set your Team ID:
   ```sh
   cp Local.xcconfig.example Local.xcconfig   # if a template exists; otherwise create Local.xcconfig
   # edit Local.xcconfig → DEVELOPMENT_TEAM = <your 10-char Team ID>
   xcodegen generate
   ```
   `Local.xcconfig` is git-ignored; the committed `Signing.xcconfig` optionally
   includes it, so your Team ID stays local and survives regeneration.
3. Connect your iPhone (trust the Mac), select it as the run destination, and
   press **Run** (⌘R). On first launch, trust the developer profile on the phone
   under **Settings ▸ General ▸ VPN & Device Management**.

CI/TestFlight signing is independent of this — see the fastlane `beta` lane.

## Tests

```sh
xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Distribution (TestFlight)

Every merge to `main` auto-ships to TestFlight via fastlane + GitHub Actions:
the pipeline computes the next [Conventional-Commits](https://www.conventionalcommits.org)
version, builds + uploads, then tags `v<version>` and cuts a GitHub Release.
Write PR titles as Conventional Commits (`feat:` → minor, `feat!`/`BREAKING
CHANGE` → major, otherwise patch) so the version bump is right. See
[`docs/testflight-setup.md`](docs/testflight-setup.md) for the one-time setup
(Apple Developer enrollment, signing, and secrets).
