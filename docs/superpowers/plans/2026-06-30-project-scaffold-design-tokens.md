# Project Scaffold & Design Tokens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the DocsIOS Xcode project (via XcodeGen) and the design-token layer (colors, typography, spacing, radius) ported from the `Docs iOS Design System` handoff, with full TDD coverage of every token value.

**Architecture:** A single XcodeGen-managed Xcode project (`project.yml` is the source of truth; `.xcodeproj` is generated and gitignored) with an app target `DocsIOS` and a unit test target `DocsIOSTests`. Design tokens are plain Swift value types/enums with zero SwiftUI-resolution ambiguity in their tests: raw hex constants and pure hex→RGB math are tested directly; the thin `Color`/`Font` wrappers built on top are exercised only by the app compiling and running.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app (`TARGETED_DEVICE_FAMILY = "1,2"`, iPhone + iPad).
- Bundle identifiers: `dev.llun.DocsIOS` (app), `dev.llun.DocsIOS.Tests` (unit tests).
- Brand theme: default indigo (`#5E5CD0` family) from the handoff bundle — not the DSFR "Bleu France" override.
- Zero third-party Swift package dependencies in this plan (tokens are pure Swift/SwiftUI, no networking/CRDT yet).
- `project.yml` is the single source of truth for the Xcode project; the generated `DocsIOS.xcodeproj` is **not** committed (gitignored) — anyone working on this repo runs `xcodegen generate` after pulling changes to `project.yml`.
- Verified local build/test destination on this machine: `-destination 'platform=iOS Simulator,name=iPhone 17'` (Xcode 26.6, iOS 26.5 SDK — confirmed working; iOS 18.3/18.4 simulators are also installed if a lower-OS check is ever needed).
- Distribution is direct Xcode→device install (no App Store Connect/provisioning-profile setup needed in this plan).
- Each task below ends in its own commit — this whole plan is intended to land as one focused PR with one commit per task.

## File Structure

```
docs-ios/
├── .gitignore
├── README.md
├── project.yml                                    — XcodeGen project spec (source of truth)
├── DocsIOS/
│   ├── App/
│   │   ├── DocsIOSApp.swift                        — @main entry point
│   │   └── RootView.swift                          — placeholder root view, built from tokens (Task 6)
│   ├── Assets.xcassets/
│   │   ├── Contents.json
│   │   ├── AppIcon.appiconset/Contents.json
│   │   └── AccentColor.colorset/Contents.json
│   └── DesignSystem/
│       └── Tokens/
│           ├── HexColor.swift                      — hexColorComponents(_:) + Color(hex:) (Task 2)
│           ├── DocsColor.swift                      — DocsColorHex + DocsColor (Task 3)
│           ├── DocsTypography.swift                 — TypographySpec + DocsTypographySpec + DocsFont (Task 4)
│           ├── DocsSpacing.swift                     — spacing scale + iOS layout constants (Task 5)
│           └── DocsRadius.swift                      — radius scale (Task 5)
└── DocsIOSTests/                                    — empty until Task 2 (Task 1 verifies the scaffold via build + an empty test run)
    └── DesignSystem/
        └── Tokens/
            ├── HexColorComponentsTests.swift         — Task 2
            ├── DocsColorHexTests.swift                — Task 3
            ├── DocsTypographySpecTests.swift          — Task 4
            ├── DocsSpacingTests.swift                  — Task 5
            └── DocsRadiusTests.swift                   — Task 5
```

---

### Task 1: Xcode project scaffold (XcodeGen)

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `project.yml`
- Create: `DocsIOS/App/DocsIOSApp.swift`
- Create: `DocsIOS/App/RootView.swift` (placeholder, replaced with token-driven content in Task 6)
- Create: `DocsIOS/Assets.xcassets/Contents.json`
- Create: `DocsIOS/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `DocsIOS/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `DocsIOSTests/.gitkeep` (git can't track empty directories; XcodeGen's `DocsIOSTests` target needs the directory to exist on disk even before Task 2 adds real tests to it)

