# Instant Local Document Content + Background Sync — Design Spec

> **Amendment (2026-07-03):** the document **lists** (Home, the editor's
> Subpages section and Pages tree, and the Shared tab) now follow this same
> seed-synchronously / revalidate-silently pattern via `DocumentCacheStore`
> and the new `DocumentChildrenCacheStore`. See
> [`../plans/2026-07-03-instant-local-doc-lists.md`](../plans/2026-07-03-instant-local-doc-lists.md).
> This supersedes the "No caching of the subpage list" non-goal and the
> §Subpages deferral below: sub-page lists are cached in
> `DocumentChildrenCacheStore` (restored synchronously in `load()`, written
> through on every successful fetch/create, purged on delete/404/403), and
> `subpages == nil` now means "no fetched *or cached* knowledge".
>
> **Amendment (2026-07-04):** a `.sessionExpired` revalidation failure is still
> transient for the cache (kept, readable), but the shared API client's
> `onSessionExpired` hook now also presents the app-level re-login sheet; the
> editor itself is unchanged and recovers on its next refresh or save (see
> [`../plans/2026-07-04-persist-session-cookies-and-reauth.md`](../plans/2026-07-04-persist-session-cookies-and-reauth.md)).

Date: 2026-07-03
Status: Implemented (shipped 2026-07-03, PR #36; rev 2 — revised the same day
after a multi-agent review of the draft against the codebase; 24 confirmed
findings folded in)

## Summary

Make an already-opened document appear **instantly** with no loading UI, by
persisting its content in a local, on-disk cache. When a cached document is
opened, its content renders immediately from the cache and the server copy is
revalidated **in the background** (stale-while-revalidate). Only a document that
has never been loaded on this device still shows a loading spinner. A
**"Synced X ago"** caption under the title reflects when the local copy last
matched the server and updates live as syncs complete. When a passive background
revalidation finds a newer server copy while the user is viewing clean content, a
subtle, tappable **"Updated"** banner offers to refresh — clean content is never
swapped out from under the user on a passive open (the stale-draft server-wins
rule in §2 is the one deliberate exception, matching today's behavior). An
**explicit pull-to-refresh** is different: it awaits the fetch and applies fresh
content directly.

As a direct consequence, previously-opened documents become **readable offline**
for the first time (offline remains read-only — editing stays disabled offline,
as today), and the editor's offline chrome is corrected to reading-oriented
wording gated on an actual local copy existing.

## Goals

- A document that has been loaded at least once (and not since evicted from the
  cache) opens **with content already on screen** — no `ProgressView`, no
  perceptible load.
- Only a document with no local copy shows a loading indicator.
- Keep the content current: revalidate against the server in the background on
  open, and surface a newer server copy without disrupting the user.
- Give pull-to-refresh real semantics: an explicit refresh awaits the fetch and
  applies the result directly.
- Show, under the title, the time the local copy last synced to the server, and
  update it live when a sync completes.
- Read previously-opened documents offline (natural consequence of the cache).
- Correct the editor's offline messaging so it only claims a device copy when one
  exists, and describes reading (not editing).

## Non-goals

- **Offline editing / sync queue** remains a non-goal (unchanged from the v1
  spec). The existing offline edit guards are **unchanged**: the tap-to-edit
  gesture stays guarded (`guard !isOffline`, `EditorView.swift:189`) and the
  "Start writing" button stays hidden offline (`EditorView.swift:215–221`).
  Offline is read-only; this feature adds offline *reading* of cached content,
  never a path that produces edits which cannot save.
- No real-time collaboration, live cursors, or automatic multi-user merge. Saves
  remain full-overwrite / last-write-wins, exactly as today.
- Revalidation runs **on open and on explicit pull-to-refresh only** — no
  periodic or background-timer revalidation.
- No caching of the subpage list (deferred; see "Subpages" below).
- No change to the Yjs save encoder, the networking primitives, CSRF handling, or
  auth.

## Background: how loading & offline work today

- `EditorViewModel.load()` sets `isLoading = true` and **unconditionally** fetches
  `GET /documents/{id}/formatted-content/?content_format=markdown`
  (`EditorViewModel.swift:99–136`). There is no local content source; every open
  is a network round-trip behind a `ProgressView()` (`EditorView.swift:67`).
  `load()` is invoked from `.task {}` (`EditorView.swift:97–99`) **and from
  pull-to-refresh** (`.refreshable { await viewModel.load() }`,
  `EditorView.swift:204–206`), and `.task` re-fires when popping back from a
  pushed subpage — so the load path is already re-entrant in practice.
- On fetch failure the `catch` sets
  `"Couldn't load this document. Pull to refresh to try again."` So opening any
  document offline currently **fails with an error** and shows no content.
- Local drafts do **not** help offline: the pending-save / stored-draft branch is
  *inside* the `do` block, consulted only **after** a successful fetch
  (`EditorViewModel.swift:111–118`, gated behind the `try await` on line 103). If
  the fetch throws, the draft is never shown. When the fetch succeeds, the stored
  draft is only trusted if
  `formatted.updatedAt <= draft.updatedAt + pendingDraftClockTolerance` (120 s,
  `EditorViewModel.swift:114–115`): **when the server copy is newer beyond
  tolerance, today's code shows the server content and ignores the stale draft**
  — a deliberate server-wins rule (documented in `PendingDraftStore.swift`) that
  this design must preserve.
- `DocumentCacheStore` (`Features/Home/DocumentCacheStore.swift`) caches document
  **metadata** (full `Document` values, including the server `updatedAt`) for the
  Home list only — never content.
- `isOffline` in the editor is **not** merely cosmetic: it shows the
  `OfflineBanner` "Editing the copy saved on this device" (`EditorView.swift:54`),
  changes the header subtitle to "Saved on this device" (`EditorView.swift:237`),
  **and puts the reading surface into read-only mode** — the tap-to-edit gesture
  is guarded off (`EditorView.swift:189`) and "Start writing" is hidden
  (`EditorView.swift:215–221`). What it does *not* do is give `load()` a local
  content source, so the banner's "Editing the copy saved on this device"
  over-promises twice: there is no copy, and there is no editing.
- The header subtitle line under the title currently hard-codes
  `isOffline ? "Saved on this device" : "Edited just now"` — a placeholder, not a
  real status.

## Architecture

Follows existing conventions: a new synchronous, non-throwing `*Store` for the
cache, following the repo's persistence-store conventions (`final class`, `try?`
reads returning safe defaults, injected seams, never throws to callers); new
state and intent methods on the `@MainActor @Observable` `EditorViewModel`; a
revalidation phase awaited as the **structured tail of `load()`/`refresh()`** —
no unstructured `Task {}`; small `EditorView` chrome changes; and a cache write
from `DocumentSaveCoordinator` on save success. The store does file I/O and — like
`DocumentCacheStore` and `PendingDraftStore` — is a plain non-`Sendable`
`final class` confined to its `@MainActor` callers (`EditorViewModel`,
`DocumentSaveCoordinator`, and the root sign-out flow — §6); do not mark it
`Sendable` or call it from off-main tasks (eviction-index updates are
read-modify-write). "Side-effect-free" purity
belongs only to the extracted helpers (eviction selection, caption formatter);
the async boundary stays at the networking layer.

