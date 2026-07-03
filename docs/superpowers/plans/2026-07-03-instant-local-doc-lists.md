# Instant-local document lists (Home, Subpages/Tree, Shared)

**Date:** 2026-07-03
**Status:** Implemented

## Problem

Opening a document was already instant-offline
(`DocumentContentCacheStore`, see
[the 2026-07-03 content design](../specs/2026-07-03-instant-local-doc-content-design.md)),
but the **lists** around it were not:

- The Home list seeded from `DocumentCacheStore` at init, yet `load()` set
  `isLoading = true` unconditionally and `DocumentListView` rendered a
  `ProgressView` *instead of* the list whenever `isLoading` was true. Since
  `.task` refires `load()` on every appearance, the cached list was replaced
  by a spinner on every navigation back. Recents were cached only for the
  `.all` filter.
- Sub pages (the editor's Subpages section and the Pages tree panel) had no
  persistence at all — both view models are recreated per navigation, so
  every hop refetched from a blank state.
- The Shared tab had no cache, ignored the `schrift.workOffline` preference,
  and set an `errorMessage` its screen never rendered.

## Design

Replicate the editor's proven pattern for all three surfaces: synchronous
local seed → spinner only on a true first run → silent generation-guarded
revalidation → write-through on success → purge on delete/404/403 → errors
surfaced only on first-ever load or explicit pull-to-refresh. Search quick
access was deliberately left out of scope.

### Decisions

- **Per-filter recent keys.** `recentDocumentsCacheKey(_:)` maps each
  `HomeFilter` to a stable name-based key; `.all` keeps the original
  `dev.llun.Schrift.cachedRecentDocuments` key so pre-split caches migrate
  for free. Keys are never derived from `HomeFilter.rawValue` Ints.
- **Optional loads drive the spinner.** `DocumentCacheStore` list loads return
  `[Document]?`: nil means never cached, which is distinct from a cached
  empty list (a real fetch result). `shouldShowLoadingPlaceholder` (pure,
  in `HomeFilter.swift`) allows the placeholder only when there is no cache
  entry *and* nothing on screen.
- **Generation guard in `HomeViewModel`.** `.task` refires on every appearance
  and races `.refreshable` and rapid filter taps; a monotonic `loadGeneration`
  (mirroring `EditorViewModel.revalidationGeneration`) makes the last-started
  load win and fixes a pre-existing latent race.
- **Children cache is UserDefaults-backed.** `DocumentChildrenCacheStore`
  keeps one `[UUID: CachedChildrenEntry]` blob under
  `dev.llun.Schrift.cachedDocumentChildren` (note: UUID keys are not
  `CodingKey`-representable, so JSONEncoder serializes the dictionary as a
  flat alternating key/value **array**, not a string-keyed object) —
  children lists are small metadata; the file-based store is reserved for
  full bodies. Millisecond
  date coding (like `PendingDraftStore`): plain `.iso8601` truncates to whole
  seconds, which would tie same-second saves and make eviction recency
  arbitrary. Capped at 100 parents, evicting by the existing pure
  `contentCacheEvictions` selection rather than a new sibling. An injectable
  `now` closure keeps eviction testable.
- **Both sub-page consumers share the store.** `EditorViewModel` seeds
  `subpages` in `load()`'s one-time local phase, writes through in
  `loadChildren()`/`addSubpage()`, and purges in `becomeUnavailable()`
  (404/403) and `handleDidDelete()`. `DocTreeModel` seeds each node
  synchronously before its fetch and revalidates each node once per panel
  session; a failed fetch keeps whatever is shown and leaves un-cached nodes
  un-loaded rather than claiming "no subpages".
- **Shared tab caches both scopes** under
  `dev.llun.Schrift.cachedSharedWithMeDocuments` / `…ByMeDocuments`, honours
  `schrift.workOffline`, gains an offline banner state, pull-to-refresh, a
  rendered error footnote, the same latest-wins generation guard as Home
  (its `.task` and `.refreshable` race identically), and a first-run
  `ProgressView` so the header never claims "0 documents" for lists that are
  simply not yet known.
- **Silent vs loud errors.** Passive revalidation failures keep cached rows
  and set only `isOffline`; `refresh()` (pull-to-refresh) passes
  `userInitiated: true` and surfaces the failure. Loudness is keyed to
  **cache existence for the exact list being loaded** (`loadRecent…(filter:)
  == nil`), not to whatever rows happen to be on screen — pinned rows are no
  evidence for a never-cached filter, so its first-ever failure still shows
  the error instead of masquerading as an empty list. The Shared tab applies
  the same rule per scope: a failing scope is silenced only by *its own*
  cache, never by the other scope's.
- **Placeholders are keyed to what will actually render.** Home counts
  pinned rows as "visible" only when the pinned section shows for the
  current filter (it is hidden under `.pinned`), so a first-ever Pinned
  visit spins instead of rendering blank; the view's empty-state gate uses
  `showsPinnedSection` for the same reason. The Shared tab tracks
  `knownScopes` (cached or fetched this session) and derives
  `showsLoadingPlaceholder`/`showsDocumentList` per *visible* scope — an
  unknown scope never renders the "0 documents" header, even offline or
  when the segment is flipped mid-fetch.
- **Children fetches are latest-wins too.** `EditorViewModel` keeps a
  `childrenGeneration` counter: `loadChildren()` applies its response only
  if no newer fetch or `addSubpage()` superseded it, so a pre-create
  snapshot can never overwrite (and durably cache) a list missing the
  just-added child.
- **Mutations never fabricate cache entries.** `addSubpage` appends to the
  cached children list only when that list is actually known (`subpages !=
  nil`) — appending to an unknown list would persist a one-element
  "complete" result that hides the real children. `createDocument`'s
  work-offline path shows and persists the new document under the `.all`
  list only (screen and cache agree): a brand-new document is neither a
  favorite nor shared-with-me, so surfacing it under the selected filter
  would poison that filter's cache or vanish on the next cache-served load.
- **Delete purges ghosts everywhere.** Delete/404/403 remove the document's
  own children entry *and* call `removeDocument(_:)`, which strips the id
  from every other parent's cached list — otherwise a deleted subpage stays
  visible offline inside its parent's Subpages/tree forever.
- **Tree revalidation counts only successes.** `DocTreeModel` un-marks a node
  on a failed fetch so collapse/re-expand (or reopening the panel) retries
  after a transient error; only a successful fetch consumes the
  once-per-session revalidation.
- **Work-offline reads are injected.** Both `HomeViewModel` and
  `SharedViewModel` read `schrift.workOffline` from an injected
  `userDefaults: UserDefaults = .standard`, keeping tests off the global
  singleton.
- **Sign-out does not clear metadata caches** — consistent with the recorded
  decision for `DocumentCacheStore` in the content-cache spec; only full
  document bodies (`DocumentContentCacheStore`) are purged. The `RootView`
  comment names `DocumentChildrenCacheStore` explicitly.
- **Accepted duplication.** Home's `.shared` filter (`is_creator_me=false`)
  and Shared's "with me" scope issue the same query but cache under different
  keys; coupling the stores would be worse than one duplicated page of
  metadata.

### Review findings consciously declined (recorded)

- **Shared test-fixture builders**: the per-file inline JSON fixtures are
  duplicated across suites, but CLAUDE.md's testing convention mandates
  *inline* fixtures — extraction to a shared helper would trade convention
  for DRY.
- **Skipping unchanged-content children saves**: the write-through refreshes
  `syncedAt`, which is the eviction-recency signal; skipping "no-op" saves
  would evict frequently-opened-but-unchanged parents first.
- **Memoizing the children blob per store instance**: multiple store
  instances (one per `EditorScreen`, plus the tree panel's) share one
  UserDefaults key; a per-instance memo would serve stale data across
  screens. The store stays stateless over its key, like
  `DocumentContentCacheStore` over its directory.

### Known gaps (recorded, not fixed here)

- `DocumentListView` passes `offlineAvailable: isOffline` uniformly to every
  `DocRow`, so the badge doesn't check whether that document's *content* is
  actually cached.
- `DocTreeRow` gates its chevron on the parent list's (possibly stale)
  `numchild` snapshot, so offline a node with cached children but a stale
  `numchild == 0` shows no expander.
- Cached `Document` values round-trip through `.iso8601` (whole-second)
  while the API delivers fractional seconds, so a cached document is not
  `Equatable`-equal to its freshly fetched twin. Nothing diffs the two at
  runtime; tests must not assert cross-source equality.
