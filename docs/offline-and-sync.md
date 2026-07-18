# Instant Local Document Content + Background Sync

> **Living design document** for Schrift's offline reading and background-sync
> model — the on-device content cache, the list caches, and the rules that keep a
> full-overwrite save from ever eating content. Kept current with the shipped
> app; update it in place when behavior changes. See also
> [`architecture.md`](architecture.md) for the overall architecture and
> [`CLAUDE.md`](../CLAUDE.md) for the operational conventions.

> **Amendment (2026-07-03):** the document **lists** (Home, the editor's
> Subpages section and Pages tree, and the Shared tab) now follow this same
> seed-synchronously / revalidate-silently pattern via `DocumentCacheStore`
> and the new `DocumentChildrenCacheStore`.
> This supersedes the "No caching of the subpage list" non-goal and the
> §Subpages deferral below: sub-page lists are cached in
> `DocumentChildrenCacheStore` (restored synchronously in `load()`, written
> through on every successful fetch/create, purged on delete/404/403), and
> `subpages == nil` now means "no fetched *or cached* knowledge".
>
> **Amendment (2026-07-04):** a `.sessionExpired` revalidation failure is still
> transient for the cache (kept, readable), but the shared API client's
> `onSessionExpired` hook now also presents the app-level re-login sheet; the
> editor itself is unchanged and recovers on its next refresh or save.
>
> **Amendment (2026-07-08):** the "never swap clean content on a passive open"
> rule below is **withdrawn**. It made a document edited on the web show its new
> **title** (applied silently) while still rendering the cached **body**, which
> reads as "remote edits never arrive". A **clean** copy — not dirty, no pending
> save, and no open editing session — now has the fetched body **installed
> directly** on every revalidation, passive or explicit; passive `load()` and
> pull-to-refresh apply identical content rules and differ only in whether a
> failure is surfaced. The **"Updated" banner** survives for the case where
> swapping is destructive: a revalidation landing while an **editing session**
> holds the caret stashes the body and offers it once editing ends.
> Independently, `displaySource` no longer stays pinned at `.pendingSave` after
> the save it named settled — that stranded the screen so *no* later
> revalidation or pull-to-refresh could ever apply server content.
> Two safeguards landed with it, each after review found it could destroy
> content: a **stored draft is unsaved work regardless of `displaySource`** (a
> mid-session save failure leaves `.clean` on screen with the draft behind it),
> and a response to a fetch that **raced one of our own saves** is never
> installed or cached (the server may answer it from the pre-save state, and the
> next full-overwrite save would push that resurrected body back).
>
> **Revised (2026-07-10):** the Markdown editing mode was removed — the block
> editor is the only editing surface. `install(...)` no longer computes
> `openInMarkdownMode` or a mode-dependent baseline; it sets
> `savedMarkdown = serializeMarkdown(blocks)` unconditionally, so opening and
> closing a non-round-trippable document without an edit still enqueues no save.
> `rawMarkdown` is retained as the authoritative reading-mode source: a fetch
> installs it, and `finishEditing` re-syncs it to the edited blocks **only when
> they diverged** from that source, so a photo upload that lands after the
> editing session still preserves an untouched non-round-tripping document.

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
matched the server and updates live as syncs complete. When a revalidation —
passive or an explicit pull-to-refresh — finds a newer server copy while the user
is viewing **clean** content, the fresh body is **installed directly**: there is
no local work to protect, so remote edits simply appear. The one exception is an
open **editing session**, where swapping the document out from under the caret
would be destructive: there the fresh body is stashed behind a subtle, tappable
**"Updated"** banner that surfaces once editing ends.

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
  surfaces failures rather than swallowing them.
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
- No real-time collaborative *writing* or live cursors, and saves remain
  full-overwrite / last-write-wins. **Live *reading* now exists** behind the
  default-off `schrift.liveCollaboration` flag (Milestone C1): when the editor is
  clean and joined to the Hocuspocus room, inbound Yjs updates are applied to the
  open editor caret-preservingly by the `LiveEditingBridge` (see
  `docs/architecture.md`). It composes with the machinery here rather than replacing
  it: while the bridge is applying live content the A5 remote-change refetch is
  **suppressed** (`isApplyingLiveContent`) — the live stream is newer than the 60 s
  REST snapshot, so installing a stale `formatted-content` body would reset the caret
  and regress content. On the first keystroke the bridge pauses and the detect-and-ask
  conflict flow below resumes unchanged; a document with a recorded conflict,
  `.pendingSync` state, stored draft, or pending save never enters live-apply.
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
    let syncedAt: Date          // client wall-clock of the fetch/save (eviction only)
    let serverUpdatedAt: Date?  // server updated_at when fetched; nil after a void save
}
```

> **Revised (offline-editing stack):** `serverUpdatedAt` was added when offline
> editing with conflict detection began. The original objection to a server
> timestamp was **clock-mixing** — comparing a stored server clock against the
> client clock. That objection does not apply to a *server-clock-to-server-clock*
> comparison, which is exactly what the draft baseline
> (`DraftBaseline`/`draftSyncDecision`) needs. So the field is a **truthful server
> `updated_at` when the entry came from a fetch, and nil after a void save** (the
> save PATCHes return no timestamp — see §3); `syncedAt` remains the
> client-clock value used only for eviction ordering. It is Optional, so entries
> written by earlier builds decode as nil. The banner is still driven by content
> equality, never by this field.

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

It must: set `title`/`savedTitle` (when a title is provided), set `rawMarkdown`
(the authoritative reading-mode source), set `blocks = parseEditorBlocks(markdown)`,
set the dirty baseline `savedMarkdown = serializeMarkdown(blocks)`, set
`hasLoadedContent = true`, record `displayedSourceMarkdown = markdown` (see
below), and set `lastSyncedAt = syncedAt` when one is provided. **Every** path
that puts content on screen — initial fetch, cache hit, draft hit,
`applyPendingUpdate()`, refresh — routes through it. Skipping it (e.g. merely
swapping `blocks`) would bypass the dirty baseline and the authoritative source
and risk a destructive full-overwrite save of non-round-trippable cached content.

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
- **Clean, and the comparison says the server changed:** install the fetched
  body (`install(...)`, so the round-trip check and the dirty baseline are never
  bypassed) and clear any stash. Update the cache entry so future opens are
  instant. **Exception — an editing session is open** (`isEditing`, but still
  clean): swapping blocks under the caret is destructive, so stash the fresh body
  in `pendingFreshContent`, set `updateAvailable = true` (drives the banner), and
  leave the displayed blocks alone; the banner renders once editing ends.
  `markDirty()` drops the stash — and **records a conflict as it does**; `startEditing()`
  only hides the banner and **keeps** the stash, or the first real keystroke would have
  nothing left to detect. See §Conflict detection & resolution.
- **Displayed source was an in-flight save (source 1) that has since settled:**
  reaching this branch proves the save is no longer pending (the dirty rule above
  intercepts the in-flight case) *and* that this fetch postdates it (the
  raced-fetch rule below intercepts the rest), so the screen holds an ordinary
  clean copy — a failed save's draft is caught by the draft rule above. Leaving
  the source pinned at `.pendingSave` strands the screen: every later
  revalidation *and* every pull-to-refresh no-ops in silence and remote edits can
  never appear.
- **A stored draft outlives the save that wrote it** (the save failed): it is
  unsaved work regardless of which source installed the screen — a mid-session
  failure leaves `.clean` on screen with the draft behind it. `apply` therefore
  consults `storedDraft(...)` *before* switching on `displaySource`.
  `hasUnsavedLocalContent` follows the same rule (gated on `hasLoadedContent`,
  since `becomeUnavailable` deliberately keeps the draft — a 403 is revoked
  access, not a deletion), so the "Synced X ago" caption never lies about a
  failed save. That draft only survives because `becomeUnavailable` **flushes the
  live edit first** (`enqueue` is write-ahead, so the user's text reaches disk
  before any PATCH), then **ends the editing session** (cancels the autosave, clears
  `isDirty`, drops to `.reading`), and `flushPendingChanges` refuses to run without
  `hasLoadedContent` — otherwise a 404/403 landing mid-edit would flush the emptied
  block list and replace the draft with an empty document. It also calls
  `suppressLocalWriteThrough`, or an in-flight save landing after the purge would
  write the full body back into the content cache (on a 403: revoked content
  reappearing on disk). A failed save also **pins** the
  document (every revalidation and pull-to-refresh no-ops while its draft is on
  screen), so the reading surface's "Couldn't save · tap to retry" caption is
  load-bearing: it is the only escape when offline, where tap-to-edit is blocked.
  **`pendingDraftClockTolerance` may only discard a draft *stranded by an earlier
  session*** — never one the retry affordance is holding. This rule runs both at
  launch (`recoverDrafts`) **and mid-session** — `syncPendingDrafts` is the
  repeatable funnel the reconnect/foreground triggers fire, so it no longer runs
  only "on a document nobody is looking at". Because of that it **skips a
  `.failed` draft** (`if case .failed = state(for:) { continue }`): a draft whose
  save failed *this* session is a retry candidate with its "Couldn't save" retry
  on screen, exactly why `reconcileDraft` returns early on
  `saveState == .failed`. A transient/transport save failure (offline, 5xx, rate
  limit) is classified as **`.pendingSync`** rather than `.failed` (see the save
  states below), and gets the same protection on **both** sides: a beyond-window
  `.pendingSync` draft is **never discarded** — `runSyncPass` records a **`SyncConflict`**
  for it instead (the `.discardServerWins` → `case .pendingSync` arm), so a queued offline
  edit the server has moved past becomes a *question*, not a silent deletion and not a
  silent overwrite. (Merely *skipping* it, as an earlier revision did, stranded it: never
  pushed, never discarded, and — the decision not being `.conflict` — no pill either, so the
  only escape left was a retry tap that overwrote the newer server copy with no prompt at
  all.) `reconcileDraft`'s early return covers `.failed` **and** `.pendingSync` so a plain
  pull-to-refresh can't drop it either — and it still **records a conflict on the way out**,
  because keeping the draft is not the same as staying blind to the server. Applying the
  tolerance rule to either deletes visible content.
  An *idle* stranded (legacy, baseline-less) draft beyond the window is discarded **only on
  the launch pass** (`syncPendingDrafts(isLaunchRecovery:)`, which only `recoverDrafts()`
  sets): mid-session the editor may be *displaying* that draft, and removing it there leaves
  on-screen content with no disk backing — the next keystroke would then full-overwrite the
  newer server body. Off the launch path it is left to `reconcileDraft`, which discards
  **and installs** the winning body atomically, on the screen actually showing it.
  Overlapping triggers are **coalesced, not dropped**: a reconnect landing during an
  in-progress (failing) pass would otherwise be lost until the next foreground cycle.
  The comparison mixes clocks — `draft.updatedAt` is the device's,
  `formatted.updatedAt` the server's **last write** — so a slow device shrinks the
  window from the draft's side, and even the user's own partially-landed save
  (content PATCH applied, title PATCH failed) can then read as "newer than the
  draft". (`pendingDraftClockTolerance`'s own doc comment states the intent:
  losing the user's typed content is worse than replaying it over a
  near-simultaneous web edit.)
- **The fetch raced one of our own saves** (a save was in flight when it was
  issued, or one settled while it awaited — `DocumentSaveCoordinator.saveMarker`
  / `mayPredateSave`): the server may have answered from its **pre-save** state.
  Never install and never cache that body: it resurrects exactly the content the
  save replaced, and because saves are a full overwrite the next save pushes it
  back to the server. Only `displaySource` is unpinned, so the next fetch — which
  postdates the save — reconciles normally. A boolean "was a save pending?" is
  insufficient: a save can start *and* settle inside a single await, which is why
  the marker carries a monotonic settled-save count.
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
  through `install(...)` (recomputing the `savedMarkdown` baseline and the
  authoritative `rawMarkdown` source — never a bare `blocks` swap), bumps `lastSyncedAt`,
  and clears `updateAvailable`/`pendingFreshContent`.

New VM state and intents (summary):

```swift
var lastSyncedAt: Date?            // drives the "Synced X ago" caption
var hasLocalCopy: Bool             // drives offline chrome
var updateAvailable: Bool          // drives the "Updated" banner
private var pendingFreshContent: (markdown: String, syncedAt: Date)?   // stashed body only
private var displayedSourceMarkdown: String      // staleness comparison basis
private var revalidationGeneration: Int

