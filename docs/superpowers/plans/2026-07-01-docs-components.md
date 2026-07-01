# Docs-Specific Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the three "docs" DesignSystem components — LinkReachPill, ShareMemberRow, DocRow — completing every component the design spec's Component Inventory calls for, and extend the component catalog.

**Architecture:** `LinkReachPill` introduces `enum LinkReach` (the canonical restricted/authenticated/public reach values, matching the backend's `LinkReachChoices` API strings exactly via a `String` raw value for future Codable use) and follows the full `BadgeStyleResolver` pattern — a real 3-case enum mapping to a background/foreground/icon/label/hint record, exactly the shape the prior plan's final review recommended. `DocRow` reuses `LinkReach` for its own compact reach indicator (nil for restricted, an icon otherwise) via a second, DocRow-specific pure function — this is deliberately a *different* function from `LinkReachPill`'s full style record, because a doc list row shows only a small icon (or nothing), not the pill's label/hint. `ShareMemberRow` gets one small testable decision (the "(you)" suffix). `DocRow` composes `DocIcon` and `IconButton` and uses `.onTapGesture` (not a wrapping `Button`) for its "open" action — SwiftUI does not reliably support nesting an interactive `Button` inside another `Button`, and `DocRow` needs a real `IconButton` (itself a `Button`) for its trailing "more options" action, so the row-level tap must not itself be a `Button`.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `public` is a Swift keyword: the enum case is declared as `` case `public` `` (backticks required at the declaration site only) but referenced elsewhere as plain `.public` or `LinkReach.public` — no backticks needed at usage sites. This was verified to compile correctly before being written into this plan; do not "fix" the backtick placement.
- `DocRow`'s row-level "open" interaction is `.onTapGesture`, not a `Button` — do not wrap the row body in `Button(action:)`, since `DocRow` also contains a real `IconButton` (a `Button`) and SwiftUI does not reliably support nested interactive `Button`s.
- `enum LinkReach` and `docRowReachIndicatorSystemImage` are consumed across files without an explicit import (same module) — `LinkReach` is declared in `LinkReachPill.swift`; `docRowReachIndicatorSystemImage` is declared in `DocRow.swift` (not `LinkReachPill.swift`) since it's a DocRow-specific display rule, not a universal property of `LinkReach` itself.

## File Structure

```
DocsIOS/
└── DesignSystem/
    └── Components/
        ├── LinkReachPill.swift                              — LinkReach, LinkReachPillStyleHex, LinkReachPillStyleResolver, LinkReachPill view (Task 1)
        ├── ShareMemberRow.swift                               — shareMemberDisplaySuffix(isCurrentUser:), ShareMemberRow view (Task 2)
        └── DocRow.swift                                        — docRowReachIndicatorSystemImage(reach:), DocRow view (Task 3)

DocsIOS/DesignSystemCatalog/
└── ComponentCatalogPreview.swift                            — MODIFY: add Link Reach Pill/Share Member Row/Doc Row sections (Task 4)

DocsIOSTests/
└── DesignSystem/
    └── Components/
        ├── LinkReachPillTests.swift                          — Task 1
        ├── ShareMemberRowTests.swift                          — Task 2
        └── DocRowTests.swift                                   — Task 3
```

---

### Task 1: LinkReachPill component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/LinkReachPill.swift`
- Test: `DocsIOSTests/DesignSystem/Components/LinkReachPillTests.swift`

**Interfaces:**
- Consumes: `DocsColorHex.surfaceMuted/textSecondary/infoSoft/info/brandFillSoft/textBrandSecondary`, `Color(hex:)`, `DocsSpacing.space4xs/spaceXS`, `DocsFont.caption`.
- Produces: `enum LinkReach: String { restricted, authenticated, \`public\` }`, `struct LinkReachPillStyleHex: Equatable { backgroundHex: UInt32, foregroundHex: UInt32, systemImage: String, label: String, hint: String }`, `enum LinkReachPillStyleResolver { static func style(reach:) -> LinkReachPillStyleHex }`, `struct LinkReachPill: View { let reach: LinkReach; var showsHint: Bool = false }` — `LinkReach` consumed by Task 3's `DocRow`; `LinkReachPill` consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/LinkReachPillTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class LinkReachPillTests: XCTestCase {
    func testRestrictedUsesNeutralStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .restricted)
        XCTAssertEqual(style, LinkReachPillStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary, systemImage: "lock.fill", label: "Restricted", hint: "Only invited people"))
    }

    func testAuthenticatedUsesInfoStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .authenticated)
        XCTAssertEqual(style, LinkReachPillStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info, systemImage: "network", label: "Connected", hint: "Anyone in the org"))
    }

    func testPublicUsesBrandStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .public)
        XCTAssertEqual(style, LinkReachPillStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary, systemImage: "globe", label: "Public", hint: "Anyone with the link"))
    }

    func testRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(LinkReach.restricted.rawValue, "restricted")
        XCTAssertEqual(LinkReach.authenticated.rawValue, "authenticated")
        XCTAssertEqual(LinkReach.public.rawValue, "public")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/LinkReachPillTests`
Expected: FAIL — `cannot find 'LinkReachPillStyleResolver' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/LinkReachPill.swift`:
```swift
import SwiftUI

