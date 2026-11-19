# Localization & appearance

`Core/Localization/` (the catalog + `LocalizationStore`) and
`App/AppAppearance.swift` (`AppAppearance` + `AppearanceStore`):

- **Appearance, Theme and Localization are `@MainActor @Observable` stores injected once at the app root**
  (`SchriftApp`) via `.environment(appearanceStore)` / `.environment(themeStore)` / `.environment(localizationStore)`,
  plus `.preferredColorScheme(appearanceStore.selected.colorScheme)` and
  `.environment(\.locale, localizationStore.locale)` so date/relative-time
  formatting re-localizes too. Screens read them with
  `@Environment(LocalizationStore.self)` / `@Environment(AppearanceStore.self)`;
  reading inside a view's `body` makes `@Observable` track the dependency, so
  switching language or appearance re-renders the whole app live — no relaunch.
  **Any `#Preview` of a view that reads either environment must inject it**
  (`.environment(LocalizationStore())`, `.environment(AppearanceStore())`) or the
  preview canvas fatal-errors; this is transitive to every parent view that
  embeds it (`MainTabView` embeds the tab screens and `RootView` embeds
  `MainTabView`; `HomeSplitView` embeds the list and the editor) — `grep -rn "<ViewName>(" Schrift` to find embedders after adding
  the environment read to a view.
- **The localization catalog is in-code, not `.lproj`/String Catalog**: an
  `enum L10nKey: String, CaseIterable` of dot-separated keys, one
  `Strings_<lang>.swift` table (`[L10nKey: String]`) per language under
  `Core/Localization/`, dispatched by `Strings.table(for:)`.
  `LocalizationStore.subscript(_:)` resolves `table[key] ?? Strings_en.table[key]
  ?? key.rawValue` (English is the guaranteed fallback) — `format(_:_:)` for
  `String(format:)` args, `plural(_:one:other:two:few:)` for count-driven
  strings (`PluralRule` picks the language's plural category; `zh-Hans`/`zh-Hant`/`th`
  are other-only, Slovene uses the full CLDR `one`/`two`/`few`/`other` set
  including the dual, the rest are one/other — `two`/`few` are optional keys
  only Slovene resolves and otherwise fall back to `other`). `StringsCompletenessTests` gates **every** `L10nKey` present
  in **every** language table (non-empty) and **format-argument parity**
  with English — not a count of `%` but the *argument list* each string
  implies (`formatArgumentList(of:)`, `SchriftTests/Support/FormatSpecifiers.swift`):
  which position takes an object, an integer, a double. Counting `%` was
  blind to the one mismatch that actually crashes — a table writing `%d`
  where English has `%@`, which hands `String(format:)` an `Int` to
  dereference as an object pointer — and could not tell a **reordered
  positional** translation (`%2$@ %1$@`, correct and the whole point of
  positional specifiers) from a reordered plain one (not). Interchangeable
  spellings (`%d`/`%i`/`%lld`) compare equal; an unrecognised conversion is
  recorded rather than dropped, so it surfaces as a mismatch instead of
  reading as "no argument here" — as is a **truncated** specifier (a `%` that
  never reaches a conversion), and `*` width/precision each occupy the argument
  they really consume. A position used with two different kinds in one string
  collapses to `.conflicted` rather than to whichever came last, and
  `testNoStringUsesOnePositionWithTwoArgumentKinds` checks that independently of
  English — a contradiction *in English* would otherwise have every parity test
  agreeing with it. Those last three exist because the first draft of this gate,
  while stronger against `%d`-for-`%@`, was **weaker** than the `%`-count it
  replaced on a corrupted tail and on self-contradictory reuse; a replacement
  gate has to be checked in that direction too — add a key to
  `L10nKey.swift` + `Strings+en.swift` first (English-only is fine to land;
  other languages are filled in by a translation pass), then that test tells
  you if a table is left stale.
  `AppLanguage` covers 11 languages (`en fr es de it nl pt sl th zh-Hans zh-Hant`);
  first-launch default is the best match of `Locale.preferredLanguages` against
  those codes, else English, but the user's explicit choice always wins
  thereafter. **English is the one reviewed source**; every other table —
  French included — carries the "AI-generated translation — pending
  native-speaker review" header, so don't treat any non-English string as
  authoritative copy.
- **Language is a local app-UI preference, never a server write.** Picking a
  language does not `PATCH` the server user's `language` field (that governs
  server emails / rendered content and would be a surprising side effect) —
  it only sets `LocalizationStore.language` (persisted `schrift.language`).
  **Document content is never translated** — server-authored titles/body render
  exactly as authored; localization covers app chrome only.
- `AppAppearance` (`system`/`light`/`dark`) persists as `schrift.appearance`;
  `.preferredColorScheme(nil)` for `.system` lets the OS decide. These preference stores
  follow the `schrift.` `@AppStorage`-prefix convention from
  [Persistence](persistence.md#persistence-store-types) even though they're hand-rolled
  `UserDefaults` stores, not `@AppStorage`, because they need `@Observable` +
  injectability.
