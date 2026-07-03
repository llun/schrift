# Instant Local Document Content + Background Sync — Design Spec

Date: 2026-07-03
Status: Proposed

## Summary

Make an already-opened document appear **instantly** with no loading UI, by
persisting its content in a local, on-disk cache. When a cached document is
opened, its content renders immediately from the cache and the server copy is
revalidated **in the background** (stale-while-revalidate). Only a document that
has never been loaded on this device still shows a loading spinner. A
**"Synced X ago"** caption under the title reflects when the local copy last
matched the server and updates live as syncs complete. When a background sync
finds a newer server copy while the user is viewing clean content, a subtle,
tappable **"Updated"** banner offers to refresh — content is never swapped out
from under the user.

As a direct consequence, previously-opened documents become **readable offline**
for the first time, and the editor's offline chrome ("Editing the copy saved on
this device") is gated on an actual local copy existing rather than shown
unconditionally.

## Goals

- A document that has been loaded at least once opens **with content already on
  screen** — no `ProgressView`, no perceptible load.
- Only a document with no local copy shows a loading indicator.
- Keep the content current: revalidate against the server in the background on
  open, and surface a newer server copy without disrupting the user.
- Show, under the title, the time the local copy last synced to the server, and
  update it live when a sync completes.
- Read previously-opened documents offline (natural consequence of the cache).
- Correct the editor's offline messaging so it only claims a device copy when one
  exists.

## Non-goals

- **Offline editing / sync queue** remains a non-goal (unchanged from the v1
  spec). Saves still require the network; this feature adds offline *reading* of
  cached content, not an offline write queue.
- No real-time collaboration, live cursors, or automatic multi-user merge. Saves
  remain full-overwrite / last-write-wins, exactly as today.
- No periodic/background-timer revalidation. Revalidation runs **on open only**.
- No change to the Yjs save encoder, the networking primitives, CSRF handling, or
  auth.

## Background: how loading & offline work today

- `EditorViewModel.load()` sets `isLoading = true` and **unconditionally** fetches
  `GET /documents/{id}/formatted-content/?content_format=markdown`
  (`EditorViewModel.swift:99–136`). There is no local content source; every open
  is a network round-trip behind a `ProgressView()` (`EditorView.swift:67`).
- On fetch failure the `catch` sets
  `"Couldn't load this document. Pull to refresh to try again."` So opening any
  document offline currently **fails with an error** and shows no content.
- Local drafts do **not** help offline: the pending-save / stored-draft branch is
  *inside* the `do` block, consulted only **after** a successful fetch
  (`EditorViewModel.swift:111–118`, gated behind the `try await` on line 103). If
  the fetch throws, the draft is never shown.
- `DocumentCacheStore` (`Features/Home/DocumentCacheStore.swift`) caches document
  **metadata** (full `Document` values, including the server `updatedAt`) for the
  Home list only — never content.
- `isOffline` in the editor is currently **cosmetic**: it shows the
  `OfflineBanner` "Editing the copy saved on this device" (`EditorView.swift:54`)
  and changes the header subtitle to "Saved on this device"
  (`EditorView.swift:237`), but gives `load()` no local content source. The banner
  over-promises.
- The header subtitle line under the title currently hard-codes
  `isOffline ? "Saved on this device" : "Edited just now"` — a placeholder, not a
  real status.

## Architecture

Follows existing conventions: a new synchronous, side-effect-free `*Store` for the
cache; new state and intent methods on the `@MainActor @Observable`
`EditorViewModel`; a background revalidation `Task`; small `EditorView` chrome
changes; and a cache write from `DocumentSaveCoordinator` on save success. No
concurrency annotations on the pure store; the async boundary stays at the
networking layer.

### 1. New store: `DocumentContentCacheStore`

New file `Schrift/Features/Editor/DocumentContentCacheStore.swift`. Persists one
cache entry per document:

```swift
struct CachedDocumentContent: Codable, Equatable, Sendable {
    let documentID: UUID
    let title: String?
    let markdown: String
    let serverUpdatedAt: Date   // FormattedDocumentContent.updatedAt at fetch time
    let syncedAt: Date          // wall-clock of the successful fetch/save
}
```

Design decisions:

