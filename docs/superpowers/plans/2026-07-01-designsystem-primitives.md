# DesignSystem Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first four DesignSystem components (Button, IconButton, Badge, Switch) as native SwiftUI views, each with a pure, testable style-resolution layer, plus a preview catalog proving they all compose.

**Architecture:** Each stateful/multi-variant component follows the pattern established by the token layer (docs/superpowers/plans/2026-06-30-project-scaffold-design-tokens.md): a pure `*StyleResolver` enum maps semantic props (variant/color/tone/disabled) to a `*StyleHex` struct of raw `UInt32` hex values — fully unit-testable with no SwiftUI-resolution ambiguity — and the SwiftUI `View` itself is a thin layer that resolves those hex values into `Color` at render time. `Switch` has no resolver (it's a direct `Toggle` wrapper with no branching logic) and is verified by build success + its Preview only, matching the precedent set by RootView in the prior plan (a component with no testable logic gets no placeholder test).

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app (`TARGETED_DEVICE_FAMILY = "1,2"`, iPhone + iPad).
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth for the Xcode project; regenerate via `xcodegen generate` after adding any new file, **before** building/testing — a file added to disk after the last generate is silently excluded from the build.
- Verified local build/test destination on this machine: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task below ends in its own commit.
- Component names must not shadow SwiftUI's own types: our button view is named `DocsButton` (not `Button`, which would shadow `SwiftUI.Button` and break its use inside our own implementation). `IconButton`, `Badge`, and `Switch` do not collide with any SwiftUI type and keep their plain names, matching the design system's component inventory.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build on this machine regardless of code changes (it's an Xcode build-system notice, not a Swift compiler warning about this code). Ignore it; it is not a defect to fix and should not appear in any "issues found" list.

## File Structure

```
DocsIOS/
├── DesignSystem/
│   ├── Tokens/
│   │   └── DocsColor.swift                            — MODIFY: add 4 soft-feedback hex tokens (Task 1)
│   └── Components/
│       ├── Button.swift                                — ButtonVariant/ButtonColor, ButtonStyleHex, ButtonStyleResolver, DocsButton view (Task 2)
│       ├── IconButton.swift                             — IconButtonVariant/IconButtonColor, IconButtonStyleHex, IconButtonStyleResolver, IconButton view (Task 3)
│       ├── Badge.swift                                  — BadgeTone, BadgeStyleHex, BadgeStyleResolver, Badge view (Task 4)
│       └── Switch.swift                                 — Switch view (Task 5, no resolver)
└── DesignSystemCatalog/
    └── ComponentCatalogPreview.swift                    — Preview-only catalog composing all 4 components (Task 6)

DocsIOSTests/
└── DesignSystem/
    ├── Tokens/
    │   └── DocsColorHexTests.swift                       — MODIFY: add soft-feedback test method (Task 1)
    └── Components/
        ├── ButtonStyleResolverTests.swift                — Task 2
        ├── IconButtonStyleResolverTests.swift             — Task 3
        └── BadgeStyleResolverTests.swift                   — Task 4
```

---

### Task 1: Soft-feedback color tokens

Button/Badge need a "soft" (tinted background) variant of each feedback color, which the prior plan didn't add. This task extends the existing token layer before any component consumes it.

**Files:**
- Modify: `DocsIOS/DesignSystem/Tokens/DocsColor.swift`
- Modify: `DocsIOSTests/DesignSystem/Tokens/DocsColorHexTests.swift`

**Interfaces:**
- Produces: 4 new `DocsColorHex` constants (`infoSoft`, `successSoft`, `warningSoft`, `dangerSoft`) and matching `DocsColor` values — consumed by Task 2's `ButtonStyleResolver` and Task 4's `BadgeStyleResolver`.

- [ ] **Step 1: Write the failing test**

In `DocsIOSTests/DesignSystem/Tokens/DocsColorHexTests.swift`, find this exact block (the end of the existing `testFeedbackTokensMatchDesignSpec` method and the file's closing brace):

```swift
        XCTAssertEqual(DocsColorHex.danger, 0xD7010E)
    }
}
```

Replace it with:

```swift
        XCTAssertEqual(DocsColorHex.danger, 0xD7010E)
    }

    func testFeedbackSoftTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.infoSoft, 0xD5E4F3)
        XCTAssertEqual(DocsColorHex.successSoft, 0xCFE4D4)
        XCTAssertEqual(DocsColorHex.warningSoft, 0xF1E0D3)
        XCTAssertEqual(DocsColorHex.dangerSoft, 0xF4DFD9)
    }
}
```

- [ ] **Step 2: Regenerate and run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsColorHexTests`
Expected: FAIL — `cannot find 'infoSoft' in scope` (or similar, for each missing member)

- [ ] **Step 3: Write the minimal implementation**

In `DocsIOS/DesignSystem/Tokens/DocsColor.swift`, find this exact block (the end of `DocsColorHex` — its last constant and closing brace):

```swift
    static let danger: UInt32 = 0xD7010E
}
```

Replace it with:

```swift
    static let danger: UInt32 = 0xD7010E

    // Feedback (soft backgrounds)
    static let infoSoft: UInt32 = 0xD5E4F3
    static let successSoft: UInt32 = 0xCFE4D4
    static let warningSoft: UInt32 = 0xF1E0D3
    static let dangerSoft: UInt32 = 0xF4DFD9
}
```

Then find this exact block (the end of `DocsColor` — its last constant and closing brace):

```swift
    static let danger = Color(hex: DocsColorHex.danger)
}
```

Replace it with:

```swift
    static let danger = Color(hex: DocsColorHex.danger)

    static let infoSoft = Color(hex: DocsColorHex.infoSoft)
    static let successSoft = Color(hex: DocsColorHex.successSoft)
    static let warningSoft = Color(hex: DocsColorHex.warningSoft)
    static let dangerSoft = Color(hex: DocsColorHex.dangerSoft)
}
```

- [ ] **Step 4: Regenerate and run the test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocsColorHexTests`
Expected: PASS — `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Tokens/DocsColor.swift DocsIOSTests/DesignSystem/Tokens/DocsColorHexTests.swift
git commit -m "Add soft-feedback color tokens"
```

