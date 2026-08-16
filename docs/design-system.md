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

> **Revised: 2026-08-13 (the Home list could not scroll).** With more documents
> than fit the screen, the Home list would not scroll at all. The cause was the
> swipe gesture the 2026-08-08 revision below introduced: a SwiftUI `DragGesture`
> is *recognized* for every drag past its `minimumDistance`, whichever direction
> it went, and `SwipeRevealRow` then discarded the vertical ones inside
> `onChanged`. That reads as "the scroll view still wins" but is not — by the time
> the closure runs the recognizer has the touch, and `.simultaneousGesture` does
> not reliably keep an *ancestor* `ScrollView`'s pan alive on iOS 26. Home is the
> only screen whose rows cover the entire viewport, so it was the only one with
> nowhere left to start a scroll; the editor's Subpages section and the Pages
> drawer both have non-row areas to grab, which is why they looked fine.
>
> The drag is now a UIKit `UIPanGestureRecognizer` bridged in with
> **`UIGestureRecognizerRepresentable`** (`SwipeRevealGesture.swift`). It fixes the
> arbitration at the level it actually happens: the recognizer **refuses** — rather
> than ignores — a drag the axis lock proves non-horizontal, and its coordinator
> declares simultaneous recognition with the scroll view's pan as a
> `UIGestureRecognizerDelegate`. The pure geometry (`swipeDragAxis`,
> `swipeRevealOffset`, `swipeRevealSettle`, the widths) is untouched; what changed
> is where the axis decision runs.
>
> **Two things about the feel did change, both deliberately.** First, a row now
> claims itself (closing whichever sibling was open) when the *pan* begins, which
> can be a move before the axis lock has judged it — a pan commits at roughly the
> distance the gate uses, so a near-diagonal reaches `.began` first and is refused
> after. The old `DragGesture` never claimed until the drag had proved horizontal.
> The claim is handed straight back through `onCancelled`, so nothing is stuck;
> what a reader should expect is that a near-diagonal drag can close an open strip
> and nudge its row a point or two, where before it did neither. A plain scroll
> closes an open strip anyway, so this widens an existing behaviour rather than
> introducing one.
>
> Second, flick projection —
> `DragGesture.Value.predictedEndTranslation`, which has no UIKit equivalent — is
> now computed from the recognizer's velocity by `swipeFlickProjection`, at UIKit's
> **fast** deceleration rate rather than its normal scroll one. The normal rate
> projects ~0.5s of travel, which is right for throwing a long list and much too
> eager for a 144pt strip: it clears the 72pt open threshold on velocity alone at
> ~145 pt/s, so a row would settle open after almost any release that was still
> drifting. The fast rate asks for a real flick (~700 pt/s from a standing start).
> It is a feel constant and wants tuning on a device.
>
> The gesture's arbitration was previously called out as "verified by hand", and
> that is what let this ship. It has a suite now (`SwipeRevealGestureTests`).

> **Revised: 2026-08-15 (a hairline of the delete fill between sub-page rows).**
> Every row in the editor's **Subpages** list — and in the **Pages drawer** — drew a
> short coloured hairline at its top and bottom edge, on the trailing side, while
> every row was *closed*. It was the destructive swipe action's own fill, painted
> outside the row it belongs to.
>
> The strip is a `background` of the row, which bounds what it **measures** but not
> what it **paints**: a flexible frame clamps the proposal it is handed only as far
> down as its own child's ideal size, and an action button's 22pt glyph over a
> caption is ~45.7pt at the Large content size. Proposed a 44pt row it answers
> 45.7pt and overhangs ~0.8pt each side — points of it at accessibility text sizes,
> where the glyph grows and the row need not. Only rows at the **44pt tap-target
> floor** were affected, which is why the Home list looked fine throughout:
> `DocRow` is ~58pt and swallowed the overflow.
>
> `SwipeRevealRow` now `.clipped()`s the composed row, so it paints nothing outside
> its own bounds — the strip behind it *and* the content sliding off it, which
> previously drew over the list's gutter and, in the drawer, over the disclosure
> chevron beside it. `sizeThatFits` cannot see any of this (a background contributes
> nothing to measure however tall it draws), so it is pinned by rendering the row
> over clear margins and scanning them, with a negative control.

> **Revised: 2026-08-16 (Move on document rows and in the Options sheet).** Every
> document row's swipe strip gained a third action, **Move**, between Pin and
> Delete — Home, the editor's Subpages section and the Pages drawer, since the
> point of the feature is moving a document *between* those places — and the
> editor's Options sheet gained a matching row. Both open the same flat picker
> sheet: **"Top level"** (withheld for a document already there, and for a server
> document until a root has been fetched to file it beside) over the
> top-level documents it can be filed under, under the shared `SheetHeader`, with
> a `ListRow` per destination and no card or divider, like every other
> list-bearing sheet here. **No confirmation alert**, deliberately: choosing a
> destination *is* the deliberate step, and unlike a deletion a move is
> reversible in the same two taps. Errors render inside the picker so the user
> can pick somewhere else without losing the sheet.
>
> Two notes for whoever touches it next. The strip is now **at its width
> budget**, in the sense that matters: `swipeActionButtonWidth` is
> `max(44, min(72, rowWidth × 0.6 / count))`, so three actions on the narrowest
> supported row (343pt — an iPhone SE less the 16pt gutter each side) come to
> 68.6pt each, still under the 72pt base and comfortably over the 44pt floor, and
> the strip lands on exactly the 60% cap. An *open* strip therefore went from
> ~42% of the row to the full 60%. A fourth action does **not** overflow — the
> cap simply shrinks each button (51.4pt at that width) — so what a further
> addition costs is target size, not layout: the 44pt floor only starts winning
> below ~293pt of row width, which is not a device. `SwipeRevealRowTests` pins
> the three-action case at that narrowest width so the next addition has to look
> at this deliberately. And the glyph is
> **`account_tree`, not Material's own `drive_file_move`** — the bundled font is
> a subset of the glyphs the app uses, so a new icon means re-subsetting and
> committing the binary; that is a follow-up rather than a blocker, and the tree
> glyph reads correctly here since what a move changes is the document's place in
> the page tree. It always appears beside the localized "Move" label.

