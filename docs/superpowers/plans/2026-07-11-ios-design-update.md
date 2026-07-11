# iOS design update — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the Claude Design handoff to the Schrift iOS app — refresh the tab pages, add a full adaptive dark theme with a Light/Dark/System toggle, add live in-app language switching across 10 languages, restructure Profile, and add version history.

**Architecture:** Additive on the existing MVVM + `@Observable` + `actor DocsAPIClient` stack. Dark mode makes the existing `DocsColor` tokens adaptive (light+dark raw hex) so almost the whole app adapts with no call-site churn; the 5 style-resolver components carry explicit dark values. Localization is an in-code catalog resolved live through an injected `@Observable LocalizationStore`. Two new app-scoped stores (`AppearanceStore`, `LocalizationStore`) are injected at the app root. Version history and the server-config row add small endpoints.

**Tech Stack:** Swift 6, SwiftUI, iOS 18, XcodeGen (`project.yml`), XCTest, `MockURLProtocol`. Zero third-party runtime deps.

**Spec:** [`docs/superpowers/specs/2026-07-11-ios-design-update-design.md`](../specs/2026-07-11-ios-design-update-design.md). Read it before starting.

## Global Constraints

Copied verbatim from `CLAUDE.md` and the spec. Every task implicitly includes these.

- **Regenerate the project before building:** on a fresh worktree there is no `.xcodeproj`. Run `brew install xcodegen` once, then `xcodegen generate` before any `xcodebuild`. Re-run after any `project.yml` change.
- **Test command:** `xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'`. Iterate with `-only-testing:SchriftTests/<ClassName>[/<method>]`. Run the full suite before declaring done.
- **Formatting:** `swift format --recursive --in-place Schrift SchriftTests` before every push. PR checks fail on unformatted files. No other linter.
- **Commits:** many **small, focused commits** (user preference), each a Conventional Commit (`feat:`/`fix:`/`docs:`/`refactor:`/`test:`). Commit only when the plan step says to. PRs are squash-merged, so the **PR title** is the release-driving subject.
- **XCTest only** — never Swift Testing. `final class <Type>Tests: XCTestCase`, `@testable import Schrift`, `@MainActor` on test classes whose subject is `@MainActor`. Mirror the source tree. Assert thrown errors with typed `do/catch`. Poll async state with the shared `waitUntil { }`; never `sleep` to wait for expected state. Isolate `UserDefaults(suiteName:)` per test (removePersistentDomain in setUp/tearDown). `MockURLProtocol.reset()` in tearDown.
- **Tokens:** caseless `enum` of `static let`. New colors get `DocsColorHexTests` assertions. Views never use raw color literals — always tokens. Style resolvers return `Equatable` raw values; the view converts hex→Color at render.
- **Stores:** UserDefaults **preferences** use the `schrift.` prefix; data keys use `dev.llun.Schrift.`. `@MainActor @Observable final class`, inject `userDefaults: UserDefaults = .standard` as the first parameter, use `try?`/safe defaults, never throw to callers.
- **Networking:** relative, lowercase, trailing-slash paths; interpolate UUIDs as `documentID.uuidString.lowercased()`; never start a path with `/`. Decode with `JSONDecoder.docsAPI`. Everything goes through `get`/`getRawData`/`send`/`sendVoid`. New mutating endpoints go through `send`/`sendVoid` (CSRF/Origin/Referer). Decode server flag/optional fields defensively (`decodeIfPresent(...) ?? default`).
- **Save-path safety:** the full-overwrite save must never eat content. Restore (Part 6) must funnel through `DocumentSaveCoordinator` and never fabricate Yjs. Do not touch `Core/Yjs` golden bytes.
- **Security (unchanged):** no new deps; no telemetry; never log cookies/CSRF/headers; keep TLS/CSRF intact; never bake in a host/secret.
- **Docs in lockstep:** update `CLAUDE.md` + affected docs in the same change (Phase G).

## File Structure

**New files**

- `Schrift/DesignSystem/Tokens/DocsColorHexDark.swift` — dark raw-hex counterparts for every `DocsColorHex` token.
- `Schrift/App/AppAppearance.swift` — `AppAppearance` enum + `AppearanceStore`.
- `Schrift/Core/Localization/AppLanguage.swift` — the 10-language enum.
- `Schrift/Core/Localization/L10nKey.swift` — the string-key enum (`CaseIterable`).
- `Schrift/Core/Localization/LocalizationStore.swift` — resolver store + plural helper.
- `Schrift/Core/Localization/PluralRule.swift` — per-language plural selection.
- `Schrift/Core/Localization/Strings+en.swift` … `Strings+zhHant.swift` — one table per language (10 files).
- `Schrift/Core/Networking/ServerConfigEndpoints.swift` — `ServerConfig` + `serverConfig()`.
- `Schrift/Core/Networking/VersionEndpoints.swift` — `DocumentVersion` + `documentVersions()` + `restoreDocumentVersion()`.
- `Schrift/Features/Editor/VersionHistorySheetView.swift` — the version-history sheet.
- `Schrift/Features/Editor/VersionHistoryViewModel.swift` — versions VM.
- `Schrift/Features/Profile/AppearancePickerSheet.swift` — appearance picker.
- `Schrift/Features/Profile/LanguagePickerSheet.swift` — language picker.
- Matching tests under `SchriftTests/…` mirroring each of the above.

**Modified files**

- `Schrift/DesignSystem/Tokens/DocsColor.swift` — tokens become adaptive.
- `Schrift/DesignSystem/Tokens/HexColor.swift` — add `Color(lightHex:darkHex:)`.
- `Schrift/DesignSystem/Components/{Badge,Button,IconButton,TextField,LinkReachPill}.swift` — light+dark resolver values.
- `Schrift/DesignSystem/Components/{ListRow,Avatar}.swift`, `Schrift/Features/Editor/InlineTextStyle.swift` — adaptive stray hexes.
- `Schrift/DesignSystem/Components/NavBar.swift` — large-title top-row collapse + inline trailing.
- `Schrift/App/{SchriftApp,RootView}.swift` — inject stores, apply `preferredColorScheme` + `\.locale`.
- `Schrift/Features/Home/HomeView.swift` + `HomeSplitView.swift` — remove account route; consume stores.
- `Schrift/Features/Profile/ProfileScreen.swift` — restructure + pickers.
- `Schrift/Features/Profile/ProfileViewModel.swift` — load server config.
- `Schrift/Features/Profile/AccountScreen.swift` — **deleted**.
- `Schrift/Features/{Home,Search,Shared,Connect,Options,Share,Editor}/…` — string extraction + divider removal + sheet detents.
- `Schrift/Features/Options/OptionsSheetView.swift` — add "Version history" row.
- `project.yml` — `CFBundleLocalizations`.

## Execution phases

- **Phase A** — Dark theme foundation (Tasks A1–A8)
- **Phase B** — Localization foundation + string extraction (Tasks B1–B12)
- **Phase C** — Profile restructure + pickers (Tasks C1–C4)
- **Phase D** — Server config row (Tasks D1–D2)
- **Phase E** — Layout fidelity (Tasks E1–E3)
- **Phase F** — Version history (Tasks F1–F4)
- **Phase G** — Wrap-up: project.yml, docs, format, PR + review loop (Tasks G1–G3)

Phases A, B, D, E, F are independent; C depends on A+B (uses both stores); G is last. Land bottom-up: A → B → C → D/E/F → G.

---

## Phase A — Dark theme foundation

### Task A1: Adaptive color initializer

**Files:**
- Modify: `Schrift/DesignSystem/Tokens/HexColor.swift`
- Test: `SchriftTests/DesignSystem/Tokens/HexColorTests.swift` (create if absent)

**Interfaces:**
- Produces: `func resolvedHex(lightHex: UInt32, darkHex: UInt32, isDark: Bool) -> UInt32`; `Color.init(lightHex: UInt32, darkHex: UInt32, opacity: Double = 1)`.

- [ ] **Step 1: Write the failing test**

```swift
import SwiftUI
import UIKit
import XCTest
@testable import Schrift

final class HexColorTests: XCTestCase {
    func testResolvedHexPicksByStyle() {
        XCTAssertEqual(resolvedHex(lightHex: 0xFFFFFF, darkHex: 0x000000, isDark: false), 0xFFFFFF)
        XCTAssertEqual(resolvedHex(lightHex: 0xFFFFFF, darkHex: 0x000000, isDark: true), 0x000000)
    }

    func testAdaptiveColorResolvesBothStyles() {
        let color = UIColor(Color(lightHex: 0xFFFFFF, darkHex: 0x000000))
        let light = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var lr: CGFloat = 0, dr: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        light.getRed(&lr, green: &g, blue: &b, alpha: &a)
        dark.getRed(&dr, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(lr, 1, accuracy: 0.01)
        XCTAssertEqual(dr, 0, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/HexColorTests`
Expected: FAIL (compile error — `resolvedHex`/`Color(lightHex:darkHex:)` undefined). Run `xcodegen generate` first if the project is missing.

- [ ] **Step 3: Implement**

Append to `Schrift/DesignSystem/Tokens/HexColor.swift`:

```swift
import UIKit

/// Pure selector for the adaptive color's two raw values — unit-testable
/// without SwiftUI or a trait collection.
func resolvedHex(lightHex: UInt32, darkHex: UInt32, isDark: Bool) -> UInt32 {
    isDark ? darkHex : lightHex
}

extension Color {
    /// Adaptive color: resolves `lightHex` in light mode, `darkHex` in dark mode.
    /// Backed by `UIColor(dynamicProvider:)` so it re-resolves on trait changes.
    init(lightHex: UInt32, darkHex: UInt32, opacity: Double = 1) {
        self.init(uiColor: UIColor { traits in
            let hex = resolvedHex(lightHex: lightHex, darkHex: darkHex, isDark: traits.userInterfaceStyle == .dark)
            let c = hexColorComponents(hex)
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: opacity)
        })
    }
}
```

