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

## Tests

```sh
xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Distribution (TestFlight)

Builds are shipped to TestFlight via fastlane + GitHub Actions (push a `v*`
tag). The pipeline is already scaffolded — see
[`docs/testflight-setup.md`](docs/testflight-setup.md) for the one-time setup
(Apple Developer enrollment, signing, and secrets).