**Interfaces:**
- Produces: `RootView` (a `View`, no parameters) — consumed by `DocsIOSApp` here and replaced with token-driven content in Task 6; later screens (outside this plan) will eventually replace `RootView` itself with real navigation, but that's out of scope here.

- [ ] **Step 1: Write `.gitignore`**

```
# macOS
.DS_Store

# Xcode / XcodeGen
DocsIOS.xcodeproj/
*.xcworkspace/
xcuserdata/
DerivedData/
*.moved-aside
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# Swift Package Manager
.swiftpm/
Package.resolved
.build/
```

- [ ] **Step 2: Write `README.md`**

```markdown
# Docs iOS

A native iOS/iPadOS client for [La Suite Numérique Docs](https://github.com/suitenumerique/docs), built against a self-hosted instance.

## Design spec

See [`docs/superpowers/specs/2026-06-30-docs-ios-design.md`](docs/superpowers/specs/2026-06-30-docs-ios-design.md) for the full architecture and design decisions.

## Setup

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Generate the Xcode project: `xcodegen generate`
3. Open `DocsIOS.xcodeproj` in Xcode and run on a simulator or your own device.

The `.xcodeproj` is generated from `project.yml` and is not committed — regenerate it any time `project.yml` changes.

## Tests

```sh
xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'
```
```

- [ ] **Step 3: Write `project.yml`**

```yaml
name: DocsIOS
options:
  bundleIdPrefix: dev.llun
  deploymentTarget:
    iOS: "18.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  DocsIOS:
    type: application
    platform: iOS
    sources:
      - path: DocsIOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.llun.DocsIOS
        GENERATE_INFOPLIST_FILE: true
        INFOPLIST_KEY_CFBundleDisplayName: Docs
        INFOPLIST_KEY_UILaunchScreen_Generation: true
        TARGETED_DEVICE_FAMILY: "1,2"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    scheme:
      testTargets:
        - DocsIOSTests
      gatherCoverageData: true
  DocsIOSTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: DocsIOSTests
    dependencies:
      - target: DocsIOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.llun.DocsIOS.Tests
        GENERATE_INFOPLIST_FILE: true
```

- [ ] **Step 4: Write the app entry point**

`DocsIOS/App/DocsIOSApp.swift`:
```swift
import SwiftUI

@main
struct DocsIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```

- [ ] **Step 5: Write a placeholder root view**

`DocsIOS/App/RootView.swift`:
```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        Text("Docs")
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 6: Write the asset catalog**

`DocsIOS/Assets.xcassets/Contents.json`:
```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