---

### Task 2: Button component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/Button.swift`
- Test: `DocsIOSTests/DesignSystem/Components/ButtonStyleResolverTests.swift`

**Interfaces:**
- Consumes: `DocsColorHex`, `DocsSpacing`, `DocsFont`, `DocsRadius` (from the prior plan); `Color(hex:)` (from `HexColor.swift`).
- Produces: `enum ButtonVariant { primary, secondary, tertiary, outline }`, `enum ButtonColor { brand, neutral, danger }`, `struct ButtonStyleHex: Equatable { backgroundHex: UInt32?, foregroundHex: UInt32, borderHex: UInt32? }`, `enum ButtonStyleResolver { static func style(variant:color:isDisabled:) -> ButtonStyleHex }`, `struct DocsButton: View` — all consumed by Task 6's catalog preview.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/ButtonStyleResolverTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class ButtonStyleResolverTests: XCTestCase {
    func testPrimaryBrandUsesFillBackground() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .brand, isDisabled: false)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.brandFill, foregroundHex: DocsColorHex.textOnBrand, borderHex: nil))
    }

    func testSecondaryBrandUsesSoftBackground() {
        let style = ButtonStyleResolver.style(variant: .secondary, color: .brand, isDisabled: false)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary, borderHex: nil))
    }

    func testTertiaryHasNoBackground() {
        let style = ButtonStyleResolver.style(variant: .tertiary, color: .brand, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.textBrandSecondary)
    }

    func testOutlineHasMatchingBorderAndForeground() {
        let style = ButtonStyleResolver.style(variant: .outline, color: .danger, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.danger)
        XCTAssertEqual(style.borderHex, DocsColorHex.danger)
    }

    func testDisabledIgnoresVariantAndColor() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .danger, isDisabled: true)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textDisabled, borderHex: nil))
    }

    func testNeutralPrimaryUsesTextPrimaryAsFill() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .neutral, isDisabled: false)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.textPrimary, foregroundHex: DocsColorHex.textOnBrand, borderHex: nil))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ButtonStyleResolverTests`
Expected: FAIL — `cannot find 'ButtonStyleResolver' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/Button.swift`:
```swift
import SwiftUI

enum ButtonVariant {
    case primary
    case secondary
    case tertiary
    case outline
}

enum ButtonColor {
    case brand
    case neutral
    case danger
}

struct ButtonStyleHex: Equatable {
    let backgroundHex: UInt32?
    let foregroundHex: UInt32
    let borderHex: UInt32?
}

