# iOS design update — tab pages, dark mode, localization

> **Living design document.** This covers a design-system refresh handed off from
> Claude Design (`schrift-ios-design-system.zip`) — the adaptive dark theme,
> in-app localization, layout-fidelity work, and read-only version history — plus
> two new user-facing features, all of which shipped. Kept current with the app;
> update it in place when behavior changes. See also
> [`architecture.md`](architecture.md) and [`CLAUDE.md`](../CLAUDE.md).

> **Revised: 2026-07-11 (post-implementation).** §3 and §5.7 below plan for
> **English and French** as primary/reviewed translations. As shipped, only
> **English** is the reviewed source: `Strings+fr.swift` carries the same
> "AI-generated translation — pending native-speaker review" header as the
> other eight non-English tables. Read every "English/French are primary"
> phrasing below as "English is primary" for the shipped state; the §5.7 body
> is kept as the original plan of record.

> **Revised: 2026-07-12 (Options sheet → flat menu).** The document **Options
> sheet** was redesigned to the handoff's updated `OptionsSheet`: a **flat,
> boxless, dividerless** list under a `SheetHeader` (inline `title2` title + a
> circular close button), replacing the grouped `ListSection` cards + `Done`
> nav bar. This **supersedes** the "keep dividers on the Options/Share menus"
> note in §8.3 and the "keep all rows / no presence banner / no close chrome"
> plan in §9.1: the sheet now shows only **Pin · Copy link · Share · Version
> history · Delete** (matching the handoff exactly), and **Copy as Markdown**
> and **Duplicate** — plus the `duplicateDocument` endpoint that backed the
> latter — were removed. The new `SheetHeader` component + the flat-sheet
> pattern are documented in [`CLAUDE.md`](../CLAUDE.md); the Share and
> Version-history sheets still use grouped separators and are unchanged.

## 1. Goals

1. **Update all four tab pages** (Schrift/Home, Search, Shared, Profile) to match
   the handoff design and the four provided screenshots — including **layout
   fidelity** (header/nav-bar spacing, section gaps, grouped-list dividers, sheet
   scroll & detents), not just components and colors (see §8, Part 5).
2. **Appearance control** — a functional Light / Dark / System toggle in Profile,
   backed by a **complete adaptive dark theme** for the whole app.
3. **Language control** — a functional in-app language picker that **switches the
   app UI live** (no relaunch), covering **11 languages**, with the whole app
   localized.
4. **Version history** — the handoff's version-history sheet + its "Version
   history" entry in the Options sheet, both absent from the current app (§9).

## 2. Context (the audit)

The app was already built from an **earlier version of this same design system**:
the same `DocsColor`/`DocsColorHex` tokens and the same components
(`NavBar`, `TabBar`, `SegmentedControl`, `DocRow`, `ListRow`, `ListSection`,
`Badge`, `SearchField`, `Switch`, …). Consequently:

- **Home, Search, Shared already match** the handoff structurally, given the real
  Docs API. The design's per-row **emoji chips** and **collaborator-avatar
  stacks** come from the prototype's *fake* data. The real list API
  (`Document`) carries **no per-doc emoji and no member list**, so the app
  renders the default doc icon + chevron. We keep that — inventing emoji/avatars
  would be fabricating data. We match the design *language*, not the mock's fake
  content.
- **Profile** carries the real structural deltas, and hosts the two new features.

So "update all tab pages" is delivered by (a) two **app-wide** changes — the dark
theme and localization make every screen adaptive and translated automatically —
and (b) a focused **Profile** restructure. Home/Search/Shared layouts are **not**
otherwise churned.

## 3. Non-goals / scope boundaries

- **No fabricated per-row emoji or collaborator avatars** on the document lists —
  not in the API.
- **Document content is never translated.** Server-authored titles/body render as
  authored. Localization covers app **chrome** only.
- **Language is a local app-UI preference.** Selecting a language does **not**
  PATCH the server user's `language` (that governs server emails / rendered
  content and would be a surprising side effect). The server `language` field and
  `CurrentUser.languageLabel` are decoupled from the app UI language.
