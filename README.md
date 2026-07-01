# Schrift

Schrift is a native iOS/iPadOS client for [La Suite Numérique Docs](https://github.com/suitenumerique/docs), built against a self-hosted instance.

## Design spec

See [`docs/superpowers/specs/2026-06-30-docs-ios-design.md`](docs/superpowers/specs/2026-06-30-docs-ios-design.md) for the full architecture and design decisions.

## Setup

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Generate the Xcode project: `xcodegen generate`
3. Open `Schrift.xcodeproj` in Xcode and run on a simulator or your own device.

The `.xcodeproj` is generated from `project.yml` and is not committed — regenerate it any time `project.yml` changes.

## Tests

```sh
xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'
```
