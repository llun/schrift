# Design system (`DesignSystem`)

- <a id="sketch-source-of-truth"></a>**Sketch source of truth.** The design
  lives in the separate [`llun/sketch`](https://github.com/llun/sketch) repo,
  under `Schrift/`:
  - `Schrift/Schrift.sketch` is the **component library only** — colors,
    type, symbols and components. When a change alters the design (a token, a
    component's shape, size or states, a new component), update the matching
    symbol or component there in the same piece of work.
  - **App screens are never placed in the Sketch file.** They are generated as
    HTML into `Schrift/Screens/` (an `index.html` viewer plus its assets).
    When a change alters a screen, regenerate the affected screens there.
  - Publishing the site is described in the sketch repo's
    [README](https://github.com/llun/sketch/blob/main/readme.md). Pushing
    alone does not update <https://sketch.llun.dev/>.
- **App identity:** `docs/assets/app-icon/make-svg.mjs` is the source of truth
  for the app icon and the sign-in logo; `export.sh` beside it renders every PNG
  (icon default/dark/tinted, logo Any/Dark). Change the geometry there and
  re-export — **never hand-edit the PNGs or regenerate them with an image
  model.** Every PNG is 1024×1024, opaque, sRGB, with square corners — do not
  bake a corner mask into either; iOS and `ConnectView` apply the rounding. Keep
  `DocsColor.brandLogo` in step with the icon (light = field mid stop, dark =
  dark relief colour). Rationale and geometry:
  [`docs/design-system.md`](../design-system.md#app-identity).
- **Tokens** are caseless `enum` namespaces of `static let` (`DocsColor` /
  `DocsColorHex`, `DocsFont` / `DocsTypographySpec`, `DocsTracking`
  (letter-spacing, applied as `.docsTracking(spec, DocsTracking.tight)`),
  `DocsSpacing`, `DocsRadius`). Adding a color means adding it to
  `DocsColorHex` (raw `UInt32`) **and** its dark counterpart in
  `DocsColorHexDark` (same name, one entry per light token — see the adaptive-
  color bullet below); add a matching `DocsColor` entry only when views use it
  directly as a SwiftUI `Color` — hues consumed only by style resolvers (the
  accent palette, the `-650` feedback foregrounds, parts of the gray ramp) stay
  hex-only. Token values are visual, so no test restates them (they are checked
  in the `#Preview` catalogs and the Sketch library); a new token must be added to
  the relevant hand-listed invariant in `DocsColorTokenInvariantTests` — an
  ink-on-fill contrast pair (light and dark) or a documented light/dark
  relationship; the suite does not discover tokens itself.
- **Personal themes preserve semantic token identity.** `ThemeStore` persists only
  `schrift.theme`, independently of Appearance, with White as the fallback for both
  new and existing installs. Initialization is read-only; unchanged selection does
  not write. The app root publishes the defaulted `docsTheme` environment value.
  Live views read `@Environment(\.docsTheme)` and use `theme.colors`; pure style
  resolvers receive `theme: AppTheme = .white` explicitly and use `DocsPalette`.
  Never remap raw hex numbers globally (page and on-brand can both be white), use a
  mutable global palette, or reset identity with `.id(theme)`. The UIKit editor row
  passes its theme into the shared block/inline resolvers and `BlockTextStyling`,
  restyling in place without dirty/save/content/selection changes. A theme change
  that lands while UIKit owns marked (IME) text repaints only after commit:
  `reconcile` returns before the styling comparison, and #159's composition
  handoff styling must carry the row's theme too. Container chrome White's light
  page hid is easy to miss: `HomeSplitView` paints `surfacePage` behind the whole
  `NavigationSplitView`, or the status-bar strip and the margin around the
  floating sidebar show the system white/black (`ThemeFlowTests
  .testRegularWidthStatusStripFollowsTheTheme`; CI's iPhone skips it, so run it
  locally on an iPad). Identity avatar
  colors and white media overlays keep their independent roles. `textOnFill` is
  the contrasting solid-control ink; do not substitute `textOnBrand` in dark fills.
  Any Profile/Theme-picker preview also injects `ThemeStore`; ordinary palette
  component previews rely on the EnvironmentKey's isolated White default.
- **Every color is adaptive — there is no light-only token.** `DocsColor.*`
  pairs each `DocsColorHex.<name>` with its `DocsColorHexDark.<name>` via
  `Color(lightHex:darkHex:)` (`HexColor.swift`), backed by
  `UIColor(dynamicProvider:)` reading `traitCollection.userInterfaceStyle` —
  the pure `resolvedHex(lightHex:darkHex:isDark:)` selector is the tested
  primitive underneath it. Because nearly the whole app consumes `DocsColor.*`
  directly, this is dark-mode support with **zero call-site changes** at most
  screens. Appearance itself is applied once at the app root — see
  [Localization & appearance](localization-and-appearance.md#localization--appearance).
- Views **never** use raw color/hex/font literals — always tokens. (One-off
  numeric sizes may be inline; colors are always tokenized.) Prefer `Capsule()` /
  `Circle()` for full-round shapes (a few components — `DocsButton`,
  `SearchScreen` — still use `DocsRadius.pill` directly).
- **Four feedback registers, and they don't overlap.** An **alert** confirms a
  destructive verb (delete, disconnect, discard) — a `.confirmationDialog` is
  for *choosing among options*, so it is the wrong control for a yes/no
  destruction. A **toast** (`.toast(_:)`) confirms something transient that
  already happened ("Link copied") and carries no button, because a message you
  must dismiss is not transient — and it belongs to the **presenting** screen,
  never to a sheet that dismisses itself as it fires one. A **skeleton**
  (`SkeletonList`) stands in for a list on its *first* load with nothing cached
  — never over existing rows, which `shouldShowLoadingPlaceholder` already
  gates; the handoff's rule is no spinners on lists. The editor's first load with
  nothing cached is the page-shaped twin, `EditorLoadingPlaceholder` (header and
  first-line bars, filling the page). An **empty state** is
  `ContentUnavailableView`. (A *callout* — a persistent in-context note — is
  specified by the handoff but has no call site yet; don't invent one.)
- **Glass is for surfaces that float over content, never for content itself.**
  A transient/floating surface — the editor's formatting bar and its slash menu —
  uses **`.glassEffect(.regular, in:)`**, and sibling glass surfaces share a
  **`GlassEffectContainer`** so the system renders them in one pass and blends
  where they meet. Never hand-roll it: `.ultraThinMaterial` plus a drawn border
  and shadow was the old approximation, and it neither refracts nor matches the
  system chrome beside it. Content surfaces stay **opaque** `DocsColor` fills
  (the handoff is explicit: transparency and blur are reserved for chrome), and
  system chrome — bars, tab bar, sheets — is glass already because it is the
  system's; do not re-skin it.
- **All text scales with Dynamic Type, and the token table is what makes that
  safe.** Every `DocsFont.*` is a *text-style-relative* font
  (`Font.system(spec.textStyle, weight:)`), never `Font.system(size:)` — the
  handoff's iOS sizes are exactly the HIG defaults at the Large content size, so
  each token maps 1:1 onto a system style (34→`.largeTitle`, 28→`.title`,
  22→`.title2`, 17→`.headline`/`.body`, 16→`.callout`, 15→`.subheadline`,
  13→`.footnote`, 12→`.caption`) and the app is byte-identical to the handoff at
  the default size while still scaling.
  `DocsTypographySpecTests.testEveryTokenSizeEqualsItsTextStyleDefaultAtTheLargeContentSize`
  is what keeps that 1:1 honest — if a token's size and its style's default ever
  disagree, the app has silently stopped matching the handoff at the size most
  people run. `spec.size` survives as the **reference** value: it is what
  tracking is derived from and what the UIKit editor scales up from. So:
  - letter-spacing goes through **`.docsTracking(spec, DocsTracking.x)`**, never
    a bare `.tracking(size * ratio)` — `.tracking` takes *points*, so a fixed
    value drifts visibly once the text grows;
  - a size the handoff specifies that is **not** on the HIG ramp (the 14pt
    medium button label is the only one) has no token, so it goes through
    **`.docsScaledFont(size:weight:relativeTo:)`**, which keeps the exact
    reference size and still scales. Everything else uses `DocsFont.*` — a bare
    `Font.system(size:)` is the thing both helpers exist to avoid;
  - the block editor's UIKit fonts (`blockTextStyling`, the one place the app
    builds `UIFont`s) go through **`scaledUIFont(_:for:dynamicTypeSize:)`**
    (`UIFontMetrics`). Scaling changes only the rendered size, never the buffer,
    so every `NSRange` stays the source offset it always was — see the
    zero-width-syntax rule under [Editor](editor-save.md#editor--the-on-device-save-coreyjs).
    The size is an **argument, not ambient state**: a `UIFont` is baked in when
    the body runs, so the calling row reads `@Environment(\.dynamicTypeSize)`
    and passes it down. Without that dependency SwiftUI has no reason to re-run
    the row, and the editor keeps rendering at a stale size until an unrelated
    edit happens to invalidate it;
  - a fixed **`height:`** on anything containing text is a bug (it clips at
    larger sizes); use `minHeight:` so the row can grow. A fixed **detent** or
    **`maxHeight`** cap sized in rows (the Appearance sheet, Share's members
    list, version history, the slash menu) needs `@ScaledMetric`, or it shows
    one row where it used to show five;
  - **a row whose title shares a line with trailing metadata reflows at
    accessibility sizes rather than truncating.** `DocRow` is the worked
    example: its date holds `layoutPriority(1)` so the date never truncates,
    which meant the *title* collapsed to `"A…"`. `rowUsesStackedLayout(_:)` is
    the shared predicate — stack the metadata under the title instead.
- **A `MaterialSymbol`'s footprint is its glyph's typographic box, not its point
  size** — about 23pt for a 24pt symbol. So a tap target sized by arithmetic off
  the point size comes up short: `checkboxSize + 2 * ((44 - checkboxSize) / 2)`
  reads as exactly 44 and measures 43. Size the padding from a token with
  headroom and **measure the padded box** in a test; the assertion that appears
  to prove the arithmetic (`size + 2 * padding == rowMinHeight`, with `padding`
  defined as `(rowMinHeight - size) / 2`) substitutes to
  `rowMinHeight == rowMinHeight` and cannot fail for any value of either.
  **In a dense checklist, bound vertical target growth to half the row gap on
  each side.** Larger shapes overlap and a tap near the boundary can toggle the
  neighbouring row. `checkboxVerticalHitPadding` keeps targets within the row
  pitch (glyph box + gap; measured 41pt at default size on iOS 26.5). Horizontal
  padding still grows the checkbox target; its overlap with the text column
  belongs to the text view. Reaching 44pt vertically would need a taller row
  shared with reading, a document-density decision rather than a padding one.
- **Icons are Google Material Symbols, never SF Symbols.** The app's entire icon
  set is the handoff's Material Symbols Outlined, bundled as a ~18KB subset
  (`Schrift/Resources/Fonts/MaterialSymbolsOutlined-Icons.ttf`, Apache-2.0,
  registered via `UIAppFonts` in `project.yml`'s `Generated/Info.plist` template —
  the same array-in-template mechanism as `CFBundleLocalizations`). Reference a
  glyph by the typed `enum MaterialIcon` (raw value = the Material glyph name from
  `brand-iconography.html`; the FILL axis renders filled via `fill: true`) and
  render it with `MaterialSymbol(_:size:fill:)` — **never** `Image(systemName:)`.
  It **scales with Dynamic Type by default** (relative to `.body`), so a glyph
  stays proportionate to the text beside it; pass `scales: false` for a glyph in
  a hard-bounded box that would crop it instead — `IconButton`, whose row of
  up to seven in the formatting bar scrolls inside a fixed width budget, and `DocIcon`,
  which scales its glyph and box together from one value.
  `IconButton(icon:)` takes a `MaterialIcon`; a `ToolbarItem`'s icon-only label
  uses `ToolbarIcon` (template image) and `.buttonBorderShape(.circle)`, with fixed
  toolbar spacers between separate glass surfaces. UIKit call sites (a `UIMenu`
  action, a tab-bar label) use `MaterialIcon.uiImage(pointSize:)`. Adding an icon
  the app doesn't yet bundle means re-subsetting the font (see
  [`docs/design-system.md`](../design-system.md)) — you can't just name any
  Material glyph. `MaterialSymbol` is `accessibilityHidden` (the glyph is a
  Private-Use-Area char with no spoken text), so every icon-only control must carry
  its own `.accessibilityLabel` and decorative icons rely on adjacent text.
- Variant/state components use the **Style Resolver** pattern: plain `enum`s for
  the axes → an `Equatable` `XStyleHex` struct of **raw** values → a caseless
  `enum XStyleResolver { static func style(...) -> XStyleHex }`. The view converts
  hex→`Color` only at render time. Never return `Color`/`Font` from a resolver —
  keep results `Equatable` and testable. **A resolver's `XStyleHex` carries
  both a light and a dark raw field per color** (`backgroundLightHex` /
  `backgroundDarkHex`, …) — never a single hex, because the same light hex can
  map to *different* darks depending on what it means in context (`#FFFFFF` is
  `surfacePage` **and** `surfaceRaised` **and** `textOnBrand`, which need
  different darks — a global hex→hex table can't express that). The resolver
  fills both halves (light from `DocsColorHex`, dark from `DocsColorHexDark`);
  the view renders via `Color(lightHex:darkHex:)`. `Badge`, `Button`,
  `IconButton`, `TextField`, `LinkReachPill` follow this; their resolver tests
  cover the light and dark fields through invariants (distinct styles, contrast) rather than restating values.
- Every component file ends with a `#Preview` **catalog** of all meaningful
  variants/states, checked in **both light and dark** (`.preferredColorScheme`)
  since adding a token doesn't guarantee its dark half looks right. Icon-only
  and composite controls must set `.accessibilityLabel` / appropriate traits
  (produced by the component's pure helper function); purely decorative
  components whose meaning is carried by adjacent text (Avatar, DocIcon) are
  instead marked `.accessibilityHidden(true)`.
- A component view that would shadow a SwiftUI type takes a `Docs` prefix
  (`DocsButton`, `DocsTextField`); everything else keeps the bare name.
- **Custom controls share a 44pt minimum height.** `IconButton` is a 44pt
  circle in every size/variant; its size changes the glyph only. `DocsButton`,
  `DocsTextField`, custom search fields and the sheet close action share that
  floor; text controls may grow with Dynamic Type. Native system controls keep
  their platform metrics, and checklist adornments retain first-line alignment.
  A hard minimum does not compress, and the 44pt buttons don't grow with Dynamic
  Type. The formatting bar's five square actions (240pt) fit every supported iPhone
  column, even under Display Zoom. The seven on a list item (adding Outdent and
  Indent, 332pt) fit the standard 343pt-or-wider column but overflow narrower ones:
  a screen Display Zoom narrows to 320pt (leaving a 288pt column) and narrow
  iPad containers (Slide Over, ⅓ split). There `EditorFormattingBar` scrolls
  horizontally inside the editor's offered width, preserving 44pt squares and screen
  geometry, and a ~24pt gradient (`mask`) fades the edge with hidden buttons
  (`scrollFadeEdges`, fed by `onScrollGeometryChange`; none when the row fits).
  `EditorFormattingBarTests` covers both the width containment and row height.
  **Family buttons: one text-style button for bold/italic/link (`TextStyleFormat`),
  one list button for all three list kinds (`ListFormat`) and one for quote/code
  (`QuoteFormat`)**, in the order add, text style, list, [outdent, indent], quote/code,
  attach. All three are `FormattingBarChoice`s; the list and quote ones are also
  `FormattingBarFormat`s (block kinds). A text-style tap applies the default (bold
  `**`, italic `_`, or the link editor) and the whole family, button and choices, is
  disabled exactly when `canEditLink` is false, the one case none of its members can
  act (as `canOfferAttach` does for attach); the default is remembered in
  `schrift.editor.defaultTextStyle`. A list or quote tap applies
  the family's remembered default (`…defaultListFormat` / `…defaultQuoteFormat`, local preferences), toggling a block already of that
  kind — checked or not, any code language — back to a paragraph
  (`blockKindAfterTapping`), and a long press (`IconButton.longPressAction`, also
  exposed as a named VoiceOver action) swaps the row in place for Close + the
  family's members. A pick applies that kind and becomes the default, and is *not*
  a toggle (`blockKindAfterChoosing`): picking the kind a block already has leaves
  it, checked state and code language included. A new family is a new conforming
  enum (a `FormattingBarChoice`, or a `FormattingBarFormat` for block kinds) plus a `Family` case in the bar — not another choices view. The
  choices replace the row rather than opening a system `Menu`, so nothing but the
  bar's own plain buttons competes with the text view mid-edit.
  **Attach is the one *tap*-to-choose slot**: the bar's last button
  (`attach_file`) swaps the row for Close + Photo + File on a tap, because neither
  upload is a sensible default — it shares the `Family` swap rather than adding a
  `Menu`. It is disabled only when neither choice can be offered; offline it opens
  with File disabled (Photo queues, File has no queue).
- **A 44pt frame is not a 44pt tap target — a plain `Button` hit-tests the shape
  its label *draws*.** So a `Button { HStack { icon; title; Spacer() } }` is
  tappable on the glyphs and nothing else: the `Spacer`, the padding and the rest
  of the row are dead, however tall the frame says it is. Every interactive row
  therefore ends its label with **`.contentShape(Rectangle())`** (`ListRow`,
  `ProfileTrailingRow`, `SharedRow`, `SubpageRow`, `PagesTreeDrawer`), and a label
  that must fill a taller container takes **`.frame(maxHeight: .infinity)` first**
  — a `Text` is only as tall as its line, so the shape it hands over is that line.
  **But `maxHeight: .infinity` fills whatever it is *proposed*, so it is only
  safe where the proposal is one you want filled.** A flexible frame answers the
  proposal clamped into the bounds you give it, and falls back to its child where
  the proposal is unspecified or a bound is missing — so an unbounded max means
  "all of it" the moment any ancestor hands down a concrete height. **The
  operative question is the proposal, not whether an ancestor caps it.** Both
  shipping call sites are worth knowing: a **scroll view** proposes an
  unspecified height along its scroll axis, so `PagesTreeDrawer`'s rows are
  ideal-sized rather than greedy — which is why the same modifier is harmless
  there, and (measured since) it still buys the full tap shape: given only a
  `minHeight:`, a flexible frame clamps an unspecified proposal *up to* that
  minimum and hands **that** down, so the row proposes 44pt inward and the
  fill-the-row label answers 44pt. Its leaf rows are worth naming, having twice
  been read the other way — a leaf reserves the disclosure column with a 22pt
  `Color.clear` where a parent puts a 44pt button, and the shorter sibling looks
  like it should shorten the label. The proposal arrives down the row, not across
  the `HStack`, so it doesn't: `PagesTreeDrawerTests` holds that to the numbers —
  the row's shape reproduced around the same tokens, leaf and parent alike at the
  same 44pt, and the label still covering the row up through the accessibility
  text sizes. Delete the fill there and the label drops to 21pt while the row
  still reports 44 — which is both what makes those assertions bite and why the
  row's own size is the one thing that cannot be measured to catch this; a
  **stack in a
  height-bounded container** hands its children a concrete proposal, which is
  what `editingSurface`'s
  `VStack(spacing: 0)` did (the editing canvas is a bare `BlockEditorView` now
  and the status lives inside its `ScrollView` — but the rule is about the
  container shape, not that one call site, and any stack you put in a
  height-bounded container behaves this way), and there `SaveStatusIndicator`'s
  Save/retry filled the row and the row filled the screen — offered 874pt it
  answered 874pt, the `VStack` saw two greedy children, split the free height
  between them, and parked the document title and first line of content
  mid-screen whenever the keyboard was up. **In the second case, floor the label itself** —
  `.frame(minHeight: DocsSpacing.rowMinHeight)` never claims a proposal and still
  grows with Dynamic Type, which the rule above *requires* (a fixed `height:`
  clips). Note the floor was also the *larger* target: that strip applied
  `.padding(.bottom, 8)` before its own `.frame(minHeight: 44)`, so a
  fill-the-row label only ever got 36pt at the strip's floor — it reached 44 only
  while inflating it. (The strip is gone; the indicator sits in
  `EditorDocumentHeader`'s status slot. The arithmetic is kept because it is the
  worked example of why a floor on the *container* is not a floor on the label —
  the same mistake this PR then made with the retry caption.) Give every sibling state the same floor
  (`SaveStatusIndicator`'s three passive states do) or the content below resizes
  as the state changes. That levelling is a **default-size** property: a floor
  only equalises states whose own text fits inside it, so once a phrase grows past
  44pt that state is text-sized again — the right trade, since capping it would
  clip the text. `SaveStatusIndicatorTests` pins what is invariant: content-sized
  against a full-screen proposal, ≥44pt tall when offered less, and ≥44pt wide for
  the short "Save" label — measured in English through an isolated
  `LocalizationStore`, because a width floor only binds while the label is
  narrower than the floor. Two shapes this rule takes:
  - a small glyph inside a bigger target keeps the glyph fixed and pads *outside*
    it — that is what `IconButton` does, and why an icon-only control should go
    through `IconButton` rather than wrapping a bare `MaterialSymbol` in a
    `Button` (the Home error-banner dismiss was a 13pt cross before it did);
  - where a hard frame would move the glyph — the checklist checkbox is the
    adornment beside the first text line, so a 44pt box would move it below the
    first line of text it sits beside — grow the hit rect and give the growth
    back with **symmetric negative padding**
    (`.padding(x).contentShape(Rectangle()).padding(-x)`): same layout, bigger
    target. Checklist vertical padding is capped at half the row gap, so adjacent
    targets meet without overlap; the resulting height is the row pitch.
  The hit *shape* is invisible in a screenshot and uncatchable by the suite,
  which is why it survived a whole design refresh on `Delete document`,
  `Sign out` and both conflict-resolution rows — check that by tapping the
  *padding*, not the text. The *geometry* a fill-the-row label demands is not
  invisible: host the view and measure it (`SaveStatusIndicatorTests`,
  `EditorFormattingBarTests`), because a control that claims the height or width
  it is offered takes it out of whatever it shares a stack with. Three things
  about measuring a label *inside* a row, which cost `PagesTreeDrawerTests` a red
  CI round to learn. `sizeThatFits` reports the row and **cannot see this class
  of defect at all** — the row floors at 44pt whether or not the label fills it.
  A **`GeometryReader`** behind the `contentShape`'d label does see it, but only
  once the hosted view is in a `UIWindow` **and** laid out; short of that it
  reports `.zero`. A hosted view's **accessibility frames** track that same
  label's bounds and can read the *real* screen rather than a copy — but they are
  materialized only where an accessibility client is, so on a freshly erased
  simulator, which is what CI runs, every frame comes back empty and every such
  test fails. Keep that one for local verification; never put it in the suite.
  Whichever instrument, land a **negative control** with it — the same row with
  the fill removed, which must measure *short*. Without one, "44pt" only says the
  instrument never reports anything else, and a measurement that cannot fail is
  not evidence.
- **Swipe actions are hand-rolled (`SwipeRevealRow`), because the app has no SwiftUI
  `List` — and `.swipeActions` silently no-ops outside one.** Every document list is a
  `ScrollView` + `VStack` + `ForEach`, which is what gives the app its flat, boxless rows;
  converting to `List` would restyle every screen and break `PagesTreeDrawer`'s
  `.frame(maxHeight: .infinity)` row trick, which is only safe because a `ScrollView`
  proposes an *unspecified* height. Seven rules travel with the component, each closing a
  real defect:
  - **Trailing edge only.** A leading swipe would fight the system's interactive-pop
    gesture on every `NavigationStack` screen.
  - **The drag is a UIKit recognizer, not a SwiftUI `DragGesture` — and refusing a drag is not
    the same as ignoring one.** This shipped as `.simultaneousGesture(DragGesture(...))` with
    the axis lock applied inside `onChanged`, on the reasoning that "simultaneous lets both
    run". It does not, reliably, for the *ancestor* `ScrollView`'s pan on iOS 26: a
    `DragGesture` is **recognized** for every drag past its `minimumDistance` whichever way it
    went, and discarding the vertical ones downstream leaves the touch already claimed. On
    Home — the one screen whose rows cover the whole viewport — that left nowhere to start a
    scroll, and the list did not move at all with more documents than fit. Two independent
    things fix it, both in `SwipeRevealGesture.swift`:
    `SwipeRevealPanGestureRecognizer` **refuses** a drag the moment the axis lock proves it
    non-horizontal (`.failed` while still `.possible`, `.cancelled` after — a pan begins on
    its own at about the same distance the gate uses, so a diagonal can beat the gate to it),
    and its coordinator declares `shouldRecognizeSimultaneouslyWith` **at the UIKit level**,
    which is where the scroll view's pan actually arbitrates. The axis lock itself is
    unchanged — decided once past the slop and then frozen (`swipeDragAxis`, whose ambiguous
    diagonal resolves *vertical*, the tie going to the scroll view) — it just runs in the
    recognizer now instead of downstream of it. Some diagonal drift is still accepted.
    `DragGesture.Value.predictedEndTranslation` has no UIKit equivalent, so the flick is
    projected explicitly by `swipeFlickProjection` (Apple's deceleration formula,
    `v ÷ 1000 × r ÷ (1 − r)`) at UIKit's **fast** rate, not its normal scroll one — the
    normal rate projects ~0.5s of travel, which clears a 144pt strip's 72pt open threshold on
    velocity alone at ~145 pt/s and would leave a strip open after almost any release that was
    still drifting; the recognizer also has a real **cancel** path, which the
    `DragGesture` never had — it leaned on `.onDisappear` to release a claim the system had
    taken, leaving close-on-scroll disabled list-wide until some other row completed a drag.
    **The lesson generalises:** a gesture that must coexist with a scroll view has to decline
    in the recognizer, not in a callback the recognizer feeds.
  - **Wrap tap-gesture rows, not `Button` rows.** A `Button`'s gesture begins tracking on
    touch-down and can still fire on touch-up *after* a swipe, and nothing cancels it (our
    drag is horizontal, the scroll pan vertical). `SubpageRow` and `PagesTreeDrawer`'s title
    were converted to `.contentShape(Rectangle()) + .onTapGesture` for exactly this; the
    drawer's disclosure chevron stays a `Button` and stays *outside* the wrapper.
  - **The strip is a `background` of the content, not a `ZStack` sibling.** Its buttons are
    `maxHeight: .infinity` so they fill the row, and as a sibling that made the stack greedy —
    a document row measured 874pt instead of 58pt. A background is proposed the decorated
    view's size, so the same `.infinity` contributes nothing back to the row's *measured*
    size. `SwipeRevealRowGeometryTests` pins it, with a negative control. What it does **not**
    buy is the next rule.
  - **Being a `background` bounds what the strip *measures*, never what it *paints* — so the
    row clips.** A flexible frame clamps the proposal it is given only as far down as its own
    child's ideal size, and an action button's label (a 22pt glyph over a caption) is ~45.7pt
    at the Large content size. Proposed a 44pt row it therefore answers 45.7pt and paints
    ~0.8pt of the destructive fill above and below the row — a hairline drawn between rows
    that were all *closed*, and points of it at accessibility text sizes, where the glyph
    grows and the row need not. It showed in the editor's Subpages list and the
    `PagesTreeDrawer`, both of which sit at the 44pt tap-target floor, while Home looked
    fine because `DocRow` is ~58pt and swallowed the overflow — so "it renders correctly on
    Home" is no evidence here. `.clipped()` on the composed row is the fix, chosen over
    sizing the strip to a measured row height because it needs no extra state and bounds the
    **sliding content** too, which otherwise draws over the list's gutter and, in the drawer,
    over the disclosure chevron beside it. `sizeThatFits` is blind to all of this (a
    background contributes nothing to measure, however tall it draws) — it is pinned by
    rendering the row over clear margins and scanning them, with a negative control that
    paints a fill which really does escape.
  - **A `background` applied after `.offset` does *not* follow it** — verified by rendering,
    not assumed, and pinned by `testABackgroundDoesNotFollowAPriorOffset`. That is what keeps
    the strip pinned while the content slides; compensating for the offset would double the
    displacement, and no size assertion can see the difference.
  - **Accessibility is not free here.** A real `List`'s `.swipeActions` exposes its actions
    automatically; this exposes nothing. The wrapper becomes the one element
    (`children: .ignore`) and **re-declares** the label and the activation the content
    composed — hence its required `accessibilityLabel` / `onActivate` parameters — plus one
    `.accessibilityAction(named:)` per action. The drawn strip is `accessibilityHidden`, or
    it puts one phantom VoiceOver stop per action after every row.

  `documentRowSwipeActions` is the shared, tested resolver for *which* actions a row gets:
  a row already waiting to be deleted offers only "Keep this document"; a locally-created
  row offers no Pin (there is no `documents/{local-uuid}/favorite/` route); and only Home
  offers Pin at all, because `SubpageRow` and the drawer render no pinned state.
- **Inter-row hairlines are opt-in per call site, not a `ListSection`
  parameter.** There is no `divided:` flag in the Swift code (that's the React
  handoff's prop) — a section draws separators only where its own body
  interleaves `ProfileRowDivider()` between rows (a 1pt `borderDefault`
  rectangle inset 52pt past the leading icon). The four tab screens'
  multi-row sections (Shared's document list, Profile's Preferences/Server
  sections) simply **omit** those calls and render flat, matching the handoff.
  **The sheets are all flat too:** Options, Share, and Version-history are boxless
  lists under a `SheetHeader` (see the next bullet), so **`ProfileRowDivider()`
  currently has no call sites** — the component is retained as the
  grouped-separator primitive should a future grouped list want it. Don't add
  `ProfileRowDivider()` calls back onto a tab screen or sheet without checking the
  handoff first — the flatness is deliberate, and reverting it is just re-adding
  the calls, not flipping a flag.
- **Sheets use `.presentationDetents` + `.presentationDragIndicator(.visible)`**
  (Share, Options, Version history, the Appearance/Language pickers) instead of
  an un-detented full-height `.sheet`, so a long scrollable list can't push a
  primary action below the fold. Where a sheet has both a pinned action and a
  potentially-long list (Share's invite field + member list), bound the list's
  own height instead of letting it grow the sheet — `ShareSheetLayout
  .membersMaxHeight` (208pt) is that pattern; copy it rather than wrapping the
  whole sheet body in one unbounded `ScrollView`.
- **Every list rendered inside a sheet/dialog is flat — boxless and
  dividerless.** Rows draw directly on `DocsColor.surfacePage` under a
  `SheetHeader`; a sheet **never** wraps its list in a `ListSection` card and
  **never** interleaves a `ProfileRowDivider` or a section-divider `Rectangle`.
  Structure inside a sheet comes from **eyebrow labels** (uppercase
  `footnote`/`textTertiary`, e.g. a `sectionLabel` helper) and spacing, not from
  boxes or hairlines. This holds for **every** list-bearing sheet today — Options,
  Share, Version history, Appearance, Language — and for any new one: a sheet that
  shows a list flattens it. **Tab/detail lists are unboxed too.** `ListSection`
  is open composition: sentence-case labels and spacing, with no enclosing fill,
  stroke or rounded clip. Profile and Account own the outer gutter and publish
  `docsRowGutter = 0` to their rows; ordinary sheet rows retain the default gutter.
  Purposeful input, selection and attachment boundaries remain. Sheets with **no** list (the re-login and link-editor form sheets, the
  web-login sheet) are exempt: they have nothing to flatten and keep their form
  chrome (a `Cancel`/`Save` toolbar is fine there — `SheetHeader`'s title+close is
  for *menu/list* sheets).
- **A menu/options sheet is a flat, boxless list under a `SheetHeader`, not a
  grouped card.** The document Options sheet (`OptionsSheetView`) matches the
  handoff `OptionsSheet`: a pinned **`SheetHeader`** (an inline `DocsFont.title2`
  title + a 44pt **circular close button** — `surfaceMuted` disc,
  `MaterialIcon.close` glyph 20pt in `textSecondary`) over `ListRow`s rendered
  **directly on `DocsColor.surfacePage`** — no `ListSection` card, no `ProfileRowDivider`, and **no `NavigationStack`/"Done"
  toolbar**. Reuse `SheetHeader` for new sheet chrome rather than re-adding a nav
  bar; the grabber is `.presentationDragIndicator(.visible)` and the close button
  is wired to `@Environment(\.dismiss)`. The header pads `16 / 16 / 10` (the
  app's 16pt sheet gutter top and sides so the title clears the drag indicator,
  not the prototype's 18); rows keep `ListRow`'s own
  16pt so the title and the row icons align. This is the pattern for future
  action/menu sheets. **The `Share` and `Version-history` sheets follow the same
  pattern** — a `SheetHeader` over a boxless body drawn on `surfacePage`, no
  `NavigationStack`/"Done", no `ListSection` card, no dividers — keeping only
  their section-label eyebrows and (for Share) the bounded members list. **Every
  menu/action/picker sheet now uses `SheetHeader` chrome** (Options, Share,
  Version history, Appearance, Language); none wrap a `NavigationStack` + "Done"
  toolbar anymore. (The **form** sheets — Link editor, Re-auth — keep a
  `Cancel`/`Save` toolbar; they host a form, not a list, per the flat-list rule
  above.) The `common.done` L10n key was removed when its last two call sites
  (these sheets) moved to `common.close`.