enum LinkReach: String {
    case restricted
    case authenticated
    case `public`
}

struct LinkReachPillStyleHex: Equatable {
    let backgroundHex: UInt32
    let foregroundHex: UInt32
    let systemImage: String
    let label: String
    let hint: String
}

enum LinkReachPillStyleResolver {
    static func style(reach: LinkReach) -> LinkReachPillStyleHex {
        switch reach {
        case .restricted:
            return LinkReachPillStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary, systemImage: "lock.fill", label: "Restricted", hint: "Only invited people")
        case .authenticated:
            return LinkReachPillStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info, systemImage: "network", label: "Connected", hint: "Anyone in the org")
        case .public:
            return LinkReachPillStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary, systemImage: "globe", label: "Public", hint: "Anyone with the link")
        }
    }
}

struct LinkReachPill: View {
    let reach: LinkReach
    var showsHint: Bool = false

    var body: some View {
        let style = LinkReachPillStyleResolver.style(reach: reach)
        HStack(spacing: DocsSpacing.space4xs) {
            Image(systemName: style.systemImage)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 0) {
                Text(style.label)
                    .font(DocsFont.caption)
                if showsHint {
                    Text(style.hint)
                        .font(.system(size: 10))
                        .opacity(0.8)
                }
            }
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
        LinkReachPill(reach: .restricted, showsHint: true)
        LinkReachPill(reach: .authenticated)
        LinkReachPill(reach: .public)
    }
    .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/LinkReachPillTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/LinkReachPill.swift DocsIOSTests/DesignSystem/Components/LinkReachPillTests.swift
git commit -m "Add LinkReachPill component"
```

---

### Task 2: ShareMemberRow component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/ShareMemberRow.swift`
- Test: `DocsIOSTests/DesignSystem/Components/ShareMemberRowTests.swift`

**Interfaces:**
- Consumes: `Avatar` (from an earlier plan), `DocsColor.textPrimary/textTertiary/textSecondary`, `DocsFont.body/footnote`, `DocsSpacing.spaceSM/space4xs/gutterGrouped/rowMinHeight`.
- Produces: `func shareMemberDisplaySuffix(isCurrentUser: Bool) -> String?`, `struct ShareMemberRow: View` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/ShareMemberRowTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class ShareMemberRowTests: XCTestCase {
    func testCurrentUserGetsYouSuffix() {
        XCTAssertEqual(shareMemberDisplaySuffix(isCurrentUser: true), "(you)")
    }

    func testOtherUserGetsNoSuffix() {
        XCTAssertNil(shareMemberDisplaySuffix(isCurrentUser: false))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ShareMemberRowTests`
Expected: FAIL — `cannot find 'shareMemberDisplaySuffix' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/ShareMemberRow.swift`:
```swift
import SwiftUI

func shareMemberDisplaySuffix(isCurrentUser: Bool) -> String? {
    isCurrentUser ? "(you)" : nil
}

struct ShareMemberRow: View {
    let name: String
    let email: String
    var role: String = "Reader"
    var isCurrentUser: Bool = false
    var onTapRole: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Avatar(name: name, size: 40)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(name)
                        .font(DocsFont.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DocsColor.textPrimary)
                    if let suffix = shareMemberDisplaySuffix(isCurrentUser: isCurrentUser) {
                        Text(suffix)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                Text(email)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }

            Spacer()

            Button(action: { onTapRole?() }) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(role)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, DocsSpacing.gutterGrouped)
        .frame(minHeight: DocsSpacing.rowMinHeight)
    }
}

#Preview {
    VStack(spacing: 0) {
        ShareMemberRow(name: "Camille Moreau", email: "camille.moreau@beta.gouv.fr", role: "Admin", isCurrentUser: true)
        ShareMemberRow(name: "Alfredo Levin", email: "alfredo.levin@test.gouv.fr", role: "Editor")
        ShareMemberRow(name: "Desirae Dokidis", email: "desirae.dokidis@gmail.com", role: "Reader")
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ShareMemberRowTests`
Expected: PASS — `Executed 2 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/ShareMemberRow.swift DocsIOSTests/DesignSystem/Components/ShareMemberRowTests.swift
git commit -m "Add ShareMemberRow component"
```

---

### Task 3: DocRow component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/DocRow.swift`
- Test: `DocsIOSTests/DesignSystem/Components/DocRowTests.swift`

**Interfaces:**
- Consumes: `LinkReach` (Task 1), `DocIcon`, `IconButton` (both from earlier plans), `DocsColor.textPrimary/textTertiary`, `DocsFont.body/footnote`, `DocsSpacing.spaceSM/space4xs/gutterGrouped/rowMinHeight`.
- Produces: `func docRowReachIndicatorSystemImage(reach: LinkReach) -> String?`, `struct DocRow: View` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/DocRowTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocRowTests: XCTestCase {
    func testRestrictedShowsNoIndicator() {
        XCTAssertNil(docRowReachIndicatorSystemImage(reach: .restricted))
    }

    func testAuthenticatedShowsNetworkIndicator() {
        XCTAssertEqual(docRowReachIndicatorSystemImage(reach: .authenticated), "network")
    }

    func testPublicShowsGlobeIndicator() {
        XCTAssertEqual(docRowReachIndicatorSystemImage(reach: .public), "globe")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocRowTests`
Expected: FAIL — `cannot find 'docRowReachIndicatorSystemImage' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/DocRow.swift`:
```swift
import SwiftUI

func docRowReachIndicatorSystemImage(reach: LinkReach) -> String? {
    switch reach {
    case .restricted: return nil
    case .authenticated: return "network"
    case .public: return "globe"
    }
}

struct DocRow: View {
    var emoji: String? = nil
    var title: String = "Untitled document"
    var pinned: Bool = false
    var reach: LinkReach = .restricted
    var date: String = ""
    var onOpen: (() -> Void)? = nil
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            DocIcon(emoji: emoji, pinned: pinned)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(title)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textPrimary)
                        .lineLimit(1)
                    if let indicatorImage = docRowReachIndicatorSystemImage(reach: reach) {
                        Image(systemName: indicatorImage)
                            .font(.system(size: 11))
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                Text(date)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }

            Spacer()

            IconButton(systemImage: "ellipsis", label: "More options", action: { onMore?() })
        }
        .padding(.horizontal, DocsSpacing.gutterGrouped)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }
}

#Preview {
    VStack(spacing: 0) {
        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
        DocRow(emoji: "📊", title: "Roadmap", reach: .authenticated, date: "Yesterday")
        DocRow(title: "Public notes", reach: .public, date: "Last week")
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocRowTests`
Expected: PASS — `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/DocRow.swift DocsIOSTests/DesignSystem/Components/DocRowTests.swift
git commit -m "Add DocRow component"
```

---

### Task 4: Extend the component catalog

**Files:**
- Modify: `DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`

**Interfaces:**
- Consumes: `LinkReachPill`, `ShareMemberRow`, `DocRow` (Tasks 1-3).
- Produces: no change to `ComponentCatalogPreview`'s own signature.

- [ ] **Step 1: Add three new catalog sections**

Find this exact block:

```swift
                catalogSection("List Row / List Section") {
                    ListSection(header: "Document", footer: "These actions apply to the current document.") {
                        ListRow(systemImage: "pin", title: "Pin", value: "Pinned", action: {})
                        ListRow(systemImage: "link", title: "Copy link", showsChevron: true, action: {})
                        ListRow(title: "Delete document", isDestructive: true, action: {})
                    }
                }
            }
```

Replace it with:

```swift
                catalogSection("List Row / List Section") {
                    ListSection(header: "Document", footer: "These actions apply to the current document.") {
                        ListRow(systemImage: "pin", title: "Pin", value: "Pinned", action: {})
                        ListRow(systemImage: "link", title: "Copy link", showsChevron: true, action: {})
                        ListRow(title: "Delete document", isDestructive: true, action: {})
                    }
                }