> **Revised: 2026-08-08 (swipe actions on document rows).** Document rows now
> offer **swipe-to-delete** — plus **pin/unpin on Home** — on three surfaces: the
> Home list, the editor's Subpages section, and the Pages drawer. (Shared and
> Search were deliberately left out of this pass.) Delete always confirms with an
> alert, reusing the Options sheet's own copy so the two routes to the same verb
> read identically; offline it queues a tombstone exactly as the sheet's Delete
> does, and the row stays struck through with its existing undo.
>
> The mechanism is a new hand-rolled DesignSystem component, **`SwipeRevealRow`**
> — *not* `.swipeActions`, which silently no-ops outside a SwiftUI `List`, and the
> app has none: every document list is a `ScrollView` + `VStack` + `ForEach`, which
> is precisely what gives these screens their flat, boxless rows. Converting to
> `List` would have restyled every screen and broken `PagesTreeDrawer`'s
> `.frame(maxHeight: .infinity)` row trick, which is only safe under a scroll
> view's unspecified height proposal.
>
> Three consequences worth knowing, all documented in full in
> [`CLAUDE.md`](../CLAUDE.md): the drag is a **UIKit recognizer** with a
> decided-once axis lock, and it *refuses* non-horizontal drags rather than
> ignoring them (see the 2026-08-13 revision above); `SubpageRow` and the drawer's title were converted off `Button` to
> `.contentShape` + `.onTapGesture`, because a `Button` can still fire on touch-up
> after a swipe; and the action strip is a **`background` of the content, not a
> `ZStack` sibling**, or its `maxHeight: .infinity` buttons make the row claim the
> whole proposed height. Accessibility is re-declared by the wrapper
> (`children: .ignore` discards what the row composed) and the drawn strip is
> `accessibilityHidden`, or every row gains phantom VoiceOver stops.
>
> **Pin is Home-only** because `SubpageRow` and the drawer render no pinned state,
> so the action there would succeed with nothing to show for it. No new localized
> strings were needed — the Options sheet's `options.pin` / `options.unpin` /
> `options.delete` and the existing `pending_delete.undo` cover every label.

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
> Version-history sheets were flattened onto the same pattern shortly after —
> see the next amendment.

> **Revised: 2026-07-12 (Share & Version-history sheets → flat menu).** The
> **Share** and **Version-history** sheets were migrated onto the same flat
> chrome: a `SheetHeader` (inline `title2` title + circular close) over a
> **boxless** body drawn on `surfacePage`, dropping the `NavigationStack` +
> `Done` toolbar, the `ListSection` cards, and every `ProfileRowDivider` /
> section divider. Kept: their section-label eyebrows, Share's **bounded members
> list** (`ShareSheetLayout.membersMaxHeight`) and confirmation dialogs, and
> Version-history's pinned **"Restore on the web"** row. This **supersedes**
> §8.3's "`ProfileRowDivider` stays for Share/Version-history" note (rewritten
> inline) and §8.4's present-tense description of these sheets as `NavigationStack`
> + "Done" wrappers. **Every menu/action/picker sheet now uses `SheetHeader`**
> (Options, Share, Version history, Appearance, Language); the two **form** sheets
> (Link editor, Re-auth) keep a `NavigationStack` + Cancel/Save toolbar — they
> host a form, not a list.
> `ProfileRowDivider` consequently has **no remaining call sites** (retained as
> the grouped-separator primitive), and the now-orphaned `common.done` L10n key
> was removed — both sheets use `common.close` for the accessibility label. This
> is now a **standing rule**: *every list inside a sheet/dialog is flat* (boxless,
> dividerless, on `surfacePage` under a `SheetHeader`); grouped `ListSection`
> cards are reserved for the **tab screens** (Profile, Shared). See
> [`CLAUDE.md`](../CLAUDE.md).