- **Translations beyond English/French are AI-generated** and must be marked as
  needing native-speaker review (see §5.7).
- No new third-party dependencies; no telemetry; no weakening of the security
  posture (per `CLAUDE.md` Safety).

---

## 4. Part 1 — Full adaptive dark theme

The handoff ships **only a light palette**. We author a complete dark palette
derived from the Cunningham gray/brand ramps the tokens already come from.

### 4.1 Token architecture

- Add `DocsColorHexDark` — a caseless `enum` of `static let <name>: UInt32`, one
  **dark** counterpart for every token in `DocsColorHex` (same names).
- Add to `HexColor.swift`:
  ```swift
  extension Color {
      /// Adaptive color: resolves `lightHex` in light mode, `darkHex` in dark.
      init(lightHex: UInt32, darkHex: UInt32, opacity: Double = 1)
  }
  ```
  Backed by `UIColor(dynamicProvider:)` reading
  `traitCollection.userInterfaceStyle`. `hexColorComponents(_:)` stays the pure,
  tested primitive; the dynamic provider reuses it.
- `DocsColor.*` become **adaptive**: each token pairs its `DocsColorHex.<name>`
  with `DocsColorHexDark.<name>`. Because nearly the entire app consumes
  `DocsColor.*` directly (`ListRow`, `NavBar`, `TabBar`, `SearchField`, `DocRow`,
  every screen), this delivers dark mode with **zero call-site changes** there.

### 4.2 Style-resolver components need explicit dark values

`Badge`, `Button`, `IconButton`, `TextField`, `LinkReachPill` return **raw hex**
from a resolver and render via `Color(hex:)`. A global hex→hex map is impossible
(e.g. `#FFFFFF` is `surfacePage` **and** `surfaceRaised` **and** `textOnBrand`,
which need *different* darks; `#E2E2EA` is `borderDefault` **and** Badge's neutral
bg). So each `*StyleHex` struct gains **light + dark** raw fields:

```swift
struct BadgeStyleHex: Equatable {
    let backgroundLightHex: UInt32
    let backgroundDarkHex: UInt32
    let foregroundLightHex: UInt32
    let foregroundDarkHex: UInt32
}
```

The resolver fills both (light from `DocsColorHex`, dark from `DocsColorHexDark`);
the view renders `Color(lightHex:darkHex:)`. This keeps the convention — resolver
returns `Equatable` raw values, view converts to `Color` at render — and stays
unit-testable without SwiftUI. Existing resolver tests extend to assert the dark
fields too.

`InlineTextStyle` (editor link color) and `listRowTitleColorHex` (ListRow
destructive/primary) also resolve raw hex → route them through adaptive tokens /
dark counterparts. `Avatar` accent backgrounds keep their hue in dark (white
initials read on both); the **accent palette is identical** in dark.

### 4.3 The dark palette (authoritative values)

| Token | Light | Dark |
|---|---|---|
| surfacePage | `FFFFFF` | `16161C` |
| surfaceSunken | `F8F8F9` | `0E0E13` |
| surfaceRaised | `FFFFFF` | `202028` |
| surfaceMuted | `F0F0F3` | `2A2A34` |
| surfaceScrim | `1B1B23`@45% | `000000`@45% |
| textPrimary | `25252F` | `F4F4F6` |
| textSecondary | `5D5D70` | `B4B4C6` |
| textTertiary | `69697D` | `9494AA` |
| textDisabled | `A9A9BF` | `5A5A6B` |
| textOnBrand | `FFFFFF` | `FFFFFF` |
| brandFill | `5E5CD0` | `7B79E8` |
| brandFillHover | `4844AD` | `8F8DF2` |
| brandFillSoft | `DDE2F5` | `2C2C50` |
| brandFillSubtle | `EEF1FA` | `1E1E33` |
| textBrand | `3E3B98` | `A9ADF9` |
| textBrandSecondary | `534FC2` | `9195FC` |
| brandLogo | `4F46E5` | `7C79F2` |
| borderDefault | `E2E2EA` | `2E2E38` |
| borderStrong | `D3D4E0` | `3C3C48` |
| borderFocus | `8184FC` | `9CA0FF` |
| info | `0069CF` | `5AA9F0` |
| success | `027B3E` | `4FB878` |
| warning | `BC4200` | `E6915F` |
| danger | `D7010E` | `F4796E` |
| infoSoft | `D5E4F3` | `12283F` |
| successSoft | `CFE4D4` | `12301E` |
| warningSoft | `F1E0D3` | `35220F` |
| dangerSoft | `F4DFD9` | `3A1A17` |
| dangerStrong | `C00100` | `F4796E` |
| info650 | `0D4EAA` | `5AA9F0` |
| success650 | `006024` | `4FB878` |
| warning650 | `9E2300` | `E6915F` |
| gray050 | `F0F0F3` | `202028` |
| gray100 | `E2E2EA` | `2E2E38` |
| gray300 | `A9A9BF` | `565663` |
| gray350 | `9C9CB2` | `6C6C80` |
| gray450 | `828297` | `8A8A9E` |
| gray600 | `5D5D70` | `B7B7CB` |
| accent* (all) | (unchanged) | (unchanged) |