enum ButtonStyleResolver {
    static func style(variant: ButtonVariant, color: ButtonColor, isDisabled: Bool) -> ButtonStyleHex {
        if isDisabled {
            return ButtonStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textDisabled, borderHex: nil)
        }

        let fillHex: UInt32
        let softHex: UInt32
        let onFillHex: UInt32
        let softForegroundHex: UInt32

        switch color {
        case .brand:
            fillHex = DocsColorHex.brandFill
            softHex = DocsColorHex.brandFillSoft
            onFillHex = DocsColorHex.textOnBrand
            softForegroundHex = DocsColorHex.textBrandSecondary
        case .neutral:
            fillHex = DocsColorHex.textPrimary
            softHex = DocsColorHex.surfaceMuted
            onFillHex = DocsColorHex.textOnBrand
            softForegroundHex = DocsColorHex.textPrimary
        case .danger:
            fillHex = DocsColorHex.danger
            softHex = DocsColorHex.dangerSoft
            onFillHex = DocsColorHex.textOnBrand
            softForegroundHex = DocsColorHex.danger
        }

        switch variant {
        case .primary:
            return ButtonStyleHex(backgroundHex: fillHex, foregroundHex: onFillHex, borderHex: nil)
        case .secondary:
            return ButtonStyleHex(backgroundHex: softHex, foregroundHex: softForegroundHex, borderHex: nil)
        case .tertiary:
            return ButtonStyleHex(backgroundHex: nil, foregroundHex: softForegroundHex, borderHex: nil)
        case .outline:
            return ButtonStyleHex(backgroundHex: nil, foregroundHex: softForegroundHex, borderHex: softForegroundHex)
        }
    }
}

struct DocsButton: View {
    let title: String
    var variant: ButtonVariant = .primary
    var color: ButtonColor = .brand
    var icon: String? = nil
    var fullWidth: Bool = false
    var pill: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        let style = ButtonStyleResolver.style(variant: variant, color: color, isDisabled: isDisabled)
        Button(action: action) {
            HStack(spacing: DocsSpacing.spaceXS) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .font(DocsFont.headline)
            }
            .padding(.horizontal, DocsSpacing.spaceBase)
            .padding(.vertical, DocsSpacing.spaceSM)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(Color(hex: style.foregroundHex))
            .background(style.backgroundHex.map { Color(hex: $0) } ?? Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: pill ? DocsRadius.pill : DocsRadius.sm)
                    .strokeBorder(style.borderHex.map { Color(hex: $0) } ?? Color.clear, lineWidth: style.borderHex == nil ? 0 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: pill ? DocsRadius.pill : DocsRadius.sm))
        }
        .disabled(isDisabled)
    }
}

#Preview {
    VStack(spacing: DocsSpacing.spaceSM) {
        DocsButton(title: "Primary", variant: .primary, color: .brand, action: {})
        DocsButton(title: "Secondary", variant: .secondary, color: .brand, action: {})
        DocsButton(title: "Tertiary", variant: .tertiary, color: .brand, action: {})
        DocsButton(title: "Outline", variant: .outline, color: .brand, action: {})
        DocsButton(title: "Danger", variant: .primary, color: .danger, action: {})
        DocsButton(title: "Disabled", variant: .primary, color: .brand, isDisabled: true, action: {})
    }
    .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ButtonStyleResolverTests`
Expected: PASS — `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/Button.swift DocsIOSTests/DesignSystem/Components/ButtonStyleResolverTests.swift
git commit -m "Add Button component"
```

---

### Task 3: IconButton component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/IconButton.swift`
- Test: `DocsIOSTests/DesignSystem/Components/IconButtonStyleResolverTests.swift`