### 1. New store: `DocumentContentCacheStore`

New file `Schrift/Features/Editor/DocumentContentCacheStore.swift`. Persists one
cache entry per document:

```swift
struct CachedDocumentContent: Codable, Equatable, Sendable {
    let documentID: UUID
    let title: String?
    let markdown: String
    let syncedAt: Date          // wall-clock of the successful fetch/save
}
```

There is deliberately **no server-timestamp field**: no decision in this design
reads one (the banner is driven by content equality, eviction and the caption by
`syncedAt`), and the save endpoints return no server timestamp (see §3), so a
stored server-clock value would either go stale or get backfilled from the client
clock — the exact clock-mixing hazard `pendingDraftClockTolerance` exists to
avoid. Any future feature that needs a server timestamp must source it from
`formatted-content` fetches only and compare it against client-stamped dates only
with tolerance.

Design decisions:

- **File-based, not UserDefaults.** Content bodies can be large; UserDefaults
  loads its entire plist into memory. Store one JSON file per document in a
  dedicated directory under Application Support
  (`.../Application Support/dev.llun.Schrift/ContentCache/<uuid>.json`).
  Application Support (not Caches) so the copy is durable and not silently
  reclaimed by the OS — "keep local" means it survives.
- **Not SQLite or Core Data** (considered and rejected). The access pattern is a
  pure key-value store — ≤50 entries, whole-blob reads, single `@MainActor`
  writer — which a directory of files already is, with no schema/migration
  machinery. Core Data/SwiftData would add a managed model artifact (touching
  `project.yml`/XcodeGen) and context machinery that clashes with the repo's
  plain-synchronous-store idiom; raw `SQLite3` (the only wrapper-free option
  under the zero-dependency rule) means hand-rolled C-API boilerplate to guard
  50 rows. Revisit as raw SQLite + FTS5 only if offline full-text search,
  partial/structured queries, or a much larger entry count ever become goals —
  migrating this small store later is cheap (the store API is
  storage-agnostic). Note the flip conditions precisely: plain **offline
  editing** (queue full-doc drafts, retry online) does *not* change the storage
  picture — it is policy on the existing draft/coordinator layering plus a
  conflict UX. **Block-level/incremental CRDT sync** does: per-doc Yjs update
  logs, state vectors, and pending-update queues need transactional multi-row
  writes, where SQLite is the right tool — but that feature's dominant cost is
  a bidirectional Yjs implementation (decode + merge; today's `Core/Yjs` is a
  write-only encoder), not storage, and its schema shares nothing with this
  cache, so adopting SQLite early would pre-build nothing.