Rationale: surfaces form an elevation ladder in dark
(sunken `0E` < page `16` < raised `20` < muted `2A`); text inverts to near-white
ramps; brand/link inks **lighten** for contrast on dark; feedback foregrounds
lighten while their soft backgrounds darken; the neutral badge foreground
(`gray600`) flips to a light gray because its chip (`gray100`) is now dark.

### 4.4 Applying the appearance

- `enum AppAppearance: String, CaseIterable, Sendable { case system, light, dark }`
  with `colorScheme: ColorScheme?` (`nil` for `.system`) and a localized label.
- `@MainActor @Observable final class AppearanceStore` — persists
  `schrift.appearance` (UserDefaults, `schrift.` preference prefix), injected via
  `.environment`, default `.system`. Takes `userDefaults: UserDefaults = .standard`.
- Applied once at the app root (`RootView`/`SchriftApp`) via
  `.preferredColorScheme(appearanceStore.selected.colorScheme)`.

### 4.5 Tests (Part 1)

- `DocsColorHexTests` — assert the dark raw value for every token (extends the
  existing light assertions).
- Resolver tests (`BadgeStyleResolverTests`, `ButtonStyleResolverTests`,
  `IconButtonStyleResolverTests`, `TextFieldStyleResolverTests`,
  `LinkReachPillStyleResolverTests`) — assert both light and dark fields.
- `AppearanceStoreTests` — default `.system`; persistence round-trip;
  `colorScheme` mapping (isolated `UserDefaults(suiteName:)`).

---

## 5. Part 2 — Localization (full app, 11 languages, live switching)

### 5.1 Languages

| Enum case | Code | Autonym |
|---|---|---|
| english | `en` | English |
| french | `fr` | Français |
| spanish | `es` | Español |
| german | `de` | Deutsch |
| italian | `it` | Italiano |
| dutch | `nl` | Nederlands |
| portuguese | `pt` | Português |
| slovene | `sl` | Slovenščina |
| thai | `th` | ไทย |
| chineseSimplified | `zh-Hans` | 简体中文 |
| chineseTraditional | `zh-Hant` | 繁體中文 |

`enum AppLanguage: String, CaseIterable, Identifiable, Sendable` — `code`,
`autonym`, `locale: Locale`. Pure value type, no concurrency annotations.

### 5.2 Catalog — in-code, not `.lproj`

Translations live in Swift, not `.lproj`/String Catalog. This is the on-brand
choice for this repo (hand-written, pure value code, zero XcodeGen resource
friction), makes **live switching trivial**, and makes **completeness testable**.

- `enum L10n` namespace. Keys are an enum:
  `enum L10n.Key: String, CaseIterable { case home_title = "home.title", … }`.
  Centralizing keys enables the completeness test and prevents typos.
- One table per language: `enum Strings_en { static let table: [L10n.Key: String] }`
  … `Strings_zhHant`, each in its own file (`Strings+en.swift` …
  `Strings+zhHant.swift`) under `Schrift/Core/Localization/`.
- Resolution: `table[language]?[key] ?? Strings_en.table[key] ?? key.rawValue`
  (English is the guaranteed fallback).

