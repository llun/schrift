# Forms Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the three remaining "forms" DesignSystem components — SearchField, SegmentedControl, DocsTextField (`Switch` was already built in an earlier plan) — and extend the component catalog to include them.

**Architecture:** Continues the established pattern. `SearchField` has no branching logic worth isolating (mirrors `Switch`'s precedent — no resolver, no test file). `SegmentedControl` has a genuinely new shape of pure logic: a layout-fraction calculation (segment width + thumb offset, as fractions of the control's total width) that's independent of screen size and testable without rendering anything. `DocsTextField` (named to avoid shadowing `SwiftUI.TextField`, same reasoning as `DocsButton`) introduces a *different* resolver shape than Button/IconButton's — a single `TextFieldState` enum (not two orthogonal enums) mapping to a 2-field `TextFieldStyleHex` (not the 3-field `backgroundHex?/foregroundHex/borderHex?` shape) — so this does NOT trigger the "4th component needs the identical 3-field shape" consolidation decision flagged in the prior plan's final review; it's simply a different shape driven by different requirements.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- Component naming: the text-field view is named `DocsTextField`, not `TextField` — `TextField` would shadow `SwiftUI.TextField`, which this view uses internally to build itself (same reasoning as `DocsButton` from an earlier plan). `SearchField` and `SegmentedControl` do not collide with any SwiftUI type and keep their plain names.

## File Structure

```
DocsIOS/
└── DesignSystem/
    └── Components/
        ├── SearchField.swift                              — SearchField view, no resolver, no test file (Task 1)
        ├── SegmentedControl.swift                           — SegmentedControlLayout, segmentedControlLayout(segmentCount:selectedIndex:), SegmentedControl view (Task 2)
        └── TextField.swift                                   — TextFieldState, TextFieldStyleHex, TextFieldStyleResolver, DocsTextField view (Task 3)

DocsIOS/DesignSystemCatalog/
└── ComponentCatalogPreview.swift                            — MODIFY: add Search Field/Segmented Control/Text Field sections + 3 new @State vars (Task 4)

DocsIOSTests/
└── DesignSystem/
    └── Components/
        ├── SegmentedControlTests.swift                       — Task 2
        └── TextFieldStyleResolverTests.swift                  — Task 3
```

---

### Task 1: SearchField component

`SearchField` is a pill search input with no variant/color branching — its only conditional is "show the clear button when text is non-empty," which is trivial SwiftUI binding-driven UI with nothing worth unit-testing in isolation (mirrors the `Switch` precedent from an earlier plan: a component with no testable logic gets no placeholder test). Verification is build success plus the Preview compiling.

**Files:**
- Create: `DocsIOS/DesignSystem/Components/SearchField.swift`

**Interfaces:**
- Consumes: `DocsColor.textTertiary`, `DocsColor.surfaceSunken`, `DocsFont.body`, `DocsSpacing.spaceXS/space2xs/spaceSM`.
- Produces: `struct SearchField: View { @Binding var text: String; var placeholder: String = "Search" }` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the component**

`DocsIOS/DesignSystem/Components/SearchField.swift`:
```swift
import SwiftUI

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"

    var body: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DocsColor.textTertiary)
            TextField(placeholder, text: $text)
                .font(DocsFont.body)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.space2xs)
        .background(DocsColor.surfaceSunken)
        .clipShape(Capsule())
    }
}

#Preview {
    @Previewable @State var text = ""
    SearchField(text: $text)
        .padding()
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add DocsIOS/DesignSystem/Components/SearchField.swift
git commit -m "Add SearchField component"
```

---

### Task 2: SegmentedControl component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/SegmentedControl.swift`
- Test: `DocsIOSTests/DesignSystem/Components/SegmentedControlTests.swift`