- **Stateless.** The store holds **no in-memory state** — the eviction index is
  derived from disk on every operation (like the existing UserDefaults-backed
  stores re-read their backing store per call), so independently-constructed
  instances writing the same directory stay consistent. All call sites are
  `@MainActor`, so synchronous operations never interleave. This is what makes
  production-default construction at each injection site safe (§5).
- Conventional seams: `init(directory: URL = <default>, fileManager: FileManager
  = .default)` — tests inject a temp directory. All reads use `try?` and return
  safe defaults; the store never throws to callers.
- **Eviction:** keep the N most-recently-synced documents (start at **50**),
  evict the oldest by `syncedAt`. Per the repo's persistence conventions, the
  selection logic is a **top-level pure free function** over `Equatable` values
  (mirroring `addingRecentServer`/`addingRecentSearch`):

  ```swift
  struct ContentCacheIndexEntry: Equatable { let id: UUID; let syncedAt: Date }
  func contentCacheEvictions(index: [ContentCacheIndexEntry], limit: Int) -> [UUID]
  ```

  The store applies it after each `save(_:)` by deleting the returned IDs'
  files. The index's `syncedAt` values come from the files' **modification
  dates** (`contentModificationDateKey` resource values) — every path that bumps
  an entry's `syncedAt` rewrites its file at that same moment, so mtime tracks
  `syncedAt` and building the index never requires reading or decoding file
  contents. Eviction removes content-cache entries **only** — it never touches
  `PendingDraftStore`, so a stranded draft keeps an evicted document readable
  and recoverable.

API:

```swift
final class DocumentContentCacheStore {
    init(directory: URL = <Application Support>/dev.llun.Schrift/ContentCache,
         fileManager: FileManager = .default)
    func content(for documentID: UUID) -> CachedDocumentContent?   // synchronous
    func save(_ entry: CachedDocumentContent)                      // + evict
    func remove(documentID: UUID)                                  // delete flow, 404/403 revalidate
    func removeAll()                                               // sign-out
}
```

This store is the single source of truth for **whether a local clean copy exists
to display**. (Not for "was this ever loaded" — eviction breaks that equivalence;
see the caption precedence in §4.)

#### Privacy & data lifecycle

- Cache entries contain **full user document text**. They must never be logged,
  printed, or interpolated into error messages or debug output — the existing
  no-sensitive-logging rule extends to this store.
- Files keep **default iOS data protection**
  (`NSFileProtectionCompleteUntilFirstUserAuthentication`), matching the
  UserDefaults-backed stores. Never weaken protection.
- **Excluded from backups**: the `ContentCache` directory is marked
  `isExcludedFromBackup`. Cached content is re-downloadable from the server, so
  full document bodies from a private self-hosted instance should not flow into
  iCloud/device backups; unsaved work is still covered by `PendingDraftStore`,
  which backs up as today.
- **Sign-out clears the cache**: the sign-out flow calls `removeAll()` (§6).
  The pre-existing `DocumentCacheStore` (metadata) and `PendingDraftStore`
  (unsaved work) keep their current sign-out behavior (retained) — changing them
  is out of scope; this is a recorded decision, not an accident.

### 2. Reworked load flow in `EditorViewModel`

Split loading into an **instant, synchronous local phase** and an **awaited
revalidation phase**. The local phase never awaits and never shows a spinner. The
"instant" behavior comes from the local phase setting blocks and
`isLoading = false` **before the first await** — not from detaching the fetch.
Revalidation is the structured tail of `load()`: because `load()` is invoked from
`.task {}` and `refresh()` from `.refreshable {}`, the fetch is cancelled
naturally on disappear, and the pull-to-refresh spinner correctly persists until
revalidation resolves. This matches the repo rule reserving unstructured
`Task {}` for work that must outlive its trigger (the save-success cache write,
which must survive dismissal, already lives in the coordinator — §3).