### 5.3 LocalizationStore + live switching

- `@MainActor @Observable final class LocalizationStore` — persists
  `schrift.language`; injected via `.environment`; takes
  `userDefaults: UserDefaults = .standard`.
- Resolution API:
  - `func string(_ key: L10n.Key) -> String`
  - `func string(_ key: L10n.Key, _ args: CVarArg...) -> String` (uses
    `String(format:locale:...)` with the current locale)
  - plural helper (see §5.5)
- **Live re-render:** `string(_:)` reads `self.language`; called inside a view
  `body`, `@Observable` records the dependency, so changing `language`
  re-renders. Each screen also reads the store from
  `@Environment(LocalizationStore.self)`, so its whole body re-evaluates.
- Root sets `.environment(\.locale, store.locale)` so
  `RelativeDateTimeFormatter`/date formatting re-localizes live too
  (`documentRowDate` takes a `Locale`).
- Ergonomics: a thin helper so call sites stay terse — a free function
  `Text.localized` alternative or a small wrapper `L(key)` bound to the
  environment store. Views read the store once (`@Environment`) and resolve via
  it.

### 5.4 Default language selection

First launch only: pick the best match of `Locale.preferredLanguages` against the
11 supported codes (script-aware for `zh-Hans`/`zh-Hant`), else English.
The user's explicit choice persists thereafter and always wins.

### 5.5 Plurals

Explicit `.one` / `.other` key variants (plus Slovene-only `.two` / `.few`) and a
small per-language plural selector (`enum PluralRule`): `zh-Hans`, `zh-Hant`, `th`
are **other-only**; **Slovene** uses the full CLDR `one`/`two`/`few`/`other` set
(including the dual — `i%100`: 1→one, 2→two, 3–4→few, else other); the rest are
one/other. `plural(_:one:other:two:few:)` takes `two`/`few` as optional keys that
only Slovene resolves and otherwise fall back to `other`, so only the Slovene table
defines those forms. Applies to the handful of counted strings (search results
count, "N documents", "Shared with N people").

### 5.6 String extraction inventory

Every user-facing literal becomes an `L10n.Key`, across: Connect/login
(`ConnectView`, `ServerURLInput`, `WebLoginView`, `ReauthenticationSheetView`),
Home/`DocumentListView`, Search, Shared, Profile, Options sheet, Share sheet,
Version history, Editor chrome (`EditorScreen`, save bar, slash menu labels,
formatting bar accessibility, link editor), `OfflineBanner`, and all friendly
error strings (`"Couldn't … Please try again."`). The plan will produce the
exhaustive key list; the completeness test guarantees no key is missing in any
language.

### 5.7 Translation generation

Translations are produced with a multi-agent workflow — one translator + one QA
reviewer **per language** over the canonical English key→value map — for coverage
and consistency. **English and French** are treated as primary; the other eight
are **AI-generated and flagged in the spec/PR as needing native-speaker review.**
Terminology is pinned to a short glossary (Schrift, document/doc, server,
Pinned/Shared, sign out) so it stays consistent across screens.

### 5.8 Tests (Part 2)

- `AppLanguageTests` — codes, autonyms, default-selection matching (incl. Chinese
  script variants).
- `LocalizationStoreTests` — resolution, English fallback for a missing key,
  persistence round-trip, format-arg substitution, locale exposure (isolated
  `UserDefaults`).
- `StringsCompletenessTests` — **every** `L10n.Key` present in **every** language
  table; and placeholder/format-specifier parity across languages (same `%@`/`%d`
  count per key).
- `PluralTests` — rule selection per language.

---

## 6. Part 3 — Profile restructure & the two pickers

Final Profile structure (matches the screenshot exactly):

1. **USER** — one static row: `account_circle` + email (no chevron, not tappable).
2. **PREFERENCES** (footer: work-offline explainer) —
   - **Appearance** (`moon`) → value = current appearance → opens Appearance sheet.
   - **Language** (`translate`) → value = current language autonym → opens
     Language sheet.
   - **Notifications** (`bell`) → `Switch` (`schrift.notifications`).
   - **Work offline** (`icloud.slash`) → `Switch` (`schrift.workOffline`).