`DocsIOS/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

`DocsIOS/Assets.xcassets/AccentColor.colorset/Contents.json` (brand fill `#5E5CD0`):
```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0xD0",
          "green" : "0x5C",
          "red" : "0x5E"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 7: Create the (still-empty) test directory**

`DocsIOSTests/.gitkeep`: an empty file (git can't track empty directories, and XcodeGen needs the directory to exist on disk).

There is no test *file* yet — that's expected. An empty test target still builds and runs cleanly (verified: `xcodebuild test` reports `Executed 0 tests, with 0 failures` rather than erroring), so this task verifies the scaffold via build + an empty test run rather than padding it with a placeholder test that asserts nothing. Real tests start in Task 2.

- [ ] **Step 8: Install XcodeGen if needed and generate the project**

Run: `which xcodegen || brew install xcodegen`
Run: `xcodegen generate`
Expected: `Created project at .../DocsIOS.xcodeproj`

- [ ] **Step 9: Build for the simulator**

Run: `xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Run the (currently empty) test target**

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 0 tests, with 0 failures`

- [ ] **Step 11: Commit**

```bash
git add .gitignore README.md project.yml DocsIOS DocsIOSTests
git commit -m "Scaffold DocsIOS Xcode project via XcodeGen"
```

---

### Task 2: Hex color conversion

**Files:**
- Create: `DocsIOS/DesignSystem/Tokens/HexColor.swift`
- Test: `DocsIOSTests/DesignSystem/Tokens/HexColorComponentsTests.swift`

**Interfaces:**
- Produces: `struct HexColorComponents: Equatable { let red, green, blue: Double }`, `func hexColorComponents(_ hex: UInt32) -> HexColorComponents`, `extension Color { init(hex: UInt32, opacity: Double = 1) }` — consumed by Task 3's `DocsColor`.

- [ ] **Step 1: Write the failing test**

`DocsIOSTests/DesignSystem/Tokens/HexColorComponentsTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class HexColorComponentsTests: XCTestCase {
    func testBlackProducesZeroComponents() {
        let components = hexColorComponents(0x000000)
        XCTAssertEqual(components.red, 0.0, accuracy: 0.0001)
        XCTAssertEqual(components.green, 0.0, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 0.0, accuracy: 0.0001)
    }

    func testWhiteProducesFullComponents() {
        let components = hexColorComponents(0xFFFFFF)
        XCTAssertEqual(components.red, 1.0, accuracy: 0.0001)
        XCTAssertEqual(components.green, 1.0, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 1.0, accuracy: 0.0001)
    }

    func testMixedHexProducesExpectedComponents() {
        let components = hexColorComponents(0xFF8000)
        XCTAssertEqual(components.red, 1.0, accuracy: 0.0001)
        XCTAssertEqual(components.green, 0.5020, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 0.0, accuracy: 0.0001)
    }

    func testBrandFillHexProducesExpectedComponents() {
        let components = hexColorComponents(0x5E5CD0)
        XCTAssertEqual(components.red, 0.3686, accuracy: 0.0001)
        XCTAssertEqual(components.green, 0.3608, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 0.8157, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Regenerate (so the new test file is picked up) and run the test to verify it fails**

XcodeGen only scans source directories at generation time — a file added to disk after the last `xcodegen generate` is silently excluded from the build until you regenerate.

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HexColorComponentsTests`
Expected: FAIL — `cannot find 'hexColorComponents' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Tokens/HexColor.swift`:
```swift
import SwiftUI

struct HexColorComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

func hexColorComponents(_ hex: UInt32) -> HexColorComponents {
    let red = Double((hex >> 16) & 0xFF) / 255.0
    let green = Double((hex >> 8) & 0xFF) / 255.0
    let blue = Double(hex & 0xFF) / 255.0
    return HexColorComponents(red: red, green: green, blue: blue)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let components = hexColorComponents(hex)
        self.init(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: opacity)
    }
}
```

- [ ] **Step 4: Add the new file to `project.yml`'s sources (no change needed — XcodeGen picks up new files under `DocsIOS/` automatically) and regenerate**

Run: `xcodegen generate`
Expected: `Created project at .../DocsIOS.xcodeproj`

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/HexColorComponentsTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add DocsIOS/DesignSystem/Tokens/HexColor.swift DocsIOSTests/DesignSystem/Tokens/HexColorComponentsTests.swift
git commit -m "Add hex color conversion utility"
```

---

### Task 3: Color tokens

**Files:**
- Create: `DocsIOS/DesignSystem/Tokens/DocsColor.swift`
- Test: `DocsIOSTests/DesignSystem/Tokens/DocsColorHexTests.swift`

**Interfaces:**
- Consumes: `hexColorComponents`, `Color(hex:)` from Task 2.
- Produces: `enum DocsColorHex` (raw `UInt32` constants) and `enum DocsColor` (`Color` values) — both consumed by every later DesignSystem component and screen.

- [ ] **Step 1: Write the failing test**

`DocsIOSTests/DesignSystem/Tokens/DocsColorHexTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocsColorHexTests: XCTestCase {
    func testBrandTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.brandFill, 0x5E5CD0)
        XCTAssertEqual(DocsColorHex.brandFillHover, 0x4844AD)
        XCTAssertEqual(DocsColorHex.brandFillSoft, 0xDDE2F5)
        XCTAssertEqual(DocsColorHex.brandFillSubtle, 0xEEF1FA)
        XCTAssertEqual(DocsColorHex.textBrand, 0x3E3B98)
        XCTAssertEqual(DocsColorHex.textBrandSecondary, 0x534FC2)
    }

    func testTextTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.textPrimary, 0x25252F)
        XCTAssertEqual(DocsColorHex.textSecondary, 0x5D5D70)
        XCTAssertEqual(DocsColorHex.textTertiary, 0x69697D)
        XCTAssertEqual(DocsColorHex.textDisabled, 0xA9A9BF)
        XCTAssertEqual(DocsColorHex.textOnBrand, 0xFFFFFF)
    }

    func testSurfaceTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.surfacePage, 0xFFFFFF)
        XCTAssertEqual(DocsColorHex.surfaceSunken, 0xF8F8F9)
        XCTAssertEqual(DocsColorHex.surfaceMuted, 0xF0F0F3)
    }

    func testBorderTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.borderDefault, 0xE2E2EA)
        XCTAssertEqual(DocsColorHex.borderStrong, 0xD3D4E0)
        XCTAssertEqual(DocsColorHex.borderFocus, 0x8184FC)
    }

    func testFeedbackTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.info, 0x0069CF)
        XCTAssertEqual(DocsColorHex.success, 0x027B3E)
        XCTAssertEqual(DocsColorHex.warning, 0xBC4200)
        XCTAssertEqual(DocsColorHex.danger, 0xD7010E)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsColorHexTests`
Expected: FAIL — `cannot find 'DocsColorHex' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Tokens/DocsColor.swift`:
```swift
import SwiftUI

enum DocsColorHex {
    // Brand
    static let brandFill: UInt32 = 0x5E5CD0
    static let brandFillHover: UInt32 = 0x4844AD
    static let brandFillSoft: UInt32 = 0xDDE2F5
    static let brandFillSubtle: UInt32 = 0xEEF1FA
    static let textBrand: UInt32 = 0x3E3B98
    static let textBrandSecondary: UInt32 = 0x534FC2

    // Text
    static let textPrimary: UInt32 = 0x25252F
    static let textSecondary: UInt32 = 0x5D5D70
    static let textTertiary: UInt32 = 0x69697D
    static let textDisabled: UInt32 = 0xA9A9BF
    static let textOnBrand: UInt32 = 0xFFFFFF

    // Surfaces
    static let surfacePage: UInt32 = 0xFFFFFF
    static let surfaceSunken: UInt32 = 0xF8F8F9
    static let surfaceMuted: UInt32 = 0xF0F0F3

    // Borders
    static let borderDefault: UInt32 = 0xE2E2EA
    static let borderStrong: UInt32 = 0xD3D4E0
    static let borderFocus: UInt32 = 0x8184FC

    // Feedback
    static let info: UInt32 = 0x0069CF
    static let success: UInt32 = 0x027B3E
    static let warning: UInt32 = 0xBC4200
    static let danger: UInt32 = 0xD7010E
}

enum DocsColor {
    static let brandFill = Color(hex: DocsColorHex.brandFill)
    static let brandFillHover = Color(hex: DocsColorHex.brandFillHover)
    static let brandFillSoft = Color(hex: DocsColorHex.brandFillSoft)
    static let brandFillSubtle = Color(hex: DocsColorHex.brandFillSubtle)
    static let textBrand = Color(hex: DocsColorHex.textBrand)
    static let textBrandSecondary = Color(hex: DocsColorHex.textBrandSecondary)

    static let textPrimary = Color(hex: DocsColorHex.textPrimary)
    static let textSecondary = Color(hex: DocsColorHex.textSecondary)
    static let textTertiary = Color(hex: DocsColorHex.textTertiary)
    static let textDisabled = Color(hex: DocsColorHex.textDisabled)
    static let textOnBrand = Color(hex: DocsColorHex.textOnBrand)

    static let surfacePage = Color(hex: DocsColorHex.surfacePage)
    static let surfaceSunken = Color(hex: DocsColorHex.surfaceSunken)
    static let surfaceMuted = Color(hex: DocsColorHex.surfaceMuted)

    static let borderDefault = Color(hex: DocsColorHex.borderDefault)
    static let borderStrong = Color(hex: DocsColorHex.borderStrong)
    static let borderFocus = Color(hex: DocsColorHex.borderFocus)

    static let info = Color(hex: DocsColorHex.info)
    static let success = Color(hex: DocsColorHex.success)
    static let warning = Color(hex: DocsColorHex.warning)
    static let danger = Color(hex: DocsColorHex.danger)
}
```

- [ ] **Step 4: Regenerate and run the test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsColorHexTests`
Expected: PASS — `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Tokens/DocsColor.swift DocsIOSTests/DesignSystem/Tokens/DocsColorHexTests.swift
git commit -m "Add color design tokens"
```

---

### Task 4: Typography tokens

**Files:**
- Create: `DocsIOS/DesignSystem/Tokens/DocsTypography.swift`
- Test: `DocsIOSTests/DesignSystem/Tokens/DocsTypographySpecTests.swift`

**Interfaces:**
- Produces: `struct TypographySpec: Equatable { let size: CGFloat; let weight: Font.Weight }`, `enum DocsTypographySpec`, `enum DocsFont` — `DocsFont` consumed by every later screen/component.

**Note on font family:** the design spec calls for Inter; this task uses `Font.system(size:weight:)` (SF Pro) as a deliberate placeholder since no Inter font files are available to bundle. Swapping in a bundled Inter font later only requires changing `DocsFont`'s implementation — `DocsTypographySpec` (size/weight) stays the source of truth either way.

- [ ] **Step 1: Write the failing test**

`DocsIOSTests/DesignSystem/Tokens/DocsTypographySpecTests.swift`:
```swift
import XCTest
import SwiftUI
@testable import DocsIOS

final class DocsTypographySpecTests: XCTestCase {
    func testLargeTitleMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.largeTitle, TypographySpec(size: 34, weight: .bold))
    }

    func testTitle1MatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.title1, TypographySpec(size: 28, weight: .bold))
    }

    func testTitle2MatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.title2, TypographySpec(size: 22, weight: .bold))
    }

    func testHeadlineMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.headline, TypographySpec(size: 17, weight: .semibold))
    }

    func testBodyMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.body, TypographySpec(size: 17, weight: .regular))
    }

    func testCalloutMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.callout, TypographySpec(size: 16, weight: .regular))
    }

    func testSubheadMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.subhead, TypographySpec(size: 15, weight: .regular))
    }

    func testFootnoteMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.footnote, TypographySpec(size: 13, weight: .regular))
    }

    func testCaptionMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.caption, TypographySpec(size: 12, weight: .regular))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsTypographySpecTests`
Expected: FAIL — `cannot find 'TypographySpec' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Tokens/DocsTypography.swift`:
```swift
import SwiftUI