#### One shared installation routine

All content installation goes through a single private helper, extracted from
today's `load()` body (`EditorViewModel.swift:104–130`):

```swift
private func install(markdown: String, title: String?, syncedAt: Date?)
```

It must: set `title`/`savedTitle` (when a title is provided), set `rawMarkdown`,
set `blocks = parseEditorBlocks(markdown)`, compute
`openInMarkdownMode = !markdown.isEmpty && !markdownSurvivesRoundTrip(markdown)`,
set the dirty baseline
`savedMarkdown = openInMarkdownMode ? markdown : serializeMarkdown(blocks)`, set
`hasLoadedContent = true`, record `displayedSourceMarkdown = markdown` (see
below), and set `lastSyncedAt = syncedAt` when one is provided. **Every** path
that puts content on screen — initial fetch, cache hit, draft hit,
`applyPendingUpdate()`, refresh — routes through it. Skipping it (e.g. merely
swapping `blocks`) would bypass the round-trip safety check and risk a
destructive full-overwrite save of non-round-trippable cached content.

#### Local phase (synchronous, no network, on `load()` entry)

Choose the display source by precedence:

1. In-flight pending save (`saveCoordinator.pendingSave`) — dirty local content.
   Install with the pending markdown/title; no `syncedAt`.
2. Stored draft (`saveCoordinator.storedDraft`) — dirty, trusted local edits.
   Install with the draft markdown/title; no `syncedAt`. *(Showing this without a
   prior successful fetch is new; it fixes the current "drafts unreachable
   offline" gap. The server-wins staleness rule is preserved — it moves to the
   revalidation phase, below.)*
3. **Cached content** (`contentCache.content(for:)`) — clean, previously synced.
   Install with the entry's markdown/title and `syncedAt` from the entry.
4. **None of the above** — set `isLoading = true` and go straight to the fetch
   (this is the **only** path that shows `ProgressView()`).

For sources 1–3, content renders immediately: `isLoading` never becomes true and
`hasLocalCopy = true`.

On `load()` entry, always reset `updateAvailable = false` and
`pendingFreshContent = nil` — the local phase re-reads the cache (which may
already contain a previously stashed fresh copy), so banner state must never
outlive the display it was computed against.

*Implementation note (2026-07-03, as shipped):* the local phase and this
banner-state reset run **once per installed document** — `load()` guards them
on `!hasLoadedContent`, because a `.task` re-fire on pop-back would otherwise
clobber a dirty editing session with the cached copy. After the first install,
`load()` is revalidate-only; banner state is instead cleared by
`startEditing()`/the first dirtying edit and by the 404/403 terminal path.

#### Staleness comparison basis

The VM keeps the exact raw markdown string the current display was installed
from: `private var displayedSourceMarkdown: String`, set by `install(...)` and,
when a save is enqueued, set to the enqueued markdown (matching §3). "Server
changed" means:

```
fetched.content != displayedSourceMarkdown
  && serializeMarkdown(parseEditorBlocks(fetched.content))
     != serializeMarkdown(parseEditorBlocks(displayedSourceMarkdown))
```

The canonical-form fallback prevents a phantom banner when the server's markdown
export differs only cosmetically (raw differs, canonical equal → treat as synced:
bump `syncedAt`, update the cache and `displayedSourceMarkdown` to the fetched
raw so comparisons converge, no banner). **Never compare the fetched markdown
against `serializeMarkdown(blocks)` / `currentMarkdown()`** — the serializer
canonicalizes (`*`→`-`, blank-line collapsing, renumbering), which would give
every non-byte-round-tripping document an unfixable do-nothing "Updated" banner
on every open.

#### Revalidation phase (awaited tail of `load()`/`refresh()`, for sources 1–3 and after 4)

Fetch `formatted-content`. Classification happens **when the fetch completes**
(`guard !Task.isCancelled`, then inspect current dirty/draft state), not when
revalidation starts — edits begun mid-fetch route to the silent-cache-update
branch instead of popping a banner. Outcomes:

- **Transient failure** (`.network`, `.server`, `.rateLimited`, and
  `.sessionExpired` — cookie expiry must **not** purge the cache, or offline
  reading dies on every re-login): keep the display; `lastSyncedAt` unchanged; no
  `errorMessage` when local content is shown. (Only source 4 — no local copy —
  surfaces the load error, as today.) This is the offline-reading path.