**Interfaces:**
- Consumes: `DocsColor.surfaceMuted`, `DocsColor.surfacePage`, `DocsColor.textPrimary`, `DocsColor.textSecondary`, `DocsFont.subhead`, `DocsRadius.sm`, `DocsSpacing.rowMinHeight`.
- Produces: `struct SegmentedControlLayout: Equatable { segmentFraction: Double, thumbOffsetFraction: Double }`, `func segmentedControlLayout(segmentCount: Int, selectedIndex: Int) -> SegmentedControlLayout`, `struct SegmentedControl: View { let segments: [String]; @Binding var selectedIndex: Int }` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/SegmentedControlTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class SegmentedControlTests: XCTestCase {
    func testFirstOfThreeSegmentsHasZeroOffset() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: 0)
        XCTAssertEqual(layout.segmentFraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(layout.thumbOffsetFraction, 0.0, accuracy: 0.0001)
    }

    func testMiddleOfThreeSegments() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: 1)
        XCTAssertEqual(layout.thumbOffsetFraction, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testLastOfFourSegments() {
        let layout = segmentedControlLayout(segmentCount: 4, selectedIndex: 3)
        XCTAssertEqual(layout.segmentFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(layout.thumbOffsetFraction, 0.75, accuracy: 0.0001)
    }

    func testOutOfRangeIndexIsClampedToLastSegment() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: 99)
        XCTAssertEqual(layout.thumbOffsetFraction, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testNegativeIndexIsClampedToFirstSegment() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: -5)
        XCTAssertEqual(layout.thumbOffsetFraction, 0.0, accuracy: 0.0001)
    }

    func testZeroSegmentsReturnsZeroedLayout() {
        let layout = segmentedControlLayout(segmentCount: 0, selectedIndex: 0)
        XCTAssertEqual(layout, SegmentedControlLayout(segmentFraction: 0, thumbOffsetFraction: 0))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/SegmentedControlTests`
Expected: FAIL — `cannot find 'segmentedControlLayout' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/SegmentedControl.swift`:
```swift
import SwiftUI

struct SegmentedControlLayout: Equatable {
    let segmentFraction: Double
    let thumbOffsetFraction: Double
}

func segmentedControlLayout(segmentCount: Int, selectedIndex: Int) -> SegmentedControlLayout {
    guard segmentCount > 0 else { return SegmentedControlLayout(segmentFraction: 0, thumbOffsetFraction: 0) }
    let fraction = 1.0 / Double(segmentCount)
    let clampedIndex = min(max(selectedIndex, 0), segmentCount - 1)
    return SegmentedControlLayout(segmentFraction: fraction, thumbOffsetFraction: fraction * Double(clampedIndex))
}

struct SegmentedControl: View {
    let segments: [String]
    @Binding var selectedIndex: Int

    var body: some View {
        GeometryReader { geometry in
            let layout = segmentedControlLayout(segmentCount: segments.count, selectedIndex: selectedIndex)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DocsRadius.sm)
                    .fill(DocsColor.surfaceMuted)

                RoundedRectangle(cornerRadius: DocsRadius.sm)
                    .fill(DocsColor.surfacePage)
                    .frame(width: geometry.size.width * layout.segmentFraction)
                    .offset(x: geometry.size.width * layout.thumbOffsetFraction)
                    .animation(.easeOut(duration: 0.2), value: selectedIndex)

                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Text(segment)
                            .font(DocsFont.subhead)
                            .foregroundStyle(index == selectedIndex ? DocsColor.textPrimary : DocsColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedIndex = index }
                    }
                }
            }
        }
        .frame(height: DocsSpacing.rowMinHeight)
    }
}

#Preview {
    @Previewable @State var selectedIndex = 0
    SegmentedControl(segments: ["All", "Shared", "Pinned"], selectedIndex: $selectedIndex)
        .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/SegmentedControlTests`
Expected: PASS — `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/SegmentedControl.swift DocsIOSTests/DesignSystem/Components/SegmentedControlTests.swift
git commit -m "Add SegmentedControl component"
```

---

### Task 3: DocsTextField component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/TextField.swift`
- Test: `DocsIOSTests/DesignSystem/Components/TextFieldStyleResolverTests.swift`