- **File-based, not UserDefaults.** Content bodies can be large; UserDefaults
  loads its entire plist into memory. Store one JSON file per document in a
  dedicated directory under Application Support
  (e.g. `.../Application Support/dev.llun.Schrift/ContentCache/<uuid>.json`),
  with a small index for eviction. Application Support (not Caches) so the copy is
  durable and not silently reclaimed by the OS — "keep local" means it survives.
- Follows store conventions: inject a `FileManager` / base-directory seam so tests
  use a temp dir; all reads use `try?` and return safe defaults; the store never
  throws to callers; reverse-DNS directory naming.
- **Eviction:** keep the N most-recently-synced documents (start at **50**), evict
  the oldest by `syncedAt`. Silent to the user.
- This store is the single source of truth for "has this document been loaded
  before on this device."

API (sketch):

```swift
final class DocumentContentCacheStore {
    func content(for documentID: UUID) -> CachedDocumentContent?   // synchronous
    func save(_ entry: CachedDocumentContent)                      // + evict
    func remove(documentID: UUID)
}
```

### 2. Reworked load flow in `EditorViewModel`

Split loading into an **instant, synchronous local phase** and an **async
revalidation phase**. The local phase never awaits and never shows a spinner.

**Local phase (synchronous, no network, on `load()` entry):** choose the display
source by precedence:

1. In-flight pending save (`saveCoordinator.pendingSave`) — dirty local content.
2. Stored draft (`saveCoordinator.storedDraft`) — dirty, trusted local edits.
   *(Showing this without a prior successful fetch is new; it fixes the current
   "drafts unreachable offline" gap.)*
3. **Cached content** (`contentCache.content(for:)`) — clean, previously synced.
4. **None of the above** — set `isLoading = true` and go straight to the async
   fetch (this is the **only** path that shows `ProgressView()`).

For sources 1–3, render immediately: parse blocks, set the dirty baseline, set
`isLoading = false` (it never became true), set `hasLocalCopy = true`, and set
`lastSyncedAt` from the cache entry's `syncedAt` (nil for a draft-only source with
no cache).

**Revalidation phase (async `Task`, for sources 1–3 and after 4):** fetch
`formatted-content` in the background.

- **Fetch fails / offline:** keep whatever is displayed; leave `lastSyncedAt`
  unchanged; do not set `errorMessage` if we already showed local content. (Only
  source 4 — no local copy — surfaces the load error, as today.)
- **On-screen content is dirty** (source 1/2, or the user has started editing):
  update the cache silently for next time; **never** show a banner or disturb the
  edits. Conflict handling stays with the save coordinator, unchanged.
- **On-screen content is clean and the fetched markdown equals what's displayed:**
  bump `syncedAt` to now and refresh `lastSyncedAt` (label becomes "Synced just
  now"). No banner. (Content equality is the signal, not `updatedAt` alone — a
  no-op save elsewhere can advance `updatedAt` without changing content, and must
  not pop a banner that does nothing.)
- **On-screen content is clean and the fetched markdown differs from what's
  displayed:** stash the fresh content, set `updateAvailable = true` (drives the
  banner). Do **not** change what's on screen. Update the cache entry so the fresh
  copy is what future opens use.

New VM state and intents:

```swift
var lastSyncedAt: Date?          // drives the "Synced X ago" caption
var hasLocalCopy: Bool           // drives offline chrome; true when displayed from a local source
var updateAvailable: Bool        // drives the "Updated" banner
private var pendingFreshContent: (markdown: String, title: String?, updatedAt: Date)?

func applyPendingUpdate()        // swap in stashed fresh blocks, bump syncedAt, clear the flag
```

`load()` writes the cache after a successful **source-4** fetch (first-ever load)
so the next open is instant.

### 3. Cache stays consistent on save

On a **successful** save, `DocumentSaveCoordinator` writes the just-saved markdown
into the content cache with `syncedAt = now` and `serverUpdatedAt` advanced to the
save's timestamp. The coordinator owns the reliable save-success point (saves can
complete after the editor is dismissed), so the write lives there, not in the
view. The coordinator gains a `DocumentContentCacheStore` dependency (injected,
with a production default), used only on save success. Draft/`PendingDraftStore`
lifecycle is otherwise unchanged.

### 4. UI changes in `EditorView`

- **Spinner only for source 4.** `if viewModel.isLoading` stays, but `isLoading`
  is now true only when there is no local copy. Cached opens render immediately —
  satisfying "no loading progress at all if loaded at least once."