- **Definitive failure** (`.notFound`, `.forbidden` — mirroring the existing
  `recoverDrafts` pattern, `DocumentSaveCoordinator.swift:115–116`): the document
  is gone or access was revoked. Call `contentCache.remove(documentID:)`, clear
  `hasLocalCopy`/`lastSyncedAt`, set `updateAvailable = false`, and show a
  terminal state: `errorMessage = "This document is no longer available."` with
  editing disabled (no "Synced" caption, no enqueueable saves that can only 404).
  The `.forbidden` purge is also a privacy requirement: revoked-access content
  must not remain readable in the durable cache. Draft lifecycle stays with the
  coordinator (`recoverDrafts` already drops drafts on 404/403).
- **Displayed source was a stored draft (source 2) and the user has NOT edited
  this session:** re-run today's staleness check. If
  `fetched.updatedAt > draft.updatedAt + pendingDraftClockTolerance`, the server
  wins — install the fetched content directly (replacing blocks/title and
  resetting the dirty baseline, matching today's behavior where the stale draft
  would never have been shown), remove the draft after re-checking it is
  unchanged (mirroring `recoverDrafts`' re-check,
  `DocumentSaveCoordinator.swift:107–109`, since the user may have started
  editing during the await), update the cache, and set `lastSyncedAt`. Otherwise
  (draft within tolerance) fall through to the dirty rule below. Without this,
  the draft-first display would permanently shadow a newer server copy and a
  resumed edit could full-overwrite it.
- **On-screen content is dirty** (in-flight save, a within-tolerance draft, or
  any edit made this session): update the cache silently for next time; **never**
  show a banner or disturb the edits. Conflict handling stays with the save
  coordinator, unchanged.
- **Clean, and the comparison above says unchanged:** bump `syncedAt` to now in
  the cache and refresh `lastSyncedAt` (caption becomes "Synced just now"). No
  banner.
- **Clean, and the comparison says the server changed:** stash the fresh
  **body** in `pendingFreshContent` and set `updateAvailable = true` (drives the
  banner). Do **not** change the displayed blocks. Update the cache entry so
  future opens use the fresh copy.
- **Title reconciliation** (in every clean branch): a changed server title
  applies **silently and immediately** — set `title` and `savedTitle` (so
  `flushPendingChanges`' title comparison doesn't enqueue a spurious save) and
  persist it to the cache entry, in *both* the unchanged and changed branches.
  Renames are non-destructive, and today's load already overwrites the title on
  every fetch. Only **body** differences drive the "Updated" banner, so
  `pendingFreshContent` carries markdown only. While dirty, never touch the
  displayed title (the user may have edited it); the silent cache update includes
  the fetched title.

After a successful **source-4** fetch (first-ever load), install the content and
write the cache entry so the next open is instant.

#### Re-entrancy

`load()` is re-entrant by design (`.task` re-fires on pop-back; the VM is
retained in `@State` on `EditorScreen`). The VM keeps a monotonically increasing
`private var revalidationGeneration: Int`; each `load()`/`refresh()` entry
increments and captures it, and a completing fetch applies its outcome **only if
its captured generation is still current** (latest-wins). No unstructured task,
no stale banner from a superseded revalidation. Content turning dirty while a
fetch is in flight is handled by completion-time classification (above).

#### Banner state machine

- `startEditing()` (and, belt-and-braces, the first dirtying edit) sets
  `updateAvailable = false` and `pendingFreshContent = nil`. Once the user edits,
  freshness conflicts belong to the save coordinator — exactly as in the dirty
  revalidation branch — and the fresh copy is already persisted to the cache, so
  nothing is lost by dropping the stash.
- `applyPendingUpdate()` guards:
  `guard !isEditing, !isDirty, let pending = pendingFreshContent else { return }`
  — a stray tap can never replace blocks mid-edit. It routes the stashed body
  through `install(...)` (recomputing `openInMarkdownMode` and the
  `savedMarkdown` baseline — never a bare `blocks` swap), bumps `lastSyncedAt`,
  and clears `updateAvailable`/`pendingFreshContent`.

New VM state and intents (summary):

```swift
var lastSyncedAt: Date?            // drives the "Synced X ago" caption
var hasLocalCopy: Bool             // drives offline chrome
var updateAvailable: Bool          // drives the "Updated" banner
private var pendingFreshContent: String?         // stashed fresh markdown (body only)
private var displayedSourceMarkdown: String      // staleness comparison basis
private var revalidationGeneration: Int

func load() async                  // SWR open flow (local phase + awaited revalidation)
func refresh() async               // explicit pull-to-refresh (below)
func applyPendingUpdate()
func handleDidDelete()             // §6
```