> **Revised: 2026-07-31 (iOS 26 minimum + Dynamic Type).** This is the first
> change of the **native-first / Liquid Glass** refresh, following a revised
> handoff whose governing rule is: *use the system component and its built-in
> behavior wherever one exists, themed with these tokens — custom chrome is a
> last resort, reserved for the editor canvas, live-collaboration presence, and
> document icons.* Two things landed here, both prerequisites for the rest:
>
> 1. **The deployment target moved 18.0 → 26.0** (`project.yml`). Standard
>    system components render Liquid Glass when built against that SDK, so the
>    floor buys the new look for native chrome with no `#available` fallbacks to
>    keep visually in sync. Nothing else in this change depends on 26.
> 2. **All text now scales with Dynamic Type**, which the handoff lists among
>    the platform behaviors you get free by staying native. The enabling
>    observation: the handoff's iOS sizes (34/28/22/17/16/15/13/12) *are* the HIG
>    defaults at the Large content size, so every token maps 1:1 onto a system
>    text style. `TypographySpec` gained a `textStyle`, `DocsFont.*` became
>    text-style-relative, and the app is unchanged at the default text size —
>    pinned by
>    `DocsTypographySpecTests.testEveryTokenSizeEqualsItsTextStyleDefaultAtTheLargeContentSize`.
>    Supporting pieces: `.docsTracking(spec, ratio)` scales letter-spacing (a
>    fixed `.tracking` in points drifts once text grows);
>    `scaledUIFont(_:for:dynamicTypeSize:)` (`UIFontMetrics`) scales the block
>    editor's UIKit fonts — rendered size only, so every `NSRange` stays a source
>    offset, and the size is an **argument** so the calling row can read
>    `@Environment(\.dynamicTypeSize)` and re-render when the setting changes
>    mid-document (a baked-in `UIFont` otherwise goes stale);
>    `docsScaledFont` covers the few component sizes off the HIG ramp (the 14pt
>    button label); `MaterialSymbol` scales by default (`scales: false` for
>    glyphs in hard-bounded boxes — `IconButton`, whose row of nine shares a
>    fixed width budget); `DocIcon` scales glyph and box together from one
>    value; fixed `height:` around text became `minHeight:` (`DocsTextField`,
>    `SearchField`, `DocsButton`, `NavBar` — whose standard-mode title, drawn in
>    an overlay that cannot grow the row, also gained the large title's
>    single-line truncation); the Appearance detent and the
>    Share/Version-history/slash-menu height caps scale; the two text-heavy
>    fixed-detent sheets (Conflict, Link editor) gained scroll views so their
>    actions can't fall below the fold; and **`DocRow` stacks its title above its
>    metadata at accessibility sizes** (`rowUsesStackedLayout`) — its date holds
>    the layout priority, so sharing one line collapsed the title to `"A…"`.
>
> Still to come in this refresh: the native tab shell and toolbars, iPad tab
> parity, the native editor toolbar, the Account screen and the Pages tree.

> **Revised: 2026-07-31 (native tab shell, toolbars, system search, iPad
> parity).** The app's chrome is now the platform's, which is what actually
> delivers the handoff's Liquid Glass look — the system draws it when built
> against the iOS 26 SDK.
>
> - **`MainTabView` replaces `HomeView`** as the one shell for both idioms: a
>   system `TabView` with `Tab(value:)` for Schrift/Shared/Profile and
>   **`Tab(value:role: .search)` last**. The search role is why the bar matches
>   `guidelines/tab-bars.html` without drawing anything: the system renders the
>   floating glass capsule, puts search in the separated circle at the trailing
>   edge, and — when search is selected — morphs the whole bar into the search
>   field. `.tabBarMinimizeBehavior(.onScrollDown)` gives the minimize-on-scroll
>   the guideline calls for. Tab glyphs stay Material Symbols, rendered to
>   template images.
> - **One `NavigationStack` per tab**, each with its own path, and one shared
>   `editorScreen(for:path:)` builder for the three tabs that open documents.
>   Per-tab stacks are required, not stylistic: `.toolbar(.hidden, for:
>   .tabBar)` (which the editor uses) only reaches the bar from inside a tab's
>   own stack, and per-tab paths are what preserve each tab's navigation state.
> - **The four tab roots dropped `NavBar`** for `.navigationTitle` +
>   `.navigationSubtitle(serverHost)` + `.toolbar`; Home's "+" is a
>   `ToolbarItem`. The drawn `TabBar` component and its catalog entry are
>   deleted. `NavBar` itself survives only for the editor, which converts next.
> - **Search uses the system field** (`.searchable` bound to the search role,
>   `.onSubmit(of: .search)` recording the term). `SearchViewModel` is untouched
>   — its 250 ms debounce still runs through `.task(id:)`. The recents chips and
>   Quick-access list stay as page content rather than `.searchSuggestions`,
>   which would have replaced the designed empty state with a plain system list.
> - **iPad reaches everything for the first time.** The size-class branch moved
>   out of `RootView` and into the documents tab, so iPad now has the tab bar
>   (as the top strip) and with it Search, Shared, Profile and sign-out — none of
>   which it could reach before — plus a create button in the split view's
>   sidebar, which it also lacked. The split view itself, including its
>   `.id(document.id)` detail identity, is unchanged.