**Interfaces:**
- Consumes: `DocsColorHex`, `DocsSpacing`; `Color(hex:)`.
- Produces: `enum IconButtonVariant { ghost, soft, outline }`, `enum IconButtonColor { neutral, brand, danger }`, `struct IconButtonStyleHex: Equatable { backgroundHex: UInt32?, foregroundHex: UInt32, borderHex: UInt32? }`, `enum IconButtonStyleResolver { static func style(variant:color:isDisabled:) -> IconButtonStyleHex }`, `struct IconButton: View` — consumed by Task 6's catalog preview.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/IconButtonStyleResolverTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class IconButtonStyleResolverTests: XCTestCase {
    func testGhostHasNoBackground() {
        let style = IconButtonStyleResolver.style(variant: .ghost, color: .neutral, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.textSecondary)
    }

    func testSoftBrandUsesBrandSoftBackground() {
        let style = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: false)
        XCTAssertEqual(style.backgroundHex, DocsColorHex.brandFillSoft)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.textBrandSecondary)
    }

    func testOutlineDangerHasMatchingBorder() {
        let style = IconButtonStyleResolver.style(variant: .outline, color: .danger, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.danger)
        XCTAssertEqual(style.borderHex, DocsColorHex.danger)
    }

    func testDisabledIgnoresVariantAndColor() {
        let style = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: true)
        XCTAssertEqual(style, IconButtonStyleHex(backgroundHex: nil, foregroundHex: DocsColorHex.textDisabled, borderHex: nil))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/IconButtonStyleResolverTests`
Expected: FAIL — `cannot find 'IconButtonStyleResolver' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/IconButton.swift`:
```swift
import SwiftUI

enum IconButtonVariant {
    case ghost
    case soft
    case outline
}

enum IconButtonColor {
    case neutral
    case brand
    case danger
}

struct IconButtonStyleHex: Equatable {
    let backgroundHex: UInt32?
    let foregroundHex: UInt32
    let borderHex: UInt32?
}

enum IconButtonStyleResolver {
    static func style(variant: IconButtonVariant, color: IconButtonColor, isDisabled: Bool) -> IconButtonStyleHex {
        if isDisabled {
            return IconButtonStyleHex(backgroundHex: nil, foregroundHex: DocsColorHex.textDisabled, borderHex: nil)
        }

        let foregroundHex: UInt32
        let softHex: UInt32

        switch color {
        case .neutral:
            foregroundHex = DocsColorHex.textSecondary
            softHex = DocsColorHex.surfaceMuted
        case .brand:
            foregroundHex = DocsColorHex.textBrandSecondary
            softHex = DocsColorHex.brandFillSoft
        case .danger:
            foregroundHex = DocsColorHex.danger
            softHex = DocsColorHex.dangerSoft
        }

        switch variant {
        case .ghost:
            return IconButtonStyleHex(backgroundHex: nil, foregroundHex: foregroundHex, borderHex: nil)
        case .soft:
            return IconButtonStyleHex(backgroundHex: softHex, foregroundHex: foregroundHex, borderHex: nil)
        case .outline:
            return IconButtonStyleHex(backgroundHex: nil, foregroundHex: foregroundHex, borderHex: foregroundHex)
        }
    }
}

struct IconButton: View {
    let systemImage: String
    let label: String
    var variant: IconButtonVariant = .ghost
    var color: IconButtonColor = .neutral
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        let style = IconButtonStyleResolver.style(variant: variant, color: color, isDisabled: isDisabled)
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: DocsSpacing.rowMinHeight, height: DocsSpacing.rowMinHeight)
                .foregroundStyle(Color(hex: style.foregroundHex))
                .background(style.backgroundHex.map { Color(hex: $0) } ?? Color.clear)
                .overlay(
                    Circle()
                        .strokeBorder(style.borderHex.map { Color(hex: $0) } ?? Color.clear, lineWidth: style.borderHex == nil ? 0 : 1)
                )
                .clipShape(Circle())
        }
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceSM) {
        IconButton(systemImage: "magnifyingglass", label: "Search", variant: .ghost, color: .neutral, action: {})
        IconButton(systemImage: "plus", label: "Add", variant: .soft, color: .brand, action: {})
        IconButton(systemImage: "trash", label: "Delete", variant: .outline, color: .danger, action: {})
        IconButton(systemImage: "ellipsis", label: "More", isDisabled: true, action: {})
    }
    .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/IconButtonStyleResolverTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/IconButton.swift DocsIOSTests/DesignSystem/Components/IconButtonStyleResolverTests.swift
git commit -m "Add IconButton component"
```

---

### Task 4: Badge component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/Badge.swift`
- Test: `DocsIOSTests/DesignSystem/Components/BadgeStyleResolverTests.swift`

