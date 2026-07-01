# iOS Chrome Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the four "ios" (native chrome) DesignSystem components — NavBar, TabBar, ListRow, ListSection — completing every component group in the design spec except "docs" (DocRow, LinkReachPill, ShareMemberRow, deferred to the next plan), and extend the component catalog.

**Architecture:** Continues the established pattern. `NavBar` and `TabBar` each have one small, genuinely testable decision extracted as a pure function (nav bar height by mode; tab icon SF Symbol name by selection state) rather than a full resolver, since neither has the kind of multi-axis variant/color branching Button/IconButton/Badge have. `ListRow` gets a minimal destructive-color resolver function (not a struct — there's only one color to resolve, a bare function is proportionate). `ListSection` is a generic container with no testable logic (matches the `Switch`/`SearchField`/`ListSection`-has-no-branching precedent) — it uses an explicit `init(@ViewBuilder content:)` rather than a `@ViewBuilder` stored property, which is the safe, standard SwiftUI pattern for generic view containers (a `@ViewBuilder` attribute on a stored property does not reliably propagate to a synthesized memberwise initializer).

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `NavBar` consumes `IconButton` (from an earlier plan) for its trailing actions — do not redefine icon-button styling inline.
- `ListSection` is generic over `Content: View` and must use the explicit-`init` pattern shown in this plan, not a `@ViewBuilder`-attributed stored property.

## File Structure

```
DocsIOS/
└── DesignSystem/
    └── Components/
        ├── NavBar.swift                                    — navBarHeight(largeTitle:), NavBarAction, NavBar view (Task 1)
        ├── TabBar.swift                                      — tabBarIconName(baseSystemImage:isSelected:), TabBarItem, TabBar view (Task 2)
        ├── ListRow.swift                                      — listRowTitleColorHex(isDestructive:), ListRow view (Task 3)
        └── ListSection.swift                                   — ListSection<Content> view, no resolver, no test file (Task 3)

DocsIOS/DesignSystemCatalog/
└── ComponentCatalogPreview.swift                            — MODIFY: add Nav Bar/Tab Bar/List Row+Section sections + 1 new @State var (Task 4)

DocsIOSTests/
└── DesignSystem/
    └── Components/
        ├── NavBarTests.swift                                 — Task 1
        ├── TabBarTests.swift                                  — Task 2
        └── ListRowTests.swift                                  — Task 3
```

---

### Task 1: NavBar component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/NavBar.swift`
- Test: `DocsIOSTests/DesignSystem/Components/NavBarTests.swift`

**Interfaces:**
- Consumes: `DocsSpacing.navBarHeight/largeTitleBarHeight/gutter/spaceXS/space4xs`, `DocsColor.surfacePage/borderDefault/textPrimary/textTertiary/textBrand`, `DocsFont.headline/caption/largeTitle/footnote/body`, `IconButton` (from an earlier plan).
- Produces: `func navBarHeight(largeTitle: Bool) -> CGFloat`, `struct NavBarAction { systemImage: String, label: String, action: () -> Void }`, `struct NavBar: View` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/NavBarTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class NavBarTests: XCTestCase {
    func testStandardHeightUsesNavBarHeight() {
        XCTAssertEqual(navBarHeight(largeTitle: false), DocsSpacing.navBarHeight)
    }

    func testLargeTitleHeightUsesLargeTitleBarHeight() {
        XCTAssertEqual(navBarHeight(largeTitle: true), DocsSpacing.largeTitleBarHeight)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/NavBarTests`
Expected: FAIL — `cannot find 'navBarHeight' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/NavBar.swift`:
```swift
import SwiftUI

func navBarHeight(largeTitle: Bool) -> CGFloat {
    largeTitle ? DocsSpacing.largeTitleBarHeight : DocsSpacing.navBarHeight
}

struct NavBarAction {
    let systemImage: String
    let label: String
    let action: () -> Void
}

struct NavBar: View {
    let title: String
    var subtitle: String? = nil
    var largeTitle: Bool = false
    var backTitle: String? = nil
    var onBack: (() -> Void)? = nil
    var trailingActions: [NavBarAction] = []
    var translucent: Bool = true
    var showsBorder: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let backTitle, let onBack {
                    Button(action: onBack) {
                        HStack(spacing: DocsSpacing.space4xs) {
                            Image(systemName: "chevron.left")
                            Text(backTitle)
                        }
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textBrand)
                    }
                }

                Spacer()

                if !largeTitle {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(DocsFont.headline)
                            .foregroundStyle(DocsColor.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(DocsFont.caption)
                                .foregroundStyle(DocsColor.textTertiary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: DocsSpacing.spaceXS) {
                    ForEach(Array(trailingActions.enumerated()), id: \.offset) { _, action in
                        IconButton(systemImage: action.systemImage, label: action.label, action: action.action)
                    }
                }
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .frame(height: DocsSpacing.navBarHeight)

            if largeTitle {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(DocsFont.largeTitle)
                        .foregroundStyle(DocsColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceXS)
            }
        }
        .frame(minHeight: navBarHeight(largeTitle: largeTitle))
        .background(translucent ? DocsColor.surfacePage.opacity(0.82) : DocsColor.surfacePage)
        .overlay(alignment: .bottom) {
            if showsBorder {
                Rectangle()
                    .fill(DocsColor.borderDefault)
                    .frame(height: 0.5)
            }
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        NavBar(title: "Docs", subtitle: "docs.example.org", largeTitle: true, trailingActions: [
            NavBarAction(systemImage: "magnifyingglass", label: "Search", action: {}),
            NavBarAction(systemImage: "plus", label: "New", action: {}),
        ])
        NavBar(title: "Docs", backTitle: "Docs", onBack: {}, trailingActions: [
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {}),
        ])
        Spacer()
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/NavBarTests`
Expected: PASS — `Executed 2 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/NavBar.swift DocsIOSTests/DesignSystem/Components/NavBarTests.swift
git commit -m "Add NavBar component"
```

---

### Task 2: TabBar component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/TabBar.swift`
- Test: `DocsIOSTests/DesignSystem/Components/TabBarTests.swift`

**Interfaces:**
- Consumes: `DocsSpacing.space4xs/space3xs/tabBarHeight/homeIndicatorHeight`, `DocsColor.brandFill/textTertiary/surfacePage/borderDefault`, `DocsFont.caption`.
- Produces: `func tabBarIconName(baseSystemImage: String, isSelected: Bool) -> String`, `struct TabBarItem { value: String, label: String, systemImage: String }`, `struct TabBar: View { let items: [TabBarItem]; @Binding var selection: String; var showsSafeArea: Bool = true }` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/TabBarTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class TabBarTests: XCTestCase {
    func testSelectedIconUsesFilledVariant() {
        XCTAssertEqual(tabBarIconName(baseSystemImage: "house", isSelected: true), "house.fill")
    }

    func testUnselectedIconUsesBaseVariant() {
        XCTAssertEqual(tabBarIconName(baseSystemImage: "house", isSelected: false), "house")
    }

    func testWorksWithCompoundSymbolNames() {
        XCTAssertEqual(tabBarIconName(baseSystemImage: "person.crop.circle", isSelected: true), "person.crop.circle.fill")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/TabBarTests`
Expected: FAIL — `cannot find 'tabBarIconName' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/TabBar.swift`:
```swift
import SwiftUI

func tabBarIconName(baseSystemImage: String, isSelected: Bool) -> String {
    isSelected ? "\(baseSystemImage).fill" : baseSystemImage
}

struct TabBarItem {
    let value: String
    let label: String
    let systemImage: String
}

struct TabBar: View {
    let items: [TabBarItem]
    @Binding var selection: String
    var showsSafeArea: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let isSelected = item.value == selection
                Button(action: { selection = item.value }) {
                    VStack(spacing: DocsSpacing.space4xs) {
                        Image(systemName: tabBarIconName(baseSystemImage: item.systemImage, isSelected: isSelected))
                        Text(item.label)
                            .font(DocsFont.caption)
                    }
                    .foregroundStyle(isSelected ? DocsColor.brandFill : DocsColor.textTertiary)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, DocsSpacing.space3xs)
        .padding(.bottom, showsSafeArea ? DocsSpacing.homeIndicatorHeight : DocsSpacing.space3xs)
        .frame(height: DocsSpacing.tabBarHeight + (showsSafeArea ? DocsSpacing.homeIndicatorHeight : 0))
        .background(DocsColor.surfacePage.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 0.5)
        }
    }
}

#Preview {
    @Previewable @State var selection = "docs"
    VStack {
        Spacer()
        TabBar(items: [
            TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
            TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
            TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
            TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
        ], selection: $selection)
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/TabBarTests`
Expected: PASS — `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/TabBar.swift DocsIOSTests/DesignSystem/Components/TabBarTests.swift
git commit -m "Add TabBar component"
```

---

### Task 3: ListRow and ListSection components

Both land in one task since `ListSection` exists to contain `ListRow`s and the two are always used together — splitting them would leave Task 3's `ListRow` un-demonstrable without a container and Task 4's catalog awkwardly split. `ListSection` has no testable logic (a generic container with only header/footer text, no color/variant branching) — matching the `Switch`/`SearchField` precedent, it gets no test file.

**Files:**
- Create: `DocsIOS/DesignSystem/Components/ListRow.swift`
- Create: `DocsIOS/DesignSystem/Components/ListSection.swift`
- Test: `DocsIOSTests/DesignSystem/Components/ListRowTests.swift`

**Interfaces:**
- Consumes (`ListRow`): `DocsColorHex.danger/textPrimary`, `Color(hex:)`, `DocsColor.danger/textSecondary/textTertiary`, `DocsFont.body/footnote`, `DocsSpacing.spaceSM/gutterGrouped/rowMinHeight`.
- Consumes (`ListSection`): `DocsSpacing.spaceXS/gutterGrouped`, `DocsColor.surfacePage/textTertiary`, `DocsFont.footnote`, `DocsRadius.lg`.
- Produces: `func listRowTitleColorHex(isDestructive: Bool) -> UInt32`, `struct ListRow: View`, `struct ListSection<Content: View>: View` — both consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/ListRowTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class ListRowTests: XCTestCase {
    func testNormalRowUsesTextPrimary() {
        XCTAssertEqual(listRowTitleColorHex(isDestructive: false), DocsColorHex.textPrimary)
    }

    func testDestructiveRowUsesDanger() {
        XCTAssertEqual(listRowTitleColorHex(isDestructive: true), DocsColorHex.danger)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ListRowTests`
Expected: FAIL — `cannot find 'listRowTitleColorHex' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/ListRow.swift`:
```swift
import SwiftUI

func listRowTitleColorHex(isDestructive: Bool) -> UInt32 {
    isDestructive ? DocsColorHex.danger : DocsColorHex.textPrimary
}

struct ListRow: View {
    var systemImage: String? = nil
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var showsChevron: Bool = false
    var isDestructive: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: DocsSpacing.spaceSM) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(isDestructive ? DocsColor.danger : DocsColor.textSecondary)
                        .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(DocsFont.body)
                        .foregroundStyle(Color(hex: listRowTitleColorHex(isDestructive: isDestructive)))
                    if let subtitle {
                        Text(subtitle)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }

                Spacer()

                if let value {
                    Text(value)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textTertiary)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
            .padding(.horizontal, DocsSpacing.gutterGrouped)
            .frame(minHeight: DocsSpacing.rowMinHeight)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        ListRow(systemImage: "pin", title: "Pin", value: "Pinned", showsChevron: false, action: {})
        ListRow(systemImage: "link", title: "Copy link", action: {})
        ListRow(title: "Delete document", isDestructive: true, action: {})
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ListRowTests`
Expected: PASS — `Executed 2 tests, with 0 failures`

- [ ] **Step 5: Write ListSection (no test — no branching logic)**

`DocsIOS/DesignSystem/Components/ListSection.swift`:
```swift
import SwiftUI

struct ListSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    let content: Content

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            if let header {
                Text(header.uppercased())
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .padding(.horizontal, DocsSpacing.gutterGrouped)
            }

            VStack(spacing: 0) {
                content
            }
            .background(DocsColor.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))

            if let footer {
                Text(footer)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .padding(.horizontal, DocsSpacing.gutterGrouped)
            }
        }
    }
}

#Preview {
    ListSection(header: "Document", footer: "These actions apply to the current document.") {
        ListRow(systemImage: "pin", title: "Pin", action: {})
        ListRow(systemImage: "link", title: "Copy link", action: {})
    }
    .padding()
}
```

- [ ] **Step 6: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add DocsIOS/DesignSystem/Components/ListRow.swift DocsIOS/DesignSystem/Components/ListSection.swift DocsIOSTests/DesignSystem/Components/ListRowTests.swift
git commit -m "Add ListRow and ListSection components"
```

---

### Task 4: Extend the component catalog

**Files:**
- Modify: `DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`

**Interfaces:**
- Consumes: `NavBar`, `NavBarAction`, `TabBar`, `TabBarItem`, `ListRow`, `ListSection` (Tasks 1-3).
- Produces: no change to `ComponentCatalogPreview`'s own signature.

- [ ] **Step 1: Add one `@State` variable**

Find this exact line:

```swift
    @State private var textFieldValue = ""
```

Replace it with:

```swift
    @State private var textFieldValue = ""
    @State private var catalogTab = "docs"
```

- [ ] **Step 2: Add three new catalog sections**

Find this exact block:

```swift
                catalogSection("Text Field") {
                    DocsTextField(label: "Docs server", text: $textFieldValue, placeholder: "docs.example.org", icon: "cloud", helper: "The app signs in with your existing session.")
                }
            }
```

Replace it with:

```swift
                catalogSection("Text Field") {
                    DocsTextField(label: "Docs server", text: $textFieldValue, placeholder: "docs.example.org", icon: "cloud", helper: "The app signs in with your existing session.")
                }

                catalogSection("Nav Bar") {
                    VStack(spacing: DocsSpacing.spaceXS) {
                        NavBar(title: "Docs", subtitle: "docs.example.org", largeTitle: true, trailingActions: [
                            NavBarAction(systemImage: "magnifyingglass", label: "Search", action: {}),
                        ])
                        NavBar(title: "Docs", backTitle: "Docs", onBack: {}, trailingActions: [
                            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {}),
                        ])
                    }
                }

                catalogSection("Tab Bar") {
                    TabBar(items: [
                        TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                        TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                        TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                    ], selection: $catalogTab, showsSafeArea: false)
                }

                catalogSection("List Row / List Section") {
                    ListSection(header: "Document", footer: "These actions apply to the current document.") {
                        ListRow(systemImage: "pin", title: "Pin", value: "Pinned", action: {})
                        ListRow(systemImage: "link", title: "Copy link", showsChevron: true, action: {})
                        ListRow(title: "Delete document", isDestructive: true, action: {})
                    }
                }
            }
```

- [ ] **Step 3: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 68 tests, with 0 failures` (61 from the prior four plans + 2 NavBar + 3 TabBar + 2 ListRow = 68; ListSection adds no tests)

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift
git commit -m "Add NavBar, TabBar, ListRow, and ListSection to the component catalog"
```

## Self-Review Notes

- **Spec coverage:** Completes the design spec's "ios" component group (NavBar, TabBar, ListRow, ListSection). Only the "docs" group (DocRow, LinkReachPill, ShareMemberRow) remains before every primitive/chrome component in the spec's inventory is built — that's the natural next plan.
- **Placeholder scan:** No TBD/TODO. `ListSection`'s lack of a test file is documented as intentional (no branching logic), not an omission.
- **Type consistency:** `navBarHeight`, `NavBarAction`, `NavBar`, `tabBarIconName`, `TabBarItem`, `TabBar`, `listRowTitleColorHex`, `ListRow`, and `ListSection` are each defined once and referenced identically across tasks. `NavBar` correctly reuses `IconButton`'s existing signature (`systemImage:label:action:`) rather than redefining icon-button styling.
- **Cross-file validation:** All code in this plan (all 4 components plus the catalog extension, including the generics-based `ListSection` and the `IconButton`-composing `NavBar`) was compiled and test-run end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 68 tests, with 0 failures`.