> **Revised: 2026-07-31 (native editor toolbar; the last custom chrome
> retired).** The editor was the one screen still drawing its own bars. It now
> uses the same system toolbar as everything else — `.inline` and title-less,
> because the document title is a large in-canvas header, not bar chrome.
>
> - **One toolbar in both modes.** `editorToolbarActions` gained `.done` and
>   swaps it into **Edit**'s slot while editing, keeping Options either way, and Share except on a locally-created
> document, which has no share URL and no accesses to list. The editing session no longer needs a bar of its own.
> - **The save status moved into the editing surface** as a slim row above the
>   canvas. `saveStatusDisplay` and its precedence rules are untouched — a
>   recorded conflict still refuses to claim a sync or offer a retry that would
>   only re-park — which is the part that matters; only where it renders changed.
>   `EditorSaveBar` is gone and `SaveStatusIndicator.swift` holds the resolver
>   and the view.
>   *(Superseded 2026-08-16: that slim row had no reading-mode counterpart and
>   appeared out of nothing on the first keystroke, so it moved again — into the
>   shared document header's status slot. The resolver and its precedence are
>   still untouched. See the revision at the end of this file.)*
> - **Presence while editing is a count badge** on the Options button
>   (`presenceBadgeCount`, suppressed offline since peer state is only as fresh
>   as the last socket message). Reading mode keeps the `PresenceBar` avatar
>   stack, which has room for one.
>   *(Superseded 2026-08-16: the document header is shared by both surfaces now
>   and draws `PresenceBar` in either mode, so the badge became a second copy of
>   the same fact one row above it and was removed. `presentedPeerCount` and its
>   tests remain as the freshness rule, applied on both surfaces — see the
>   revision at the end of this file.)*
> - **Back is the system's**, in both modes. Leaving mid-edit is safe because
>   `onDisappear` already flushes; the old `onBack` closure existed only to
>   drive a drawn button and is deleted.
> - **Deleted:** `NavBar` (+`NavBarAction`), `EditorSaveBar`,
>   `InteractivePopGesture` and its restorer modifier, `DocsSpacing.navBarHeight`
>   / `largeTitleBarHeight`, and the catalog's Nav Bar card. Nothing in the app
>   hides a navigation bar any more, which is what made the pop-gesture
>   workaround necessary in the first place.