#### Pull-to-refresh (explicit refresh)

`.refreshable` stops calling `load()` and calls a distinct intent
`func refresh() async` (`EditorView.swift:204–206`):

- It **awaits** the revalidation fetch, so the system refresh spinner reflects
  real work.
- When the displayed content is **clean**, it applies the fetched content
  **directly** through `install(...)` (bumping `syncedAt`/`lastSyncedAt`,
  updating the cache, clearing any pending `updateAvailable`) — the "Updated"
  banner is reserved for *passive* on-open revalidation; a user who explicitly
  asked for a refresh gets the content, not a pill telling them to tap again.
  The never-swap-clean-content rule applies to passive opens only.
- When the displayed content is **dirty**, the dirty rules above hold (silent
  cache update, edits untouched) — the visual no-op is deliberate.
- On failure it **sets `errorMessage` even when local content is shown**
  (`"Couldn't refresh. Please try again."`) — an explicit refresh must not fail
  silently, unlike passive revalidation. The definitive-failure (404/403)
  handling is the same as passive revalidation. This keeps the retained
  source-4 error copy ("Pull to refresh to try again.") truthful.
- Re-entrancy uses the same generation counter — repeated pulls are latest-wins.

#### Subpages

`loadChildren()` (a network call) moves out of the instant path into the
revalidation phase, after the content fetch, matching today's post-fetch
ordering; the local phase never blocks on it. `subpages` becomes optional
(`[Document]?`, nil = not fetched this session): the subpages empty-state copy
("Organize this document by creating subpages.") is suppressed until a fetch has
succeeded this session — render nothing (or just the eyebrow) in the meantime, so
the instant/offline path doesn't falsely claim "no subpages". The "Add a subpage"
button is hidden when `isOffline` (`createChild` is a network POST that currently
fails silently via `try?`). Caching the subpage list is deferred (Non-goals): if
it were added to `CachedDocumentContent`, the coordinator's save-success cache
write would have to preserve the prior entry's subpages, so the fetched-flag
approach is the baseline.

### 3. Cache stays consistent on save

On a **successful** save, `DocumentSaveCoordinator` writes the just-saved
markdown and title into the content cache with `syncedAt = now`. Both save
requests (`setContent`, `updateTitle`) are void PATCHes with no response body, so
**no server timestamp is available at save success** — which is fine, because
nothing in the cache stores one (§1); the entry is simply
`(documentID, title, markdown, syncedAt: Date())`, written whether or not a prior
entry existed (a save after eviction recreates the entry). The coordinator owns
the reliable save-success point (saves can complete after the editor is
dismissed), so the write lives there, not in the view. The coordinator gains a
`DocumentContentCacheStore` dependency (injected, with a production default),
used only on save success. Draft/`PendingDraftStore` lifecycle is otherwise
unchanged. The VM also updates `displayedSourceMarkdown` to the enqueued markdown
when it enqueues a save, keeping the staleness comparison anchored to what the
server is about to hold.

### 4. UI changes in `EditorView`

- **Spinner only for source 4.** `if viewModel.isLoading` stays, but `isLoading`
  is now true only when there is no local copy. Cached opens render immediately —
  satisfying "no loading progress at all if loaded at least once."
- **Header subtitle → real sync status** (`EditorView.swift:237`). Replace the
  hard-coded line with, in precedence order:
  1. content is **dirty** — displayed source was a draft/in-flight save
     (sources 1–2), *or* the user has edited this session (a source-3 display
     dirtied before the autosave enqueues counts) → the save-oriented wording
     wins **regardless of `lastSyncedAt`** (offline → "Saved on this device";
     online → the coordinator's `DocSaveState` for this document, e.g.
     "Saving…" / "Saved" / the failure copy — the state the VM already maps at
     `EditorViewModel.swift:88–95`). After eviction, "no cache entry" does not
     imply "never synced" — a previously-synced doc with a stranded draft must
     not read "Not synced yet".
  2. clean with `lastSyncedAt` → **"Synced X ago"**.
  3. brand-new document with neither cache entry nor draft → "Not synced yet"
     (or empty).

  The precedence selection lives in the view (driven by VM state), per the
  navigation-in-view convention; the pure formatter below produces only the
  rule-2 copy.

  Mechanism for "live": wrap the caption in
  `TimelineView(.periodic(from: .now, by: 60))` and pass the timeline's
  `context.date` into a **pure** formatter
  `syncStatusCaption(lastSyncedAt: Date, now: Date) -> String` (note
  `documentRowDate` is *not* pure — it reads `Date()` internally; the new
  formatter takes `now` as a parameter, which is what makes it unit-testable).
  "Live" covers both: the immediate jump to "Synced just now" when a sync
  completes (state-driven via `@Observable`), and the minute-by-minute tick-over
  while the screen stays open (TimelineView). (`Text(_, style: .relative)` was
  rejected: it renders bare counting text without the "Synced … ago" copy and
  defeats the pure formatter.)
