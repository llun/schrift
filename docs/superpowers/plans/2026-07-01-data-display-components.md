# Data Display Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the three "data-display" DesignSystem components — Avatar, AvatarGroup, DocIcon — each with pure, testable logic extracted from its View, and extend the existing component catalog to include them.

**Architecture:** Continues the pattern from the prior two plans, but these three components don't have variant/color branching like Button/IconButton/Badge — instead each has a different shape of pure logic worth isolating: Avatar has deterministic initials-extraction and hash-based color selection; AvatarGroup has an overflow/visible-count layout calculation; DocIcon has a simple emoji-vs-fallback-glyph decision. Each pure function is tested directly; the View is a thin consumer.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- Carried forward from the prior plan's final review: `ButtonStyleHex`/`IconButtonStyleHex` are now byte-identical (3-field: `backgroundHex: UInt32?`, `foregroundHex: UInt32`, `borderHex: UInt32?`). None of this plan's three components need that shape (Avatar/AvatarGroup/DocIcon have different logic shapes entirely), so no consolidation decision is needed yet — but do not introduce a fourth divergent copy of that specific 3-field shape without checking whether to share it.

## File Structure

```
DocsIOS/
└── DesignSystem/
    └── Components/
        ├── Avatar.swift                                  — avatarColorPalette, avatarInitials(for:), avatarColorHex(for:), Avatar view (Task 1)
        ├── AvatarGroup.swift                               — AvatarGroupLayout, avatarGroupLayout(names:max:), AvatarGroup view (Task 2)
        └── DocIcon.swift                                    — docIconDisplayText(emoji:), DocIcon view (Task 3)

DocsIOS/DesignSystemCatalog/
└── ComponentCatalogPreview.swift                            — MODIFY: add Avatars/Avatar Group/Doc Icons sections (Task 4)

DocsIOSTests/
└── DesignSystem/
    └── Components/
        ├── AvatarTests.swift                                — Task 1
        ├── AvatarGroupTests.swift                            — Task 2
        └── DocIconTests.swift                                 — Task 3
```

---

### Task 1: Avatar component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/Avatar.swift`
- Test: `DocsIOSTests/DesignSystem/Components/AvatarTests.swift`

**Interfaces:**
- Consumes: `Color(hex:)` (from `HexColor.swift`).
- Produces: `let avatarColorPalette: [UInt32]` (10-color deterministic palette), `func avatarInitials(for name: String) -> String`, `func avatarColorHex(for name: String) -> UInt32`, `struct Avatar: View { let name: String; var imageURL: URL? = nil; var size: CGFloat = 36 }` — `Avatar` consumed by Task 2's `AvatarGroup` and Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/AvatarTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class AvatarTests: XCTestCase {
    func testInitialsUsesFirstLetterOfFirstTwoWords() {
        XCTAssertEqual(avatarInitials(for: "Camille Moreau"), "CM")
        XCTAssertEqual(avatarInitials(for: "Alfredo Levin"), "AL")
    }

    func testInitialsHandlesSingleWord() {
        XCTAssertEqual(avatarInitials(for: "Cher"), "C")
    }

    func testInitialsHandlesEmptyName() {
        XCTAssertEqual(avatarInitials(for: ""), "")
    }

    func testColorHexIsDeterministicForSameName() {
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorHex(for: "Camille Moreau"))
    }

    func testColorHexMatchesExpectedPaletteIndex() {
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorPalette[4])
        XCTAssertEqual(avatarColorHex(for: "Amandine Salambo"), avatarColorPalette[2])
        XCTAssertEqual(avatarColorHex(for: "Desirae Dokidis"), avatarColorPalette[4])
        XCTAssertEqual(avatarColorHex(for: "Alfredo Levin"), avatarColorPalette[3])
    }

    func testColorHexFallsBackToFirstPaletteEntryForEmptyName() {
        XCTAssertEqual(avatarColorHex(for: ""), avatarColorPalette[0])
    }
}
```

Note: the expected palette indices above (4, 2, 4, 3) were computed by summing each character's Unicode scalar value and taking modulo 10 against the palette below — this is exactly what `avatarColorHex` does, so these are not arbitrary; they were verified by running this exact implementation before this plan was written.

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/AvatarTests`
Expected: FAIL — `cannot find 'avatarInitials' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/Avatar.swift`:
```swift
import SwiftUI

let avatarColorPalette: [UInt32] = [
    0xDA3B49, 0xB95D33, 0x8F7158, 0x9D6E00, 0x008948,
    0x4279B9, 0x00848F, 0x9961AF, 0xAA5F80, 0x75758A,
]

func avatarInitials(for name: String) -> String {
    let words = name.split(separator: " ").prefix(2)
    return words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
}

func avatarColorHex(for name: String) -> UInt32 {
    guard !name.isEmpty else { return avatarColorPalette[0] }
    let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return avatarColorPalette[sum % avatarColorPalette.count]
}

struct Avatar: View {
    let name: String
    var imageURL: URL? = nil
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsView
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initialsView: some View {
        Circle()
            .fill(Color(hex: avatarColorHex(for: name)))
            .overlay(
                Text(avatarInitials(for: name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceSM) {
        Avatar(name: "Camille Moreau")
        Avatar(name: "Alfredo Levin", size: 48)
        Avatar(name: "")
    }
    .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/AvatarTests`