Note: `HexColor.swift` currently `import SwiftUI` only; keep the existing `Color(hex:)` init untouched (still used for one-off literals) and add `import UIKit` at the top.

- [ ] **Step 4: Run to verify it passes**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Schrift/DesignSystem/Tokens/HexColor.swift SchriftTests/DesignSystem/Tokens/HexColorTests.swift
git commit -m "feat: add adaptive Color(lightHex:darkHex:) initializer"
```

### Task A2: Dark token palette + adaptive DocsColor

**Files:**
- Create: `Schrift/DesignSystem/Tokens/DocsColorHexDark.swift`
- Modify: `Schrift/DesignSystem/Tokens/DocsColor.swift`
- Test: `SchriftTests/DesignSystem/Tokens/DocsColorHexTests.swift` (add dark assertions; create if absent)

**Interfaces:**
- Produces: `enum DocsColorHexDark` (same member names as `DocsColorHex`); `DocsColor.*` become adaptive `Color`s.

- [ ] **Step 1: Write the failing test** — assert a representative sample of dark values (full set asserted, abbreviated here):

```swift
import XCTest
@testable import Schrift

final class DocsColorHexDarkTests: XCTestCase {
    func testDarkSurfaces() {
        XCTAssertEqual(DocsColorHexDark.surfacePage, 0x16161C)
        XCTAssertEqual(DocsColorHexDark.surfaceSunken, 0x0E0E13)
        XCTAssertEqual(DocsColorHexDark.surfaceRaised, 0x202028)
        XCTAssertEqual(DocsColorHexDark.surfaceMuted, 0x2A2A34)
    }
    func testDarkText() {
        XCTAssertEqual(DocsColorHexDark.textPrimary, 0xF4F4F6)
        XCTAssertEqual(DocsColorHexDark.textSecondary, 0xB4B4C6)
        XCTAssertEqual(DocsColorHexDark.textTertiary, 0x9494AA)
    }
    func testDarkBrandAndFeedback() {
        XCTAssertEqual(DocsColorHexDark.brandFill, 0x7B79E8)
        XCTAssertEqual(DocsColorHexDark.textBrand, 0xA9ADF9)
        XCTAssertEqual(DocsColorHexDark.danger, 0xF4796E)
        XCTAssertEqual(DocsColorHexDark.borderDefault, 0x2E2E38)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `-only-testing:SchriftTests/DocsColorHexDarkTests`. Expected: FAIL (`DocsColorHexDark` undefined).

- [ ] **Step 3: Implement** — create `DocsColorHexDark.swift` with every token from the §4.3 table (authoritative). Full list:

```swift
enum DocsColorHexDark {
    // Brand
    static let brandFill: UInt32 = 0x7B79E8
    static let brandFillHover: UInt32 = 0x8F8DF2
    static let brandFillSoft: UInt32 = 0x2C2C50
    static let brandFillSubtle: UInt32 = 0x1E1E33
    static let textBrand: UInt32 = 0xA9ADF9
    static let textBrandSecondary: UInt32 = 0x9195FC
    // Text
    static let textPrimary: UInt32 = 0xF4F4F6
    static let textSecondary: UInt32 = 0xB4B4C6
    static let textTertiary: UInt32 = 0x9494AA
    static let textDisabled: UInt32 = 0x5A5A6B
    static let textOnBrand: UInt32 = 0xFFFFFF
    // Surfaces
    static let surfacePage: UInt32 = 0x16161C
    static let surfaceSunken: UInt32 = 0x0E0E13
    static let surfaceMuted: UInt32 = 0x2A2A34
    static let surfaceRaised: UInt32 = 0x202028
    static let surfaceScrim: UInt32 = 0x000000  // rendered at 0.50 opacity
    // Borders
    static let borderDefault: UInt32 = 0x2E2E38
    static let borderStrong: UInt32 = 0x3C3C48
    static let borderFocus: UInt32 = 0x9CA0FF
    // Feedback
    static let info: UInt32 = 0x5AA9F0
    static let success: UInt32 = 0x4FB878
    static let warning: UInt32 = 0xE6915F
    static let danger: UInt32 = 0xF4796E
    static let infoSoft: UInt32 = 0x12283F
    static let successSoft: UInt32 = 0x12301E
    static let warningSoft: UInt32 = 0x35220F
    static let dangerSoft: UInt32 = 0x3A1A17
    static let dangerStrong: UInt32 = 0xF4796E
    static let info650: UInt32 = 0x5AA9F0
    static let success650: UInt32 = 0x4FB878
    static let warning650: UInt32 = 0xE6915F
    // Brand logo
    static let brandLogo: UInt32 = 0x7C79F2
    // Neutral gray ramp
    static let gray050: UInt32 = 0x202028
    static let gray100: UInt32 = 0x2E2E38
    static let gray300: UInt32 = 0x565663
    static let gray350: UInt32 = 0x6C6C80
    static let gray450: UInt32 = 0x8A8A9E
    static let gray600: UInt32 = 0xB7B7CB
    // Accent palette — unchanged in dark (white initials read on both)
    static let accentOrange: UInt32 = 0xB95D33
    static let accentBrown: UInt32 = 0x8F7158
    static let accentGreen: UInt32 = 0x008948
    static let accentBlue1: UInt32 = 0x4279B9
    static let accentBlue2: UInt32 = 0x00848F
    static let accentPurple: UInt32 = 0x9961AF
    static let accentPink: UInt32 = 0xAA5F80
}
```

Then rewrite each `DocsColor.*` in `DocsColor.swift` to pair light+dark, e.g.:

```swift
static let brandFill = Color(lightHex: DocsColorHex.brandFill, darkHex: DocsColorHexDark.brandFill)
static let surfacePage = Color(lightHex: DocsColorHex.surfacePage, darkHex: DocsColorHexDark.surfacePage)
static let surfaceScrim = Color(lightHex: DocsColorHex.surfaceScrim, darkHex: DocsColorHexDark.surfaceScrim, opacity: 0.45)
// …every token, including gray050/gray300/gray350/gray450 which the app consumes directly
```

Add `gray100`/`gray600`/`borderStrong`/`textDisabled`/`brandFillHover`/etc. to the `DocsColor` enum as adaptive `Color`s if any view consumes them directly (currently they're consumed only via resolvers — leave those out of `DocsColor` unless a view needs them; the resolver task A3–A5 reads the Hex enums directly).

- [ ] **Step 4: Run to verify it passes.** Also run the full DocsColorHexTests to confirm the existing light assertions still pass.

- [ ] **Step 5: Commit**

```bash
git add Schrift/DesignSystem/Tokens/DocsColorHexDark.swift Schrift/DesignSystem/Tokens/DocsColor.swift SchriftTests/DesignSystem/Tokens/DocsColorHexDarkTests.swift
git commit -m "feat: add dark color palette and make DocsColor tokens adaptive"
```

### Task A3: Badge resolver — light + dark

**Files:**
- Modify: `Schrift/DesignSystem/Components/Badge.swift`
- Test: `SchriftTests/DesignSystem/Components/BadgeStyleResolverTests.swift`

**Interfaces:**
- Produces: `BadgeStyleHex { backgroundLightHex, backgroundDarkHex, foregroundLightHex, foregroundDarkHex }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Schrift

final class BadgeStyleResolverTests: XCTestCase {
    func testSuccessToneCarriesLightAndDark() {
        let s = BadgeStyleResolver.style(tone: .success)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.successSoft)
        XCTAssertEqual(s.backgroundDarkHex, DocsColorHexDark.successSoft)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.success650)
        XCTAssertEqual(s.foregroundDarkHex, DocsColorHexDark.success650)
    }
    func testNeutralToneFlipsForegroundLightInDark() {
        let s = BadgeStyleResolver.style(tone: .neutral)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.gray100)
        XCTAssertEqual(s.backgroundDarkHex, DocsColorHexDark.gray100)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.gray600)
        XCTAssertEqual(s.foregroundDarkHex, DocsColorHexDark.gray600)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL (struct has no dark fields).

- [ ] **Step 3: Implement** — update the struct, resolver (fill dark from `DocsColorHexDark`), and the view (`body`) to render adaptively:

```swift
struct BadgeStyleHex: Equatable {
    let backgroundLightHex: UInt32
    let backgroundDarkHex: UInt32
    let foregroundLightHex: UInt32
    let foregroundDarkHex: UInt32
}

enum BadgeStyleResolver {
    static func style(tone: BadgeTone) -> BadgeStyleHex {
        switch tone {
        case .accent:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.brandFillSoft, backgroundDarkHex: DocsColorHexDark.brandFillSoft,
                foregroundLightHex: DocsColorHex.textBrandSecondary, foregroundDarkHex: DocsColorHexDark.textBrandSecondary)
        case .neutral:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.gray100, backgroundDarkHex: DocsColorHexDark.gray100,
                foregroundLightHex: DocsColorHex.gray600, foregroundDarkHex: DocsColorHexDark.gray600)
        case .danger:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.dangerSoft, backgroundDarkHex: DocsColorHexDark.dangerSoft,
                foregroundLightHex: DocsColorHex.dangerStrong, foregroundDarkHex: DocsColorHexDark.dangerStrong)
        case .success:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.successSoft, backgroundDarkHex: DocsColorHexDark.successSoft,
                foregroundLightHex: DocsColorHex.success650, foregroundDarkHex: DocsColorHexDark.success650)
        case .warning:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.warningSoft, backgroundDarkHex: DocsColorHexDark.warningSoft,
                foregroundLightHex: DocsColorHex.warning650, foregroundDarkHex: DocsColorHexDark.warning650)
        case .info:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.infoSoft, backgroundDarkHex: DocsColorHexDark.infoSoft,
                foregroundLightHex: DocsColorHex.info650, foregroundDarkHex: DocsColorHexDark.info650)
        }
    }
}
```

In `body`, replace the color derivations:

```swift
let style = BadgeStyleResolver.style(tone: tone)
let foreground = Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex)
// …
.background(Color(lightHex: style.backgroundLightHex, darkHex: style.backgroundDarkHex))
```

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: give Badge resolver dark-mode values"`