- **"Updated" banner.** Render the pill only when
  `viewModel.updateAvailable && !viewModel.isEditing` — a subtle, tappable
  "Document updated · tap to refresh" below the nav/offline banner and above the
  content; tapping calls `viewModel.applyPendingUpdate()`.
- **`OfflineBanner` gated on a real copy, with reading-oriented copy**
  (`EditorView.swift:54`). Show **"Reading the copy saved on this device"** only
  when `isOffline && viewModel.hasLocalCopy`. (Editing stays blocked offline —
  the guards are unchanged, per Non-goals — so the old "Editing…" wording would
  still over-promise.) Offline with nothing cached falls through to the normal
  error/empty state.

### 5. Navigation / wiring

`EditorScreen` and `EditorViewModel` gain a
`contentCache: DocumentContentCacheStore = DocumentContentCacheStore()` parameter
(seam with production default), as does `DocumentSaveCoordinator`. This is
deliberately **not** the `saveCoordinator` pattern (a single app-scoped instance
threaded everywhere as a required parameter): the content store is **stateless**
(§1), so independently-constructed instances over the same directory are
consistent, and per-site production defaults keep initializers small. No change
to what the Home list passes (still a `Document` / id).

### 6. Delete & sign-out keep local state consistent

- **Local delete** (options sheet): `EditorViewModel` gains
  `handleDidDelete()`, invoked in the options sheet's onDeleted path before the
  existing `onDeleted` closure is forwarded. It calls
  `contentCache.remove(documentID:)` and asks the coordinator to drop the
  document's queued/pending work (cancel any coalesced save,
  `PendingDraftStore.remove(documentID:)`). Without this, a deleted document
  remains reachable from retained Search/Shared results and `DocTreePanel`,
  renders its full cached content instantly, and — because transient revalidation
  failures are swallowed — reads as alive indefinitely. The revalidation-404
  purge (§2) is defense-in-depth for deletes performed on other devices.
- **Sign-out**: the sign-out flow calls `contentCache.removeAll()` (threaded
  through the existing sign-out path — e.g. alongside where `SessionStore.signOut`
  is invoked in the root flow). Full document bodies must not survive sign-out on
  disk. Covered by a test (sign out → `content(for:)` returns nil).

## Data flow

```
open document
      │
      ▼
load() ── local phase (sync, no network; reset banner state) ─────────┐
      │  in-flight save? ──▶ install (dirty)                           │
      │  stored draft?   ──▶ install (dirty; staleness checked later)  │
      │  cached content? ──▶ install (clean) + lastSyncedAt            │
      │  none            ──▶ isLoading=true ─▶ ProgressView            │
      ▼                                                                │
revalidate (awaited tail; classify at completion; latest-wins) ◀───────┘
      │  transient fail (network/5xx/429/401) ─▶ keep display (offline reading)
      │  definitive fail (404/403) ─▶ purge entry, "no longer available"
      │  stale draft (beyond tolerance, no session edits)
      │                        ─▶ install server copy, drop draft
      │  dirty on screen       ─▶ update cache silently, no banner
      │  clean & unchanged     ─▶ bump syncedAt ("Synced just now")
      │  clean & body changed  ─▶ stash body + updateAvailable (banner)
      │  clean & title changed ─▶ apply title silently (both branches)
      ▼
refresh() (pull) ─▶ same, but awaited by the spinner; clean+changed
      │             applies directly (no banner); failure sets errorMessage
      ▼
save success (coordinator) ──▶ write cache (markdown+title, syncedAt = now)
delete / 404 / 403 ──▶ remove cache entry        sign-out ──▶ removeAll()
```

## Error handling

- Local content shown → **passive** revalidation failure is swallowed (no error
  banner); the stale copy stays readable. This is the offline-read path.
