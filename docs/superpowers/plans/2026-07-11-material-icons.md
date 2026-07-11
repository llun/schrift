# Material Symbols icon system — 2026-07-11

**Goal:** Replace the app's SF Symbol icons with the exact Google Material Symbols
Outlined glyphs the design handoff specifies, so the app's iconography matches the
design pixel-for-pixel instead of approximating with SF Symbols.

## Why a bundled font

The handoff (`brand-iconography.html`) states the icon system is **Google Material
Symbols Outlined**, loaded from the Google Fonts CDN — "the exact set the codebase
ships." None of the handoff zips bundle the glyph vectors; they reference the font
by glyph name (69 glyphs, grouped by where each appears). SF Symbols has no exact
match for many Material glyphs (`share`, `account_tree`, …), which is what earlier
review rounds kept flagging.

Chosen approach (user-selected): **bundle the Material Symbols font**, mirroring what
the web design does — one asset, pixel-identical, trivially extensible, and it
supports the FILL axis for active/selected states.

## What shipped

- **Font asset:** `Schrift/Resources/Fonts/MaterialSymbolsOutlined-Icons.ttf` — the
  upstream Apache-2.0 variable font, subset with `pyftsubset` to the glyphs the app
  uses and instanced (`fontTools.varLib.instancer`) to pin `wght=400 GRAD=0 opsz=24`,
  keeping only the **FILL** axis (0 outlined / 1 filled). ~18KB. License text bundled
  alongside (`MaterialSymbols-LICENSE.txt`).
- **Glyph set:** the handoff's 69 + 8 further Material Symbols the iOS app needs that
  the mockups didn't surface (`horizontal_rule` divider, `link_off` remove-link,
  `format_h3`, `subject` for the "Text" block, `sync` for the update banner,
  `schedule` for version timestamps, and `check_box` / `check_box_outline_blank` for
  checklist items) = **77 glyphs**. To add another glyph you must re-subset the font
  (the codepoint must be in the `.ttf`), not just name it.
- **Registration:** `UIAppFonts` in `project.yml`'s `info.properties` (the
  `Generated/Info.plist` template) — arrays can't go through `INFOPLIST_KEY_*`, same
  constraint as `CFBundleLocalizations`.
- **`DesignSystem/Tokens/MaterialIcon.swift`:** `enum MaterialIcon: String` (raw value
  = Material glyph name) with each glyph's PUA `codepoint` and `character`. `public` is
  backticked (Swift keyword).
- **`DesignSystem/Components/MaterialSymbol.swift`:** `MaterialSymbol(_:size:fill:)`
  SwiftUI view (renders the glyph via the font; FILL set through a
  `kCTFontVariationAttribute` descriptor), plus `MaterialIcon.uiImage(pointSize:fill:)`
  for UIKit call sites (the block editor's link `UIMenu`).
- **Component API:** `IconButton(icon:)` and `NavBarAction(icon:)` now take a
  `MaterialIcon` (were `systemImage: String`); the `NavBar` back button uses
  `arrow_back_ios_new`.
- **Migration:** every `Image(systemName:)` / `systemImage:` / `UIImage(systemName:)`
  across the design system and feature screens replaced with the mapped `MaterialIcon`
  (mapping table lives in the icon-migration guide used to drive the change). Structs
  that stored an SF name string (`LinkReachPillStyleHex`, `SlashMenuItem`,
  `AppAppearance` icon, `DocRow` reach indicator) now store a `MaterialIcon`.

## Tests / verification

- `MaterialIconTests` — 77 cases, known codepoints, every glyph has a valid scalar,
  and the bundled font is registered (`UIFont(name:)` non-nil).
- A temporary snapshot probe rendered all 77 glyphs (outline + a few FILL=1) to confirm
  the font loads and the glyphs are correct, then the migrated screens light + dark.
- Full suite green; PR review loop; CI `Build & Test` green.

## Notes

- Zero third-party *code* dependencies preserved — this adds a bundled Apache-2.0 font
  asset (the design's own icon system), not an SPM/CocoaPods package.
- `MaterialSymbol` is `accessibilityHidden`; icon-only controls carry their own
  `.accessibilityLabel`.