**Interfaces:**
- Consumes: `DocsColorHex`, `DocsSpacing`, `DocsFont`; `Color(hex:)`.
- Produces: `enum BadgeTone { accent, neutral, danger, success, warning, info }`, `struct BadgeStyleHex: Equatable { backgroundHex: UInt32, foregroundHex: UInt32 }`, `enum BadgeStyleResolver { static func style(tone:) -> BadgeStyleHex }`, `struct Badge: View` — consumed by Task 6's catalog preview.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/BadgeStyleResolverTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class BadgeStyleResolverTests: XCTestCase {
    func testAccentToneUsesBrandSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .accent), BadgeStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary))
    }

    func testNeutralToneUsesSurfaceMuted() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .neutral), BadgeStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary))
    }

    func testDangerToneUsesDangerSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .danger), BadgeStyleHex(backgroundHex: DocsColorHex.dangerSoft, foregroundHex: DocsColorHex.danger))
    }

    func testSuccessToneUsesSuccessSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .success), BadgeStyleHex(backgroundHex: DocsColorHex.successSoft, foregroundHex: DocsColorHex.success))
    }

    func testWarningToneUsesWarningSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .warning), BadgeStyleHex(backgroundHex: DocsColorHex.warningSoft, foregroundHex: DocsColorHex.warning))
    }

    func testInfoToneUsesInfoSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .info), BadgeStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/BadgeStyleResolverTests`
Expected: FAIL — `cannot find 'BadgeStyleResolver' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/Badge.swift`:
```swift
import SwiftUI

enum BadgeTone {
    case accent
    case neutral
    case danger
    case success
    case warning
    case info
}

struct BadgeStyleHex: Equatable {
    let backgroundHex: UInt32
    let foregroundHex: UInt32
}

enum BadgeStyleResolver {
    static func style(tone: BadgeTone) -> BadgeStyleHex {
        switch tone {
        case .accent:
            return BadgeStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary)
        case .neutral:
            return BadgeStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary)
        case .danger:
            return BadgeStyleHex(backgroundHex: DocsColorHex.dangerSoft, foregroundHex: DocsColorHex.danger)
        case .success:
            return BadgeStyleHex(backgroundHex: DocsColorHex.successSoft, foregroundHex: DocsColorHex.success)
        case .warning:
            return BadgeStyleHex(backgroundHex: DocsColorHex.warningSoft, foregroundHex: DocsColorHex.warning)
        case .info:
            return BadgeStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info)
        }
    }
}

struct Badge: View {
    let text: String
    var tone: BadgeTone = .neutral
    var icon: String? = nil

    var body: some View {
        let style = BadgeStyleResolver.style(tone: tone)
        HStack(spacing: DocsSpacing.space4xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
            }
            Text(text)
                .font(DocsFont.caption)
        }
        .padding(.horizontal, DocsSpacing.spaceXS)
        .padding(.vertical, DocsSpacing.space4xs)
        .foregroundStyle(Color(hex: style.foregroundHex))
        .background(Color(hex: style.backgroundHex))
        .clipShape(Capsule())
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceXS) {
        Badge(text: "Admin", tone: .accent)
        Badge(text: "3", tone: .neutral)
        Badge(text: "Failed", tone: .danger, icon: "xmark.circle")
        Badge(text: "Active", tone: .success)
        Badge(text: "Pending", tone: .warning)
        Badge(text: "Info", tone: .info)
    }
    .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/BadgeStyleResolverTests`
Expected: PASS — `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/Badge.swift DocsIOSTests/DesignSystem/Components/BadgeStyleResolverTests.swift
git commit -m "Add Badge component"
```

---

### Task 5: Switch component

`Switch` wraps SwiftUI's `Toggle` with the brand tint. Unlike Tasks 2-4, it has no variant/color branching logic — there is nothing to put in a resolver, so (matching the precedent set by `RootView` in the prior plan) this task has no new test file. Verification is build success plus the Preview compiling.

**Files:**
- Create: `DocsIOS/DesignSystem/Components/Switch.swift`

**Interfaces:**
- Consumes: `DocsColor.brandFill`.
- Produces: `struct Switch: View { @Binding var isOn: Bool; var isDisabled: Bool = false }` — consumed by Task 6's catalog preview.

- [ ] **Step 1: Write the component**

`DocsIOS/DesignSystem/Components/Switch.swift`:
```swift
import SwiftUI

struct Switch: View {
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(DocsColor.brandFill)
            .disabled(isDisabled)
    }
}