- **Explicit refresh** failure sets `errorMessage` even with local content shown
  — a user-requested refresh never fails silently.
- `.notFound`/`.forbidden` on revalidate → terminal "This document is no longer
  available." state with the cache entry purged (§2).
- No local content (source 4) and fetch fails → existing
  `"Couldn't load this document. Pull to refresh to try again."` error, unchanged
  (and still truthful, because `refresh()` awaits and surfaces errors).
- Cache read/write failures are non-fatal (`try?`), degrading to today's
  network-only behavior.

## Testing

XCTest, mirroring the source tree. New/updated:

- `DocumentContentCacheStoreTests` — save/load round-trip, `remove`, `removeAll`,
  eviction applied on save, corrupt/missing file returns nil; injected temp
  directory. Plus **pure, filesystem-free** `contentCacheEvictions` tests: keeps
  newest N by `syncedAt`, returns oldest beyond the limit, empty result at/under
  the limit.
- `EditorViewModelTests`:
  - cache present → `isLoading` never becomes true; content on screen before any
    network call resolves (delayed/failing `MockURLProtocol` stub);
  - no cache → `isLoading` toggles true then false; content cached afterward;
  - offline (fetch throws) with cache → content stays, no `errorMessage`,
    `hasLocalCopy == true`; offline with no cache → `errorMessage` set;
  - cached markdown that fails byte round-trip (e.g. `*` bullets) → opens with
    `openInMarkdownMode == true`, both on cached open and after
    `applyPendingUpdate()` (destructive-save regression);
  - revalidate, server identical → `lastSyncedAt` advances, no banner; server
    export differing **only in canonicalization** → no banner (phantom-banner
    regression); same after a save success;
  - revalidate, body changed, clean → `updateAvailable == true`, on-screen blocks
    unchanged until `applyPendingUpdate()`;
  - revalidate, **title** changed, body identical → title + cache + `savedTitle`
    updated silently (no spurious save), no banner;
  - revalidate while dirty → three cases: in-flight save → untouched; stored
    draft within tolerance → untouched, cache updated; stored draft **stale**
    (server newer beyond tolerance, no session edits) → server content installed,
    draft removed, cache updated;
  - banner then edit: `updateAvailable == true`, then `startEditing()` →
    `updateAvailable == false`, blocks unchanged; `applyPendingUpdate()` while
    dirty/editing is a no-op;
  - second `load()` during an in-flight revalidation → latest-wins, no stale
    banner; content turning dirty mid-fetch → no banner;
  - revalidation 404 → cache entry removed, "no longer available" shown, editing
    disabled; 403 → same; 401 → cache kept, content readable;
  - `refresh()`: applies newer server content directly (no banner) when clean;
    sets `errorMessage` on failure even with cached content; leaves edits
    untouched when dirty;
  - stored draft with no cache renders offline (regression for the current gap);
  - `handleDidDelete()` → cache entry and draft removed;
  - subpages: empty-state suppressed until a successful fetch this session.
- `DocumentSaveCoordinatorTests` — content cache updated on save success
  (including when no prior entry exists); not updated on save failure.
- Sign-out flow test — signing out invokes `removeAll()`; afterwards
  `content(for:)` returns nil for previously cached documents (§6).
- Pure `syncStatusCaption(lastSyncedAt:now:)` unit test (rule-2 copy only; the
  precedence selection is exercised via the view-model state tests above).

## Rollout / risk

- Additive: a new store plus reordered load logic. The network fetch, save
  encoder, CSRF, and auth paths are untouched.
- Worst case if the cache misbehaves: it returns nil and the editor falls back to
  today's network-only load. No data loss risk — the cache is a read-through
  copy; the server and `PendingDraftStore` remain the sources of truth for
  unsaved work.

## Docs to update alongside implementation

- `CLAUDE.md` — note the content cache tier and the load precedence in the Editor
  section; add `DocumentContentCacheStore` to the persistence-stores list (with
  the file-based/backup-excluded/sign-out-cleared posture) and the repo-layout
  map.
- `docs/superpowers/specs/2026-06-30-docs-ios-design.md` — following the existing
  "Revised: 2026-07-02" precedent, add a dated revision note amending the error
  handling line "no offline queue/cache in v1": previously-opened documents are
  now cached on disk and readable offline with background revalidation (see this
  spec). Clarify (don't remove) the "Offline editing/sync queue" non-goal —
  offline *editing* remains out of scope; only offline *reading* was added.
- `README.md` reviewed — it makes no offline/loading claims, so no change.
- This spec is the point-in-time design record.