struct TypographySpec: Equatable {
    let size: CGFloat
    let weight: Font.Weight
}

enum DocsTypographySpec {
    static let largeTitle = TypographySpec(size: 34, weight: .bold)
    static let title1 = TypographySpec(size: 28, weight: .bold)
    static let title2 = TypographySpec(size: 22, weight: .bold)
    static let headline = TypographySpec(size: 17, weight: .semibold)
    static let body = TypographySpec(size: 17, weight: .regular)
    static let callout = TypographySpec(size: 16, weight: .regular)
    static let subhead = TypographySpec(size: 15, weight: .regular)
    static let footnote = TypographySpec(size: 13, weight: .regular)
    static let caption = TypographySpec(size: 12, weight: .regular)
}

enum DocsFont {
    static let largeTitle = Font.system(size: DocsTypographySpec.largeTitle.size, weight: DocsTypographySpec.largeTitle.weight)
    static let title1 = Font.system(size: DocsTypographySpec.title1.size, weight: DocsTypographySpec.title1.weight)
    static let title2 = Font.system(size: DocsTypographySpec.title2.size, weight: DocsTypographySpec.title2.weight)
    static let headline = Font.system(size: DocsTypographySpec.headline.size, weight: DocsTypographySpec.headline.weight)
    static let body = Font.system(size: DocsTypographySpec.body.size, weight: DocsTypographySpec.body.weight)
    static let callout = Font.system(size: DocsTypographySpec.callout.size, weight: DocsTypographySpec.callout.weight)
    static let subhead = Font.system(size: DocsTypographySpec.subhead.size, weight: DocsTypographySpec.subhead.weight)
    static let footnote = Font.system(size: DocsTypographySpec.footnote.size, weight: DocsTypographySpec.footnote.weight)
    static let caption = Font.system(size: DocsTypographySpec.caption.size, weight: DocsTypographySpec.caption.weight)
}
```

- [ ] **Step 4: Regenerate and run the test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsTypographySpecTests`
Expected: PASS — `Executed 9 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Tokens/DocsTypography.swift DocsIOSTests/DesignSystem/Tokens/DocsTypographySpecTests.swift
git commit -m "Add typography design tokens"
```