Expected: PASS — `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/Avatar.swift DocsIOSTests/DesignSystem/Components/AvatarTests.swift
git commit -m "Add Avatar component"
```

---

### Task 2: AvatarGroup component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/AvatarGroup.swift`
- Test: `DocsIOSTests/DesignSystem/Components/AvatarGroupTests.swift`

**Interfaces:**
- Consumes: `Avatar` (from Task 1), `DocsColor.surfacePage`, `DocsColor.surfaceMuted`, `DocsColor.textSecondary`.
- Produces: `struct AvatarGroupLayout: Equatable { visibleNames: [String], overflowCount: Int }`, `func avatarGroupLayout(names: [String], max: Int) -> AvatarGroupLayout`, `struct AvatarGroup: View { let names: [String]; var size: CGFloat = 32; var max: Int = 4 }` — consumed by Task 4's catalog.

**Overflow convention** (worth stating explicitly since there's no single universal convention): when `names.count > max`, the group reserves the *last visible slot* for the overflow badge — it shows `max - 1` avatars plus one "+N" badge, so the total number of circles displayed never exceeds `max`. When `names.count <= max`, all names are shown with no badge.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/AvatarGroupTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class AvatarGroupTests: XCTestCase {
    func testFewerNamesThanMaxShowsAllWithNoOverflow() {
        let layout = avatarGroupLayout(names: ["A", "B"], max: 4)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B"], overflowCount: 0))
    }

    func testExactlyMaxNamesShowsAllWithNoOverflow() {
        let layout = avatarGroupLayout(names: ["A", "B", "C", "D"], max: 4)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B", "C", "D"], overflowCount: 0))
    }

    func testMoreNamesThanMaxReservesLastSlotForOverflowBadge() {
        let layout = avatarGroupLayout(names: ["A", "B", "C", "D", "E"], max: 3)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B"], overflowCount: 3))
    }

    func testLargeOverflowCount() {
        let layout = avatarGroupLayout(names: (1...10).map { "User \($0)" }, max: 3)
        XCTAssertEqual(layout.visibleNames.count, 2)
        XCTAssertEqual(layout.overflowCount, 8)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/AvatarGroupTests`
Expected: FAIL — `cannot find 'avatarGroupLayout' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/AvatarGroup.swift`:
```swift
import SwiftUI

struct AvatarGroupLayout: Equatable {
    let visibleNames: [String]
    let overflowCount: Int
}

func avatarGroupLayout(names: [String], max: Int) -> AvatarGroupLayout {
    if names.count <= max {
        return AvatarGroupLayout(visibleNames: names, overflowCount: 0)
    }
    let visibleCount = Swift.max(max - 1, 0)
    let visible = Array(names.prefix(visibleCount))
    let overflow = names.count - visibleCount
    return AvatarGroupLayout(visibleNames: visible, overflowCount: overflow)
}

struct AvatarGroup: View {
    let names: [String]
    var size: CGFloat = 32
    var max: Int = 4

    var body: some View {
        let layout = avatarGroupLayout(names: names, max: max)
        HStack(spacing: -size * 0.3) {
            ForEach(Array(layout.visibleNames.enumerated()), id: \.offset) { _, name in
                Avatar(name: name, size: size)
                    .overlay(Circle().stroke(DocsColor.surfacePage, lineWidth: 2))
            }
            if layout.overflowCount > 0 {
                Circle()
                    .fill(DocsColor.surfaceMuted)
                    .frame(width: size, height: size)
                    .overlay(
                        Text("+\(layout.overflowCount)")
                            .font(.system(size: size * 0.35, weight: .semibold))
                            .foregroundStyle(DocsColor.textSecondary)
                    )
                    .overlay(Circle().stroke(DocsColor.surfacePage, lineWidth: 2))
            }
        }
    }
}

#Preview {
    AvatarGroup(names: ["Camille Moreau", "Alfredo Levin", "Desirae Dokidis", "Amandine Salambo", "Charlie Saris"], max: 3)
        .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/AvatarGroupTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/AvatarGroup.swift DocsIOSTests/DesignSystem/Components/AvatarGroupTests.swift
git commit -m "Add AvatarGroup component"
```

---

### Task 3: DocIcon component

**Files:**
- Create: `DocsIOS/DesignSystem/Components/DocIcon.swift`
- Test: `DocsIOSTests/DesignSystem/Components/DocIconTests.swift`

**Interfaces:**
- Consumes: `DocsColor.brandFill`, `DocsColor.brandFillSoft`, `DocsColor.surfacePage`, `DocsRadius.sm`.
- Produces: `func docIconDisplayText(emoji: String?) -> String?`, `struct DocIcon: View { var emoji: String? = nil; var size: CGFloat = 24; var tinted: Bool = false; var pinned: Bool = false }` — consumed by Task 4's catalog.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/DesignSystem/Components/DocIconTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocIconTests: XCTestCase {
    func testCustomEmojiIsDisplayed() {
        XCTAssertEqual(docIconDisplayText(emoji: "📄"), "📄")
    }

    func testNilEmojiFallsBackToDefaultGlyph() {
        XCTAssertNil(docIconDisplayText(emoji: nil))
    }

    func testEmptyEmojiFallsBackToDefaultGlyph() {
        XCTAssertNil(docIconDisplayText(emoji: ""))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocIconTests`
Expected: FAIL — `cannot find 'docIconDisplayText' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/DesignSystem/Components/DocIcon.swift`:
```swift
import SwiftUI

func docIconDisplayText(emoji: String?) -> String? {
    guard let emoji, !emoji.isEmpty else { return nil }
    return emoji
}

struct DocIcon: View {
    var emoji: String? = nil
    var size: CGFloat = 24
    var tinted: Bool = false
    var pinned: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let displayEmoji = docIconDisplayText(emoji: emoji) {
                    Text(displayEmoji)
                        .font(.system(size: size * 0.7))
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: size * 0.55))
                        .foregroundStyle(DocsColor.brandFill)
                }
            }
            .frame(width: size, height: size)
            .background(tinted ? DocsColor.brandFillSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))

            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(DocsColor.brandFill)
                    .background(Circle().fill(DocsColor.surfacePage).frame(width: size * 0.4, height: size * 0.4))
                    .offset(x: size * 0.15, y: size * 0.15)
            }
        }
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceSM) {
        DocIcon(emoji: "📄")
        DocIcon(emoji: nil, tinted: true)
        DocIcon(emoji: "📌", pinned: true)
    }
    .padding()
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocIconTests`
Expected: PASS — `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/DesignSystem/Components/DocIcon.swift DocsIOSTests/DesignSystem/Components/DocIconTests.swift
git commit -m "Add DocIcon component"
```

---

### Task 4: Extend the component catalog

**Files:**
- Modify: `DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`

**Interfaces:**
- Consumes: `Avatar`, `AvatarGroup`, `DocIcon` (Tasks 1-3).
- Produces: no change to `ComponentCatalogPreview`'s own signature (still a `#Preview`-only `View`, no parameters).

- [ ] **Step 1: Add three new catalog sections**

In `DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift`, find this exact block:

```swift
                catalogSection("Switch") {
                    Switch(isOn: $isSwitchOn)
                }
            }
```

Replace it with:

```swift
                catalogSection("Switch") {
                    Switch(isOn: $isSwitchOn)
                }

                catalogSection("Avatars") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        Avatar(name: "Camille Moreau")
                        Avatar(name: "Alfredo Levin", size: 48)
                        Avatar(name: "")
                    }
                }

                catalogSection("Avatar Group") {
                    AvatarGroup(names: ["Camille Moreau", "Alfredo Levin", "Desirae Dokidis", "Amandine Salambo", "Charlie Saris"], max: 3)
                }

                catalogSection("Doc Icons") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        DocIcon(emoji: "📄")
                        DocIcon(emoji: nil, tinted: true)
                        DocIcon(emoji: "📌", pinned: true)
                    }
                }
            }
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 51 tests, with 0 failures` (38 from the prior two plans + 6 Avatar + 4 AvatarGroup + 3 DocIcon = 51)

- [ ] **Step 3: Commit**

```bash
git add DocsIOS/DesignSystemCatalog/ComponentCatalogPreview.swift
git commit -m "Add Avatar, AvatarGroup, and DocIcon to the component catalog"
```

## Self-Review Notes

- **Spec coverage:** Covers the design spec's "data-display" component group (Avatar, AvatarGroup, DocIcon) — Badge was already covered in the prior plan despite also being in that group. Remaining components (SearchField, SegmentedControl, TextField from "forms"; NavBar, TabBar, ListRow, ListSection from "ios"; DocRow, LinkReachPill, ShareMemberRow from "docs") are deferred to subsequent plans.
- **Placeholder scan:** No TBD/TODO.
- **Type consistency:** `Avatar`, `AvatarGroupLayout`, `avatarGroupLayout`, and `DocIcon` are each defined once and referenced identically across all tasks. `AvatarGroup` consumes `Avatar` by exact name/parameter match (`Avatar(name:size:)`).
- **Cross-file validation:** All code in this plan (all 3 components plus the catalog extension) was compiled and test-run end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 51 tests, with 0 failures`. The avatar color palette indices in Task 1's test file were computed from the actual hashing implementation, not guessed.