### Task A4: Button + IconButton resolvers — light + dark

**Files:**
- Modify: `Schrift/DesignSystem/Components/Button.swift`, `Schrift/DesignSystem/Components/IconButton.swift`
- Test: `SchriftTests/DesignSystem/Components/ButtonStyleResolverTests.swift`, `SchriftTests/DesignSystem/Components/IconButtonStyleResolverTests.swift`

**Interfaces:**
- Produces: `ButtonStyleHex` and `IconButtonStyleHex` each gain `*LightHex`/`*DarkHex` fields for every color they carry.

- [ ] **Step 1: Read the two files first** to enumerate each resolver's existing fields (background, foreground, border, disabled variants). For **each** existing `xHex` field, add a paired `xLightHex`/`xDarkHex` (rename the existing to `…LightHex`, add `…DarkHex` from `DocsColorHexDark`).
- [ ] **Step 2: Write failing tests** asserting, for one representative variant each, that light fields equal the current `DocsColorHex.*` and dark fields equal `DocsColorHexDark.*` (mirror A3's shape).
- [ ] **Step 3: Run to verify they fail.**
- [ ] **Step 4: Implement** — update structs, resolvers, and the views' render lines to `Color(lightHex:darkHex:)`. Keep every existing light value identical (existing resolver tests must still pass).
- [ ] **Step 5: Run both resolver test files + the components' existing tests.**
- [ ] **Step 6: Commit** — `git commit -m "feat: give Button and IconButton resolvers dark-mode values"`

### Task A5: TextField + LinkReachPill resolvers — light + dark

**Files:**
- Modify: `Schrift/DesignSystem/Components/TextField.swift`, `Schrift/DesignSystem/Components/LinkReachPill.swift`
- Test: `SchriftTests/DesignSystem/Components/TextFieldStyleResolverTests.swift`, `SchriftTests/DesignSystem/Components/LinkReachPillStyleResolverTests.swift`

Same procedure as A4 for these two resolvers. **Steps:** read files → failing tests (light == `DocsColorHex`, dark == `DocsColorHexDark`) → run-fail → implement structs+resolvers+views → run-pass → commit `feat: give TextField and LinkReachPill resolvers dark-mode values`.

### Task A6: Adaptive stray hexes (ListRow, Avatar, InlineTextStyle)

**Files:**
- Modify: `Schrift/DesignSystem/Components/ListRow.swift` (`listRowTitleColorHex` → adaptive), `Schrift/DesignSystem/Components/Avatar.swift`, `Schrift/Features/Editor/InlineTextStyle.swift`
- Test: `SchriftTests/DesignSystem/Components/ListRowTests.swift` (create), `SchriftTests/Features/Editor/InlineTextStyleTests.swift` (extend if present)

- [ ] **Step 1:** `ListRow.listRowTitleColorHex(isDestructive:)` returns raw hex used via `Color(hex:)`. Change the title color to adaptive: either return a `(light,dark)` pair or, simplest, render the title with `DocsColor.danger`/`DocsColor.textPrimary` (already adaptive tokens) instead of `Color(hex: listRowTitleColorHex(...))`. Prefer the token route; keep a pure helper only if a test needs it. Write a test asserting destructive→danger token, else primary (via a small `enum`-returning helper if you keep one).
- [ ] **Step 2:** `Avatar` — the accent background stays the same hue in dark; ensure it uses the accent tokens (unchanged). White initials read on both. No change unless it hardcodes a light-only text color; if so, keep white.
- [ ] **Step 3:** `InlineTextStyle` — the editor link color must have a dark variant. Route the link color through an adaptive token (e.g. `Color(lightHex: DocsColorHex.info, darkHex: DocsColorHexDark.info)` or the `textBrand` pair) instead of a single `Color(hex:)`. Add/extend a test asserting the link style resolves to the info/brand hex pair.
- [ ] **Step 4:** Run the touched tests.
- [ ] **Step 5: Commit** — `git commit -m "feat: make ListRow/Avatar/InlineTextStyle colors dark-adaptive"`

### Task A7: AppAppearance + AppearanceStore

**Files:**
- Create: `Schrift/App/AppAppearance.swift`
- Test: `SchriftTests/App/AppearanceStoreTests.swift`

**Interfaces:**
- Produces: `enum AppAppearance: String, CaseIterable, Sendable { case system, light, dark }` with `var colorScheme: ColorScheme?` and `var iconName: String`; `@MainActor @Observable final class AppearanceStore` with `var selected: AppAppearance` (persisted `schrift.appearance`) and `init(userDefaults: UserDefaults = .standard)`.

- [ ] **Step 1: Write the failing test**

```swift
import SwiftUI
import XCTest
@testable import Schrift

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    override func setUp() { defaults = UserDefaults(suiteName: #function); defaults.removePersistentDomain(forName: #function) }
    override func tearDown() { defaults.removePersistentDomain(forName: #function); defaults = nil }

    func testDefaultsToSystem() {
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .system)
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }
    func testPersistsSelection() {
        let store = AppearanceStore(userDefaults: defaults)
        store.selected = .dark
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .dark)
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement**

```swift
import SwiftUI

enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var iconName: String {
        switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" }
    }
}

@MainActor
@Observable
final class AppearanceStore {
    var selected: AppAppearance {
        didSet { userDefaults.set(selected.rawValue, forKey: Self.key) }
    }
    private let userDefaults: UserDefaults
    private static let key = "schrift.appearance"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let raw = userDefaults.string(forKey: Self.key)
        selected = raw.flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}
```

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add AppAppearance and AppearanceStore"`

### Task A8: Apply appearance at the app root

**Files:**
- Modify: `Schrift/App/SchriftApp.swift`, `Schrift/App/RootView.swift`
- Test: manual (no unit test — SwiftUI wiring). Verified via the dark-mode `#Preview`s and a run.

- [ ] **Step 1:** In `SchriftApp`, build `@State private var appearanceStore = AppearanceStore()` and inject it: `RootView().environment(appearanceStore).preferredColorScheme(appearanceStore.selected.colorScheme)`. (LocalizationStore injection is added in Task B4 — leave a note; do not add it here yet.)
- [ ] **Step 2:** Confirm `RootView` compiles and every screen inherits the environment. Add `@Environment(AppearanceStore.self)` reads only where needed later (Profile, Task C3).
- [ ] **Step 3:** Add a dark-scheme preview to a representative component to eyeball the palette, e.g. in `Badge.swift`'s `#Preview` add `.preferredColorScheme(.dark)` variant or a second preview.
- [ ] **Step 4:** `xcodegen generate` (no project.yml change here, but safe) and build: `xcodebuild build -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'`. Expected: BUILD SUCCEEDED.
- [ ] **Step 5: Commit** — `git commit -m "feat: apply the selected appearance at the app root"`

---

## Phase B — Localization foundation + string extraction

**Convention — localized view-model errors.** A VM that stores a resolved English
string in `errorMessage: String?` would not re-localize when the user switches
language live. So as each screen is localized, change its VM to expose the error
as **`var errorKey: L10nKey?`** (renamed from `errorMessage`), and the view
renders `errorKey.map { loc[$0] }`. This is live-localizable and makes error
tests assert an enum case, not English copy. Where a VM sets different messages
per operation, add one key per message. Apply this per-VM inside the relevant
screen task (B5–B11) and in D2/F2. (This supersedes the `errorMessage: String?`
convention in CLAUDE.md for user-facing VM errors — record that in Task G2.)

### Task B1: AppLanguage enum

**Files:**
- Create: `Schrift/Core/Localization/AppLanguage.swift`
- Test: `SchriftTests/Core/Localization/AppLanguageTests.swift`

**Interfaces:**
- Produces: `enum AppLanguage: String, CaseIterable, Identifiable, Sendable` with `code`, `autonym`, `locale`, and `static func bestMatch(preferred: [String]) -> AppLanguage`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import XCTest
@testable import Schrift

final class AppLanguageTests: XCTestCase {
    func testCodesAndAutonyms() {
        XCTAssertEqual(AppLanguage.thai.code, "th")
        XCTAssertEqual(AppLanguage.thai.autonym, "ไทย")
        XCTAssertEqual(AppLanguage.chineseSimplified.code, "zh-Hans")
        XCTAssertEqual(AppLanguage.chineseTraditional.code, "zh-Hant")
        XCTAssertEqual(AppLanguage.allCases.count, 10)
    }
    func testBestMatchPrefersExactThenScriptThenEnglish() {
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["fr-FR", "en"]), .french)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["zh-Hant-TW"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["zh-Hans-CN"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["ja"]), .english)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: []), .english)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `-only-testing:SchriftTests/AppLanguageTests`.
- [ ] **Step 3: Implement**