**Interfaces:**
- Consumes: `DocsColorHex.borderDefault/borderFocus/danger/textSecondary/textBrandSecondary/textDisabled`, `Color(hex:)`, `DocsColor.surfacePage/textTertiary/danger`, `DocsFont.footnote/body/caption`, `DocsSpacing.space4xs/spaceXS/spaceSM`, `DocsRadius.sm`.
- Produces: `enum TextFieldState: Equatable { normal, focused, error, disabled }`, `struct TextFieldStyleHex: Equatable { borderHex: UInt32, labelHex: UInt32 }`, `enum TextFieldStyleResolver { static func style(state:) -> TextFieldStyleHex }`, `struct DocsTextField: View` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/TextFieldStyleResolverTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class TextFieldStyleResolverTests: XCTestCase {
    func testNormalStateUsesDefaultBorder() {
        let style = TextFieldStyleResolver.style(state: .normal)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textSecondary))
    }

    func testFocusedStateUsesBrandBorder() {
        let style = TextFieldStyleResolver.style(state: .focused)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderFocus, labelHex: DocsColorHex.textBrandSecondary))
    }

    func testErrorStateUsesDangerBorder() {
        let style = TextFieldStyleResolver.style(state: .error)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.danger, labelHex: DocsColorHex.danger))
    }

    func testDisabledStateUsesDefaultBorderWithDisabledLabel() {
        let style = TextFieldStyleResolver.style(state: .disabled)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textDisabled))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/TextFieldStyleResolverTests`
Expected: FAIL — `cannot find 'TextFieldStyleResolver' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/TextField.swift`:
```swift
import SwiftUI

enum TextFieldState: Equatable {
    case normal
    case focused
    case error
    case disabled
}

struct TextFieldStyleHex: Equatable {
    let borderHex: UInt32
    let labelHex: UInt32
}

enum TextFieldStyleResolver {
    static func style(state: TextFieldState) -> TextFieldStyleHex {
        switch state {
        case .normal:
            return TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textSecondary)
        case .focused:
            return TextFieldStyleHex(borderHex: DocsColorHex.borderFocus, labelHex: DocsColorHex.textBrandSecondary)
        case .error:
            return TextFieldStyleHex(borderHex: DocsColorHex.danger, labelHex: DocsColorHex.danger)
        case .disabled:
            return TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textDisabled)
        }
    }
}

struct DocsTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var icon: String? = nil
    var helper: String? = nil
    var error: String? = nil
    var isDisabled: Bool = false

    @FocusState private var isFocused: Bool

    private var state: TextFieldState {
        if isDisabled { return .disabled }
        if error != nil { return .error }
        if isFocused { return .focused }
        return .normal
    }

    var body: some View {
        let style = TextFieldStyleResolver.style(state: state)
        VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
            Text(label)
                .font(DocsFont.footnote)
                .foregroundStyle(Color(hex: style.labelHex))

            HStack(spacing: DocsSpacing.spaceXS) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(DocsColor.textTertiary)
                }
                TextField(placeholder, text: $text)
                    .font(DocsFont.body)
                    .focused($isFocused)
                    .disabled(isDisabled)
            }
            .padding(DocsSpacing.spaceSM)
            .background(DocsColor.surfacePage)
            .overlay(
                RoundedRectangle(cornerRadius: DocsRadius.sm)
                    .strokeBorder(Color(hex: style.borderHex), lineWidth: state == .focused ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))

            if let error {
                Text(error)
                    .font(DocsFont.caption)
                    .foregroundStyle(DocsColor.danger)
            } else if let helper {
                Text(helper)
                    .font(DocsFont.caption)
                    .foregroundStyle(DocsColor.textTertiary)
            }
        }
    }
}

