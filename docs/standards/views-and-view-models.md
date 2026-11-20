# Views & view models (MVVM)

- Each feature is a pair: `@MainActor @Observable final class <Feature>ViewModel`
  (owns all mutable UI state as plain `var`; injected dependencies and identity
  are `let`) + a `struct <Feature>View/Screen: View` that observes it via
  `@Bindable var viewModel`. Never `@StateObject`/`@ObservedObject`.
- Views **never** do networking or persistence directly — they call `async`
  view-model methods from `.task {}`, `.task(id:)`, or
  `Task { await viewModel.x() }`.
- A view model that must retain state across presentations is built **once** in
  the view's `init` and stored in `@State` via `_viewModel = State(initialValue:)`
  so parent re-renders never recreate the session. Sheet VMs follow the same
  rule — `EditorView` builds its Options and Share VMs in its `init` and stores
  them in `@State`; no VM is constructed inline inside a `.sheet {}` closure.
- All model mutation flows through **named intent methods** on the VM; the view
  forwards events into them and never mutates model arrays/state directly.
  Binding setters and intent methods early-return on unchanged input
  (`guard old != new`) to avoid spurious dirty/save churn.
- **Navigation lives in the view**, not the VM: a `NavigationStack(path:)` per
  tab over a `NavigationPath` — push `DocumentEditorRoute` values for document
  screens (ordinary open or one-time creation intent)
  (add a small `Hashable` route enum alongside them if an auxiliary screen ever
  needs one), with one `navigationDestination(for:)` per pushed type — plus
  closure callbacks
  (`onOpenDocument`, `onCreatedDocument`, `onSignOut`, …). VMs signal outcomes via state flags
  (`didDelete`), they don't navigate.