3. **SERVER** (footer: web-session explainer) —
   - Server row: `server.rack` + host + `Connected`/`Offline` `Badge` + chevron →
     disconnect confirmation.
   - **Server version** row: `deployed_code`-equivalent + version (from `GET
     /config/`, §7). Hidden if unavailable.
4. **ABOUT** — `Version` row (app short version string).
5. **Sign out** — destructive row.

**Deletions (confirmed with user):**
- The tappable **account banner** (avatar + name + email) → replaced by the static
  email row.
- **`AccountScreen.swift`** and its route: remove the `HomeRoute` enum (its only
  case was `.account`), the `.navigationDestination(for: HomeRoute.self)`, and
  the `onOpenAccount` param/closure on `ProfileScreen`/`HomeView`.
  `ProfileViewModel` is retained (supplies the email).
- The **Support** section (Help & feedback, Privacy policy) → replaced by the
  ABOUT → Version row.

**Pickers** (match the handoff `Sheet` + `OptionPicker`: grabber, title, close,
option rows with leading icon + title + trailing checkmark on the current
choice; selecting closes):
- **Appearance sheet** — Light (`sun.max`), Dark (`moon`), System
  (`circle.lefthalf.filled`). Writes `AppearanceStore`.
- **Language sheet** — 11 languages by autonym, checkmark on current. Writes
  `LocalizationStore`; the whole app re-renders live.