#Preview {
    @Previewable @State var text = ""
    DocsTextField(label: "Docs server", text: $text, placeholder: "docs.example.org", icon: "cloud", helper: "The app signs in with your existing session.")
        .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/TextFieldStyleResolverTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/TextField.swift DocsIOSTests/DesignSystem/Components/TextFieldStyleResolverTests.swift
git commit -m "Add DocsTextField component"
```

---

### Task 4: Extend the component catalog

**Files:**
- Modify: `DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`

**Interfaces:**
- Consumes: `SearchField`, `SegmentedControl`, `DocsTextField` (Tasks 1-3).
- Produces: no change to `ComponentCatalogPreview`'s own signature (still a `#Preview`-only `View`, no parameters).

- [ ] **Step 1: Add three `@State` variables**

In `DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`, find this exact line:

```swift
    @State private var isSwitchOn = true
```

Replace it with:

```swift
    @State private var isSwitchOn = true
    @State private var searchText = ""
    @State private var selectedSegment = 0
    @State private var textFieldValue = ""
```

- [ ] **Step 2: Add three new catalog sections**

Find this exact block:

```swift
                catalogSection("Doc Icons") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        DocIcon(emoji: "📄")
                        DocIcon(emoji: nil, tinted: true)
                        DocIcon(emoji: "📌", pinned: true)
                    }
                }
            }
```

Replace it with:

```swift
                catalogSection("Doc Icons") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        DocIcon(emoji: "📄")
                        DocIcon(emoji: nil, tinted: true)
                        DocIcon(emoji: "📌", pinned: true)
                    }
                }

                catalogSection("Search Field") {
                    SearchField(text: $searchText)
                }

                catalogSection("Segmented Control") {
                    SegmentedControl(segments: ["All", "Shared", "Pinned"], selectedIndex: $selectedSegment)
                }

                catalogSection("Text Field") {
                    DocsTextField(label: "Docs server", text: $textFieldValue, placeholder: "docs.example.org", icon: "cloud", helper: "The app signs in with your existing session.")
                }
            }
```

- [ ] **Step 3: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 61 tests, with 0 failures` (51 from the prior three plans + 6 SegmentedControl + 4 TextFieldStyleResolver = 61; SearchField adds no tests, matching the Switch precedent)

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift
git commit -m "Add SearchField, SegmentedControl, and DocsTextField to the component catalog"
```

## Self-Review Notes

- **Spec coverage:** Completes the design spec's "forms" component group (SearchField, SegmentedControl, TextField — Switch was already done in an earlier plan). This completes ALL primitive DesignSystem components from `components/buttons/`, `components/data-display/`, and `components/forms/` in the original handoff. Remaining component groups (`components/ios/`: NavBar, TabBar, ListRow, ListSection; `components/docs/`: DocRow, LinkReachPill, ShareMemberRow) are deferred to subsequent plans, as are all screens.
- **Placeholder scan:** No TBD/TODO. SearchField's lack of a test file is documented as intentional (no branching logic), not an omission.
- **Type consistency:** `SegmentedControlLayout`, `segmentedControlLayout`, `TextFieldState`, `TextFieldStyleHex`, `TextFieldStyleResolver`, and `DocsTextField` are each defined once and referenced identically across tasks.
- **Resolves the carried-forward consolidation question:** the prior plan's final review flagged that a 4th component needing the exact 3-field `backgroundHex?/foregroundHex/borderHex?` shape would be the moment to decide on sharing vs. keeping distinct. `TextFieldStyleHex` uses a different 2-field, non-optional shape driven by a single state enum rather than two orthogonal enums — so that decision point has not yet arrived. It's called out explicitly here (not silently sidestepped) so a future plan doesn't have to re-derive this reasoning.
- **Cross-file validation:** All code in this plan (all 3 components plus the catalog extension) was compiled and test-run end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 61 tests, with 0 failures`.