- **Top-level navigation is the system `TabView`, and the tab roots use system
  navigation bars.** `MainTabView` (`Schrift/Features/Home/MainTabView.swift`)
  is the one shell for both idioms: ordinary `Tab(value:)` destinations for
  Schrift/Shared/Profile, with **Profile last**. Search is not a primary tab and
  no destination uses `role: .search`. Screens set `.navigationTitle` /
  `.navigationSubtitle` and put actions in `.toolbar` — they do not draw a `NavBar`.
  Keep native Liquid Glass, minimize-on-scroll, scroll-edge effects and safe areas.
  - The offline banner on Home, Shared and Search goes on the list's `ScrollView`
    as `.safeAreaInset(edge: .top, spacing: 0)`, never as a `VStack` sibling above
    it. In a `VStack`, inserting the banner while the screen is up (it is debounced,
    so it typically lands after a pull to refresh) moved the scroll view down, and
    the bar stopped drawing the large title and subtitle — a blank band under "+"
    until the screen was rebuilt. The inset keeps the scroll view against the bar;
    collapsed, the opaque strip sits flush under the bar and rows only pass under
    the bar's glass, as online. Not `.safeAreaBar`: rows showed between the
    collapsed bar and the strip. Never let such a strip's fill bleed
    through the top edge: the bare `.background(color)` is the ShapeStyle overload
    that ignores the safe area on every edge, so a strip against the bar's safe area
    paints up through the whole bar. Use
    `.background(color, ignoresSafeAreaEdges: .horizontal)` (and give a hairline
    `.ignoresSafeArea(edges: .horizontal)`), which keeps the top bounded while the
    strip still runs edge to edge in landscape. That bleed is what hid Home's large
    title and subtitle when the screen launched offline (a grey band under "+",
    read as blank in White); the `VStack` insertion above is what hid them when the
    banner arrived later.
  - Editors are pushed with the system's standard slide, never
    `.navigationTransition(.zoom)`: popping a zoomed editor on iOS 26 intermittently
    leaves the bar in its collapsed large-title state, so Home's title goes missing on
    return, and no app-side repair held (docs/design-system.md, 2026-11-03).
  - Home's circular create action uses a Material Symbols template `Image`
    and `.buttonBorderShape(.circle)`. A `MaterialSymbol` text label is sized
    as a wider text action by the native toolbar, making its glass surface oval.
  - **Independent navigation per primary tab.** Compact Home and Shared own
    separate `NavigationPath`s; Profile owns its account stack. Regular-width
    Home owns a `NavigationSplitView` with inline sidebar search.
  - Home's compact search affordance pushes `HomeRoute.search` onto `docsPath`.
    Search results push `DocumentEditorRoute` onto that same path: Back returns
    to Search, then Home. Retain the shell-owned `SearchViewModel` so the query,
    results and recent terms survive navigation and tab switches.
  - Search uses `.searchable` with `.navigationBarDrawer(displayMode: .always)`;
    do not rely on a search-role tab to reveal its field. Home's shortcut remains
    one localized accessibility button and stays enabled offline (Search then looks
    through this device's documents); the regular-width inline field is the
    server's search and disables offline with an explanation, recovering on
    reconnect.
  - **Search is on-device first, then server** (`LocalSearch.swift`,
    `SearchViewModel.search()`). Every keystroke matches the cached documents at once,
    with no debounce, off the main actor and cancelled with the task; the server is
    asked after the debounce and `mergeSearchResults` shows its rows in its order, then
    the on-device matches it did not return under an "On this device" label (deduped by
    id). The index is only `DocumentCacheStore.documents(fetchedFor: <signed-in user>)`
    (lists stamped for another account or unstamped never appear; nothing without a
    known account) plus `DocumentChildrenCacheStore.children(ofParents:)` of exactly
    those documents, with `DocumentContentCacheStore` body text attached only to
    documents so listed. Matching is `searchQueryTerms`/`searchTextContains` from
    `DocHighlight.swift` (every term must appear in the title, excerpt or body), ranked
    title matches first, then recency. Offline the server's retained rows are ignored,
    no request is made, and the banner says results are from this device only; results
    already on screen are never replaced by a skeleton while the server or the device is
    working (offline too, `isSearching` holds until the device answers), and the server's
    rows for the previous query stay in their section until its new answer lands, but only
    while the current query is theirs or refines it (`showsServerRows`); a failed request
    drops another query's rows. On-device rows record the account they were found for and
    are hidden from any other; server and Quick access rows record the sign-in session
    (`signInGeneration`, passed by `SearchScreen` and set by `beginSession`) and the account
    known when they landed, so an answer that lands before a re-login learns the id is kept,
    and rows known to be another account's are hidden at once. `SearchScreen` keys its tasks
    on `signInGeneration`, and the search task also on `signedInUserID` (observed through
    `pins.revision`), so the device is searched again once a re-login learns the id. The
    on-device index lives for one session: one build at a time (later keystrokes await it),
    dropped when the query is cleared, when Search appears or on re-login
    (`beginSession`/`invalidateLocalIndex`), and rebuilt for another account or availability
    token; a build that finishes after its session was reset is discarded. Every non-empty
    search clears `errorKey` first.
  - Home (including Search) and Shared share one `editorScreen(for:path:)`
    builder. `.toolbar(.hidden, for: .tabBar)` hides the native bar while an
    editor is pushed and restores it on pop. Keep Profile's account destination.
  - The **editor** uses the same system bar, `.inline` and title-less: the
    document title is a large in-canvas header, not bar chrome. One toolbar
    serves both modes — `editorToolbarActions` swaps **Edit** for **Done** in
    the same slot — so nothing hides the navigation bar anywhere in the app
    any more, and swipe-back is the system's own. (`NavBar`, `EditorSaveBar`
    and the `InteractivePopGesture` restorer existed only for the hidden-bar
    arrangement and are gone.)
- Async VM methods **catch errors internally** and set a user-facing
  `var errorKey: L10nKey?` — a friendly copy key of the form
  `"Couldn't <do X>. Please try again."` (`Strings+en.swift`), resolved by the
  view via `loc[errorKey]` — they don't rethrow, surface raw errors, or store a
  pre-resolved `String`. (This superseded a plain `var errorMessage: String?`
  when localization landed; see
  [Localization & appearance](localization-and-appearance.md#localization--appearance).) Loading state is a
  `var isLoading` (or a named flag like
  `isSigningIn`/`isDuplicating`). Simple one-shot methods reset it with
  `defer { isLoading = false }`; generation-guarded list/content loads must
  **not** use `defer` — they reset explicitly, gated on
  `generation == loadGeneration` (HomeViewModel, SharedViewModel), so a
  superseded load can never clear a newer load's spinner.