- Presented with SwiftUI `.sheet` + `.presentationDetents([.medium])` (matching
  the app's existing sheet convention), each a small reusable view
  (`AppearancePickerSheet`, `LanguagePickerSheet`) with a pure
  option-list body so it is previewable and testable.

**iPad:** `HomeSplitView` gets the same appearance/language behavior via the
shared environment stores; it does not reference the account route (verified), so
no split-view route cleanup is needed beyond the shared injection.

### 6.1 Tests (Part 3)

- `ProfileScreen` option-model tests (pure): appearance options + icons; language
  options; checkmark selection logic.
- Snapshot-free assertions on the picker view models / pure helpers (no UI
  snapshotting — consistent with the repo).

---

## 7. Part 4 — Server config endpoint

- `struct ServerConfig: Codable, Equatable, Sendable { var version: String? }`
  decoding `RELEASE_VERSION` (defensive `decodeIfPresent`).
- `extension DocsAPIClient { func serverConfig() async throws -> ServerConfig }`
  → `GET config/` (relative, trailing slash, via the shared `get` primitive;
  path resolves under the client's `/api/v1.0/` base — no leading slash).
- `ProfileViewModel` loads it best-effort (tolerate failure → hide the row), same
  pattern as `currentUser()`.
- Tests: `ServerConfigClientTests` (method `GET`, path `config/`, decode; missing
  version tolerated) via `MockURLProtocol`.

---

## 8. Part 5 — Layout & interaction fidelity

Matching the handoff is as much about spacing, scroll behavior and list styling
as it is about tokens. All numbers below are lifted from the handoff JSX (the
authoritative source per the bundle README) and the `tokens/spacing.css` /
`radius.css` scales. The four inline screenshots are renders of this same JSX, so
JSX and screenshots agree; where a value differs from the current app it is a
fix.

### 8.1 Header / nav-bar spacing (all four tabs)

The current `NavBar` always renders a fixed **44pt top row**, even in large-title
mode with no back button and no leading view. Result: Search/Shared/Profile carry
~44pt of dead space above the large title, and Home's "+" sits in that empty bar
instead of beside the title. The handoff collapses that row and lays the large
title out compactly. Target (from `NavBar.jsx`):

- **Collapse the top row** when `largeTitle && back == nil && leading == nil`
  (all four tabs): it contributes **0** height. Keep the 44pt row only when a
  back button or leading view exists (standard mode is unchanged).
- **Trailing actions render inline with the large title**, right-aligned, in the
  same row — not in a bar above it. Gap **12pt** between the title and the
  trailing group; **2pt** within the group. (Home's "+" `IconButton`; the other
  three tabs have none.)
- Large-title block padding **`10 / 16 / 10`** (top / sides / bottom) when there
  is no back/leading; **`2 / 16 / 10`** when there is. Title
  `DocsFont.largeTitle` (34pt) with `DocsTracking.tight`. Subtitle
  `DocsFont.subhead`, `textTertiary`, **2pt** above it.
- **No bottom border** on the tab nav bars: all four screens pass `border={false}`
  in the handoff, so `showsBorder: false`. (The app's **solid-white** bar fill is
  a deliberate, documented anti-seam choice and is *kept* — we do **not**
  reintroduce the frosted-glass translucency.)
- `NavBar` gains a pure helper `navBarShowsTopRow(largeTitle:hasBack:hasLeading:)`
  so the collapse rule is unit-testable, and a `largeTitleTrailingActions` path
  so trailing actions move into the title row in large-title mode.

The two large-title-with-back users (`AccountScreen`) are being removed (§6), so
the only large-title screens after this change are the four tabs — all
back-less — and they all get the compact header.

### 8.2 Screen content spacing

Already matches the handoff and is preserved: scroll-content inset **`4 / 16 /
16`**; **12pt** below the search field; **18pt** below the segmented control;
section header padding **`0 / 8 / 4`**; grouped-list side gutter **20pt**
(`gutterGrouped`). Any ≤2pt drift found while implementing is aligned to these
values; no structural change.

### 8.3 Grouped lists & dividers (the "no divider between items" fix)

The handoff `ListSection` defaults to `divided={true}` (a 1pt `border-default`
hairline between rows, inset **52pt** when the row has a leading icon, else
**16pt**), but **every multi-row section on the tab screens turns it off**:

- **Shared** documents list — `divided={false}`. The current app inserts a
  `ProfileRowDivider()` between every shared row → **remove them** (flat rows).
- **Profile** — Preferences and Server sections are `divided={false}` in the
  handoff → **remove** their inter-row `ProfileRowDivider()`s. (Single-row
  sections — User, About, Sign out — have no dividers regardless.)
- **Home** document sections are already flat (correct — keep).

So after this change no tab screen draws inter-row hairlines. This is a
deliberate match to the design system and the screenshots; it is reversible by a
single `divided:` flag if a later review prefers iOS-style separators.
`ListSection` card styling (surface-raised, 1pt border, `radius-lg`, header
padding `0/16/6`, footer padding `6/16/0`) already matches and is preserved. The
`ProfileRowDivider` component stays for the Share / Version-history sheets, where
grouped separators are appropriate. (The **Options sheet** was later flattened to
a boxless, dividerless menu — see the 2026-07-12 amendment at the top and the
flat-sheet pattern in [`CLAUDE.md`](../CLAUDE.md).)

### 8.4 Sheets & scrolling (the "share dialog scroll" fix)

Handoff sheets (`chrome.jsx` `Sheet`) are **bottom sheets** with a grabber, an
inline title, a scrollable body bounded by a **detent**, and bottom padding for
the home indicator. The current Share / Options / Version sheets present as
full-height `.sheet`s (no detent, no drag indicator) wrapping a `NavigationStack`
+ "Done", with all content in one scroll view — so a long member list pushes the
primary **Copy link** action below the fold.

Target:

- Present Share, Options, and Version-history sheets with **`.presentationDetents`**
  + **`.presentationDragIndicator(.visible)`** (the grabber). Detents mirror the
  handoff: Share ≈ `.large`, Options ≈ `.medium`, Versions ≈ `.medium`
  (`.fraction` used where a closer match is wanted). This is SwiftUI-native — no
  hand-built grabber/close chrome — matching the handoff's *behavior* while
  staying on-platform.
- **Share sheet keeps its primary action reachable.** The invite field stays
  pinned at the top; the **members list scrolls in a bounded region**
  (`maxHeight` ≈ 208pt like the handoff, via an inner scroll / `.frame(maxHeight:)`),
  so "Link parameters" and the **Copy link** pill remain visible without
  scrolling the whole sheet. This is the concrete scroll fix.
- Sheet bodies respect the **bottom safe area** (home indicator) so no control
  sits under the indicator.
- The new **Appearance** and **Language** picker sheets follow the same pattern:
  drag indicator + inline title + scrollable option list, with a **fitted**
  detent for Appearance (3 rows) and `.medium` for Language (10 rows, scrolls).

### 8.5 Tab bar

`TabBar` height 49pt + home-indicator safe area already matches the handoff and is
unchanged; it inherits the adaptive dark tokens automatically.

### 8.6 Layout tests

Layout is verified primarily via the component `#Preview` catalogs (light **and**
dark) and a manual run. Pure helpers are unit-tested where they exist:
`navBarShowsTopRow(largeTitle:hasBack:hasLeading:)`, the divider leading-inset
rule (`52` with a leading icon, else `16`), and the sheet detent/`maxHeight`
constants.

## 9. Part 6 — Version history

The handoff includes a **Version History** sheet (`VersionHistorySheet.jsx`),
opened from a **"Version history"** row in the Options sheet — the current app has
**neither**. This part adds both.

### 9.1 UI

- **Options sheet** gains a `ListRow` — `clock.arrow.circlepath` + "Version
  history" + chevron — that presents the version-history sheet. *(Superseded by
  the 2026-07-12 amendment: the Options sheet was later flattened to the
  handoff's `OptionsSheet` — a boxless, dividerless list of only Pin, Copy link,
  Share, Version history, and Delete; Copy as Markdown and Duplicate were
  removed. The "N people editing" presence banner is still **not** added — it
  needs live-presence data the app doesn't have, same call as the row emojis /
  avatars in §2.)*
- **Version-history sheet** matches `VersionHistorySheet.jsx`: a bottom sheet
  (detent + drag indicator, per §8.4) whose **only scrolling region is the
  version list** (`maxHeight` ≈ 340pt); a flat, chronological list, newest first;
  each row shows the timestamp (`DocsFont.body`), the newest is labeled **"Current
  version"** (`success`), older rows carry a **"Restore"** pill
  (`brandFillSoft` bg / `textBrand`, pill radius). Fully localized + dark-adaptive
  like everything else.

### 9.2 Data — versions list (the guaranteed deliverable)

- `struct DocumentVersion: Codable, Equatable, Sendable, Identifiable`
  — `id: String` (the S3 `version_id`), `lastModified: Date`, `isCurrent: Bool`
  (`decodeIfPresent ?? false`).
- `extension DocsAPIClient { func documentVersions(documentID:) async throws ->
  [DocumentVersion] }` → `GET documents/{id}/versions/`, decoding the Docs
  backend's `{ versions: [...] , … }` wrapper. Trailing slash, lowercase UUID,
  via the shared `get` primitive.
- A `VersionHistoryViewModel` (`@MainActor @Observable`) loads best-effort,
  friendly `errorMessage` on failure, `isLoading` gate. Timestamps render with
  the current locale (relative or absolute per the design's `when` style).
- Tests: `DocumentVersionsClientTests` (method/path/decode incl. `is_current`,
  empty list) via `MockURLProtocol`; VM load + error-path tests.

### 9.3 Restore — verify-gated, funneled through the save path

**Constraint:** the app has a Yjs **encoder only, no decoder**, and it reads
current content as **server-rendered markdown** (`formatted-content/`). A
version's stored `content` is **base64 Yjs**, which the app cannot turn into
markdown. So restore cannot go through the normal markdown → encode save.

**Mechanism (feasible without a decoder):** re-PATCH the version's *own stored
Yjs bytes* back as the current content — the app never has to understand them:

1. Serialize with `DocumentSaveCoordinator`: require no unsaved local edits
   (flush/settle any in-flight save first) so restore can't race a save or be
   clobbered by one.
2. `GET documents/{id}/versions/{version_id}/` → the version's base64 content.
3. `PATCH documents/{id}/content/` with those exact bytes (the same primitive the
   save uses).
4. Trigger the editor's existing coordinator-aware **reload** (`refresh()`), so
   the restored content re-renders from `formatted-content/` and the content
   cache updates through the normal revalidation path (respecting
   `mayPredateSave`).

This reuses the safe, tested save/reload plumbing and never fabricates Yjs.

**Verification gate:** the exact `versions/` and `versions/{id}/` response shapes
must be confirmed **on-device against `docs.llun.dev`** (the Simulator's HTTP/3
quirk notwithstanding) before restore ships, because they are not exercisable
from unit tests alone. If the retrieve endpoint does **not** return usable
content bytes, restore is **not shipped this pass**: the sheet ships **read-only**
(list + "Current version", no Restore pill), and restore-on-the-web is offered
instead — the list is valuable on its own and carries no risk to the
full-overwrite save. This split keeps §9.2 unconditional and isolates the only
uncertain piece.

- Tests: `restoreDocumentVersion` client test (fetch-then-PATCH sequence, order
  pinned via `RequestRecorder`); VM restore success/failure; a regression test
  that restore is blocked while `isDirty` / a save is in flight.

## 10. Cross-cutting integration

- **Injection point:** `SchriftApp`/`RootView` own `AppearanceStore` +
  `LocalizationStore` (as `@State`), inject both via `.environment`, apply
  `.preferredColorScheme` and `.environment(\.locale,)` at the root so **every**
  screen (Connect, Home tabs, Editor, sheets, iPad split) inherits them.
- **project.yml:** no new bundled resources (in-code catalog). Add
  `CFBundleLocalizations` (the 10 codes) + `CFBundleDevelopmentRegion = en` via
  `INFOPLIST_KEY_*` so the OS advertises supported languages; regenerate with
  `xcodegen generate`. (Functionality does not depend on this — the custom
  resolver does the work — but it keeps Settings/App Store metadata honest.)
- **Formatting/CI:** `swift format --recursive --in-place Schrift SchriftTests`;
  full suite green on iPhone simulator; docs updated in the same change.

## 11. Docs to update in this change

- **`CLAUDE.md`** — new conventions: adaptive color tokens
  (`DocsColorHexDark` + `Color(lightHex:darkHex:)`), the resolver light+dark
  contract, the `AppearanceStore`/`LocalizationStore` injection rule, the in-code
  localization catalog + completeness test, the "language is a local app
  preference, content is never translated" rule, and the layout rules from §8
  (large-title header collapses its top row and inlines trailing actions;
  tab sections are dividerless; sheets use detents + a bounded member list).
- **`README.md`** — mention dark mode + language support.
- **Living doc** [`architecture.md`](architecture.md) — note dark mode +
  localization in the design summary.

## 12. Risks & mitigations

- **Translation quality** (Thai/Chinese/etc. are AI-generated) → flagged for
  native review; completeness + placeholder-parity tests prevent structural
  breakage; English fallback prevents blank UI.
- **Dark palette taste** → validated via component `#Preview` catalogs in both
  schemes; values are centralized so a later tweak is one table.
- **Live-switch reactivity** relying on `@Observable` dependency tracking → the
  store is read from `@Environment` at each screen root, guaranteeing body
  re-evaluation; covered by manual verification and store tests.
- **Big diff** (every string touched) → landed test-first, screen by screen; the
  translation fan-out is mechanical over a frozen English key set.
- **Shared `NavBar` change** touches every large-title screen → after §6 only the
  four back-less tabs remain large-title, so the collapse rule applies uniformly;
  the standard (non-large, with-back) path is left untouched and its `#Preview`
  guards it.
- **Dividerless tab sections may read as under-separated** to some eyes → it is a
  faithful match to the handoff and reversible via one `divided:` flag; validated
  against the screenshots in both color schemes.
- **Version restore touches the safety-critical save path** and depends on
  unverified backend response shapes → the versions **list** ships unconditionally
  (no save-path risk); **restore** is verify-gated on-device, funnels through the
  coordinator (no in-flight save), re-PATCHes the version's own bytes (never
  fabricated Yjs), and falls back to read-only + web-restore if the endpoint
  can't supply usable content (§9.3).

## 13. Definition of done

Per `CLAUDE.md`: swift-format run; full suite green locally and on CI
(`Build & Test`); new behavior test-covered; docs updated in the same change; PR
title a Conventional Commit; PR review loop run and threads resolved.