```swift
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english, french, spanish, german, italian, dutch, portuguese, thai
    case chineseSimplified, chineseTraditional

    var id: String { rawValue }

    var code: String {
        switch self {
        case .english: "en"; case .french: "fr"; case .spanish: "es"; case .german: "de"
        case .italian: "it"; case .dutch: "nl"; case .portuguese: "pt"; case .thai: "th"
        case .chineseSimplified: "zh-Hans"; case .chineseTraditional: "zh-Hant"
        }
    }

    /// The language's own name, shown in the picker.
    var autonym: String {
        switch self {
        case .english: "English"; case .french: "Français"; case .spanish: "Español"
        case .german: "Deutsch"; case .italian: "Italiano"; case .dutch: "Nederlands"
        case .portuguese: "Português"; case .thai: "ไทย"
        case .chineseSimplified: "简体中文"; case .chineseTraditional: "繁體中文"
        }
    }

    var locale: Locale { Locale(identifier: code) }

    /// First-launch default: exact code, then script (zh-Hans/zh-Hant), then base
    /// language, else English.
    static func bestMatch(preferred: [String]) -> AppLanguage {
        for tag in preferred {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") {
                if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
                    return .chineseTraditional
                }
                return .chineseSimplified
            }
            let base = String(lower.prefix(2))
            if let match = allCases.first(where: { $0.code == base }) { return match }
        }
        return .english
    }
}
```

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add AppLanguage enum"`

### Task B2: L10nKey, English table, LocalizationStore

**Files:**
- Create: `Schrift/Core/Localization/L10nKey.swift`, `Schrift/Core/Localization/Strings+en.swift`, `Schrift/Core/Localization/LocalizationStore.swift`
- Test: `SchriftTests/Core/Localization/LocalizationStoreTests.swift`

**Interfaces:**
- Produces: `enum L10nKey: String, CaseIterable, Sendable`; `enum Strings_en { static let table: [L10nKey: String] }`; `enum Strings { static func table(for: AppLanguage) -> [L10nKey: String] }`; `@MainActor @Observable final class LocalizationStore` with `var language`, `subscript(_ key: L10nKey) -> String`, `func format(_ key: L10nKey, _ args: CVarArg...) -> String`, `var locale: Locale`, `init(userDefaults: UserDefaults = .standard)`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import XCTest
@testable import Schrift