#Preview {
    @Previewable @State var isOn = true
    Switch(isOn: $isOn)
        .padding()
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add DocsIOS/DesignSystem/Components/Switch.swift
git commit -m "Add Switch component"
```

---

### Task 6: Component catalog preview

A single file with Previews of all four components together, serving as the visual QA catalog per the design spec's testing section. This is presentational only — no new testable logic, so verification is the full test suite (proving nothing broke) plus build success.

**Files:**
- Create: `DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`

**Interfaces:**
- Consumes: `DocsButton`, `IconButton`, `Badge`, `Switch` (Tasks 2-5), `DocsSpacing`, `DocsColor`, `DocsFont` (prior plan).
- Produces: `struct ComponentCatalogPreview: View` — a `#Preview`-only artifact, not consumed by any other file in this plan (later screens will use the individual components directly, not this catalog).

- [ ] **Step 1: Write the catalog view**

`DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`:
```swift
import SwiftUI

struct ComponentCatalogPreview: View {
    @State private var isSwitchOn = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceLG) {
                catalogSection("Buttons") {
                    VStack(spacing: DocsSpacing.spaceSM) {
                        DocsButton(title: "Primary", variant: .primary, color: .brand, action: {})
                        DocsButton(title: "Secondary", variant: .secondary, color: .brand, action: {})
                        DocsButton(title: "Tertiary", variant: .tertiary, color: .brand, action: {})
                        DocsButton(title: "Outline", variant: .outline, color: .brand, action: {})
                        DocsButton(title: "Danger", variant: .primary, color: .danger, action: {})
                        DocsButton(title: "Disabled", variant: .primary, color: .brand, isDisabled: true, action: {})
                    }
                }

                catalogSection("Icon Buttons") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        IconButton(systemImage: "magnifyingglass", label: "Search", variant: .ghost, color: .neutral, action: {})
                        IconButton(systemImage: "plus", label: "Add", variant: .soft, color: .brand, action: {})
                        IconButton(systemImage: "trash", label: "Delete", variant: .outline, color: .danger, action: {})
                    }
                }

                catalogSection("Badges") {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Badge(text: "Admin", tone: .accent)
                        Badge(text: "3", tone: .neutral)
                        Badge(text: "Failed", tone: .danger, icon: "xmark.circle")
                        Badge(text: "Active", tone: .success)
                    }
                }

                catalogSection("Switch") {
                    Switch(isOn: $isSwitchOn)
                }
            }
            .padding(DocsSpacing.spaceBase)
        }
        .background(DocsColor.surfacePage)
    }

    @ViewBuilder
    private func catalogSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            Text(title)
                .font(DocsFont.title2)
                .foregroundStyle(DocsColor.textPrimary)
            content()
        }
    }
}

#Preview {
    ComponentCatalogPreview()
}
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 38 tests, with 0 failures` (21 from the prior plan + 1 new soft-feedback color test + 6 Button + 4 IconButton + 6 Badge = 38)

- [ ] **Step 3: Commit**

```bash
git add DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift
git commit -m "Add component catalog preview"
```

## Self-Review Notes

- **Spec coverage:** This plan covers 4 of the design spec's ~17 DesignSystem components (Button, IconButton, Badge, Switch) — the primitives with real conditional styling logic worth establishing the resolver pattern on. The remaining components (Avatar, AvatarGroup, DocIcon, SearchField, SegmentedControl, TextField, NavBar, TabBar, ListRow, ListSection, DocRow, LinkReachPill, ShareMemberRow) are deferred to subsequent plans, consistent with the design spec's phased build sequence and the writing-plans Scope Check guidance (one independently-shippable subsystem per plan).
- **Placeholder scan:** No TBD/TODO. Switch has no test file, but this is documented as an intentional no-testable-logic case (matching the RootView precedent), not an omission.
- **Type consistency:** `ButtonStyleHex`/`IconButtonStyleHex` share the same 3-field shape (`backgroundHex: UInt32?`, `foregroundHex: UInt32`, `borderHex: UInt32?`) but are deliberately distinct types (not shared), since Button and IconButton are independent components with no reason to couple their style representations. `BadgeStyleHex` has only 2 fields (`backgroundHex: UInt32`, `foregroundHex: UInt32`, both non-optional) since badges never omit their background or use borders — this asymmetry is intentional, not an inconsistency.
- **Cross-file validation:** All code in this plan (including the Task 1 token extension and all 4 components together) was compiled and test-run end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 38 tests, with 0 failures`.