- **Header subtitle → real sync status** (`EditorView.swift:237`). Replace the
  hard-coded `"Edited just now"` / `"Saved on this device"` with:
  - clean & synced → **"Synced X ago"** (relative, from `lastSyncedAt`, via a pure
    formatter like `documentRowDate`), updating live;
  - unsaved local edits present → the save-oriented wording (offline → "Saved on
    this device"; online → the live save state);
  - never synced (brand-new/draft-only) → "Not synced yet" (or empty).
- **"Updated" banner.** When `viewModel.updateAvailable`, show a subtle, tappable
  pill ("Document updated · tap to refresh") below the nav/offline banner and
  above the content; tapping calls `viewModel.applyPendingUpdate()`.
- **`OfflineBanner` gated on a real copy** (`EditorView.swift:54`). Show
  "Editing the copy saved on this device" only when
  `isOffline && viewModel.hasLocalCopy`. Offline with nothing cached falls through
  to the normal error/empty state instead of over-promising.

### 5. Navigation / wiring

`EditorScreen` constructs the `EditorViewModel`; it gains the
`DocumentContentCacheStore` dependency (production default) and passes it through,
mirroring how `saveCoordinator` is threaded today. No change to what the Home list
passes (still a `Document` / id).

## Data flow

```
open document
      │
      ▼
load() ── local phase (sync, no network) ─────────────────────────────┐
      │  in-flight save? ──▶ show (dirty)                              │
      │  stored draft?   ──▶ show (dirty)                              │
      │  cached content? ──▶ show (clean) + lastSyncedAt from cache    │
      │  none            ──▶ isLoading=true ─▶ ProgressView            │
      ▼                                                                │
revalidate (async fetch formatted-content) ◀───────────────────────────┘
      │  fails/offline           ──▶ keep display (offline reading works)
      │  dirty on screen         ──▶ update cache silently, no banner
      │  clean & fetched==shown  ──▶ bump syncedAt ("Synced just now")
      │  clean & fetched differs  ──▶ stash + updateAvailable (banner)
      ▼
save success (coordinator) ──▶ write cache (syncedAt = now)
```

## Error handling

- Local content shown → background fetch failure is swallowed (no error banner);
  the stale copy stays readable. This is the offline-read path.
- No local content (source 4) and fetch fails → existing
  `"Couldn't load this document. Pull to refresh to try again."` error, unchanged.
- Cache read/write failures are non-fatal (`try?`), degrading to today's
  network-only behavior.

## Testing

XCTest, mirroring the source tree. New/updated:

- `DocumentContentCacheStoreTests` — save/load round-trip, `remove`, eviction to N
  by `syncedAt`, corrupt/missing file returns nil; injected temp directory.
- `EditorViewModelTests`:
  - cache present → `isLoading` never becomes true; content on screen before any
    network call resolves (via `MockURLProtocol` with a delayed/failing stub);
  - no cache → `isLoading` toggles true then false; content cached afterward;
  - offline (fetch throws) with cache → content stays, no `errorMessage`,
    `hasLocalCopy == true`;
  - offline with no cache → `errorMessage` set (unchanged behavior);
  - revalidate, server identical → `lastSyncedAt` advances, `updateAvailable`
    stays false;
  - revalidate, server newer, clean → `updateAvailable == true`, on-screen blocks
    unchanged until `applyPendingUpdate()`;
  - revalidate while dirty (draft/in-flight) → no banner, edits untouched, cache
    updated;
  - stored draft with no cache renders offline (regression for the current gap).
- `DocumentSaveCoordinatorTests` — content cache updated on save success; not
  updated on save failure.
- Pure relative-time formatter unit test.

## Rollout / risk

- Additive: a new store plus reordered load logic. The network fetch, save
  encoder, CSRF, and auth paths are untouched.
- Worst case if the cache misbehaves: it returns nil and the editor falls back to
  today's network-only load. No data loss risk — the cache is a read-through copy;
  the server and `PendingDraftStore` remain the sources of truth for unsaved work.

## Docs to update alongside implementation

- `CLAUDE.md` — note the content cache tier and the load precedence in the Editor
  section; add `DocumentContentCacheStore` to the persistence-stores list and the
  repo-layout map.
- This spec is the point-in-time design record.