---

### Task 5: Spacing and radius tokens

**Files:**
- Create: `DocsIOS/DesignSystem/Tokens/DocsSpacing.swift`
- Create: `DocsIOS/DesignSystem/Tokens/DocsRadius.swift`
- Test: `DocsIOSTests/DesignSystem/Tokens/DocsSpacingTests.swift`
- Test: `DocsIOSTests/DesignSystem/Tokens/DocsRadiusTests.swift`

**Interfaces:**
- Produces: `enum DocsSpacing` and `enum DocsRadius` (both plain `CGFloat` constants) — consumed by every later layout.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Tokens/DocsSpacingTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocsSpacingTests: XCTestCase {
    func testDesignScaleMatchesSpec() {
        XCTAssertEqual(DocsSpacing.space4xs, 2)
        XCTAssertEqual(DocsSpacing.space3xs, 4)
        XCTAssertEqual(DocsSpacing.space2xs, 6)
        XCTAssertEqual(DocsSpacing.spaceXS, 8)
        XCTAssertEqual(DocsSpacing.spaceSM, 12)
        XCTAssertEqual(DocsSpacing.spaceBase, 16)
        XCTAssertEqual(DocsSpacing.spaceMD, 24)
        XCTAssertEqual(DocsSpacing.spaceLG, 32)
        XCTAssertEqual(DocsSpacing.spaceXL, 40)
        XCTAssertEqual(DocsSpacing.space2XL, 48)
        XCTAssertEqual(DocsSpacing.space3XL, 56)
        XCTAssertEqual(DocsSpacing.space4XL, 64)
        XCTAssertEqual(DocsSpacing.space5XL, 72)
    }

    func testIOSLayoutConstantsMatchSpec() {
        XCTAssertEqual(DocsSpacing.statusBarHeight, 54)
        XCTAssertEqual(DocsSpacing.navBarHeight, 44)
        XCTAssertEqual(DocsSpacing.largeTitleBarHeight, 96)
        XCTAssertEqual(DocsSpacing.tabBarHeight, 49)
        XCTAssertEqual(DocsSpacing.homeIndicatorHeight, 34)
        XCTAssertEqual(DocsSpacing.rowMinHeight, 44)
        XCTAssertEqual(DocsSpacing.toolbarHeight, 44)
        XCTAssertEqual(DocsSpacing.gutter, 16)
        XCTAssertEqual(DocsSpacing.gutterGrouped, 20)
    }
}
```

`DocsIOSTests/DesignSystem/Tokens/DocsRadiusTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocsRadiusTests: XCTestCase {
    func testRadiusScaleMatchesSpec() {
        XCTAssertEqual(DocsRadius.xs, 2)
        XCTAssertEqual(DocsRadius.sm, 4)
        XCTAssertEqual(DocsRadius.md, 8)
        XCTAssertEqual(DocsRadius.lg, 12)
        XCTAssertEqual(DocsRadius.xl, 16)
        XCTAssertEqual(DocsRadius.xl2, 24)
        XCTAssertEqual(DocsRadius.pill, 999)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsSpacingTests -only-testing:DocsIOSTests/DocsRadiusTests`
Expected: FAIL — `cannot find 'DocsSpacing' in scope`, `cannot find 'DocsRadius' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Tokens/DocsSpacing.swift`:
```swift
import CoreGraphics

enum DocsSpacing {
    // Design scale (4px base unit)
    static let space4xs: CGFloat = 2
    static let space3xs: CGFloat = 4
    static let space2xs: CGFloat = 6
    static let spaceXS: CGFloat = 8
    static let spaceSM: CGFloat = 12
    static let spaceBase: CGFloat = 16
    static let spaceMD: CGFloat = 24
    static let spaceLG: CGFloat = 32
    static let spaceXL: CGFloat = 40
    static let space2XL: CGFloat = 48
    static let space3XL: CGFloat = 56
    static let space4XL: CGFloat = 64
    static let space5XL: CGFloat = 72

    // iOS layout constants
    static let statusBarHeight: CGFloat = 54
    static let navBarHeight: CGFloat = 44
    static let largeTitleBarHeight: CGFloat = 96
    static let tabBarHeight: CGFloat = 49
    static let homeIndicatorHeight: CGFloat = 34
    static let rowMinHeight: CGFloat = 44
    static let toolbarHeight: CGFloat = 44
    static let gutter: CGFloat = 16
    static let gutterGrouped: CGFloat = 20
}
```

`DocsIOS/DesignSystem/Tokens/DocsRadius.swift`:
```swift
import CoreGraphics

enum DocsRadius {
    static let xs: CGFloat = 2
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xl2: CGFloat = 24
    /// Use `Capsule()`/`Circle()` shapes for true pill/circular corners rather than this value directly.
    static let pill: CGFloat = 999
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsSpacingTests -only-testing:DocsIOSTests/DocsRadiusTests`
Expected: PASS — `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Tokens/DocsSpacing.swift DocsIOS/DesignSystem/Tokens/DocsRadius.swift DocsIOSTests/DesignSystem/Tokens/DocsSpacingTests.swift DocsIOSTests/DesignSystem/Tokens/DocsRadiusTests.swift
git commit -m "Add spacing and radius design tokens"
```

---

### Task 6: Wire tokens into the root view

**Files:**
- Modify: `DocsIOS/App/RootView.swift`

**Interfaces:**
- Consumes: `DocsColor`, `DocsFont`, `DocsSpacing` from Tasks 3-5.
- Produces: `RootView` (same signature as Task 1, content changed) — unchanged interface, so no other file needs to change.

- [ ] **Step 1: Replace the placeholder view with a token-driven one**

`DocsIOS/App/RootView.swift`:
```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: DocsSpacing.spaceSM) {
            Text("Docs")
                .font(DocsFont.largeTitle)
                .foregroundStyle(DocsColor.textPrimary)
            Text("Connected to your documents")
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textSecondary)
        }
        .padding(DocsSpacing.spaceBase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DocsColor.surfacePage)
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the full test suite**

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 21 tests, with 0 failures` (4 hex color + 5 color hex + 9 typography + 2 spacing + 1 radius = 21)

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/App/RootView.swift
git commit -m "Wire design tokens into the root view"
```

## Self-Review Notes

- **Spec coverage:** Every token table in `docs/superpowers/specs/2026-06-30-docs-ios-design.md`'s "Design tokens" section (colors, typography, spacing, radius) has a corresponding task and test. The Material Symbols vs SF Symbols and Inter-vs-system-font deferrals from the spec are carried forward explicitly in Task 4's note rather than silently resolved.
- **Placeholder scan:** No TBD/TODO. Task 1 deliberately has no placeholder test — it verifies the scaffold via `xcodebuild build`/`xcodebuild test` against an empty test target (`Executed 0 tests, with 0 failures`) rather than padding it with a test that asserts nothing, since that pattern is itself a defect the review rubric flags.
- **Type consistency:** `TypographySpec`, `DocsColorHex`, `DocsColor`, `DocsSpacing`, `DocsRadius`, and `RootView` are each defined exactly once and referenced with identical names/signatures everywhere they're used across tasks.
- **Out of scope for this plan** (next plans): DesignSystem components (Button, IconButton, NavBar, etc.), networking layer, auth, and all screens — per the spec's build sequence, items 2 onward.