> **Revised: 2026-07-31 (editor polish — real glass, subpage summaries).**
> Follows the native-toolbar change above.
>
> - **The editor's floating surfaces are real Liquid Glass.** The formatting bar
>   and the slash menu used `.ultraThinMaterial` plus a hand-drawn border and
>   shadow to approximate it; they now use `.glassEffect(.regular, in:)` and
>   share a `GlassEffectContainer`, so the system supplies the refraction, edge
>   and shadow and renders both in one pass. This is the standing rule now:
>   *glass is for surfaces that float over content, never for content itself* —
>   see [`CLAUDE.md`](../CLAUDE.md).
> - **Subpage rows carry the handoff's one-line summary** under the title
>   (`Document.excerpt`, dropped when blank). The child-count chip
>   (`account_tree` + `numchild`) was already there.
>
> **Two kit items deliberately not implemented, with reasons:**
>
> - **Breadcrumbs** (the handoff's ancestor trail above the document title). The
>   trail is *document hierarchy*, not navigation history — the handoff computes
>   it by walking the tree — and the API exposes no ancestors route. `Document`
>   carries a treebeard `path`/`depth`, but resolving those to titles needs an
>   endpoint we can't verify against a server from here, and using the navigation
>   stack instead would be wrong the moment a document is reached from search or
>   an in-document link rather than from its parent. Deferred rather than shipped
>   with the wrong semantics.
> - **Dropping the reading-mode presence avatars.** The handoff's editor shows
>   presence *only* as the count badge on the options button. The app keeps the
>   `PresenceBar` avatar stack while reading (where there is room for it) and
>   uses the badge only while editing. Avatars carry *who* is present, which a
>   count cannot, and live collaboration is still being built out — trading that
>   away for mock fidelity would remove information from a feature that is not
>   finished yet.
>   *(Superseded 2026-08-16: the badge is gone entirely. The document header is
>   shared by both surfaces now, so the avatar stack is what presence looks like
>   in either mode — the same conclusion, reached without the badge.)*

> **Revised: 2026-07-31 (Account screen, flat Shared list, and the feedback
> registers).** The last of the screen-level handoff work.
>
> - **`AccountScreen`** is pushed from Profile's user row, which used to be a
>   static email line with nowhere to go. It is scoped to what `GET /users/me/`
>   actually returns (id, email, full name, short name, language): identity
>   hero, a display-only Profile section, a Sign-in section, and one link out to
>   the web app. The handoff's role badge, organization, "member since",
>   photo-change control and editable name are **not** implemented — the API has
>   none of them, and rows that cannot be filled or controls that cannot save
>   would be worse than a shorter screen. Note the Language row here is the
>   *server* profile's language, distinct from the app's own UI language in
>   Preferences (which is never written back to the server).
> - **Shared is flat** — an uppercase count eyebrow over rows drawn straight on
>   the page, matching Home's sections. The grouped `ListSection` card it used
>   to sit in is gone.
> - **The four feedback registers now exist as the handoff defines them.**
>   *Alert* for destructive confirms (delete document, disconnect, keep-server)
>   — these moved off `.confirmationDialog`, which is for choosing among
>   options, not for confirming one destructive verb. *Toast* for transient
>   confirmations ("Link copied", ~2s, glass, no button — a message you must
>   dismiss is not transient). *Skeleton* rows replace the spinner on a
>   first-load list, per the handoff's "no spinners on lists". *Callout* is
>   still unused and unbuilt: no screen calls for one.
> - The toast is owned by the **presenting** screen, not the sheets that raise
>   it — Options and Share both dismiss themselves in the same breath, and a
>   toast inside one would be torn down before it could be read.

> **Revised: 2026-07-31 (Pages tree drawer — the refresh complete).** The
> handoff's `DocTreePanel`, which it designed but never wired to an opener.
>
> - A **leading slide-in drawer** in the editor, opened from a toolbar button
>   beside back (it is a *left* panel, and the trailing group already has
>   three items). Root row = the open document, then its subpages, expandable
>   to any depth; the scrim closes it.
> - **Levels load lazily and cache-first.** Opening fetches the root's children;
>   each expand fetches that node's. Every level is read from
>   `DocumentChildrenCacheStore` before the network — the same store the
>   editor's own Subpages list fills — so a document you have already opened
>   has its level available offline. A failed fetch keeps whatever the cache
>   gave and says so; it never empties a level the user can see, and never
>   tears the editor down (it concerns a *different* document's children).
>   **"Work offline" is honoured the same way the document lists honour it** —
>   read through the view model's injected `UserDefaults`, and the network is
>   never reached at all, not attempted-and-caught.
> - **A level that failed with nothing cached collapses again**, and its error
>   is recorded per node rather than in one shared flag. Left expanded it would
>   render as a node with no children — indistinguishable from a leaf, with no
>   way back — and one shared flag would let a success elsewhere in the tree
>   silently clear a message about a level the user is still looking at.
>   Collapsed, the arrow returns, and tapping it is the retry.
> - **"New page" only slots into a level that is actually known.** Appending to
>   an unloaded one would show, and durably cache, a fabricated one-item level
>   that hides the document's real children — and the cache is shared with the
>   editor's Subpages list, so the lie outlives the drawer. This is the same
>   rule, for the same reason, as `EditorViewModel.addSubpage`. A per-level
>   mutation stamp additionally drops a list fetch that started *before* the
>   create, whose snapshot would otherwise take the new page back off screen —
>   and the stamp is bumped **only when the create actually appended**. Bumping
>   it on a create that declined to append blocks the in-flight fetch as well,
>   and then *neither* writer fills the level: it stays unknown, and the drawer
>   reports "no subpages" about a document that just got its first one.
> - A failed **create** is cleared when the drawer is reopened, not by the next
>   successful load. The view model is `@State` on the editor and outlives the
>   drawer, so without that a single failed "New page" would keep reporting
>   itself over every later opening; clearing it on any load instead would let
>   an unrelated level erase a message the user is still reading.
> - **The disclosure arrow comes from `numchild`**, so it appears before a level
>   has ever been fetched. `pagesTreeRows` is the pure flattening rule and
>   carries the whole layout decision — including that an expanded-but-unloaded
>   node contributes nothing yet, so a slow level never collapses the ones above
>   it, and a cycle in server data terminates instead of overrunning the stack.
> - The arrow and the title are **separate controls**: collapsing a branch
>   should not navigate away from what you are reading. Both are floored at the
>   44pt tap target (`PagesTreeLayout.disclosureWidth`; the title's label fills
>   the row's height before taking its tap shape, or a 44pt-*looking* row would
>   only open from the middle strip of text). The chevron itself stays small —
>   this is `IconButton`'s pattern, tap target around glyph.
> - A row's identity is **the (parent, document) pair**, not the document id.
>   The tree is drawn from a session-local dictionary of levels, so a document
>   the server has re-parented can still sit in a stale level while its new
>   parent lists it too; keyed on the id alone those two rows collide in
>   `ForEach`.
> - Because it is an overlay rather than a sheet it gets **none of a sheet's
>   VoiceOver scoping for free**: the editor behind it is explicitly
>   `.accessibilityHidden` while it is open, and opening/closing posts a
>   screen-changed notification. A new modal-ish overlay owes the same — and
>   note that hiding the screen's body is **not** enough on its own: toolbar
>   content is hosted by the navigation bar as its own accessibility subtree,
>   so the bar buttons must be hidden with it or a swipe still reaches them
>   through the covering surface.
>
> **Deviation:** the drawer sits below the navigation bar rather than covering
> the full height as the mock does, so the toolbar (and its back button) stays
> reachable while the tree is open. **Still deferred:** breadcrumbs, for the
> reason recorded in the previous amendment — the API exposes no ancestors
> route, and the tree drawer does not change that.

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
(`NavBar`, `TabBar`, `DocRow`, `ListRow`, `ListSection`,
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
  > **Superseded 2026-07-31.** The revised handoff specifies an Account screen,
  > so it is back — `Features/Profile/AccountScreen.swift`, pushed from the
  > Profile user row via `NavigationLink(value: ProfileRoute.account)` with the
  > destination registered in `MainTabView`. It is trimmed to what `/users/me/`
  > actually returns (see the 2026-07-31 amendment near the top of this file).
  > `HomeView` no longer exists either; its shell is `MainTabView`.
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

**Superseded 2026-07-31** — the drawn `NavBar` is gone. Every screen uses the
system navigation bar (`.navigationTitle` / `.navigationSubtitle` / `.toolbar`),
which handles the large-title collapse, spacing and scroll-edge behavior this
section was specifying by hand. Kept below as the record of what the handoff
asked for. See the amendments at the top of this document.

The (former) `NavBar` always rendered a fixed **44pt top row**, even in large-title
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
padding `0/16/6`, footer padding `6/16/0`) already matches and is preserved (still
used by the Shared and Profile tab screens). (The **Options, Share, and
Version-history sheets** were later flattened to boxless, dividerless menus under
a `SheetHeader` — see the 2026-07-12 amendments at the top and the flat-sheet
pattern in [`CLAUDE.md`](../CLAUDE.md); `ProfileRowDivider` consequently has no
remaining call sites.)

### 8.4 Sheets & scrolling (the "share dialog scroll" fix)

Handoff sheets (`chrome.jsx` `Sheet`) are **bottom sheets** with a grabber, an
inline title, a scrollable body bounded by a **detent**, and bottom padding for
the home indicator. *(Superseded "before" snapshot — the state this part fixed:)*
the Share / Options / Version sheets originally presented as full-height
`.sheet`s (no detent, no drag indicator) wrapping a `NavigationStack` + "Done",
with all content in one scroll view — so a long member list pushed the primary
**Copy link** action below the fold. (They now use `.presentationDetents` + a
`SheetHeader`; see the 2026-07-12 amendments at the top.)

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

**Superseded 2026-07-31** — the drawn `TabBar` component is gone. Top-level
navigation is the system `TabView` (`MainTabView`), which renders the handoff's
floating Liquid Glass capsule and separated search button itself. See the
amendment at the top of this document.

### 8.6 Layout tests

Layout is verified primarily via the component `#Preview` catalogs (light **and**
dark) and a manual run. Pure helpers are unit-tested where they exist:
the divider leading-inset rule (`52` with a leading icon, else `16`), the
editor's toolbar-action table (`editorToolbarActions`) and presence-freshness
rule (`presentedPeerCount`), and the sheet detent/`maxHeight` constants.
(`navBarShowsTopRow` went with `NavBar`; the system bar owns that behavior now.)

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

> **Revised: 2026-08-01 (accessibility pass).** Cleanup after the native-first
> refresh, from an audit of the completed series.
>
> - **A 44pt frame is not a 44pt tap target.** A plain `Button` hit-tests the
>   shape its label *draws*, so a row whose label is `HStack { icon; title;
>   Spacer() }` was tappable on the glyphs alone — the `Spacer` and the padding
>   were dead however tall the frame said it was. Every interactive row now ends
>   its label with `.contentShape(Rectangle())`, and a label filling a taller
>   container takes `.frame(maxHeight: .infinity)` first (a `Text` is only as
>   tall as its line) — and a *narrow* label needs the width floor too, which is
>   why the editor's "Save" carries a `minWidth` its longer-phrased sibling
>   states do not. This had been true of `ListRow` since it was written,
>   which put it under **Delete document, Sign out and both conflict-resolution
>   choices** — the decisions least forgiving of a missed tap. It is invisible in
>   a screenshot and uncatchable by the suite; test it by tapping the padding.
> - Icon-only controls go through **`IconButton`**, which keeps the small glyph
>   and pads *outside* it to the floor, rather than wrapping a bare
>   `MaterialSymbol` in a `Button` (the Home error-banner dismiss was a 13pt
>   cross). Where a hard frame would move the glyph — the checklist checkbox is
>   the adornment of a `.top`-aligned row — grow the hit rect and give the growth
>   back with symmetric negative padding.
> - **`Avatar`/`AvatarGroup` now scale with Dynamic Type**, the last shipping
>   views with a bare `Font.system(size:)` and a fixed frame; the refresh's
>   typography sweep missed them, so they shrank against the names beside them at
>   large text sizes. `avatarGroupMetrics(size:scale:)` is the pure rule, and its
>   test pins the one thing that can go wrong: the diameter, the negative overlap
>   and the "+N" label must scale *together*.
> - The eleven **`DocsColor` wrappers with no call site** are gone, per the
>   standing convention that a hue consumed only by a style resolver stays
>   hex-only. The `DocsColorHex`/`DocsColorHexDark` palette is untouched — it is
>   the design system's colour definition, complete whether or not every entry is
>   currently spent.

> **Amended: 2026-08-05 (the save status took half the editor).**
> `maxHeight: .infinity` was the wrong half of the tap-target technique above
> for the editing save-status row, and the bug was very visible: the document
> title and first line of content sat mid-screen with the keyboard up.
>
> A flexible frame answers the **proposal**, clamped into the bounds you give it,
> and falls back to its child where the proposal is unspecified or a bound is
> missing — so an unbounded max means "all of it" as soon as an ancestor hands
> down a concrete height. Both halves matter here: in the height axis the drawer's
> label and the old save label were identically bounded (no min, infinite max), so
> only the proposal separates them.
> That is the real test, not "is an ancestor bounded". `editingSurface` **was** a
> `VStack(spacing: 0)` of the row and the canvas in a height-bounded container,
> so the Save/retry label answered 874pt to an 874pt proposal, the stack saw two
> greedy children and split the free height between them. (That structure is gone
> — the editing canvas is a bare `BlockEditorView` and the status sits inside its
> `ScrollView` — but the lesson is about the container shape, not that call site.) `PagesTreeDrawer`
> keeps the same technique and is *not* greedy, because a scroll view proposes an
> unspecified height along its scroll axis, so its rows are ideal-sized — the
> distinction that tells the two call sites apart.
>
> **Amended: 2026-08-06.** That drawer row does still get its full 44pt tap
> shape under an unspecified proposal, and it is now measured rather than
> assumed. Given only a `minHeight:`, a flexible frame clamps an unspecified
> proposal *up to* that minimum and proposes **that** to its child, so the row
> hands 44pt inward and the fill-the-row label answers 44pt. The leaf rows had
> been read the other way twice — a leaf reserves the disclosure column with a
> 22pt `Color.clear` where a parent puts a 44pt button, which looks like it
> should shorten the label beside it — but the proposal arrives down the row,
> not across the `HStack`, so leaf and parent measure identically.
> `PagesTreeDrawerTests` pins that, and carries a negative control (the same row
> with the fill removed, which must measure short) because a measurement that
> cannot fail proves nothing.
>
> Measuring a label *inside* a row took three tries, which is worth writing down.
> `sizeThatFits` cannot see this class of defect at all: the row floors at 44pt
> whether or not the label fills it. A `GeometryReader` behind the
> `contentShape`'d label does see it, but reports `.zero` unless the hosted view
> is in a `UIWindow` and laid out. A hosted view's accessibility frames track the
> same bounds and can read the *real* drawer rather than a copy — that is how the
> shipping view was checked (every row 44.0pt; deleting the fill dropped every
> row, parents included, to 21.0pt) — but they are materialized only where an
> accessibility client is, so on the freshly erased simulator CI runs they come
> back empty and the whole suite goes red. The landed tests therefore measure the
> row's shape reproduced from the same tokens, and say so; keep the replica in
> step with `treeRow`.
>
> `SaveStatusIndicator` now floors each state itself
> (`minHeight: DocsSpacing.rowMinHeight`), which never claims a proposal and
> still grows with Dynamic Type. It is also the *bigger* target: the row pads 8pt
> below before its own 44pt floor, so a fill-the-row label only ever got 36pt at
> the row's floor — 44pt was reached only while the row was inflating. The three
> passive states carry the same floor so the canvas cannot resize as the status
> moves Save → Saving → Saved. That levelling is a **default-size** property: a
> floor only equalises states whose own text fits inside it, so a phrase that
> grows past 44pt is text-sized again — the right trade, since capping it would
> clip the text. `SaveStatusIndicatorTests` measures the hosted component at the
> width the row actually offers it (the screen less the row's gutters), against a
> full-screen proposal, a 10pt proposal and the largest accessibility size, in
> English through an isolated `LocalizationStore` — a width floor only binds while
> the label is narrower than the floor, which "Save" is and its translations need
> not be.

> **Revised: 2026-08-16 (one document, drawn once — the reading and editing
> surfaces made identical).** The editor renders the same `[EditorBlock]` twice,
> as SwiftUI `Text` while reading and as a UIKit `UITextView` while editing, and
> each surface carried its own copy of what a block looks like. The copies had
> drifted far enough that tapping a paragraph re-laid-out the whole page, which
> reads as *navigating somewhere* rather than as placing a caret: the body gutter
> was 22pt reading and 16pt editing (so every line re-wrapped and slid 6pt left),
> the inter-block gap was 12pt against 6pt (cumulative — a ten-block document
> pulled ~54pt up), the header's whole metadata row had no editing counterpart
> (~38pt more), the title lost its `-0.02em` tracking, a quote lost its sunken
> panel and its brand bar turned into a grey hairline, a prose `.unknown` block
> turned from 17pt body text into 15pt monospace in a panel, the checkbox shrank
> 20pt → 17pt, and a completed to-do lost its strikethrough. A second jump landed
> on the *first keystroke*, when the save-status strip materialised above the
> canvas and shoved the document down ~52pt.
>
> The fix is structural, not a round of matched constants — matched constants are
> what had drifted. **`Schrift/Features/Editor/EditorBlockStyle.swift`** is now
> the one table both surfaces read:
>
> - `EditorBlockMetrics` — gutter (`DocsSpacing.gutter`, like every other screen
>   and like the editor's own chrome), inter-block gap, adornment gap, checkbox
>   size and its hit padding, quote/panel padding, divider padding, and the
>   header spacings. Each entry is a place the two surfaces disagreed.
> - `blockTextAppearance(for:text:)` → a `BlockTextAppearance` of raw tokens
>   (`TypographySpec`, `Font.Design?`, italic, struck-through, light/dark hex),
>   converted to `Font`/`Color` by the reading surface and to
>   `UIFont`/`UIColor` by `blockTextStyling` — the same raw-value split the
>   design-system style resolvers use.
> - `editorBlockDecoration(_:)` — one `ViewModifier` for the quote bar and the
>   verbatim panel, so the `Text` and the `UITextView` cannot be decorated
>   differently. It varies **only padding/background/overlay values**, never
>   which view is decorated: a structural branch there would recreate the
>   `UITextView` and drop the keyboard on every block conversion.
> - `EditorBlockAdornment` — the bullet, the number and the checkbox. The
>   checkbox is a `Button` only where a toggle closure is supplied (editing);
>   the symmetric ±`checkboxHitPadding` pair grows the target and gives every
>   point back, so the plain reading glyph occupies exactly the same space. The
>   shape clears 44pt **in isolation**; in a checklist, consecutive rows sit
>   `blockSpacing` apart, so neighbouring shapes overlap and the unambiguous
>   per-checkbox target is bounded by the row pitch (glyph + gap ≈ 35pt). That is
>   the honest claim — about half again as much as the ~22pt pitch these rows had
>   before ("roughly doubles" was the old *shape* comparison and does not survive
>   restating this as a pitch), and 44pt on a dense list would need a taller row
>   than the reading surface shares.
>   That padding is a **token with headroom, not an arithmetic fit**: sizing it
>   as `(rowMinHeight - checkboxSize) / 2` lands at 43pt, because a
>   `MaterialSymbol` is a `Text` and occupies its glyph's typographic box (23pt
>   for a 24pt symbol), not its point size — and the assertion that "proves" the
>   fit substitutes to `rowMinHeight == rowMinHeight`, so it can never catch the
>   miss. Measure the padded box instead.
> - `EditorDocumentHeader` — the title and the reach/status/presence row, drawn
>   by **both** surfaces. The title is a `TextField` while editing and a `Text`
>   while reading, same font and tracking either way, and an untitled document
>   now shows the same "Untitled" placeholder on both (it used to render an empty
>   line while reading and a placeholder while editing).
>
> Three consequences worth stating plainly:
>
> - **The save status moved into that shared header's status slot**, replacing
>   the strip pinned above the canvas. `saveStatusDisplay` and its precedence are
>   untouched — a recorded conflict still refuses to claim a sync or offer a
>   retry that would only re-park — and `.none` now falls through to the reading
>   sync caption rather than collapsing, so the slot never changes height under
>   the user mid-keystroke. The trade: the status scrolls with the document
>   instead of staying pinned. Nothing becomes unreachable — the toolbar keeps
>   **Done**, which flushes exactly as tapping **Save** does.
> - **The checkbox is 24pt**, larger than either surface drew it, and its state
>   is finally spoken: the glyph is a Private-Use-Area character and so is
>   `accessibilityHidden`, and a strikethrough is not spoken, so a checklist read
>   aloud gave no clue which items were done. The reading row carries an
>   `accessibilityValue` of the *state* ("Done" / "Not done"), distinct from the
>   editing checkbox's *action* label ("Mark as done"). It is set on the `Text`
>   rather than by collapsing the row with
>   `.accessibilityElement(children: .combine)` — the conventional way to give a
>   row a value, but one that flattens the element tree, and that `Text` can hold
>   inline links VoiceOver reaches through the Links rotor. Whether combining
>   really would drop them is not something this repo can assert (it runs no
>   VoiceOver tests), and between two options that both add the announcement, the
>   one that cannot take anything away is the right bet.
> - **Scroll position survives the swap.** The two surfaces are different
>   `ScrollView`s, so the offset used to be discarded: tapping a paragraph three
>   screens down opened the editor at the very top. Both canvases now name their
>   rows with `EditorScrollTarget` under a `.scrollTargetLayout()` and share one
>   `.scrollPosition(id:anchor: .top)` binding. It is backed by
>   `EditorScrollAnchorStore`, a plain (deliberately **not** `@Observable`)
>   reference type — routing scroll updates through `@State` would invalidate
>   `EditorView` on every change, and the reading surface re-runs
>   `AttributedString(markdown:)` and an `NSDataDetector` pass per block.
>
> `EditorSurfaceParityTests` pins what a shared table cannot guarantee by
> itself — that the SwiftUI and UIKit conversions of one appearance land on the
> same font (weight read from the descriptor, since UIKit flags `.semibold` as
> `.traitBold`) and the same colour, that a completed to-do is struck through
> over the *whole buffer* on both surfaces, that the checkbox's hit padding nets
> out, and that the decoration adds exactly the metrics it claims. Every
> measurement carries a negative control, and the three fixes it exists to guard
> were mutation-checked: reverting each one reds exactly the intended tests.
>
> **One residual is accepted and bounded rather than closed.** A SwiftUI `Text`
> carries a little more leading than the same font in a `UITextView` with
> `lineFragmentPadding` and `textContainerInset` zeroed — ~3.7pt at body 17,
> ~7.3pt at title1 28, per wrapped line — so a paragraph is a hair shorter while
> editing. Every *adorned* row is exactly equal, because the SwiftUI adornment
> sets the row height on both sides, and nothing moves horizontally or re-wraps,
> so it is a uniform tightening rather than a re-flow. The parity test bounds it
> at `0.35 × font size × line count` with a hard `delta >= 0` on the other side,
> which is what catches the two historical per-row offenders (a quote's missing
> panel padding, ~20pt on one 17pt line; a verbatim panel around every
> `.unknown`, ~15pt the other way). Closing it would mean reverse-engineering
> SwiftUI's internal line metrics into the text container's insets.
>
> **Presence has one home.** The Options button's editing-only count badge
> existed because the editing surface had no `PresenceBar`; the shared header
> gives it one in both modes, so the badge became a second copy of the same fact
> one row above it and is gone. `presentedPeerCount` — renamed from `presenceBadgeCount`, since the badge it was named for is gone — and its tests survive as
> the one rule for whether peer state is fresh enough to show at all, now applied
> on **both** surfaces: before, only the badge honoured it and the reading
> surface drew its avatars offline, where they are whatever the socket last said.