                catalogSection("Link Reach Pill") {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        LinkReachPill(reach: .restricted, showsHint: true)
                        LinkReachPill(reach: .authenticated)
                        LinkReachPill(reach: .public)
                    }
                }

                catalogSection("Share Member Row") {
                    VStack(spacing: 0) {
                        ShareMemberRow(name: "Camille Moreau", email: "camille.moreau@beta.gouv.fr", role: "Admin", isCurrentUser: true)
                        ShareMemberRow(name: "Alfredo Levin", email: "alfredo.levin@test.gouv.fr", role: "Editor")
                        ShareMemberRow(name: "Desirae Dokidis", email: "desirae.dokidis@gmail.com", role: "Reader")
                    }
                }

                catalogSection("Doc Row") {
                    VStack(spacing: 0) {
                        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
                        DocRow(emoji: "📊", title: "Roadmap", reach: .authenticated, date: "Yesterday")
                        DocRow(title: "Public notes", reach: .public, date: "Last week")
                    }
                }
            }
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 77 tests, with 0 failures` (68 from the prior five plans + 4 LinkReachPill + 2 ShareMemberRow + 3 DocRow = 77)

- [ ] **Step 3: Commit**

```bash
git add DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift
git commit -m "Add LinkReachPill, ShareMemberRow, and DocRow to the component catalog"
```

## Self-Review Notes

- **Spec coverage:** Completes the design spec's "docs" component group — every component in the design spec's Component Inventory table (17 components across buttons/data-display/forms/ios/docs groups) now exists. This is the last DesignSystem-layer plan; the next plan moves to the Networking layer per the design spec's build sequence.
- **Placeholder scan:** No TBD/TODO.
- **Type consistency:** `LinkReach`, `LinkReachPillStyleHex`, `LinkReachPillStyleResolver`, `LinkReachPill`, `shareMemberDisplaySuffix`, `ShareMemberRow`, `docRowReachIndicatorSystemImage`, and `DocRow` are each defined once. `DocRow` correctly reuses `LinkReach` from Task 1 rather than redefining its own reach enum, and correctly reuses `DocIcon`/`IconButton` from earlier plans rather than reimplementing their styling.
- **Cross-file validation:** All code in this plan (all 3 components plus the catalog extension, including the `` `public` `` backtick keyword case and the nested-Button-avoidance pattern in `DocRow`) was compiled and test-run end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 77 tests, with 0 failures`.