func load() async                  // SWR open flow (local phase + awaited revalidation)
func refresh() async               // explicit pull-to-refresh (below)
func applyPendingUpdate()
func handleDidDelete()             // §6
```

#### Conflict detection & resolution

The whole point of carrying `DraftBaseline` on a draft is this: when a queued
offline edit is reconciled against the server (by `syncPendingDrafts` on a
reconnect/foreground/launch trigger, or by the editor's own `reconcileDraft`
revalidation) and `draftSyncDecision` returns **`.conflict`** — the server body
moved on *and* it no longer matches the baseline the edit descended from — the app
**detects and asks** rather than silently picking a winner. There is no on-device
Yjs *decoder* and no CRDT merge, by design (Non-goals); a conflict is resolved by
choosing one whole version.

- **Record.** `DocumentSaveCoordinator` keeps `conflicts: [UUID: SyncConflict]`.
  `SyncConflict` carries only `serverUpdatedAt` — which the sheet shows ("The server
  copy changed *\<when\>*"), the one fact the user needs to choose a winner — and
  deliberately **no server markdown**, so "Keep the server version" re-fetches
  through the editor's guarded funnel rather than installing a body the coordinator
  squirreled away. Every detection site records the same way — through
  `recordConflict(...)`, never a direct write (see the single-writer rule below), and `conflict(for:)` is read
  by the VM's `syncConflict` so the pill appears/disappears live (`@Observable`).
  **The record is persisted, not just in-memory** — mirrored onto the draft as
  `PendingDraft.conflictServerUpdatedAt`, and rehydrated into `conflicts` in the
  coordinator's `init` (which runs at app start, before any editor exists). It has to be:
  on launch the editor renders a stored draft *synchronously* and unblocks editing before
  any revalidation returns, so with an in-memory-only record a Done tap could reach
  `enqueue` with no hold in force and full-overwrite the co-author's body the user had
  already been warned about. The baseline and rule 1's stamp are persisted for the same
  reason; the hold is no different.
  **`reconcileDraft` records a conflict even in its `.pendingSync`/`.failed` early
  return.** That branch exists so the tolerance rule can't discard content the retry
  affordance is holding — but skipping *detection* there left the hole this whole
  feature exists to close: the fetch has just proved the server moved on, and with no
  record the enqueue-hold never engages, so the user's next "tap to retry"
  (`saveNow` enqueues straight through) full-overwrites the web edit the app had
  already fetched. Recording is non-destructive — nothing is installed, the draft
  stays — and strictly more protective.
- **Superseded plan decision — conflict detection is NOT limited to the draft-replay path.**
  The approved plan locked "the online 10 s autosave loop stays last-write-wins; the conflict
  check runs only on the draft replay path". That decision does not survive contact with the
  code, and review found the data loss it permits, twice: `apply` diverts to
  `cacheServerCopy` the moment the screen is dirty, so **a single keystroke landing while a
  revalidation is in flight** skipped detection entirely and the ensuing autosave
  full-overwrote a web edit the app had *already fetched*; and the "Updated" stash — a server
  body the app fetched **and showed the user a banner for** — was thrown away on the first
  keystroke with nothing recorded. In both cases whether the destructive push got checked was
  decided by *when the user's finger landed*, which is not a policy anyone chose. Detection
  therefore also runs in `apply`'s dirty branch and in `abandonPendingFreshContent`. It is
  still **not** a live-collaboration feature: the app never merges, and a conflict only ever
  arises from a body the app has already fetched.
- **Lifecycle: a conflict record is meaningful only while local work exists.** Record it
  when such work appears (`markDirty`, a queued draft, a dirty revalidation); release it when
  it is gone (`reconcileClean`, which `apply` reaches only with no pending save, no draft and
  not dirty — so a record there cannot be live). Get the first half wrong and a *phantom*
  conflict wedges a document with no unsaved changes; get the second wrong and a conflict
  that has become moot parks every future save behind a question with nothing left to ask.
  Only a `.push` decision releases it: `.discardServerWins` is **not** "no conflict" — it is
  rule 3 firing for a legacy draft the server has moved past, which is exactly the state
  `runSyncPass` records a conflict for.
- **Hold the push.** While a conflict is recorded, `enqueue` writes the draft and
  the queued slot (write-ahead, so `pendingSave()`/`hasUnsavedLocalContent` keep
  working) but does **not** start a save — an autosave flush must never overwrite
  the conflicting server copy unasked. `syncPendingDrafts` likewise skips a
  conflicted draft entirely. Together these give the **invariant both resolvers rely
  on: while a conflict is recorded, no save for that document is in flight** (nothing
  can record one *during* a save either — `apply` diverts to `cacheServerCopy`
  whenever `pendingSave != nil`, so `reconcileDraft` is unreachable then). No save can
  land underneath a resolver and resurrect the losing body.
- **Keep mine** (`resolveConflictKeepingLocal`): clear the record and release the
  held push — an unchecked, last-writer-wins overwrite the user chose (the
  overwritten server version is recoverable from the web's version history). The VM
  wrapper `flushPendingChanges()` first, so the push captures the newest content.
  **It also advances the baseline** — on the stored draft *and* on the editor's
  in-memory `serverBaseline` — to the server timestamp the user chose to overwrite.
  Both halves are load-bearing: the released push very often fails (the conflict is
  usually reviewed on the connection that caused it), and a surviving draft with its
  original baseline would make the next sync re-detect the identical conflict and hold
  the push again — the answer evaporating, forever. Advancing only the draft is not
  enough either, because `enqueue` rebuilds the draft from the baseline its *caller*
  passes and the next autosave flush passes the editor's.
- **Keep the server version** (`resolveConflictKeepingServer`): the one sanctioned
  discard — and it **fetches before it discards**. The VM ends the editing session,
  fetches the server body, and only once that body is *in hand* (generation still
  current, `mayPredateSave` false) drops the draft/queued work and installs it.
  Discarding first and refreshing after was a real data-loss path: a conflict is
  usually reviewed on the same flaky connection that caused it, and a failed fetch
  then left the discarded body still on screen with nothing backing it on disk, the
  conflict record cleared and the stale baseline intact — so the next keystroke
  full-overwrote the server copy the user had just chosen to keep. On failure the
  draft *and* the conflict both survive, so the pill and sheet stay available and
  everything on screen is still backed by disk.
- **A remote rename is merged, not reverted and not dialogued.** A save PATCHes content
  **and** title, so the title needs a rule of its own — and it is a *merge*, because
  title and body are independent fields. `DraftBaseline` therefore carries the server's
  `title` alongside its `markdown`, and `draftSyncDecision` resolves **which title a
  `.push` PATCHes** (`draftTitleOutcome`), rather than leaving the caller to reach for
  `draft.title`. With `b` = the baseline's title, `d` = the draft's, `s` = the server's:

  | | |
  |---|---|
  | `b` or `s` unknown, or the server is no newer than the baseline | push `d` |
  | `s == d` (already agree) | push `d` |
  | `d == b` — only the server renamed | **adopt `s`** |
  | `s == b` — only the user renamed | push `d` |
  | all three differ — two different renames | **`.conflict`** |

  Without this, a web rename left the body untouched, so it *was* rule 2's body-equality
  `.push` — correctly, since a rename must not raise a conflict dialog — and the replay's
  title PATCH then quietly reverted it to the title the draft was made with. The
  co-author's rename disappeared with no prompt. A titleless baseline (`b == nil`: a
  draft or cache entry written before the field existed) keeps the old behavior exactly:
  nothing to compare against, so nothing is adopted and no conflict is invented. The
  `.push`'s `PushEvidence` rides through the title resolution untouched — a one-sided
  rename is a fact about the title, not the body, so it can't weaken the body evidence a
  standing conflict is released on.

  **Adopting a title advances the baseline's title with it** (`adoptedBaseline`). The
  draft now descends from that server title, and a baseline left on the old one would
  make the adopted title look like a *local* rename to the next reconcile — so a
  **second** remote rename would read as "both renamed, differently" and raise a
  `.conflict` the user never created. A push that keeps the draft's own title advances
  nothing: writing the *user's* rename into the baseline would make the next reconcile
  mistake the server's older title for a rename they never made and adopt it back over
  theirs.

  The date short-circuit in the first row is also what makes a **"keep mine" answer
  stick**: that resolution advances the draft's baseline to the server state the user
  chose to overwrite, so the retry after a failed push sees a server no newer than the
  baseline and pushes their title — rather than re-raising the identical title conflict
  they just answered, forever.
- **The editor must not push a title behind the replay's back.** The editor **never
  refetches on foreground** — it only flushes — and foreground/reconnect is exactly when
  `syncPendingDrafts` runs. So a background replay can adopt a co-author's rename into a
  document's queued work, push it, and land it entirely behind an open screen still
  showing the pre-rename title; the next keystroke's flush PATCHes `title` and would put
  the old name straight back. Three things close that, and each has a named regression
  test:
  - `reconcileDraft` adopts a resolved title onto the screen **and** onto the stored
    draft (`DocumentSaveCoordinator.adoptServerTitle`, which rewrites the draft without
    starting a save). It does this in its `.pendingSync`/`.failed` early return too, and
    in `apply`'s **dirty** branch — that state's funnel is the user's retry (`saveNow`)
    or the next flush, both of which PATCH `savedTitle` with no reconcile of their own.
  - `DocumentSaveCoordinator.knownServerTitles` records the newest title anything knows
    the server holds — written by a landed save (the server now holds *our* title) and by
    every editor fetch that clears `mayPredateSave` (`noteServerTitle`, called in **both**
    `apply` and `installFetched`; the latter covers the one install that does not go
    through `apply`, `resolveConflictKeepingServer`, which is also the one that drops the
    draft — a stale entry there would be exactly what the next flush PATCHed).
  - `EditorViewModel.adoptQueuedTitleIfUnseen` runs in both save funnels
    (`flushPendingChanges`, `saveNow`) and takes the newest of: the queued save's title,
    the stored draft's, then the known server title — in that order, because unsaved local
    work holds a title the server does not have yet. An **unflushed local rename**
    (`title != savedTitle`) outranks all of them: that is the user's own edit, and it is
    what makes a reconcile call two titles a conflict rather than a merge.
- **Detection also runs in `apply`'s dirty branch** — it must, or the whole safety net
  turns on **keystroke timing**. That branch (`pendingSave != nil || isDirty` →
  `cacheServerCopy`) used to return without consulting the decision, so a queued offline
  draft whose revalidation proved the server had moved on got its push held — *unless* the
  user happened to type one character while that fetch was in flight, in which case
  `isDirty` diverted here, nothing was recorded, and the next autosave full-overwrote the
  web edit the app had just fetched. Whether a destructive push is checked cannot hinge on
  a race with the user's fingers. Recording there is non-destructive (nothing is installed;
  the edits and the draft stay put) and it engages the enqueue-hold, so the pending autosave
  parks and the pill — which renders **while editing** — asks. Two constraints make it safe:
  it is gated on `pendingSave == nil`, preserving the "no conflict while a save is in
  flight" invariant; and rule 1 is fed from `lastConfirmedPush(documentID:)` rather than the
  stored draft, which is nil right after a save lands and would otherwise make **our own
  just-pushed body** read as a diverged server and raise a false conflict against the user.
- **No false conflicts against our own writes.** After a confirmed save the
  coordinator remembers what it pushed (`lastConfirmedPushMarkdown`) and stamps it
  onto the next edit's draft as `lastPushedMarkdown`, so `draftSyncDecision` rule 1
  recognises "the server's most recent writer was us" — even across a relaunch —
  and pushes instead of flagging a conflict. A web title-only rename (body still
  equals the baseline) is rule 2's body-equality push, also not a conflict.

#### Pull-to-refresh (explicit refresh)

`.refreshable` stops calling `load()` and calls a distinct intent
`func refresh() async` (`EditorView.swift:257–259`):

- It **awaits** the revalidation fetch, so the system refresh spinner reflects
  real work.
- It applies the **same content rules** as a passive revalidation — `apply(...)`
  takes no "user initiated" flag. A clean copy gets the fetched body installed
  either way, so a refresh can never be the only way to see a remote edit.
- Its one difference is **loudness**: a failure sets `errorMessage` instead of
  being swallowed. A user who explicitly asked deserves to know it didn't work.
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
**no server timestamp is available at save success** — so the entry records
`serverUpdatedAt: nil` (truthfully "unknown after a void save"; §1), i.e.
`(documentID, title, markdown, syncedAt: Date(), serverUpdatedAt: nil)`, written
whether or not a prior entry existed (a save after eviction recreates the entry).
Fetch-sourced writes (`installFetched`, `reconcileClean`, `cacheServerCopy`) do
record the fetched `updated_at`, so a later open can build a draft baseline from
the cache. The coordinator owns
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
     `EditorViewModel.swift:88–95`). A transient/transport failure maps to
     **`.pendingSync`** ("Saved on this device · syncs when online"), which sits
     just below the hard-`.failed` "Couldn't save · tap to retry" tier: it beats
     the plain offline wording and, when the device is actually online (so the
     reconnect/foreground auto-sync can't fire), it doubles as a manual retry.
     After eviction, "no cache entry" does not
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
- **Sync-conflict pill & sheet.** Render a `danger`-tinted "Sync conflict · tap
  to review" pill (mirroring the "Updated" banner's placement/structure) whenever
  `viewModel.syncConflict != nil` — **including while editing**, unlike the "Updated"
  banner: the enqueue-hold parks an editing session's autosave, so a typist would
  otherwise have no signal *and* no way out. For the same reason `syncCaption` takes
  `hasConflict` and degrades to a passive "Saved on this device": while the push is held,
  `.pendingSync`'s "syncs when online · tap to retry" would promise a sync that cannot
  happen and offer a retry that re-enqueues straight back into the hold.
  **The editing header applies the identical precedence** — `saveStatusDisplay`
  (`EditorSaveBar.swift`), the pure resolver behind `SaveStatusIndicator`: it is the surface
  the user is actually looking at while typing, and detection on the dirty branch means a
  save can now be held *mid-session*, where the raw state would render as "Saving…"/"Saved"
  (a sync that is not happening) or offer a `.failed` "tap to retry" that only re-parks. Under
  a held conflict it shows a passive "Saved on this device" (`cloud_off`) and offers nothing,
  leaving the pill as the sole affordance. `.dirty` keeps its **Save** funnel: the newest
  keystrokes are not on disk until the flush writes the draft, so "Saved on this device"
  would be a lie there — and the tap still persists them (held, but safe). Tapping the pill presents
  `ConflictSheetView` — a flat `SheetHeader` list (per the design system) offering
  **Keep my version** (`resolveConflictKeepingMine()`) and a destructive,
  confirmation-gated **Keep the server version** (`resolveConflictKeepingServer()`),
  plus a footnote that overwritten versions are restorable from the web's version
  history. See *Conflict detection & resolution* above.
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
  remains reachable from retained Search/Shared results (and, historically, the
  since-removed `DocTreePanel`), renders its full cached content instantly, and —
  because transient revalidation
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
      │  clean & body changed  ─▶ install it (editing? stash + banner instead)
      │  clean & title changed ─▶ apply title silently (both branches)
      │  fetch raced our save  ─▶ discard the response; unpin .pendingSave only
      │  save settled          ─▶ .pendingSave reclassifies: draft (failed) / clean
      ▼
refresh() (pull) ─▶ same rules, awaited by the spinner; a failure additionally
      │             sets errorMessage instead of being swallowed
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
  - cached markdown that fails byte round-trip (e.g. `*` bullets) → opening and
    closing the editor without an edit enqueues **no** save (the `savedMarkdown`
    baseline equals `serializeMarkdown(blocks)`), both on cached open and after
    `applyPendingUpdate()` (destructive-save regression);
  - revalidate, server identical → `lastSyncedAt` advances, no banner; server
    export differing **only in canonicalization** → no banner (phantom-banner
    regression); same after a save success;
  - revalidate, body changed, clean & **not** editing → body installed, no banner
    (the "only the title updates" regression); clean & editing →
    `updateAvailable == true`, blocks unchanged until `applyPendingUpdate()`;
  - revalidate whose fetch raced a local save → body neither installed nor
    cached; the screen keeps the just-saved content and is not stranded;
  - revalidate with a draft left behind by a failed save → draft survives
    regardless of `displaySource`; a draft the server has passed beyond the clock
    tolerance is discarded and the server copy installed;
  - revalidate, **title** changed, body identical → title + cache + `savedTitle`
    updated silently (no spurious save), no banner;
  - revalidate while dirty → the fetched body is cached silently and the edits are
    untouched, but the **decision still runs** (`pendingSave == nil`): a diverged server
    records a `SyncConflict`, so the ensuing autosave is *held* rather than overwriting a
    web edit the app has just fetched. Whether a destructive push gets checked must not
    depend on whether a keystroke landed before or after the fetch resolved;
  - a stored draft is reconciled by **`draftSyncDecision`**, not the bare tolerance rule:
    a baseline-carrying draft is never silently discarded — it either pushes or becomes a
    `.conflict`. The tolerance rule survives only as rule 3, for legacy baseline-less drafts;
  - banner then edit: `updateAvailable == true`, then `startEditing()` / the first keystroke
    → `updateAvailable == false`, blocks unchanged — **and the abandoned stash records a
    conflict**, because it is a server body the app fetched and *showed the user*, which the
    next autosave would otherwise full-overwrite unasked; `applyPendingUpdate()` while
    dirty/editing is a no-op;
  - second `load()` during an in-flight revalidation → latest-wins, no stale
    banner; content turning dirty mid-fetch → no banner;
  - revalidation 404 → cache entry removed, "no longer available" shown, editing
    disabled; 403 → same; 401 → cache kept, content readable;
  - `refresh()`: applies newer server content directly (no banner) when clean;
    sets `errorMessage` on failure even with cached content; leaves edits
    untouched when dirty; reclassifies a completed `.pendingSave` so it can
    apply remote content instead of no-oping forever;
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
- [`architecture.md`](architecture.md) — the error-handling line "no offline
  queue/cache in v1" is superseded: previously-opened documents are now cached on
  disk and readable offline with background revalidation (see this doc). The
  "Offline editing/sync queue" non-goal stands — offline *editing* remains out of
  scope; only offline *reading* was added.
- `README.md` reviewed — it makes no offline/loading claims, so no change.
- This document is a living design doc — kept current as behavior changes.