@MainActor
final class LocalizationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    override func setUp() { defaults = UserDefaults(suiteName: #function); defaults.removePersistentDomain(forName: #function) }
    override func tearDown() { defaults.removePersistentDomain(forName: #function); defaults = nil }

    func testResolvesCurrentLanguage() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .french
        XCTAssertEqual(store[.common_done], Strings_fr.table[.common_done])
        XCTAssertEqual(store.locale.identifier, "fr")
    }
    func testFallsBackToEnglishForMissingKey() {
        // A key intentionally absent from a non-English table resolves to English.
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .thai
        let value = store[.common_done]
        XCTAssertFalse(value.isEmpty)
    }
    func testFormatSubstitutesArgs() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        XCTAssertEqual(store.format(.search_results_other, 3), "3 results")
    }
    func testPersistsLanguage() {
        LocalizationStore(userDefaults: defaults).language = .german
        XCTAssertEqual(LocalizationStore(userDefaults: defaults).language, .german)
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement L10nKey** — the starter key set (later tasks append). Include the common/error keys and the search-results plural pair used by the test:

```swift
enum L10nKey: String, CaseIterable, Sendable {
    // Common
    case common_done = "common.done"
    case common_cancel = "common.cancel"
    case common_retry = "common.retry"
    case common_untitled = "common.untitled_document"
    // Search results plural
    case search_results_one = "search.results.one"      // "%d result"
    case search_results_other = "search.results.other"  // "%d results"
    // (screen-specific keys are added by B5–B11, Phase C, Phase F)
}
```

Implement `Strings_en`:

```swift
enum Strings_en {
    static let table: [L10nKey: String] = [
        .common_done: "Done",
        .common_cancel: "Cancel",
        .common_retry: "Try again",
        .common_untitled: "Untitled document",
        .search_results_one: "%d result",
        .search_results_other: "%d results",
    ]
}
```

Implement the dispatcher + store (create `Strings_fr`…`Strings_zhHant` in B12; for now the dispatcher returns `Strings_en.table` for languages whose file doesn't exist yet — but to compile the store's `switch`, add empty stub tables in B12; here, temporarily map all non-en to `Strings_en.table`):

```swift
enum Strings {
    static func table(for language: AppLanguage) -> [L10nKey: String] {
        switch language {
        case .english: Strings_en.table
        default: Strings_en.table  // replaced by real tables in Task B12
        }
    }
}

@MainActor
@Observable
final class LocalizationStore {
    var language: AppLanguage { didSet { userDefaults.set(language.code, forKey: Self.key) } }
    private let userDefaults: UserDefaults
    private static let key = "schrift.language"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let code = userDefaults.string(forKey: Self.key),
           let saved = AppLanguage.allCases.first(where: { $0.code == code }) {
            language = saved
        } else {
            language = AppLanguage.bestMatch(preferred: Locale.preferredLanguages)
        }
    }

    subscript(_ key: L10nKey) -> String {
        Strings.table(for: language)[key] ?? Strings_en.table[key] ?? key.rawValue
    }

    func format(_ key: L10nKey, _ args: CVarArg...) -> String {
        String(format: self[key], locale: locale, arguments: args)
    }

    var locale: Locale { language.locale }
}
```

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add L10nKey, English strings, and LocalizationStore"`

### Task B3: Plural rule

**Files:**
- Create: `Schrift/Core/Localization/PluralRule.swift`
- Modify: `Schrift/Core/Localization/LocalizationStore.swift` (add `plural(_:one:other:)`)
- Test: `SchriftTests/Core/Localization/PluralRuleTests.swift`

**Interfaces:**
- Produces: `enum PluralCategory { case one, other }`; `func pluralCategory(_ count: Int, language: AppLanguage) -> PluralCategory`; `LocalizationStore.plural(_ count: Int, one: L10nKey, other: L10nKey) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Schrift

final class PluralRuleTests: XCTestCase {
    func testEnglishOneVsOther() {
        XCTAssertEqual(pluralCategory(1, language: .english), .one)
        XCTAssertEqual(pluralCategory(2, language: .english), .other)
        XCTAssertEqual(pluralCategory(0, language: .english), .other)
    }
    func testChineseAndThaiAreOtherOnly() {
        XCTAssertEqual(pluralCategory(1, language: .chineseSimplified), .other)
        XCTAssertEqual(pluralCategory(1, language: .chineseTraditional), .other)
        XCTAssertEqual(pluralCategory(1, language: .thai), .other)
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement**

```swift
enum PluralCategory { case one, other }

/// CLDR-simplified: zh-Hans/zh-Hant/th have a single form; the rest use one/other.
func pluralCategory(_ count: Int, language: AppLanguage) -> PluralCategory {
    switch language {
    case .chineseSimplified, .chineseTraditional, .thai: return .other
    default: return count == 1 ? .one : .other
    }
}
```

Add to `LocalizationStore`:

```swift
func plural(_ count: Int, one: L10nKey, other: L10nKey) -> String {
    let key = pluralCategory(count, language: language) == .one ? one : other
    return String(format: self[key], locale: locale, arguments: [count])
}
```

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add per-language plural rule"`

### Task B4: Inject LocalizationStore + locale; localize dates

**Files:**
- Modify: `Schrift/App/SchriftApp.swift`, `Schrift/Features/Home/HomeView.swift` (`documentRowDate`)
- Test: manual + existing tests still green.

- [ ] **Step 1:** In `SchriftApp`, add `@State private var localizationStore = LocalizationStore()` and chain onto the root: `.environment(localizationStore).environment(\.locale, localizationStore.locale)` (alongside the appearance injection from A8).
- [ ] **Step 2:** Change the free function `documentRowDate(_ document: Document)` in `HomeView.swift` to `documentRowDate(_ document: Document, locale: Locale)` — set `formatter.locale = locale` on the `RelativeDateTimeFormatter`. Update **every** call site now: `grep -rn "documentRowDate(" Schrift` and pass the caller's `loc.locale` at each (Home, Search, Shared, and any others the grep surfaces — e.g. SharedRow/SubpageRow if present). Screens that don't yet have `loc` add `@Environment(LocalizationStore.self) private var loc` in this step (their full string extraction still happens in B5–B7).
- [ ] **Step 3:** Build. Expected: BUILD SUCCEEDED with no remaining no-arg `documentRowDate` calls.
- [ ] **Step 4: Commit** — `git commit -m "feat: inject LocalizationStore and localize relative dates"`

### Task B5: Localize the Home screen (worked example — the pattern for B6–B11)

**Files:**
- Modify: `Schrift/Features/Home/DocumentListView.swift`
- Modify: `Schrift/Core/Localization/L10nKey.swift` (+keys), `Schrift/Core/Localization/Strings+en.swift` (+English)
- Test: covered by `LocalizationStoreTests` + the completeness test (B12); no per-screen unit test.

**The mechanical pattern (identical for every screen task B5–B11 and Phase C/F screens):**
1. Add `@Environment(LocalizationStore.self) private var loc` to the `View` struct.
2. Add each user-facing literal as an `L10nKey` case (`screen.purpose`) + its English value in `Strings_en.table`.
3. Replace the literal with `loc[.key]` (static) / `loc.format(.key, arg)` (interpolated) / `loc.plural(n, one:.k_one, other:.k_other)` (counted).
4. Pass `loc.locale` to `documentRowDate(_:locale:)`.

- [ ] **Step 1:** Add keys + English:

```swift
// L10nKey
case home_title = "home.title"                 // "Schrift"
case home_search_placeholder = "home.search_placeholder" // "Search %@"
case home_filter_all = "home.filter.all"       // "All"
case home_filter_shared = "home.filter.shared" // "Shared"
case home_filter_pinned = "home.filter.pinned" // "Pinned"
case home_section_pinned = "home.section.pinned" // "Pinned"
case home_section_recent = "home.section.recent" // "Recent"
case home_section_shared = "home.section.shared" // "Shared with me"
case home_results = "home.results"             // "Results"
case home_empty_title = "home.empty.title"     // "No documents yet"
case home_empty_body = "home.empty.body"       // "Documents you create or that are shared with you will appear here."
case home_newdoc = "home.new_document"         // "New doc"
case home_pin = "home.pin"                     // "Pin"
case home_unpin = "home.unpin"                 // "Unpin"
case home_dismiss_error = "home.dismiss_error" // "Dismiss error"
```

(Add matching English entries to `Strings_en.table`.) `HomeFilter.title` currently returns literals — change `HomeFilter` to expose an `L10nKey` (`titleKey`) and resolve in the view, or map in the view. Prefer: add `var titleKey: L10nKey` to `HomeFilter` and the view builds `HomeFilter.allCases.map { loc[$0.titleKey] }`.

- [ ] **Step 2:** Replace every literal in `DocumentListView.swift` per the mapping. Examples: `NavBar(title: loc[.home_title], subtitle: serverHost, …)`; the `NavBarAction` label → `loc[.home_newdoc]`; `SearchField(placeholder: loc.format(.home_search_placeholder, serverHost))`; section titles via `mainSectionTitle` → return keys; `ContentUnavailableView(loc[.home_empty_title], systemImage:…, description: Text(loc[.home_empty_body]))`; the favorite confirmation button → `loc[.home_pin]`/`loc[.home_unpin]`; `documentRowDate(document, locale: loc.locale)`; `.accessibilityLabel(loc[.home_dismiss_error])`. Keep "Results" as `loc[.home_results]`.
- [ ] **Step 3:** Build + run the app once in the Simulator; toggle nothing yet (translations land in B12) — verify English renders unchanged.
- [ ] **Step 4: Commit** — `git commit -m "feat: localize the Home document list"`

### Task B6: Localize the Search screen

Same pattern as B5. **Keys + English** to add: `search_title`="Search", `search_placeholder`="Search all documents", `search_recent`="Recent searches", `search_quick`="Quick access", `search_quick_empty`="Pinned documents will appear here.", `search_empty_title`="No documents found", `search_empty_body`="Nothing matches “%@”. Try another title or keyword.", plus reuse `search_results_one`/`search_results_other`. Replace literals in `SearchScreen.swift`; results count → `loc.plural(count, one: .search_results_one, other: .search_results_other)`; empty body → `loc.format(.search_empty_body, trimmedQuery)`; `documentRowDate(_, locale: loc.locale)`. **Commit:** `feat: localize the Search screen`.

### Task B7: Localize the Shared screen

Same pattern. **Keys + English:** `shared_title`="Shared", `shared_with_me`="Shared with me", `shared_by_me`="Shared by me", `shared_count_one`="%d document", `shared_count_other`="%d documents", `shared_subtitle_with`="Shared · %@", `shared_subtitle_by`="%@ · Shared %@", `shared_footer_with`="Documents other people have invited you to. Your access depends on your role on each one.", `shared_footer_by`="Documents you own or have shared. Manage who can see them from each document’s share sheet.", plus reach labels `reach_restricted`="Restricted", `reach_connected`="Connected", `reach_public`="Public". Replace literals in `SharedScreen.swift`; count header → `loc.plural(...)`; subtitles → `loc.format(...)`; `reachLabel` returns a key. `documentRowDate(_, locale: loc.locale)`. **Commit:** `feat: localize the Shared screen`.

### Task B8: Localize the Connect / login / reauth flow

Same pattern across `Schrift/Features/Connect/{ConnectView,ServerURLInput,WebLoginView,ReauthenticationSheetView}.swift`. Extract every literal (field placeholders, buttons like "Connect"/"Sign in", titles, the recent-servers labels, and the friendly error strings) into `connect.*` / `reauth.*` keys with English values. Note: `ConnectView`/`ReauthenticationViewModel` build **hook-less** clients (per CLAUDE.md) — do not change that; only localize strings. **Commit:** `feat: localize the Connect and reauthentication flow`.

### Task B9: Localize the Editor chrome

Same pattern across `Schrift/Features/Editor/{EditorScreen,EditorView,EditorSaveBar,SlashMenu,SlashMenuView,EditorFormattingBar,LinkEditorSheet}.swift`. Keys `editor.*`: save-bar states ("Edited just now", "Saving…", "Couldn't save · tap to retry", etc.), slash-menu item titles (Text, Heading, Bullet, Photo, Divider, …), formatting-bar accessibility labels, link-editor labels/placeholders ("Add link", "Text", "URL", "Save", "Remove"), the uploading-photo banner, and the "Empty document"/"no longer available" reading-surface strings. Keep the save-state **logic** unchanged — only the display strings move to keys. **Commit:** `feat: localize the editor chrome`.

### Task B10: Localize the Options and Share sheets

Same pattern across `Schrift/Features/Options/OptionsSheetView.swift` and `Schrift/Features/Share/ShareSheetView.swift`. Keys `options.*` (Pin/Unpin, Pinned, Copy link, Share, Copy as Markdown, Duplicate, Delete document, "Delete this document?", Options, Done) and `share.*` (Share, "Invite by name or email", "Shared with %d person"/"%d people" plural, "Add people", "No people found", "Link parameters", "Change link access", link-reach option labels, "Copy link", role names). Replace literals; the members-count → `loc.plural(...)`. `shareRoleDisplayTitle`/`reach` labels resolve keys. **Commit:** `feat: localize the Options and Share sheets`.

### Task B11: Localize common chrome (OfflineBanner, errors, misc)

Same pattern for `Schrift/DesignSystem/Components/OfflineBanner.swift` (the "Offline" + "All documents saved on this device" strings) and any remaining literals surfaced by a repo-wide search (Step 1 below). Keys `common.*` / `offline.*`.

- [ ] **Step 1:** Find stragglers: `grep -rnE '"[A-Z][a-z].*"' Schrift/Features Schrift/DesignSystem | grep -viE 'systemImage|systemName|forKey:|identifier|rawValue|CodingKeys|accessibilityIdentifier|#Preview|Preview\(|case \.|"/|https?://|api/v1'` — triage each hit: user-facing → key it; identifier/URL/log → leave.
- [ ] **Step 2:** Key + replace the survivors.
- [ ] **Step 3: Commit** — `git commit -m "feat: localize offline banner and remaining chrome strings"`

### Task B12: Generate the 10 translations + completeness/parity tests

**Files:**
- Create: `Schrift/Core/Localization/Strings+fr.swift` … `Strings+zhHant.swift` (9 non-English tables)
- Modify: `Schrift/Core/Localization/LocalizationStore.swift` (`Strings.table(for:)` returns the real tables)
- Test: `SchriftTests/Core/Localization/StringsCompletenessTests.swift`

**Interfaces:**
- Produces: `Strings_fr` … `Strings_zhHant`, each `static let table: [L10nKey: String]` covering **all** `L10nKey.allCases`.

- [ ] **Step 1: Write the failing completeness + parity test**

```swift
import Foundation
import XCTest
@testable import Schrift

final class StringsCompletenessTests: XCTestCase {
    /// Count of `%@` / `%d` / `%lld` placeholders (ignoring escaped `%%`).
    private func placeholderCount(_ s: String) -> Int {
        var count = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%" {
                let next = s.index(after: i)
                guard next < s.endIndex else { break }
                if s[next] == "%" { i = s.index(after: next); continue } // escaped %%
                count += 1
            }
            i = s.index(after: i)
        }
        return count
    }

    func testEveryLanguageHasEveryKey() {
        for language in AppLanguage.allCases {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases {
                XCTAssertNotNil(table[key], "\(language.code) missing \(key.rawValue)")
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(language.code) empty \(key.rawValue)")
            }
        }
    }

    func testFormatSpecifierParityWithEnglish() {
        // Same placeholder count per key across languages, so String(format:)
        // can't crash on a mismatched arg list.
        let en = Strings_en.table
        for language in AppLanguage.allCases where language != .english {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases {
                XCTAssertEqual(placeholderCount(table[key] ?? ""), placeholderCount(en[key] ?? ""),
                               "\(language.code) placeholder mismatch on \(key.rawValue)")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails** (tables don't exist / `Strings.table(for:)` maps everything to English so non-English are "complete" but wrong — the test still passes structurally; the *real* gate is that each table exists and is wired). Adjust: the test fails to compile until `Strings_fr`… exist and `Strings.table(for:)` references them.
- [ ] **Step 3: Generate translations with a workflow.** Freeze the English table (`Strings_en` + `L10nKey`) as the source. Run a translation workflow — **one translator agent + one QA agent per language** (9 languages) — each producing a `[L10nKey: String]` Swift dictionary literal that (a) covers every key, (b) preserves `%@`/`%d` placeholders and their order, (c) keeps the glossary fixed (Schrift, document/doc, server, Pinned, Shared, Sign out), (d) uses sentence case and no exclamation marks (house voice). Write each result to `Strings+<code>.swift` as `enum Strings_<code> { static let table: [L10nKey: String] = [ … ] }`. **Mark non-en/fr files** with a top comment: `// AI-generated translation — pending native-speaker review.`
- [ ] **Step 4:** Wire `Strings.table(for:)` to the real tables:

```swift
static func table(for language: AppLanguage) -> [L10nKey: String] {
    switch language {
    case .english: Strings_en.table
    case .french: Strings_fr.table
    case .spanish: Strings_es.table
    case .german: Strings_de.table
    case .italian: Strings_it.table
    case .dutch: Strings_nl.table
    case .portuguese: Strings_pt.table
    case .thai: Strings_th.table
    case .chineseSimplified: Strings_zhHans.table
    case .chineseTraditional: Strings_zhHant.table
    }
}
```

- [ ] **Step 5: Run to verify the completeness + parity tests pass.** Fix any missing/empty/placeholder-mismatched entries the test reports.
- [ ] **Step 6: Commit** — `git commit -m "feat: add translations for all 10 languages"` (one commit; large but purely additive data).

---

## Phase C — Profile restructure + pickers

### Task C1: Delete the Account screen + its route

**Files:**
- Delete: `Schrift/Features/Profile/AccountScreen.swift`
- Modify: `Schrift/Features/Home/HomeView.swift`, `Schrift/Features/Profile/ProfileScreen.swift`
- Test: build (no unit test); confirm no dangling references.

- [ ] **Step 1:** `git rm Schrift/Features/Profile/AccountScreen.swift`.
- [ ] **Step 2:** In `HomeView.swift`: delete the `HomeRoute` enum (its only case is `.account`), delete the `.navigationDestination(for: HomeRoute.self) { … }` block, and delete the `onOpenAccount:` argument from the `ProfileScreen(…)` call. `profileViewModel` stays (Profile still uses it for the email).
- [ ] **Step 3:** In `ProfileScreen.swift`: remove the `var onOpenAccount: () -> Void` property, the `accountBanner` view, and its use in `body`.
- [ ] **Step 4:** `grep -rn "AccountScreen\|HomeRoute\|onOpenAccount" Schrift SchriftTests` → expect **no matches**. Build. Expected: BUILD SUCCEEDED.
- [ ] **Step 5: Commit** — `git commit -m "refactor: remove the Account detail screen per the new design"`

### Task C2: Restructure the Profile screen (User / About) + localize

**Files:**
- Modify: `Schrift/Features/Profile/ProfileScreen.swift`, `Schrift/Features/Profile/ProfileViewModel.swift` (email only; server config in D2)
- Modify: `Schrift/Core/Localization/L10nKey.swift` + `Strings+en.swift` (+`profile.*` keys)
- Test: manual + completeness test (B12 re-runs after Phase G translation top-up — see note).

**Keys + English:** `profile_title`="Profile", `profile_user`="User", `profile_prefs`="Preferences", `profile_prefs_footer`="When on, documents you've opened stay readable on this device without a connection.", `profile_appearance`="Appearance", `profile_language`="Language", `profile_notifications`="Notifications", `profile_work_offline`="Work offline", `profile_server`="Server", `profile_server_footer`="The app connects to any Schrift server using your existing web session.", `profile_connected`="Connected", `profile_offline`="Offline", `profile_server_version`="Server version", `profile_about`="About", `profile_version`="Version", `profile_sign_out`="Sign out", `profile_disconnect_title`="Disconnect from %@?", `profile_disconnect`="Disconnect", `profile_disconnect_body`="You'll need to sign in again to reconnect.", plus appearance labels `appearance_system`="System", `appearance_light`="Light", `appearance_dark`="Dark".

- [ ] **Step 1:** Add the keys + English.
- [ ] **Step 2:** Rewrite `ProfileScreen.body` to the final structure (§6): USER `ListSection(header: loc[.profile_user])` with a single static `ListRow(systemImage: "person.circle", title: viewModel.user?.email ?? "—")` (no chevron, no action); PREFERENCES with Appearance/Language rows (open pickers — wired in C3/C4), Notifications + Work offline switches; SERVER with the server row (badge + disconnect) — Server-version row added in D2; ABOUT `ListSection(header: loc[.profile_about])` with `ListRow(title: loc[.profile_version], value: appVersion)`; Sign out. **Remove** the entire Support section. Localize every string via `loc`. Add `@Environment(LocalizationStore.self) private var loc` and `@Environment(AppearanceStore.self) private var appearance`.
- [ ] **Step 3:** The Appearance row shows the current appearance label + `moon` icon: `ListRow(systemImage: "moon", title: loc[.profile_appearance], value: loc[appearanceValueKey(appearance.selected)], showsChevron: true, action: { showAppearanceSheet = true })` where `appearanceValueKey` maps `.system/.light/.dark` → `.appearance_system/_light/_dark`. The Language row: `value: loc.language.autonym` (read the localization store: `@Environment(LocalizationStore.self)`), action opens the language sheet.
- [ ] **Step 4:** Build + run; verify the Profile matches the screenshot (email row, no banner, no Support, About→Version). Dividers removed in E2.
- [ ] **Step 5: Commit** — `git commit -m "feat: restructure Profile to the new design and localize it"`

### Task C3: Appearance picker sheet

**Files:**
- Create: `Schrift/Features/Profile/AppearancePickerSheet.swift`
- Modify: `Schrift/Features/Profile/ProfileScreen.swift` (present it)
- Test: `SchriftTests/Features/Profile/AppearancePickerTests.swift` (pure option model)

**Interfaces:**
- Produces: `struct AppearancePickerSheet: View` reading `@Environment(AppearanceStore.self)` and `@Environment(LocalizationStore.self)`, dismissing on selection; a pure `appearanceOptions() -> [AppAppearance]` (== `AppAppearance.allCases` ordered light, dark, system).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Schrift

final class AppearancePickerTests: XCTestCase {
    func testOptionsOrderAndIcons() {
        XCTAssertEqual(appearanceOptions(), [.light, .dark, .system])
        XCTAssertEqual(AppAppearance.light.iconName, "sun.max")
        XCTAssertEqual(AppAppearance.dark.iconName, "moon")
        XCTAssertEqual(AppAppearance.system.iconName, "circle.lefthalf.filled")
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `appearanceOptions()` + the sheet: a `NavigationStack`/`VStack` with a title (`loc[.profile_appearance]`) and one `ListRow` per option (`systemImage: opt.iconName`, `title: loc[appearanceValueKey(opt)]`, trailing checkmark when `opt == store.selected`), tapping sets `store.selected = opt` then `dismiss()`. Match the design's option-row look (leading icon + title + brand checkmark).
- [ ] **Step 4:** In `ProfileScreen`, add `@State private var showAppearanceSheet = false` and `.sheet(isPresented: $showAppearanceSheet) { AppearancePickerSheet().presentationDetents([.height(280)]).presentationDragIndicator(.visible) }`.
- [ ] **Step 5: Run test; build; run app — toggle Light/Dark/System and confirm the whole app re-themes.**
- [ ] **Step 6: Commit** — `git commit -m "feat: add the appearance picker sheet"`

### Task C4: Language picker sheet

**Files:**
- Create: `Schrift/Features/Profile/LanguagePickerSheet.swift`
- Modify: `Schrift/Features/Profile/ProfileScreen.swift`
- Test: covered by `AppLanguageTests` (options == `allCases`); no new unit test.

- [ ] **Step 1:** Implement the sheet: title `loc[.profile_language]`, one `ListRow` per `AppLanguage.allCases` (`title: lang.autonym`, trailing checkmark when `lang == loc.language`), tapping sets `loc.language = lang` then `dismiss()`. Reads `@Environment(LocalizationStore.self)`.
- [ ] **Step 2:** Present from `ProfileScreen`: `@State private var showLanguageSheet = false` + `.sheet(isPresented: $showLanguageSheet) { LanguagePickerSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }`.
- [ ] **Step 3:** Build + run; switch to ไทย / 简体中文 and confirm the whole UI switches live (once B12 translations exist).
- [ ] **Step 4: Commit** — `git commit -m "feat: add the language picker sheet"`

---

## Phase D — Server config row

### Task D1: ServerConfig endpoint

**Files:**
- Create: `Schrift/Core/Networking/ServerConfigEndpoints.swift`
- Test: `SchriftTests/Core/Networking/ServerConfigClientTests.swift`

**Interfaces:**
- Produces: `struct ServerConfig: Codable, Equatable, Sendable { var version: String? }`; `func DocsAPIClient.serverConfig() async throws -> ServerConfig`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Schrift

final class ServerConfigClientTests: XCTestCase {
    override func tearDown() { MockURLProtocol.reset() }

    func testFetchesConfigVersion() async throws {
        MockURLProtocol.stubHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/api/v1.0/config/"))
            return Stub(json: #"{"RELEASE_VERSION":"5.4.1"}"#)
        }
        let client = DocsAPIClient(baseURL: URL(string: "https://x.example/api/v1.0/")!, session: makeSession())
        let config = try await client.serverConfig()
        XCTAssertEqual(config.version, "5.4.1")
    }
    func testMissingVersionTolerated() async throws {
        MockURLProtocol.stubHandler = { _ in Stub(json: "{}") }
        let client = DocsAPIClient(baseURL: URL(string: "https://x.example/api/v1.0/")!, session: makeSession())
        XCTAssertNil(try await client.serverConfig().version)
    }
}
```

(Match the exact `MockURLProtocol`/`Stub`/`makeSession` API used by the existing `…ClientTests` — read `ShareEndpoints`' test for the current shape before writing.)

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Public server config (`GET /api/v1.0/config/`). The Docs backend returns
/// `RELEASE_VERSION`; `JSONDecoder.docsAPI`'s `.convertFromSnakeCase` rewrites
/// that JSON key to `releaseVersion` *before* matching, so the property is named
/// to match the converted key (no custom CodingKeys). Optional ⇒ synthesized
/// `decodeIfPresent`, so a config without the key decodes to nil.
struct ServerConfig: Codable, Equatable, Sendable {
    let releaseVersion: String?

    /// Convenience alias for the Profile row.
    var version: String? { releaseVersion }

    init(releaseVersion: String? = nil) { self.releaseVersion = releaseVersion }
}

extension DocsAPIClient {
    /// Best-effort; the Profile hides the server-version row when unavailable.
    func serverConfig() async throws -> ServerConfig {
        try await get("config/")
    }
}
```

Note: this relies on `.convertFromSnakeCase` mapping `RELEASE_VERSION` → `releaseVersion` (Foundation lowercases the first component and capitalizes the rest: `["RELEASE","VERSION"]` → `"release"+"Version"`). **Verify the real key on-device** in Phase F's verification pass; if the server key differs, rename the property (still no CodingKeys) or add an explicit `init(from:)` reading the actual converted key.

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add the server config endpoint"`

### Task D2: Server-version row in Profile

**Files:**
- Modify: `Schrift/Features/Profile/ProfileViewModel.swift`, `Schrift/Features/Profile/ProfileScreen.swift`
- Test: `SchriftTests/Features/Profile/ProfileViewModelTests.swift` (create/extend)

**Interfaces:**
- Consumes: `DocsAPIClient.serverConfig()`.
- Produces: `ProfileViewModel.serverVersion: String?`.

- [ ] **Step 1: Write the failing test** — VM loads config best-effort, sets `serverVersion`, tolerates failure (nil):

```swift
@MainActor
final class ProfileViewModelTests: XCTestCase {
    override func tearDown() { MockURLProtocol.reset() }
    func testLoadsServerVersion() async {
        MockURLProtocol.stubHandler = { request in
            if request.url!.absoluteString.contains("/config/") { return Stub(json: #"{"RELEASE_VERSION":"5.4.1"}"#) }
            return Stub(json: #"{"id":"11111111-1111-1111-1111-111111111111","email":"a@b.c"}"#)
        }
        let client = DocsAPIClient(baseURL: URL(string: "https://x.example/api/v1.0/")!, session: makeSession())
        let vm = ProfileViewModel(client: client)
        await vm.load()
        await waitUntil { vm.serverVersion == "5.4.1" }
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** — add `var serverVersion: String?` to `ProfileViewModel`; in `load()`, alongside `currentUser()`, fetch config best-effort: `serverVersion = try? await client.serverConfig().version` (use `async let` for the two fetches). In `ProfileScreen`, in the SERVER section, conditionally render `if let v = viewModel.serverVersion { ListRow(systemImage: "shippingbox", title: loc[.profile_server_version], value: v) }`.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: show the server version in Profile"`

---

## Phase E — Layout fidelity

### Task E1: NavBar large-title collapse + inline trailing + borderless tabs

**Files:**
- Modify: `Schrift/DesignSystem/Components/NavBar.swift`
- Modify: `Schrift/Features/Home/DocumentListView.swift`, `Search/SearchScreen.swift`, `Shared/SharedScreen.swift`, `Profile/ProfileScreen.swift` (pass `showsBorder: false`)
- Test: `SchriftTests/DesignSystem/Components/NavBarLayoutTests.swift`

**Interfaces:**
- Produces: `func navBarShowsTopRow(largeTitle: Bool, hasBack: Bool, hasLeading: Bool) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Schrift

final class NavBarLayoutTests: XCTestCase {
    func testLargeTitleWithoutBackCollapsesTopRow() {
        XCTAssertFalse(navBarShowsTopRow(largeTitle: true, hasBack: false, hasLeading: false))
        XCTAssertTrue(navBarShowsTopRow(largeTitle: true, hasBack: true, hasLeading: false))
        XCTAssertTrue(navBarShowsTopRow(largeTitle: false, hasBack: false, hasLeading: false))
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** — add the helper; in `NavBar.body`, only render the 44pt top `HStack` when `navBarShowsTopRow(largeTitle:hasBack:hasLeading:)` is true (`hasBack = backTitle != nil && onBack != nil`, `hasLeading = false` today). In large-title mode, render `trailingActions` **inside** the large-title row: put the title + a trailing `HStack(spacing: DocsSpacing.space4xs)` of `IconButton`s in an `HStack(spacing: DocsSpacing.spaceSM)`, title `.frame(maxWidth: .infinity, alignment: .leading)`. Move the trailing-actions rendering out of the top row for large-title mode (keep it in the top row for standard mode). Keep the solid-white fill and the on-scroll-border behavior via `showsBorder`.
- [ ] **Step 4:** Pass `showsBorder: false` from all four tab screens' `NavBar(...)` calls.
- [ ] **Step 5: Run the test; build; run — verify Search/Shared/Profile have no dead space above the title and Home's "+" sits beside "Schrift".**
- [ ] **Step 6: Commit** — `git commit -m "fix: collapse the large-title nav bar and inline its trailing actions"`

### Task E2: Remove inter-row dividers on Shared and Profile

**Files:**
- Modify: `Schrift/Features/Shared/SharedScreen.swift`, `Schrift/Features/Profile/ProfileScreen.swift`
- Test: manual (visual).

- [ ] **Step 1:** In `SharedScreen`, delete the `if index > 0 { ProfileRowDivider() }` inside the shared `ForEach` (flat rows, matching `divided={false}`).
- [ ] **Step 2:** In `ProfileScreen`, delete every `ProfileRowDivider()` in the Preferences and Server sections (single-row sections had none).
- [ ] **Step 3:** Build + run; confirm Shared and Profile rows have no hairlines. (`ProfileRowDivider` stays for the Options / Share "Add people" menus — do not delete the component.)
- [ ] **Step 4: Commit** — `git commit -m "fix: drop inter-row dividers on Shared and Profile to match the design"`

### Task E3: Sheet detents + drag indicator + bounded members list

**Files:**
- Modify: `Schrift/Features/Editor/EditorView.swift` (Share/Options `.sheet` modifiers), `Schrift/Features/Share/ShareSheetView.swift`
- Test: `SchriftTests/Features/Share/ShareSheetLayoutTests.swift` (constant for the members `maxHeight`)

- [ ] **Step 1:** In `EditorView`, add to the Share sheet: `.presentationDetents([.large])` + `.presentationDragIndicator(.visible)`; to the Options sheet: `.presentationDetents([.medium, .large])` + `.presentationDragIndicator(.visible)`. (Version-history sheet gets the same in Task F3.)
- [ ] **Step 2:** In `ShareSheetView`, bound the members list so **Copy link stays reachable**: wrap `membersSection`'s `ForEach` in a `ScrollView { … }.frame(maxHeight: ShareSheetLayout.membersMaxHeight)` where `enum ShareSheetLayout { static let membersMaxHeight: CGFloat = 208 }`, keeping the invite field pinned above and the link section + copy-link button below the bounded region (outside the inner scroll). Write a trivial test asserting `ShareSheetLayout.membersMaxHeight == 208`.
- [ ] **Step 3:** Build + run; open Share with many members — confirm the list scrolls internally while Copy link remains visible.
- [ ] **Step 4: Commit** — `git commit -m "fix: present sheets as detents and bound the Share members list"`

---

## Phase F — Version history

### Task F1: Versions list endpoint + model

**Files:**
- Create: `Schrift/Core/Networking/VersionEndpoints.swift`
- Test: `SchriftTests/Core/Networking/VersionEndpointsClientTests.swift`

**Interfaces:**
- Produces: `struct DocumentVersion: Codable, Equatable, Sendable, Identifiable { let id: String; let lastModified: Date; var isCurrent: Bool }`; `func DocsAPIClient.documentVersions(documentID: UUID) async throws -> [DocumentVersion]`.

- [ ] **Step 1: Write the failing test** — GET path + decode a `{ "versions": [...] }` wrapper (confirm the exact wrapper shape on-device in Task F4's verification; keep the model tolerant):

```swift
final class VersionEndpointsClientTests: XCTestCase {
    override func tearDown() { MockURLProtocol.reset() }
    func testListsVersions() async throws {
        MockURLProtocol.stubHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/documents/11111111-1111-1111-1111-111111111111/versions/"))
            return Stub(json: #"{"versions":[{"version_id":"v1","last_modified":"2026-07-11T15:04:00Z","is_current":true},{"version_id":"v2","last_modified":"2026-07-11T14:32:00Z"}]}"#)
        }
        let client = DocsAPIClient(baseURL: URL(string: "https://x.example/api/v1.0/")!, session: makeSession())
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let versions = try await client.documentVersions(documentID: id)
        XCTAssertEqual(versions.count, 2)
        XCTAssertTrue(versions[0].isCurrent)
        XCTAssertFalse(versions[1].isCurrent)
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement**

`JSONDecoder.docsAPI` converts snake_case → camelCase, so the JSON keys
`version_id` / `last_modified` / `is_current` arrive as `versionId` /
`lastModified` / `isCurrent`. Mirror the `Document` pattern: memberwise init in
the struct, an explicit `init(from:)` in an extension reading the converted keys
(`isCurrent` defensively defaulted).

```swift
import Foundation

struct DocumentVersion: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let lastModified: Date
    var isCurrent: Bool

    init(id: String, lastModified: Date, isCurrent: Bool) {
        self.id = id
        self.lastModified = lastModified
        self.isCurrent = isCurrent
    }
}

// In an extension so the memberwise initializer above survives (see Document.swift).
extension DocumentVersion {
    private enum Keys: String, CodingKey { case versionId, lastModified, isCurrent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .versionId)
        lastModified = try c.decode(Date.self, forKey: .lastModified)
        isCurrent = try c.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
    }
}

private struct DocumentVersionsResponse: Decodable { let versions: [DocumentVersion] }

extension DocsAPIClient {
    func documentVersions(documentID: UUID) async throws -> [DocumentVersion] {
        let response: DocumentVersionsResponse =
            try await get("documents/\(documentID.uuidString.lowercased())/versions/")
        return response.versions
    }
}
```

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add the document versions list endpoint"`

### Task F2: VersionHistoryViewModel

**Files:**
- Create: `Schrift/Features/Editor/VersionHistoryViewModel.swift`
- Modify: `Schrift/Core/Localization/L10nKey.swift` + `Strings+en.swift` (+`versions.*` keys)
- Test: `SchriftTests/Features/Editor/VersionHistoryViewModelTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class VersionHistoryViewModel` with `var versions: [DocumentVersion]`, `var isLoading: Bool`, `var errorKey: L10nKey?`, `func load() async`.

**Keys + English (added here; F3 reuses them):** `versions_title`="Version history", `versions_current`="Current version", `versions_restore`="Restore", `versions_error`="Couldn't load versions. Please try again.", `versions_empty`="No earlier versions yet.".

- [ ] **Step 0:** Add the `versions.*` keys + English above to `L10nKey` and `Strings_en.table`.
- [ ] **Step 1: Write the failing test** — load success populates `versions` and leaves `errorKey` nil; a failing request sets `errorKey == .versions_error` and leaves `versions` empty. (Mirror an existing VM test's `MockURLProtocol` setup.)
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** — VM holds `client`, `documentID`; `load()` sets `isLoading = true`, `errorKey = nil`, calls `documentVersions`, and in a `catch` sets `errorKey = .versions_error` (the localized-VM-error convention above). The view renders `errorKey.map { loc[$0] }`. `isLoading` reset with `defer`.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add the version history view model"`

### Task F3: Version history sheet + Options row

**Files:**
- Create: `Schrift/Features/Editor/VersionHistorySheetView.swift`
- Modify: `Schrift/Features/Options/OptionsSheetView.swift` (add the row + presentation)
- Test: manual (UI).

The `versions.*` keys were added in F2.

- [ ] **Step 1:** Implement `VersionHistorySheetView`: title `loc[.versions_title]`; a scroll-bounded list (`ScrollView { … }.frame(maxHeight: 340)`) of rows — timestamp (localized via `loc.locale`, absolute/relative to match the design's `when`), the newest (`isCurrent`) shows `loc[.versions_current]` in `DocsColor.success`, older rows show a `Restore` pill (`brandFillSoft` bg / `textBrand`). In this task the pill is **non-interactive** (no action) — F4 wires it to `viewModel.restore(_:)`. Load on `.task`.
- [ ] **Step 2:** In `OptionsSheetView`, add a `ListRow(systemImage: "clock.arrow.circlepath", title: loc[.versions_title], showsChevron: true, action: { showVersions = true })` in the appropriate section, and present `.sheet(isPresented: $showVersions) { VersionHistorySheetView(viewModel: …).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }`. Build the VM in the sheet's owner (`EditorView` or `OptionsSheetView`) following the "VM built once, stored in `@State`" rule.
- [ ] **Step 3:** Build + run; open Options → Version history; confirm the list renders.
- [ ] **Step 4: Commit** — `git commit -m "feat: add the version history sheet and Options entry"`

### Task F4: Restore (verify-gated)

**Files:**
- Modify: `Schrift/Core/Networking/VersionEndpoints.swift` (+`restoreDocumentVersion`), `Schrift/Features/Editor/VersionHistoryViewModel.swift` (+`restore`), `Schrift/Features/Editor/VersionHistorySheetView.swift` (wire the pill), and the editor reload path.
- Test: `SchriftTests/Core/Networking/VersionEndpointsClientTests.swift` (restore sequence), `VersionHistoryViewModelTests.swift` (blocked while dirty).

**Interfaces:**
- Produces: `func DocsAPIClient.restoreDocumentVersion(documentID: UUID, versionID: String) async throws` (fetch version content → PATCH content).

- [ ] **Step 0 — ON-DEVICE VERIFICATION (gate):** Before writing restore, confirm on `docs.llun.dev` (real device or Simulator past the HTTP/3 stall) the exact shapes of `GET documents/{id}/versions/` and `GET documents/{id}/versions/{version_id}/`. Capture: does the retrieve return usable content bytes the app can re-PATCH as `documents/{id}/content/`? If **no** (e.g. it 404s, or returns only a URL, or a format the content PATCH rejects), **stop**: ship the read-only sheet (remove the Restore pill; add a subtle "Restore is available on the web" affordance opening `https://<host>/docs/<id>/versions/` via `UIApplication.open`) and commit that instead — the list still ships. Record the finding in the spec (dated amendment) and the plan. Only proceed to Steps 1–5 if verification passes.
- [ ] **Step 1: Write the failing test** — `restoreDocumentVersion` performs `GET versions/{id}/` then `PATCH documents/{id}/content/` with the fetched bytes; pin the order with `RequestRecorder`. And a VM test: `restore` is a no-op / disabled when a save is in flight or the editor is dirty (guarded via the coordinator).
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `restoreDocumentVersion`: `getRawData("documents/{id}/versions/{versionID}/")` (or the JSON `{content}` shape found in Step 0) → `sendVoid(.patch, "documents/{id}/content/", body: ContentPatch(content: bytes))` reusing the existing content-PATCH request type used by the save path (find it in the save code). In the VM, `restore(_ version:)` funnels through the coordinator: require no unsaved edits (`saveCoordinator`/editor `isDirty == false`); call `restoreDocumentVersion`; on success trigger the editor's existing `refresh()` so content re-renders from `formatted-content/` and the cache revalidates. Wire the sheet's Restore pill to `viewModel.restore(version)`; reload the list after.
- [ ] **Step 4: Run tests; then verify restore end-to-end on-device** (create a doc, edit, restore an earlier version, confirm content reverts and a new current version appears).
- [ ] **Step 5: Commit** — `git commit -m "feat: restore a document version through the save coordinator"` (or, if the gate failed: `feat: ship read-only version history with web restore`).

---

## Phase G — Wrap-up

### Task G1: project.yml localizations + regenerate

**Files:**
- Modify: `project.yml`
- Test: build.

- [ ] **Step 1:** Add the supported languages so the OS advertises them. In `project.yml`, set the target's Info.plist keys: `INFOPLIST_KEY_CFBundleDevelopmentRegion: en` and add `CFBundleLocalizations` (array of `en, fr, es, de, it, nl, pt, th, zh-Hans, zh-Hant`). If `INFOPLIST_KEY_*` cannot express an array cleanly, add a minimal `knownRegions`/`settings` entry per XcodeGen docs. Keep `GENERATE_INFOPLIST_FILE: true` — do not add an Info.plist file.
- [ ] **Step 2:** `xcodegen generate` → build. Expected: BUILD SUCCEEDED, and Settings → the app shows a Language option listing the 10 languages.
- [ ] **Step 3: Commit** — `git commit -m "chore: advertise supported localizations in project.yml"`

### Task G2: Docs update

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/superpowers/specs/2026-06-30-docs-ios-design.md`
- Test: none.

- [ ] **Step 1: `CLAUDE.md`** — add the new conventions (adaptive tokens `DocsColorHexDark` + `Color(lightHex:darkHex:)`; resolver light+dark contract; `AppearanceStore`/`LocalizationStore` env injection + the "language is a local app preference, content never translated" rule; the in-code catalog + completeness/parity tests; the layout rules — large-title collapse + inline trailing, dividerless tab sections, sheet detents + bounded Share list; version-history restore via re-PATCH through the coordinator).
- [ ] **Step 2: `README.md`** — mention dark mode + 10-language support.
- [ ] **Step 3: living spec** `2026-06-30-docs-ios-design.md` — add a dated `Revised:` note pointing at dark mode + localization + version history.
- [ ] **Step 4: Commit** — `git commit -m "docs: document dark mode, localization, and layout conventions"`

### Task G3: Format, full suite, PR + review loop

- [ ] **Step 1:** `swift format --recursive --in-place Schrift SchriftTests`; commit any diff as `style: swift-format`.
- [ ] **Step 2:** `xcodegen generate` then the **full** suite: `xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'`. All green. (Beware concurrent-worktree simulator interference — if a run is killed with `signal kill`, it's the environment, not the code; re-run on a dedicated device per CLAUDE.md.)
- [ ] **Step 3:** Push the branch and open the PR. **PR title (Conventional Commit, drives the release bump):** `feat: dark mode, in-app localization, version history, and design-system refresh`. PR body: summarize the 6 parts, link the spec, and **flag** that non-en/fr translations are AI-generated pending native review, and whether restore shipped or is read-only (per F4 Step 0).
- [ ] **Step 4:** Run the required **PR review loop** (CLAUDE.md): sub-agent review of the full diff (correctness, conventions, safety, test coverage), post findings as PR comments, address + reply + resolve each, re-request bots, repeat until a clean round + `Build & Test` green. Do not mark done while the check is red/pending.

---

## Notes on PR size

This is a large change. Default: **one PR with the many small commits above** (your stated preference). If review becomes unwieldy, the phases are independent enough to split into a stacked sequence — **A (dark) → B (localization) → C (profile) → D/E (config+layout) → F (version history)** — each its own PR off the previous. Decide at Task G3.

