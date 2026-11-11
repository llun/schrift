# Schrift — Architecture & Design

> **Living design document.** This is the full architecture and design rationale
> behind Schrift, kept current with the shipped app — update it in place when
> behavior changes. [`AGENTS.md`](../AGENTS.md) is the shorter operational
> "how we write code here" companion. Two sibling docs go deep on areas this one
> only summarizes: [`offline-and-sync.md`](offline-and-sync.md) (on-device
> caching and background revalidation) and
> [`design-system.md`](design-system.md) (the design-system refresh — adaptive
> dark theme, in-app localization, and read-only version history).

Notable behavior that post-dates the original v1 scope and is reflected below:

- **Saving is fully on-device.** The app builds a byte-exact Yjs update with a
  hand-written encoder in `Core/Yjs` and `PATCH`es it directly — no temporary
  document is created.
- **Offline reading, editing, and lists.** Previously-opened documents and every
  document list are cached on-device and render instantly with silent background
  revalidation; a **Work Offline** toggle (`schrift.workOffline`, Profile) serves
  those caches without touching the network. Since 2026-08-01 a cached document
  is also **editable** offline: the edit is written to `PendingDraftStore` before
  any network attempt, parks at `.pendingSync` ("Saved on this device · syncs
  when online"), and replays on reconnect/foreground/launch. Offline *creation*
  has landed too — Home's `+`, "Add a subpage" and the drawer's "New page" mint a
  client-minted-id record when the network cannot take the POST, and a replay POSTs it
  and migrates the draft onto the server's id. Its storage and safety holds
  (`PendingDocumentCreateStore`, the gates that keep any *save* from naming a
  client-minted id, and the replay that POSTs such a document and migrates it onto
  the server's id) landed first. See
  [`offline-and-sync.md`](offline-and-sync.md).
- **Persistent sessions.** Session cookies persist in the Keychain (as
  `…WhenUnlockedThisDeviceOnly`, so a restored backup can't carry a live session
  onto another device) across app kills, and a real 401 presents an in-place
  re-login sheet instead of dropping back to the Connect screen.
- **Rich editor content.** A standalone `![alt](url)` line with an absolute
  http(s) URL is a first-class image block through the whole editor/save
  pipeline, and photos can be inserted from the library (uploaded, then embedded
  on success). An embedded image whose origin matches the user's Docs server
  (every `/media/…` attachment) auto-loads; one hosted anywhere else renders a
  tap-to-load placeholder and fetches nothing until the reader taps it, closing a
  render-time IP/User-Agent/timing disclosure to a host the document's author
  chose (`imageLoadPolicy`). Displayed image bytes persist across mode switches and
  offline relaunch in a bounded session-scoped cache; image redirects stay on the
  requested origin. **Generic file
  attachments** (PDF, docx, …) that the web editor added render as inline cards
  that download once and preview full-screen through QuickLook, and stay
  readable offline from a disk cache — see
  [File attachments](#file-attachments-read-side) below.
- **Design-system refresh.** A complete adaptive dark theme, in-app localization
  across 11 languages with live switching, a restructured Profile, layout-fidelity
  work, and read-only version history browsing. In-app version *restore* and
  document-content translation remain out of scope (restore is a "Restore on the
  web" link). See [`design-system.md`](design-system.md).
- **Iconography.** The app bundles the exact Material Symbols font (a ~18KB
  Apache-2.0 subset, FILL axis only), rendered via `MaterialIcon`/`MaterialSymbol`.

## Summary

A native SwiftUI iOS/iPadOS app that acts as a client for [La Suite Numérique Docs](https://github.com/suitenumerique/docs) ("Impress"), targeting a self-hosted instance at `docs.llun.dev`. Visual design comes from the `Docs iOS Design System` design handoff bundle. v1 scope: browse/search documents, view rendered content, basic non-realtime editing (save replaces content), and sharing/permissions management. No real-time collaborative editing.

## Goals

- Browse, search, pin documents from docs.llun.dev on iPhone and iPad.
- View a document's rendered content natively.
- Edit a document's text and save changes back to the server.
- View and manage sharing: member roles and link visibility.
- Match the visual design system from the handoff bundle (indigo theme, iOS-native chrome).
- Install directly to the user's own devices via Xcode (no App Store distribution required).

## Non-goals (v1)

- Real-time collaborative *writing* (typing that other clients see live) — the two-way write path is now **fully wired end to end** (C2a's sync engine + C2b's snapshot-save mechanism + **C2c**'s editor wiring: a keystroke forwards to the replica and broadcasts, a peer's edit applies caret-preservingly, and a ~60 s debounce PATCHes a full-state snapshot), but it is **opt-in** — everything above runs only behind the default-off `schrift.liveCollaboration` flag, so shipped behavior is unchanged until a user enables it via **Profile → Preferences → "Live collaboration"** (C3). The owner will run the remaining on-device WebSocket check in TestFlight for this build. Presence avatars are live. See "The Yjs CRDT core" → "Live editing (C1)", "Two-way sync engine (C2a)", "Live-snapshot save (C2b)", and "Editor wiring — the write path complete (C2c)". With the flag off, outbound edits use the existing HTTP save route: a full-overwrite PATCH before Docs 6, or a GET plus incremental PATCH on Docs 6.
- ~~Offline editing/sync queue.~~ **Superseded.** Offline *reading* of
  previously-opened documents was added 2026-07-03; the sync queue (write-ahead
  drafts, `.pendingSync`, conflict-checked replay on reconnect/foreground/launch)
  landed with the offline-sync work, and 2026-08-01 removed the view gates that
  kept it unreachable from a cold offline open. Offline **creation** of a
  document landed 2026-08-02, and **sub-pages of a document that is itself
  unsynced** followed on 2026-08-06 — the replay orders two dependent creates by
  refusing to POST a record whose parent is still pending, and repointing every
  such child at the id the server assigns the moment the parent lands.
- Comments/threads.
- AI features (proxy/transform/translate endpoints exist server-side but are out of scope).
- ~~Document version history browsing/restore.~~ **Superseded for browsing**: a
  read-only version-history list shipped (see the notes at the top of this
  document). **Restore** remains a non-goal — it hands off to the web app
  instead.
- File download/export (PDF/Word/ODT).
- Multiple simultaneous logged-in accounts/servers.

## Background research (why these choices)

Full detail lives in this conversation's research; key facts that drove the design:

- **Auth is OIDC-only**, server-to-server confidential client by default. No documented native/PKCE public-client flow for this codebase, and no personal API tokens. The DRF API validates bearer tokens via the IdP's `userinfo` endpoint with no audience restriction (so a token from any client on the same IdP *would* be accepted), but that path requires registering a new OIDC client per self-hosted instance and the app having no portable way to discover IdP endpoints from a Docs server URL alone.
- **Document content is an opaque base64-encoded Yjs CRDT blob**, stored in S3, edited live via a separate Node.js Hocuspocus WebSocket service authenticated purely by Django session cookie. No Swift Yjs implementation exists anywhere.
- The backend exposes `GET /documents/{id}/formatted-content/?content_format=markdown|html|json` for **reading** a converted snapshot, and (before Docs 6) `PATCH /documents/{id}/content/` for **writing** — but the write endpoint requires raw base64 Yjs bytes, not markdown/HTML. **Docs 6 removed `content/` (and `versions/`)**: content lives in the collaboration server ("yhub", `@y/hub`) mounted on the same origin under `/collaboration/`, whose `/collaboration/ydoc/v1/{org}/{id}` route returns the document's Yjs state as JSON and applies a PATCHed update *incrementally* — see "Editing & save mechanism" below.
- File-to-Yjs conversion (`Converter().convert(..., accept=YJS)`) is wired into document **creation only** (`POST /documents/` with a `file` field) — confirmed NOT present in the update path (`perform_update`/`DocumentSerializer.update`).
- Sharing model: document roles `reader < commenter < editor < administrator < owner` (`RoleChoices`); link reach `restricted < authenticated < public` (`LinkReachChoices`); link role `reader < commenter < editor` (`LinkRoleChoices`). Matches the design system's `LinkReachPill`/`ShareMemberRow` components exactly.
- API base path `/api/v1.0/`, `PageNumberPagination` (default page size 20, max 200), DRF throttle scope `document` at 80/min default.

## Architecture

Native SwiftUI app, iOS 26+ minimum deployment target, universal (iPhone + iPad). MVVM-ish: SwiftUI views + `@Observable` view models + an async/await networking layer. No third-party dependencies planned for v1 beyond what's needed for Markdown parsing/rendering (evaluate Apple's `AttributedString(markdown:)` first before reaching for a package).

```
Schrift/                  (originally planned as "DocsIOS/"; renamed 2026-07-01)
├── App/                  — app entry point, root navigation (RootView), appearance store. The tab shell is Features/Home/MainTabView: one system TabView (Home, Shared, Profile last) with independent navigation per tab, the docs tab hosting HomeSplitView at regular width. The swipe-back restorer is gone — the system back button restores the gesture itself
├── DesignSystem/         — tokens ported from tokens/*.css (indigo theme), and components: Button, IconButton, Avatar, AvatarGroup, Badge, DocIcon, DocIdentity, MaterialSymbol, SearchField, Switch, TextField, ListRow, ListSection, DocRow, PinnedCard, LinkReachPill, ShareMemberRow, OfflineBanner, SheetHeader, Skeleton, Toast
├── DesignSystemCatalog/  — visual QA catalog of every component
├── Core/
│   ├── Networking/       — DocsAPIClient (URLSession + async/await), endpoint definitions, Codable models mirroring DRF serializers, error types
│   ├── Auth/             — SessionStore (Keychain-backed session-cookie + server URL persistence, re-auth flag), SessionCookies (Codable HTTPCookie snapshot), WebLogin free functions (login-URL/completion detection, cookie sync), KeychainStore
│   ├── Collaboration/    — Hocuspocus/Yjs live-collaboration layer (wire codecs, WebSocket transport, session state machine, presence, and — C1 — a manager-owned per-document Yjs replica fed by inbound updates + the `LiveEditingBridge` that reflects it into the editor), dormant behind the default-off `schrift.liveCollaboration` flag
│   └── Yjs/              — the Yjs layer, two halves: the on-device Markdown→BlockNote→Yjs *encoder* (hand-written lib0/Yjs-v1 wire format) that builds the base64 content payload for saves, and the *CRDT core* (lib0 decoder, update decoder, struct store + YATA integration, the B3 store encoder `YStateEncoder`, and the B5 replica→editor projection `YBlockProjection`/`InlineMarkdownWriter`) — see "The Yjs CRDT core"
├── Features/
│   ├── Connect/          — server URL entry, recent servers, WebLoginView (WKWebView OIDC login sheet), session-expiry re-login sheet
│   ├── Home/             — MainTabView (the tab shell), document list: pinned/recent, pin toggle, offline list cache
│   ├── Search/ Shared/ Profile/ — Search is pushed from compact Home; Shared and Profile are the other primary tabs
│   ├── Editor/           — read rendering + edit + save, drafts, content cache
│   ├── Share/            — Share sheet (members, invite, link reach)
│   └── Options/          — Options sheet (pin, copy link, share, version history, delete)
└── Assets.xcassets/
SchriftTests/             — XCTest suite mirroring the source tree by directory
                            (sibling of Schrift/ at the repo root)
```

### Why no third-party CRDT/networking dependencies

The app *constructs* Yjs binary updates to save (see "Editing & save mechanism" below), but does so with a small hand-written lib0/Yjs-v1 encoder (`Core/Yjs`) rather than pulling in a CRDT library. This keeps third-party dependencies at zero.

> **Revised 2026-07-17.** This section used to add "It never needs to *parse* incoming Yjs — reads go through `formatted-content`." That is no longer true: `Core/Yjs` now also *reads* Yjs, and is growing into a full CRDT replica for live editing (see "The Yjs CRDT core"). The zero-dependency rule is unchanged — the replica is hand-written too.

## The Yjs CRDT core

`Core/Yjs` is being built out into a Swift Yjs replica so the app can join the same
Hocuspocus room as the web client and speak real Yjs, rather than PATCHing a
full-overwrite blob that a live web session would silently overwrite. It lands in
stages; today it can **decode** an update, **integrate** it into a live document,
**encode** the integrated document back out (B3) — a full snapshot, a diff against a
peer's state vector, or a state vector — byte-identical to yjs, **garbage-collect
and clean up formatting** on remote transactions (B4), **project** the integrated
replica back into the editor's block/markdown vocabulary (B5), turn a **local**
editor edit into local Yjs operations plus the incremental update they mint (B6),
and capture/resolve **relative positions** so a caret or selection survives local
and remote edits (B2). The
replica runs with **gc on by default** (`YDoc(gc: true)`, matching a real yjs client
and the live write path):
each transaction, `tryGcDeleteSet` sweeps the replica's *own* deleted items —
replacing a deleted item's content with a `ContentDeleted` tombstone and a deleted
type's children with `GC` structs (`Item.gc`). gc is still overridable to `false` for
the golden fixtures that pin the gc-off mode. GC *structs* occur regardless of the
flag — they arrive on the wire from peers that collect, `YItem.integrate` mints one
whenever an integrated item resolves to no parent (a neighbour was collected), and
`YStateEncoder` re-encodes all of them; what the flag toggles is only the periodic
`tryGcDeleteSet` sweep of the replica's own deletions.

| Piece | What it does |
|---|---|
| `Lib0Decoder` / `Lib0Encoder` | lib0 binary primitives (varint, varString, `any`), shared with the collaboration wire codecs |
| `YUpdateDecoder` / `YUpdateReencoder` | the v1 wire model — decodes updates, delete sets, and state vectors, and re-encodes them **byte-identically** |
| `YStateEncoder` | the **store** encode side (B3): `encodeStateAsUpdate(doc, since:)` (full snapshot / diff against a state vector) and `encodeStateVector(doc)`, byte-identical to yjs's `writeClientsStructs`/`writeStructs`/`Item.write`. Derives each item's wire info byte from the live item (never `YItem.info`); writes clients **descending** everywhere; reuses `YUpdateReencoder`'s delete-set/state-vector writers. **Throws** while `pendingStructs`/`pendingDs` are non-nil — yjs folds pending state in, but a pending replica must never be snapshotted (see "Pending structs and delete sets") |
| `YEvent` / `YDoc.afterTransaction` | the **change signal** (B3): `afterTransaction` fires at yjs's `'afterTransaction'` point (@3337), in the observer phase before formatting cleanup and gc/merge, with `transaction.changedParentTypes` filled by `callTypeObservers` (@5035, changed type plus every ancestor, `changed` insertion order) — only while a hook is set, since that hook is its only consumer. Text events carry yjs's `YTextEvent` delta, computed lazily from the transaction's before-state and delete set against the live item list, valid only during the hook, and never opening a transaction to read itself. Element events carry no delta. Events are dropped after the hook. A `transact` inside the hook is queued, as in yjs |
| `YTransactionEncoder` | the **transaction** encode side (A3): `encodeUpdate(transaction)` transliterates yjs 13.6.33 `writeUpdateMessageFromTransaction` (@3163) / `writeStructsFromTransaction` (@1674). Reuses the state encoder's struct writer and descending delete-set writer, but sends only this transaction's deletes, avoiding a whole-store tombstone scan per edit. Returns nil for no change; refuses pending state or active transactions/cleanup. Capture `tx` via the existing `transact` return and encode immediately after the outermost call succeeds, after `afterState`, gc and merging, before any further edit. `duringCleanup: true` is the one exception, used only by `YDoc.onUpdate` (yjs emits `'update'` from inside `cleanupTransactions`, @3388-3392). Use `YStateEncoder` for snapshots and peer state-vector replies (whole delete set) |
| `YContent` | the live, mutable content model (splice, merge) |
| `YStruct` / `YItem` / `YGC` / `YSkip`, `YType`, `YDoc` | the document graph |
| `YStructStore` | structs per client, binary search, splits |
| `YDeleteSet` | delete ranges, and applying an update's delete set |
| `YTransaction` | transaction lifecycle + the merge cleanup that runs after every update |
| `YStructIntegrator` | the driver: dependency ordering, pending structs, retry |
| `YBlockProjection` / `InlineMarkdownWriter` | the **read-out** side (B5): projects an integrated replica into BlockNote-vocabulary `ProjectedBlock`s and then into the editor's markdown. See "Projecting the replica" below |
| `YWrite` / `TextSpanDiff` / `BlockNoteWrite` | the **write-in** side (B6): local list/map mutation primitives, a char-level self-describing text-span diff, and the block-level edit driver that turns old/new BlockNote blocks into local ops + an incremental update. `applyEdit` (live) reconciles survivors through `BlockNoteWriter`; `applyEditLegacy` (the Docs 6 save) keeps the hand-authored reconcile. See "Local-edit transactions" below |
| `YRelativePosition` | the **caret/selection** primitive (B2): yjs `RelativePosition` — capture from a type index, resolve against a later document state, binary + JSON codecs, compare. See "Relative positions" below |
| `YTextOps` | the **format-aware text ops** (B4): yjs `YText`'s `insert`/`insertEmbed`/`delete`/`format` and the `ItemTextListPosition` cursor they share, on a root `YText` or a nested `XmlText`. See "Format-aware text operations" below |

### Relative positions (B2)

A caret or selection cannot be stored as an index: a peer inserting before it shifts
it, and a peer deleting the character it names destroys it. `YRelativePosition` is
yjs's answer — the type (by defining item id when nested, by root `share` key when
root) plus the id of one character/element plus an `assoc` side — and it is the
primitive the native editor will use to keep carets stable across local and remote
edits. `fromTypeIndex` captures, `resolve(in:)` resolves against any later state
(returning the type and its visible index), `encode`/`decode` are the binary form
over the existing lib0 codec, `json`/`init(json:)` are yjs's JSON shape, and
`compare` is its equality. There is no production caller yet.

Two behaviours are yjs's and look like bugs: an unknown kind tag **decodes** (yjs's
`switch` has no `default`; the position is merely unresolvable), and an unknown
`tname` **resolves to a fresh empty root** because yjs calls `doc.get(tname)`. The
binary form is lossy in one direction — an item-id encoding carries no type, since
the item's parent implies it. `assoc` is load-bearing at `index == length`: `assoc 0`
is the end-of-type position and follows text a peer appends, `assoc -1` is pinned to
the last character and stays before it (the C2 end-of-paragraph IME fix).
`followUndoneDeletions` follows `YItem.redone`, which `YUndoManager` (PR07a) sets when
an undo or redo re-creates content, so a position on undone text lands on its copy.

`resolve` reads and mutates the live doc, so it belongs on the replica's owner (main
actor) like every other doc access, and a future cursor path must treat it carefully:
an unknown `tname` **creates that root permanently** in `doc.share` (so a peer-fed
caller only resolves names that already exist or that the schema owns), and a throw
means a **malformed position, not a corrupt replica** — drop that cursor, never latch
`replicaFailSafe`.

### Projecting the replica (B5)

Decoding and integrating a remote update produces a live `YDoc`; **projection** turns
that document graph back into something the editor can show, in two pure stages.

- **Stage 1 — `YBlockProjection.project(_:interlinkingOrigin:)`** walks
  `document-store → blockGroup → blockContainer*` and folds each block's `xmlText`
  child (its interleaved `ContentString`/`ContentFormat` items) back into `InlineRun`s
  — the exact inverse of `BlockNoteYjs.emitInline`. It is a **total function**: it
  never throws and never traps on any replica shape (clocks are attacker-influenced),
  because anything it does not recognise is recorded as fidelity rather than crashing.
  Each `ProjectedBlock` carries a `ProjectionFidelity`:
  - `.modeled` — round-trips losslessly (the block kinds the editor already models,
    with known marks bold/italic/code/strike/link).
  - `.lossy(reasons:)` — renders with the same parity the server's own markdown export
    gives, but a write-back would drop data the editor can't represent (a non-default
    `textColor`/`backgroundColor`/`textAlignment`, a numbered-list `start ≠ 1`, an
    image caption). Markdown has no spelling for these, and neither does the export.
  - `.opaque(reason:)` — cannot be represented as markdown at all (unknown node, a
    toggle heading's collapsible children, a nested `blockGroup`, unknown inline
    content). A document with any opaque block is not `isFullyRenderable`.
  The web's `interlinkingLinkInline` (a `content:'none'` leaf inline node carrying
  `docId`/`title`) is modeled as a plain `[title](origin/docs/docId/)` link **when the
  caller supplies the server origin** — exact parity with the server's markdown export,
  which flattens it the same way — and is `.opaque` otherwise (the pure projection has
  no origin by default, and a lossy flatten would let a later classic save drop the
  link). C1 supplies the origin.
- **Stage 2 — `projectedMarkdown(_:)`** renders those blocks to the editor's markdown
  via `InlineMarkdownWriter` (runs → markdown) and then **self-verifies**: it re-parses
  its own output and, block by block, escalates escaping until the round trip holds,
  returning `nil` rather than ever emitting markdown that would re-parse to a different
  document. `InlineMarkdownWriter` is the inverse of the `InlineMarkdown` scanner, and
  the **scanner is its oracle**: the writer's correctness property is
  `InlineMarkdown.parse(write(runs)) ≡ normalized(runs)`, and where the two would
  disagree the writer refuses (emits `nil`) rather than lie. It is not a third inline
  engine — it holds a locked copy of the scanner's escaping/flanking predicates (a
  sync-lock test fails if they drift, the same discipline `isEscapable` already uses).

`YBlockProjection.project` never produces content the app's own encoder authored; its
job is to read **web-authored** replicas. Its faithfulness is pinned two ways: an
exact round-trip over the app's whole golden markdown corpus
(`encode(md) → decode → integrate → project → markdown == serializeMarkdown(parse(md))`),
and oracle fixtures captured from real yjs for the shapes the app can't author —
incrementally-typed split strings, concurrent two-client formatting, gc'd documents,
`mergeUpdates` output (Skip structs), nested lists.

### Live editing: applying remote updates (C1)

B5's projection is the read side; **C1 wires it into the open editor caret-preservingly.**
The pieces live across `Core/Collaboration` and `Features/Editor`:

- **The manager owns one replica per document.** `DocumentCollaborationManager` already
  owns per-document collaboration state (ref-counted sessions, a monotonic
  `remoteChangeToken`); C1 adds a per-document `YDoc` replica beside it. The session now
  delivers inbound sync update bytes through an `onSyncUpdate` callback (previously it
  discarded them and only signalled); the manager decodes and `applyUpdate`s them, bumps a
  monotonic `replicaVersion(for:)`, and exposes `projectedReplica(for:interlinkingOrigin:)`.
  It is the **single owner that touches the `YDoc`** — the editor receives only value-type
  projections — and it calls `YDoc.destroy()` when the entry is torn down. A decode/apply
  throw latches a per-document **`failSafe`**: the replica is destroyed and the document
  reverts to signal-only (the `remoteChangeToken` fallback still fires — a corrupt replica
  never drives the editor). `projectedReplica` returns nil until the first update is applied
  and while `pendingStructs` are outstanding.
- **`LiveEditingBridge`** (`@MainActor`, one per editor) owns the BlockNote-id ⇄
  `EditorBlock.id` identity map. On each `replicaVersion` change the view calls
  `replicaDidChange()`, which coalesces notifications to one display-frame apply. That
  apply — only when the editor is engageable — resolves the latest replica to
  `(rendered blocks, markdown)` via `YBlockProjection.renderedEditorDocument` (the escalated
  rendering `projectedMarkdown` settled on, so the applied blocks and the baseline are
  consistent by construction), diffs it against the current blocks by BlockNote id
  (`liveChangeSet`), and applies the change through the editor's surgical funnel. Surviving
  blocks keep their `EditorBlock.id`, so SwiftUI identity, focus, and scroll survive.
- **`EditorViewModel.applyLiveRemoteChange` is the one content-swap funnel that is NOT
  `install(...)`.** `install` re-parses the whole body, keeps only the ids of blocks whose
  content is unchanged (`reusingBlockIDs`), and nulls the caret (correct for a full
  server-wins swap); the live funnel instead mutates blocks in place, recomputes the
  focused block's caret with the pure UTF-16 `transformedCaret` rule, and advances the dirty
  baseline (`savedMarkdown`/`serverBaseline`) to the projected content — so a later
  tap-to-edit never false-dirties. It **never** enqueues a save, never sets `isDirty`, and
  never calls `install`.
- **Engagement is clean-session-only.** `canEngageLiveEditing` is true only while the editor
  is loaded, not dirty, not discarded/unavailable, and the coordinator reports no pending
  save, no stored draft, no recorded conflict, and an idle/saved state. On the first
  keystroke the bridge pauses and the existing A5 signal → refetch → #76 detect-and-ask
  machinery resumes unchanged. While the bridge is applying live content, the A5 REST
  refetch is **suppressed** (`isApplyingLiveContent`, evaluated fresh from the same
  engagement condition the apply uses) — the stream is newer than the 60 s REST snapshot, so
  installing a stale REST body would reset the caret and regress content.
- **Read-only in C1 — the write path is now wired on top of it (C2a/C2b/C2c, below).**
  At C1, nothing was encoded, broadcast, or PATCHed, and a peer's inbound `.step1` was
  ignored outright. **C2a** built the two-way sync *engine* one layer down (the session
  answers a peer's `.step1` with a real `.step2` diff, and the manager's `applyLocalEdit`
  turns a local edit into a broadcast update); **C2b** added the save *mechanism*
  (`enqueueLiveSnapshot`/`saveLiveSnapshot`); **C2c** is what finally calls both from the
  editor — see "Editor wiring — the write path complete (C2c)".

### Intent-based native writer (B5a)

`BlockNoteWriter` exposes `replaceText`, `formatRange`, `splitBlock`, `joinBlocks`,
and `setBlockType` against unique BlockNote ids, compared by UTF-16 code units
like opaque JavaScript strings (canonical normalization forms stay distinct,
including in duplicate checks and split's new id). Each intent runs in a local-user
transaction and returns only that transaction's update after cleanup. Its
`transaction` helper groups intents; nested calls return an empty update and the
outer call returns the combined update. A group is not atomic: each intent
validates before it mutates, but when a later intent throws, the earlier ones stay
in the store and the transaction's observers still deliver them, while the call
throws and returns no bytes — yjs has no rollback, so after a throw the replica is
the truth. Replica ownership/lifetime stays with the caller, which destroys the replica on any throw (as with `applyReplicaUpdate`): a throw out of transaction cleanup leaves it unusable. Since B5b it is the reconcile the **live** path uses (`BlockNoteWrite.applyEdit`); the Docs 6 save still calls `applyEditLegacy` (see "Local-edit transactions").

Ranges use UTF-16 text positions and one unit per atomic inline element (mentions,
interlinks, math and hard breaks — BlockNote's Shift+Enter is an empty `hardBreak`
element with no text, so a code block conversion drops it). A bound inside a
surrogate pair grows the range to the whole character and a caret there moves back
to its start; yjs would otherwise splice the pair and write U+FFFD into both halves.
They are clamped before format-aware `YTextOps` calls; the
writer never requests yjs's past-end newline padding. Nil insertion marks inherit
like yjs `insert`; an explicit map specifies the inserted marks. Code blocks allow
no marks: `formatRange` succeeds as a no-op and returns an empty update;
`replaceText` inserts plain text regardless of supplied marks. Node captures of
BlockNote's range style command, explicit-mark insertion and stored-mark typing
confirm this behavior; converting back to a paragraph retains plain text. This
is a supported no-op, rather than an `unsupportedBlockType` error (unlike a refused
code-block split or join). Copies keep inline
elements rather than flattening them, and copied runs go through the existing
`InlineContent.pieces(for:)` single shape builder. Supported content types are the
text blocks paragraph, heading, bullet/numbered/check list item and code block
(`BlockNoteWriter.propSchemas`, which also holds BlockNote 0.56's prop order and
defaults). The native engine's writer uses `nativePropSchemas`, which adds `quote` and
Docs' `callout` in their schema order; the classic live reconcile keeps the narrower table.

The block intents reproduce BlockNote 0.56's own commands, captured in node/jsdom
against real BlockNote + yjs 13.6.33 and inlined in `BlockNoteWriterCaptures`:

- **Split (Enter).** The block keeps its id, type, props and the text before the
  offset; the new block takes the rest and the nested children, and is a list item
  for list items, a paragraph otherwise, with default props. At offset 0 of
  non-empty content an empty block is inserted above, so the text keeps its id.
  Code blocks (Enter is a line break) are refused, and so is a toggle unless the
  caller passes its open state (`toggleOpen`, PR06b): closed, the split keeps the
  children with the toggle; open, the text after the caret becomes a new first
  child. An offset inside a surrogate pair snaps back to
  the pair's start; BlockNote itself writes U+FFFD into both halves there. Enter on
  an empty *nested* block outdents it in BlockNote (`emptyChildEnter: "outdent"`);
  the writer splits, and outdenting is the caller's choice.
- **Join (`mergeBlocksCommand`).** The content joins the previous sibling's last
  descendant, and the source's children are lifted into its place. An empty block
  above with the same type and props is removed instead, and the source moves up
  keeping its id and children. Code blocks on either side are refused, as in
  BlockNote; a block type the writer does not edit (image, quote, toggle list item)
  as the previous sibling or its last descendant is refused too, even where
  BlockNote would merge. The first sibling throws `noPreviousBlock` (BlockNote
  merges a first child into its parent; not implemented).
- **Type change (`updateBlock`).** Keeping the type writes only the changed props
  onto the existing element — byte-identical to BlockNote's checkbox toggle and
  heading-level change, and a collaborator's concurrent typing in the block
  survives. A new type replaces only the content element; the container, id and
  nested group stay. Given props override; every other prop of
  the new type keeps its existing value or takes its default. Into a code block the
  content becomes plain `textContent` (marks and mentions/interlinks drop, math
  keeps its source) — copying inline nodes into a code block made BlockNote delete
  the whole fragment on mount.

Missing targets, broken structure (`malformedBlock`) and duplicate ids throw typed
writer errors; a valid block the writer does not edit (divider, image, table)
throws `unsupportedBlockType`, so callers can tell broken from unsupported.
Keyboard-level choices BlockNote makes before these commands (Backspace resetting a
list item to a paragraph, Enter resetting an empty list item or outdenting an empty
nested block) stay with the caller.

### Local-edit transactions (B6)

C1 wires the *read* side into the editor; **B6 is the write side** — a pure `Core/Yjs`
layer that turns an editor edit (old blocks → new blocks) into local Yjs operations
against a replica and encodes only the incremental update those operations minted. C2a
threads it through the collaboration session and transport (`applyLocalEdit`); the
Docs 6 save reaches it through `BlockNoteIncrementalSave`.

**The single writer, gated in two parts (B5b, plan decision 6).** Insertion is shared
by both entry points — `insertBlock`/`insertContentElement` — so from-empty and
new-block insertion stay byte-identical to the golden encoder on either path. A
*surviving* block is reconciled by one of two paths, chosen explicitly at the call
site:

- `applyEdit` — the **live** path (`DocumentCollaborationManager.applyLocalEdit`) —
  reconciles through `BlockNoteWriter`'s intents: text through `replaceText` (one
  intent per run of the span `TextSpanDiff` chose, with explicit marks so the span
  never inherits a mark open at the caret), props and kind changes through
  `setBlockType` (same type sets only the changed props on the existing element; a
  kind change replaces the content element and keeps the container, `id` and nested
  group). The writer's own `transaction` sees the caller's open transaction and
  returns the empty update, so the whole edit stays one transaction and one
  broadcast. It addresses the block by the **container's live `id`**, not the
  caller's (the editor re-identifies a row after a remote structural change while the
  replica keeps the server's id, and the legacy reconcile never rewrote a survivor's
  id either), and it refuses an `old` whose text length disagrees with the live
  element — a lying-`old` guard, because the writer clamps a range for editor safety,
  so a lying `old` would silently rewrite the wrong span instead of failing, and the
  manager's fail-safe contract depends on the throw; the guard is skipped for
  inline-node blocks, which never take the writer path. Two kinds of survivor fall
  back to the legacy reconcile: a block type the writer does not edit (`quote`,
  `divider`, `image` — the projection models them, so the live path can reach them),
  and a block whose element holds an inline node — exact for `interlinkingLinkInline`,
  which the projection folds into a run whose text is the link title while the live
  element counts the node as one unit, so run-space offsets do not map to live offsets;
  defensive for mention/math/hard break, which the projection does not fold (it returns
  non-text inline content, so the block is `.opaque` and the live bridge never writes
  it). Both fallbacks are the code the live path ran before; the
  alternative is a throw the manager turns into a fail-safe and a permanent
  downgrade to classic.
- `applyEditLegacy` — the **Docs 6 incremental save** (`BlockNoteIncrementalSave`) —
  keeps the hand-authored `TextSpanDiff` + `YWrite` reconcile, byte-for-byte as
  before the writer landed. Plan decision 6 does not re-point it in phase 1;
  `BlockNoteIncrementalSaveTests` pins its bytes.

The re-point was gated on a parity lane (an out-of-tree harness, run once): 1000 seeds ×
3 sequential random edits over paragraphs, headings, list items, check lists, code
blocks, quotes, dividers and images — text edits with marks/links/emoji, prop changes,
kind changes, inserts, deletes, moves and empty blocks — each applied to two identical
replicas through `applyEditLegacy` and `applyEdit`, comparing the **projected
document** (id, node, props, per-unit marks, fidelity) and a from-empty render of
`new`: 3000 cases, 0 mismatches. The lane covers link **marks** only: `BlockNoteBlock`
runs cannot express an inline node, so it never produced an `interlinkingLinkInline`
— that shape is covered by `BlockNoteWriteLiveReconcileTests`. The one intended
difference it surfaced is a code
block whose runs carry marks (a document BlockNote cannot produce — the projection
reads it as opaque `marked code`): the legacy path keeps the marks, the writer drops
them, which is BlockNote's own rule. No incremental byte pin moved.

- **`YWrite`** is the local-mutation primitive layer: `insertAfter`/`insert` (list
  insert, yjs `typeListInsertGenericsAfter`/`typeListInsertGenerics`), `delete` (list
  delete, yjs `typeListDelete`), and `mapSet` (yjs `typeMapSet`) — each a faithful
  transliteration reduced to Schrift's needs (the caller already holds a built
  `YContent`, so the JS-value classification switch and the search-marker no-ops both
  disappear). Every primitive mints local `YItem`s at `store.getState(clientID)` and
  integrates them through the existing YATA loop (`YItem.integrate`) inside
  `doc.transact(local: true)` — pure value code that **mutates** the live replica
  graph, so it must run under the replica's single owner exactly like every other
  mutation.
- **`BlockNoteWrite.applyEdit(old:new:to:)`** is the entry point: it diffs `old` →
  `new` BlockNote blocks by id (insert / remove / kind-change / prop-change /
  in-place-survivor / moved-survivor), applies the difference as local `YWrite` ops
  inside one transaction, and returns `YTransactionEncoder.encodeUpdate(tx)` after
  the outermost `transact` returns successfully — an update containing only the
  structs and deletes this edit made. Cleanup must have filled `afterState` and
  completed gc/merging, matching yjs's update-event timing. This avoids rebuilding
  the whole store's delete set on every keystroke. The existing `Data` API maps a
  nil (unchanged) transaction to the canonical empty update `0000`. The Docs 6
  incremental save continues to decide "nothing changed" from store clocks/deletes,
  independently of the encoded update size. **Move is v1-coarse**: a survivor whose
  relative order changed is rebuilt whole (delete + re-insert after its new `left`) rather than
  relocated in place; reorders are rare in practice and remain covered by
  full-snapshot fixtures, so this trades minimality for simplicity.
- **The from-empty byte-identity anchor.** `applyEdit(old: [], new: blocks)` must be
  byte-identical to `BlockNoteYjs.encode(blocks, clientID:)` — the shipping golden
  encoder, itself already pinned to real yjs. This is B6's strongest correctness gate:
  it proves the builder reproduces the exact document shape yjs authors (item order,
  origins, parents, clocks) for every block type, because both encode the same store
  shape. It holds because `insertBlock` mints items in the same order the golden
  encoder does — blockGroup, then per block the container, the content element, the
  `xmlText` and its run pieces, the element's props, a nested `blockGroup` holding the
  block's children (if any, with the element as its left origin), then the container's
  `id` — and each `YWrite` primitive mints sequentially, so clocks/origins/parents (and
  therefore the encoded bytes) coincide. Children are only ever *inserted*, and only when the
  caller opts in with `allowsNestedInserts: true` (the Docs 6 save, which writes nested
  lists that way; the live path keeps the default `false` and throws): `old` must be flat, and a survivor whose new block
  has children is rebuilt rather than reconciled. On the legacy path a text change is
  spliced in place only when the element's sole child is one `xmlText`; an element with
  none (y-prosemirror's empty paragraph) or several (text split by an inline node) is
  rebuilt instead. The writer path has no such restriction for a text-only element:
  `replaceText` addresses the right `xmlText` and creates one when the element has
  none. An element holding an inline node still takes the legacy rebuild on both
  paths, because its run-space offsets do not map to live offsets.
- **B6 deviates from yjs only in local-item *construction*, never in the store
  algorithm — so it is verified at the document/projection level, not the
  store-structure level.** A changed text span is rebuilt wholesale from the new runs
  rather than yjs's incremental per-character format delta, and the generic
  list-delete used for a text edit deletes interior `ContentFormat` items that yjs's
  own text-specific `deleteText` steps past — both differences are harmless because
  the inserted replacement span is **self-describing** (see `TextSpanDiff` below) and
  re-establishes every boundary mark the deletion removed. `YItem.integrate`, merge
  cleanup, gc, and the encoders are exactly the code B1–B5 already proved against the
  oracle; B6 touches none of it. A store-dump comparison against a yjs oracle would
  therefore **false-fail** on a correct B6 edit (different items, same rendered
  content) — B6's own correctness property is instead *apply the same edit on both
  sides, then compare the projected document (and convergence across peers)*, never
  raw store shape.
- **`TextSpanDiff`** computes the minimal change between an old and new run list as a
  **character-level (char, active-marks) diff**, not a UTF-16-unit diff: it flattens
  both run lists to one `(UTF-16 unit, marks-dictionary)` pair per unit, finds the
  common prefix/suffix in that space, then **snaps both boundaries to code-point
  boundaries** so a surrogate pair can never be split across the kept/changed regions
  (splitting one would render two U+FFFD — yjs#248 — corrupting content the edit never
  touched). The changed span's replacement is built as **self-describing pieces**
  (`buildSpanPieces`): it opens the marks active at the new start and, at the end,
  transitions to whatever marks the kept suffix expects — so the replacement is
  correct even though the store-level delete may have removed the very
  `ContentFormat` items the suffix's formatting relied on.
- **`InlineContent.pieces(for:)`** (`InlineContent.swift`) is the shared open/
  carry/close-format sequence builder behind both the from-scratch encoder
  (`BlockNoteYjs.emitInline`) and `BlockNoteWrite`'s whole-subtree paths (a fresh
  block insert, a kind-changed element's fresh text) — extracted so the two cannot
  drift on what a run list means. `TextSpanDiff`'s own `buildSpanPieces` is a
  distinct, diff-specific builder (self-describing boundary opens/closes rather than
  a full sequence over whole runs), not a second definition of inline shape: both
  builders emit the same `InlinePiece` vocabulary, and `BlockNoteWrite` maps either
  output into `YContent` through one shared `content(of:)`. Don't add a third way to
  turn runs into pieces.
- **Verification.** A differential-fuzz harness run once out of tree (the
  zero-dependency rule) drove roughly 26,000 seeds / 400,000 oracle-verified renders
  against node yjs 13.6.31 across three lanes — BMP text edits, concurrent multi-peer
  convergence, and interop with `mergeUpdates`/gc/`diffUpdate` — and found zero
  divergences after fixing one bug: an early version diffed at raw UTF-16-unit
  boundaries and could split a surrogate pair, which the fuzz caught; the code-point
  snap described above is the fix.

### The headless document engine (B6a/B6b)

The phase 2 native editor's foundation. The default editor keeps its existing
path; PR01 connects this engine to an opt-in read-only TextKit 2 surface.
`Features/Editor/Engine/` holds these pieces:

- **`EditorSurface`** — the model → UI protocol: one `applyPatch(BlockPatch)`.
  A patch is a list of `BlockChange`s: `.text(blockID, [TextDelta])` (a
  block-relative UTF-16 range, its replacement and the marks it carries),
  `.props` (attributes only), `.insert(after:, [BlockSnapshot])`, `.remove`,
  `.replaceBlock` (the whole-block fallback for inline nodes, split/join, a type
  change, or a delta the text form cannot express) and `.reset([BlockSnapshot])`
  (the whole surface list, for a root-group replacement, a fragment that was
  empty when the engine attached, a container `id` changed in place, and every
  transaction while the replica is not index-shaped, `BlockIndex.isCanonical`). Every patch carries a `BlockPatchOrigin`
  (`.localUser`, `.remote`, `.other`) normally taken from the transaction;
  composition rebuilds always use `.other` and must be applied. The surface also
  receives `setCompositionDeferred(Bool)`; selection uses the engine's query API.
- **`HeadlessSurface`** — an in-memory surface that only ever changes through
  `applyPatch`, so a test can assert it equals the replica's projection after
  every step.
- **`DocumentEngine`** (no actor annotation: confined to the domain that creates it, PR08a) — borrows the replica from
  `DocumentCollaborationManager` or the native route's `DocumentReplicaSession` actor (PR08b; never owns it), exposes block-relative intents
  (`replaceText`, `formatRange`, `splitBlock`, `joinBlocks`, `setBlockType`)
  that resolve through `BlockNoteWriter` in one `.localUser` transaction and
  return the update bytes for broadcast, and turns the change signal into
  patches.
- **`BlockIndex` / `PatchBuilder`** — the index maps a block id to its container,
  content element and text children and is maintained incrementally from the
  transaction's changed types; the builder classifies those types and emits the
  patch.
- **`CompositionQueue`** — discards composing-block deltas, preserves independent
  block delivery, and remembers when completion needs a whole-list reset.
- **`EngineSelection`** — directed surface positions and their internal relative
  captures, including an element anchor for an empty text-capable block.

**Native reader (phase 2 PR01).** Profile's `schrift.nativeEditor` preference
defaults off and is read by `NativeEditorOpen` at each open or reopen. A selected surface
never changes in response to a preference write. `NativeEditorOpen` fetches the
existing raw `collaborationYDocState` for eligible online Docs 6 documents.
Legacy servers, offline/unreachable or local documents, pending deletions/local
content, pending creation intents and failed raw fetches/decodes stay with the classic editor. A three-second
prefetch deadline selects classic without waiting for a stalled request to finish
cancelling; closed/timed-out result streams cannot install late native sessions.
Its tasks, controls and live bridge
are not mounted alongside a native session.

Successful native selection also refreshes the existing offline cache before
publishing the session. The cache-only view-model path reuses `formattedContent`,
leaf-nesting recovery and `cacheServerCopy`; the stored representation remains
server-exported Markdown plus title, client sync time and server `updated_at`,
rather than a potentially lossy native projection. It does not install classic
display state or advance its edit baseline. This read is covered by the same
prefetch deadline, cancellation/availability checks and save-marker freshness
guard. The classic load route remains unchanged.
This refresh covers content only, not the children cache.

The native replica is separate from `DocumentCollaborationManager`. Since PR08b the
read-only reader is a one-shot projection (`NativeEditorSession.inspect`), and an
editable session's replica belongs to `actor DocumentReplicaSession`, which integrates
the raw baseline, attaches one engine and hands `NativeTextSurface` its first projection.
Close and deinitialization destroy the replica; failed seeding also destroys it.
`NativeTextView` uses standard TextKit 2 storage, asserts a text layout manager,
allows selection/copy, and owns scrolling. There is no legacy layout-manager read,
document-height measurement or full-document layout request.

`AttributedDocumentProjection` renders semantic marks, token-based typography,
block identity/type and structural separators. `BlockSnapshot.isOpaque` preserves
the difference between an opaque paragraph and an empty one. Unsupported blocks
get bounded read-only previews (one attachment each, PR06e below); an unsupported root has an explicit state.
`ProjectionRangeIndex` maps UTF-16 ranges without treating separators as replica
characters; duplicate/missing IDs are not addressable. `NativeTextSurface` applies
all six patch kinds and every origin, replacing exact text-delta ranges or affected block storage
slices (reset replaces all storage). Its settled storage equals a fresh
projection under normalized attribute comparison. For text/props changes, the
session projects the affected top-level block again; placeholders and fidelity
changes rebuild that slice instead of using replica offsets in a UI label. The
lookup scans container identities without reprojecting unrelated block text.
Dynamic Type/language changes
only rebuild presentation. No native edit/save/live path is introduced here;
durable typing/legacy adapters and complete block chrome belong to later PRs.
The generated project includes an isolated production-reader fixture host and
UI smoke test; `--native-large` supplies the 5,000-paragraph scroll fixture.

**PR02a persistence checkpoint.** `ReplicaStore` and `ReplicaManifest` add the
durable storage foundation used by the session/save component APIs and, since
slice B, the production open route. The main-actor store hashes the
server/account/org/document scope into an Application Support directory, retains
backup-included immutable checkpoint/update files, and flushes files and directory
entries before switching a checksummed manifest. Restore verifies all referenced
files; corrupt committed state is copied into recovery storage and blocked rather
than treated as empty. Unreferenced interrupted writes are ignored. Replay returns
checkpoint plus ordered updates; their Yjs client IDs remain intact.

The HTTP outbox is independent of the replay checkpoint and of state vectors.
Compaction retains pending local update bytes even when the new checkpoint already
contains their effect. Acknowledging a captured prefix leaves later edits queued;
delete-only updates require the same HTTP confirmation. There is no eviction or
sign-out removal; `remove(for:)` is an explicit discard through a tombstone rename,
and only of the signed-in owner's replica (another account's replica and native draft
survive a discard or deletion made in another session).
A durable owner marker (`ReplicaOwnershipStore`), written before any replica file,
keeps the classic and live writers off a native-owned document even after its draft
is gone; the open route restores it (typeable only with the switch on), and unknown ownership is read-only. The caller must author a checkpoint for the exact revision,
restore into a fresh non-colliding client, and stop writing after a disk failure.
The store does not validate Yjs semantics or perform a network request.

`PendingDraftStore` now preserves every distinct unreadable blob before a write
reuses the live key. Its hold survives writes/relaunches; explicit recovery retries
all blobs, merges without replacing newer live drafts, and writes before clearing
the hold. `DocumentSaveCoordinator.recoverQuarantinedDrafts()` rehydrates conflict
stamps; Profile offers it while the hold is in force.
`PendingDraft` now has an optional replica reference; the save component checkpoint
below describes its reconstruction audit. Production open/reconnect wiring and typing
activation are described under "PR02 activation (slice B)" below; migration remains.
See [offline-and-sync.md](offline-and-sync.md).

**PR02a typing component checkpoint.** Native sessions can explicitly install a
`NativeInputCoordinator` with a durable-update callback; since slice B the
production open route invokes it behind the switch. The delegate rejects UIKit's default mutation
and sends a command ID, base revision and block-relative UTF-16 replacement to the
engine. Before mutation, the engine validates the canonical indexed simple-text
target, readable fidelity and character boundaries. After the writer returns its
incremental update, patch delivery stays held until the persistence callback succeeds.
The surface applies each stamped command emission once; it still applies untagged
local patches and every authoritative `.other` rebuild. This avoids provisional
storage and double-application altogether. Both target resolution and settled
reprojection use the engine index. No full projection/snapshot encoding occurs per
key; tests bound touched-entry, projection and incremental-byte counts on 5,000 blocks.

Unsupported/opaque/scrubbed blocks, object characters and invalid UTF-16 boundaries
are refused before transactions; ranges across separators and newline input became
range commands in PR04b (below). Marked text (IME) is
handled by the PR03 composition session below; a composition this editor cannot
support keeps the preserved read-only refusal. Undo arrived with PR07b (below). A failed mutation or
append freezes the unsafe replica and retains any returned unconfirmed update in memory;
the accepted display and earlier durable journal remain intact.
The isolated native host's `--native-typing` fixture enables this component against
disposable journal files; a UI test exercises keyboard input and a Return split.
Production launch arguments and default routing remain unchanged.

**PR02a save and restore component checkpoint.** `ReplicaSaveAdapter` captures
verified journal bytes for `DocumentSaveCoordinator.enqueueReplica`. The coordinator
reuses its existing save slots, enqueue holds, conflict/title logic, error states
and background lifetime. A native request verifies the same server, Docs 6 org and
current account, then uses the existing collaboration-ydoc PATCH directly. It never
invokes the legacy live-snapshot fallback or a Markdown encoder/diff. Only a fully
confirmed captured body batch is durably acknowledged; title follows, with the
same half-land contract as classic saves. Newer outbox revisions keep honest
pending state and their draft even when their Markdown shadow did not change.

The optional draft reference names scope, raw format, generation, revision and a
canonical shadow digest. Existing Markdown drafts cannot be adopted implicitly;
compatibility writers cannot replace a raw-owned draft. All nine coordinator draft
constructions were audited: conflict/title/finish rewrites preserve provenance;
create/migration and attachment rewrites are held when raw provenance exists.
`runSyncPass` keeps A5's live-replica skip, including post-await rechecks. It replays
matching raw references through the native path, preserves raw drafts on 403/404
and uses the existing conflict/title decisions without a Markdown overwrite.

Offline restoration is available as a component API: `NativeEditorSession.restore`
replays raw checkpoint and journal, checks for unresolved dependencies, selects a
new non-colliding author client and restores the durable revision. Reconnect bytes
can merge into this same owner through a remote journal/delivery barrier. Even an
idempotent remote update advances the matching journal/engine revision and never
enters the local outbox. Failed remote persistence freezes writes before publishing
the changed display. A draft reference older than the journal
is re-stamped from the current raw revision during replay; an incompatible one is
refused, and a first capture projects its shadow from raw rather than trusting the
caller. A durable session freezes on any unjournaled transaction (with the
storage-failed notice) so the engine revision cannot drift from the manifest.
Backspace at a block start is structural (PR04a, below); at the document end it is
refused with a notice. Permanent migration/rollback ownership
and a total shadow for opaque documents remain open; production activation is below.

**PR02 activation (slice B).** With the default-off switch on, `NativeEditorOpen`
enables durable typing only for a signed-in user whose document metadata grants
`abilities.update`, on a Docs 6 server, for a document that is not a pending create
or delete, has no classic draft or queued save, has no live owner (A5's
`isLiveReplicaHeld`) and projects fully (`NativeEditorSession.canType`: fully
modeled with a Markdown shadow). An owned replica is restored offline-first, then
the fetched raw state is integrated into the same durable owner; a converted
response is never installed. An unowned eligible document is seeded into a new
replica from the fetched raw state (`ReplicaStore.create` writes the marker first)
and restored. Everything else keeps PR01's in-memory read-only view and never gains a
marker. Each persisted command schedules `NativeReplicaSaveScheduler`, which uses the
classic autosave cadence (trailing interval, 30 s cap) and hands the verified outbox
to `enqueueReplica` with the cached server title/baseline. Close and backgrounding
flush it; reopening a replica whose outbox has no draft (a process that ended inside
the debounce) schedules it. The native view reuses `SaveStatusIndicator`: debounced
journal bytes show "Saved on this device", then the coordinator's real state. A
refused capture freezes authoring and reports `.failed`. Reconnect integrates the
fetched state again. The sign-in guard reuses `SessionStore.signInGeneration`
(threaded to `EditorView`, which closes and reopens a native route on change) plus
the remembered signed-in user, rechecked after every await; `enqueueReplica` and
the sender already refuse another account. Both login flows hand the confirmed id to
`signIn`, which remembers it before the generation moves, and a flush while the
account is unknown keeps the save pending ("Saved on this device") for the reopen.
Sign-out bumps the generation too. An unparseable confirmation id signs in with the
identity unknown. `/users/me/` writers
drop answers from before the session changed hands (`SignedInUserStore.epoch`), and
close cancels the reopen and reconnect tasks. A marker without a replica is cleared,
with the switch on, only when no manifest, quarantine, draft or queued save exists,
and the unowned route then re-seeds it. Profile's recovery row also rebuilds
corrupt or lost marker data from the scoped manifests on disk and native drafts
(`DocumentSaveCoordinator.repairReplicaOwnership`); it writes nothing while a folder
cannot be read or two scopes claim a document with no draft or single outbox to
choose by; the alert can then set the unreadable folders aside (bytes kept in
`ReplicaDraftsSetAside`, never read) and repair again. A native draft owns its document
even without a marker entry. Native live content has its own socket (PR09a, below),
and a native session never takes the live write path. The isolated host's
`--native-open` fixture runs the real `EditorView` route offline over an owned
replica; its UI test types, relaunches and finds the text restored.

**PR03 IME composition and provisional recovery.** `NativeCompositionSession` ships
marked-text input through the engine for one block. `setMarkedText` and
`setAttributedMarkedText` (the system Japanese/Chinese keyboards' entry point) in a
typeable block capture both replacement endpoints as a `RelativeEditorRange` before UIKit
owns the marked range (an insertion at the caret, or a selected-text replacement inside
one block), then let UIKit own the provisional range in storage. Provisional text never
enters Yjs. A composing keyboard first asks the text view's delegate about the raw
keystroke; for a `ja`/`zh`/`yue`/`ko` input mode a one-character insertion at the
selection proceeds to the overridden marking/insertion entry points instead of becoming
a Latin command, and `textViewDidChange` restores the projection if UIKit ever writes
storage behind the command path. While text is marked the whole text view is frozen
(`NativeTextSurface.setCompositionDeferred(true)`): remote patches still integrate into
the replica (the engine defers the composing block), but the surface buffers every
patch, defers theme/width restyles, and offset-based commands and selection publication
are suspended, because document-wide UIKit offsets are stale until reconciliation.
Commit (`unmarkText`, writing what UIKit displays, or `insertText` replacing the marked
text) resolves the anchors and writes the string once as one durable `NativeEditCommand`
through `DocumentEngine.compositionCommitted(text:commandID:persist:)`
(journal-before-publication, the same `ReplicaStore.append` path as typing), then delivers
one `.other` rebuild. Reconciliation replaces only the provisional block's storage slice,
then applies the buffered patches and any deferred restyle. A target deleted or replaced
during the composition returns `.orphaned`: nothing is written, and a commit is never
redirected into a new text under the same block id. Cancel (empty marked text) writes
nothing, reconciles and returns the caret to the composition start; focus loss that never
reached `unmarkText` also writes nothing but keeps the text for recovery. A multi-block
selection or an opaque/placeholder target keeps the preserved read-only refusal
(`native_editor_marked_unavailable`). Provisional text is persisted beside the journal
for explicit recovery (see `docs/offline-and-sync.md`); the view offers orphaned and
interrupted text with Insert at cursor, Copy and Discard, never inserting it by itself.

**PR04a Return and boundary Backspace.** Return at a caret and Backspace at a block
start are one `NativeEditCommand` each (`.split(offset:newID:)`, `.join`) through
`DocumentEngine.applyStructural(_:persist:)`: the same journal-before-publication
barrier, stamped echo and unjournaled-transaction exemption as typing. The keyboard
choices BlockNote 0.56 makes before its block commands are made here too: Return
splits through the writer's `splitBlock` (a heading's new block is a paragraph, a list
item's the same kind, default props, the new id minted once by the coordinator); Return
in an empty list item resets it to a paragraph in place, so no id is minted into the
model; Backspace at a heading or list item start resets it to a paragraph; only a
paragraph joins the block above through `joinBlocks`. The caret goes to the start of
the lower block (the old id at offset 0 of non-empty text, where the writer inserts the
empty block above) or the join point. Opaque, placeholder, code and inline-node
blocks (and, since PR06a, an unreadable or locked child a split or join would move) are refused before mutation: Return with a notice, Backspace as a quiet no-op,
as is Backspace at the first paragraph. `NativeTextView.insertText` routes key-input
Return once, and the delegate covers UIKit paths that ask it. The software keyboard
deletes at a block start by replacing the separator before the caret rather than calling
`deleteBackward`; the command path treats that exact shape as the same Backspace. With text marked, Return
commits the composition and never splits it. Patches reconcile slices (`.text`,
`.insert`, `.remove`), never the whole storage, so the scroll offset holds. Quote blocks
are not writer-supported and stay refused, like typing in them.

**PR04b Selection and structural range input.** A replacement over a document range
that may span blocks, or text containing a line break, is one `NativeEditCommand`
(`.range(NativeRangeCommand)`: the first block's start offset, the end block and offset,
plain replacement text and the coordinator-minted ids for the blocks its newlines create)
through the same `applyStructural` barrier. The engine validates every block from the
first to the last before arming: an opaque block, a placeholder, code, inline nodes, a
toggle (PR06b) or a block outside the first block's group (PR06a) anywhere refuses the whole command with
`native_editor_range_unavailable` and no write, never the freeze. The writer's
`replaceRange` then deletes the span, joins the last block's tail onto the last line and
inserts the text in one grouped transaction, which is ProseMirror's replace over a
selection: the first block keeps its id, type and props; each later line is a new block
(a list item's kind, else a paragraph, default props, as Return makes); the blocks
between and the end block are removed. A range from a paragraph's end to the next start
writes exactly BlockNote's merge, and a pasted line break exactly its Enter (checked
against the node captures). `NativeInputCoordinator.replace` sends anything that is not
one block's text without a line break here, so typing, Backspace or the delete key over a
selection, Return over a selection, dictation's final result, UITextInput `replace` and
paste each arrive once. Every line break (CRLF, CR, U+2028, U+2029, NEL) becomes "\n".
The end-of-document boundary can end a range (the last block's end) but is never a caret.

`NativeSelectionCoordinator` publishes UIKit's selection on every change (not while a
patch edits storage or text is marked) as directed engine relative positions: UIKit's
range is unordered, so direction comes from which end moved, as hardware Shift-arrows
move it. A non-empty range keeps a peer's insertion at either boundary outside it. After
every patch that is not the editor's own command echo, and only when the range moved
(setting `selectedRange` ends a handle drag; UIKit does not shift it for an edit before
the selection), it restores the view from
`currentSelectionEndpoints()`: a vanished endpoint collapses the selection to the one
that survived, and with both gone the caret moves to the start of the block after the
head's old block (else the end of the one before it). A peer's split resolves an end in
the moved text to the split point. An endpoint in a placeholder is not tracked. A
command's storage edit and caret, and a patch's restored selection, reach the keyboard
as one text change (`inputDelegate` `textWillChange`/`textDidChange`): UIKit accepts a
pending autocorrection or inline prediction, at the range it last saw, when the caret is
set outside one.
`NativeClipboard` and the view's `copy:`/`cut:`/`paste:`/`pasteAndMatchStyle:` overrides
give a plain-text clipboard: copy is one line per block (placeholders contribute nothing,
and nothing copyable or marked text leaves the pasteboard alone);
cut is copy plus one range delete, leaving the pasteboard unchanged when refused; paste
takes only the pasteboard's plain string, so rich content contributes its text, and
refuses whole a paste over 200,000 UTF-16 units or 2,000 lines. Since PR06d a copy of
whole subtrees also carries a lossless payload a paste at a caret prefers (below). IME over
a multi-block selection keeps PR03's refusal.

**PR05a Inline marks, links and colours.** Marks are Yjs format attributes beside the
text, in BlockNote 0.56's vocabulary (`{}` for bold, italic, underline, strike and code;
`{"stringValue":"<name>"}` for text and background colour; `{"href":…}` for a link), never
characters in it. The engine reads the replica with `YBlockProjection`'s `nativeMarks`
option, which keeps every stored mark — including ones this build does not know — in the
snapshots, so a rebuild never normalises one away and no mark makes a document read-only;
the classic projection (live path, Markdown shadow, save preservation) still scrubs them.
A formatting action is one durable `.marks(NativeMarkCommand)` through `applyStructural`,
validated over every block it touches before arming, and written as one grouped
`formatRange` per block that changes only the named keys; the patch is `.text` deltas that
rewrite each range with its own text (one per uniform run), so the text never changes.
Toggling follows BlockNote: a selection whose every character has the mark turns it off,
anything else (a partial or mixed run) turns it on everywhere; at a caret the toggle only
changes what the next typed text carries. Typing uses ProseMirror's marks at the caret
(links and unknown marks do not grow from their edges) and writes them explicitly only
when Yjs's own inheritance would differ. Links use the classic editor's sheet and URL
rules. Colours are dynamic colours keyed by BlockNote's names, so a theme change rewrites
neither storage nor the replica.

**PR05b Block presentation and controls.** Block chrome (bullets, numbers, quote bar,
callout box and emoji, code panel, divider and the distinct dashed page break) is drawn by
a custom TextKit 2 layout fragment from plain attributes of the projection, in theme colours
resolved at draw time, so neither a theme change nor Dynamic Type writes to the replica and
no marker character exists in storage or Yjs. Checkboxes and the code-language menu are real
buttons laid over the visible fragments; headings carry their level for VoiceOver and a
Headings rotor walks them. Each prop edit (checked, start, language, emoji, level) is its own
validated `.props` command, BlockNote's same-type `updateBlock`, never a type change; a
slash-menu choice is one `.blockType` command that removes only the "/query" token before the
caret (the paragraph's other text stays) and changes the type in one transaction. Code keeps its line breaks as source: Return and multi-line paste stay in
the block, displayed as U+2028 so the block is one TextKit paragraph.

**PR06a Tree projection, nested prose and indent/outdent.** `NativeBlockProjection` is the
native read: the whole block tree in preorder, each block read exactly as the classic
per-block projection reads it (`projectBlock(…, nestedChildren: true)`; the classic
default keeps a block with children opaque for its own callers) plus `depth`, parent and a
`NativeBlockHandle` (per-engine generation, integrated container id, string id as
metadata). A missing or repeated id, or nesting past depth 64, makes that block an opaque
placeholder standing for its subtree; opacity never spreads to an unknown block's
children. `BlockIndex` indexes the same tree in preorder, so nested text keeps the `.text`
fast path and nested attributes `.props`; a group membership or container child change
rebuilds the index and diffs the preorder into `.remove`, anchored `.insert`s and
`.replaceBlock` for a kept block whose container, depth or parent changed. Tab/Shift-Tab and
the bar's Indent/Outdent are BlockNote's `nestBlock`/`unnestBlock` for one block, one
validated `applyStructural` command each: the writer (`BlockNoteTreeCommands`) copies every
moved block losslessly and deletes the original in one transaction (Yjs cannot reparent an
integrated node), so ids survive but identity does not, and a peer's concurrent edit inside
a moved block is lost as it is in BlockNote. Every moved block must be readable and unlocked
and the deepest stays within 16 levels. Return in an empty nested block outdents it (an
empty list item first becomes a paragraph); Backspace at a nested paragraph's start
merges it into the block above (a first child into its parent), as BlockNote does, and
outdents it only when that merge cannot happen. Each level indents one scaled list gutter and numbers per sibling run. The save
shadow indents list nesting (`NativeBlockProjection.markdownShadow`), so a nested list stays
typeable and savable.

**PR06b Toggles and local folding.** Under the native flag the projection models
BlockNote 0.56's `toggleListItem` and a heading with `isToggleable: true` (the classic
projection keeps both opaque, so classic callers, preservation and golden bytes are
unchanged): the title is the block's text, the children its nested group, and a
disclosure button in the gutter (a real `UIButton` with an expanded/collapsed value)
folds it. **Folding is a presentation layer over the projection, never data.**
`NativeTextSurface` keeps the expanded toggle ids in memory for the open document
(collapsed by default, as BlockNote) and which positions they hide. Storage, the block
list and the range index always hold the whole projection, hidden children included;
the TextKit 2 content-storage delegate simply does not enumerate a hidden paragraph,
so it is neither laid out nor drawn. That is how the storage/projection invariant holds
while children are hidden: every patch, a peer's edit inside folded children included,
applies to storage exactly as when unfolded, and unfolding is only a layout
invalidation that shows the updated text. A fold writes no Yjs and no storage. A toggle
that gains a child opens. VoiceOver reads the text without folded content
(`accessibilityValue`), the Headings rotor skips it and folded blocks have no controls.
Hidden content is never edited by a visible command: a range or mark command touching a
folded toggle's children is refused before arming, no command targets a hidden block, a
caret placed in folded content moves past it, and a Backspace merge into a folded
toggle's hidden last descendant unfolds it first. Enter and Backspace follow the
installed 0.56 keyboard rules, with the open state carried in the split command (an
open toggle's Enter starts its children, a closed one splits and keeps them, an empty
toggle resets); the slash menu offers Toggle heading and Toggle list. A toggle has no
Markdown shadow yet, so production keeps such a document read-only, like a callout.

**PR06e Bounded previews and the S2 attachment sizing.** Every block the native editor
does not author yet (image, video, audio, file, PDF, table, column list, math, diagram,
any unknown node and any opaque prose) is **one attachment character** in storage, a
`NativeBlockAttachment` whose view is a read-only preview card. Authoring them is
PR11–PR14; until then they stay preserved and read-only (range commands touching one are
refused, as before). The preview data is a bounded value read from the replica with the
block (`NativeBlockPreview`, in `NativeBlockProjection.projectBlock`, so a peer's edit
inside a table arrives as the block's existing `.replaceBlock`): the first 6 × 4 table
cells and the full size, the first three lines of up to four columns, the first four
source lines of math or a diagram (no renderer, an owner decision), media name, kind and
URL, or a labelled preserved card with a line of text. Every string is capped, so a
10,000-row table costs a walk of its row list, never its text. **Bounded realisation:**
TextKit 2 asks for an attachment's view provider only for laid-out fragments, so with
5,000 blocks and 200 previews only the dozen around the viewport exist; a preview view is
built with plain UIKit, never SwiftUI. **Sizing (the S2 fix, attachment paragraphs
only):** the projection computes each card's size from the usable text width and Dynamic
Type (an image: BlockNote `previewWidth`, capped at the width, over the image loader's
remembered aspect ratio, else the classic 160 pt placeholder; bounded 44–640 pt), the
view reports exactly that as its intrinsic size (the provider tracks view bounds), and the
paragraph's minimum and maximum line height are that height plus the separator font's
descent, so TextKit 2's estimate for an unlaid-out attachment paragraph is already its
final height. Text lines are not pinned. The attachment's own `bounds` stay zero: setting
them makes TextKit 2 draw a file icon and never ask for a provider (S1 finding 3, checked
again here; the S2 spike's bounds were part of what it measured, not what ships). **A
download changes nothing in layout:** the image fills the reserved box (aspect fit), and
its ratio applies at the next restyle: a width change (rotation, split view; only the
attachment slices are replaced, in place), a Dynamic Type change or the next open. Images
go through the app's `ImageLoader` (`NativeEditorView` reads it from the environment and
passes the offline flag and the document's server origin; a loader of another server's
session shows and requests nothing, as the classic `matchesSession`): the same-origin rule, "External image · tap to load", consent,
the disk cache and the offline state are the loader's, unchanged. VoiceOver reads each
card as one element ("Image: alt", "Video: clip.mp4", "Table, 3 by 4", "Columns, 2",
"Math"), and the text view's value reads the label in place of the attachment character.
Opening, scrolling, a download and a restyle write no Yjs.

**PR07a Undo core.** `Core/Yjs/YUndoManager` transliterates yjs 13.6.33's `UndoManager`
with `redoItem`, `followRedone`, `keepItem` and `isParentOf`. It listens through
`YDoc`'s afterTransaction observer list (the engine keeps the single
`afterTransaction` slot), captures tracked origins over a scope of types, merges
captures inside `captureTimeout`, and marks deletions it can restore `keep`, which
gc already skips; `clear()` releases them and `destroy()`, as in yjs, only
unsubscribes. Undo and redo are local transactions whose origin is the manager
(`YTransactionOrigin.undoManager`), so they reach the store and encoder like any
other local edit. `YUndoManagerOracleTests` replays node yjs captures (peer edits
kept, deletes, formats, nested BlockNote blocks, map conflicts, a remotely deleted
parent) and asserts byte-identical state after every step.

**PR07b Native undo.** Each native typing session owns one `NativeUndoManager`: a
`YUndoManager` over the `document-store` fragment that tracks only the engine's
`.localUser` origin, so peers, server fetches and derived format cleanup are never
undone, and that is destroyed with the session (history is never persisted; at most
100 steps, the oldest trimmed with their `keep` marks released). Undo and redo are
commands like any other: `DocumentEngine.applyHistoryStep` arms a `.undo`/`.redo`
`NativeEditCommand`, runs the step, encodes its single transaction and journals it
before the surface sees the `.other` patch, so a step is saved through the outbox and
replayed on reopen like typing. The native editor has no live socket yet, so the
outbox is the only way an undo reaches peers, once; the collaboration manager's
replica (which broadcasts only nil-origin cleanup) is not involved. Typing groups by
the 500 ms capture window while it continues from where typing left the caret;
structural commands, a composition commit and undo/redo are explicit boundaries.
Every step stores the relative selection from before it and restores it when popped,
as y-prosemirror does. `NativeTextView` exposes an `UndoManager` subclass whose undo,
redo and enablement route to this history, so the Edit menu, shake, ⌘Z/⇧⌘Z and the
keyboard's undo all use it and UIKit's own text history never runs. Undo is refused
while text is marked, read-only or after a write failure.

**PR08a Sendable boundary, confined engine, serialized journal.** Preparation for moving
the native replica onto an actor (PR08b), with no behaviour change. The engine's value
outputs (`BlockPatch` and its parts, `EditorSelection`, `CompositionCommitResult`, the
projected and native block snapshots) are compiler-checked `Sendable`. `DocumentEngine`
loses `@MainActor` and is confined to whichever domain creates it with its replica; so is
`ReplicaHistory`, the Yjs half of the native undo history split out of the main-actor
`NativeUndoManager` (which keeps UIKit's undo manager and checkpoint notifications).
Paste-payload decoding moves from the input coordinator into the engine: `.insertSubtrees`
carries only the payload, and `prepareBlockCommand` bounds and validates it, mints the ids
and refuses an oversized one with `.payloadTooLarge` (the too-large notice). `ReplicaStore`
serializes every read/modify/switch with one `Mutex` shared by all instances, so its journal
entry points are callable off main, while the operations that touch the main-actor ownership
marker stay on main and take the same lock; callers and their order are unchanged.

**PR08b The replica off the main actor: one ordered mailbox, optimistic typing, barriers.**
`actor DocumentReplicaSession` owns the native replica, its engine, the shared undo history
and the journal writes for its scope; the main-actor `NativeEditorSession` keeps only the
view (no graph: a grep test enforces it) and talks to it through one bounded, ordered
mailbox. Each message is handled in one synchronous session turn, engine call, journal
append and delivery yield with no await between them, and each surface reads its
deliveries in order. The owner chose option A for input: same-block typing is shown at
once and journaled a few milliseconds later, in order; every other command is a barrier
shown when its result arrives, with keys typed meanwhile held and replayed. This
redefines journal before publication: publication is the canonical advance, save
scheduling or a network send, all of which still follow the append; a predicted
keystroke on screen is provisional UI, like marked text. A failed or refused append
rolls the display back to canonical, stops authoring and keeps the dropped text as a
recovery entry. A change the surface had not seen when it predicted (a server
integration) is rebased with the same `TextDelta.rebase` on both sides, so the display
and the journal agree; when it cannot be rebased the surface's epoch is invalidated and
its pending keys become a recovery entry, and a barrier that met such a change is
retried once. IME begin is posted and commit is a barrier; the history is one per replica
session with grouping decided on the main actor; block-menu availability and copy payloads
are asked of the session asynchronously. Multi-window stays off; the per-scope registry
and fan-out are PR08c (below), the native live socket PR09a. AGENTS.md has the
operational detail and the bounds.

**PR08c One replica session per scope, fanned out, with bounded delivery.**
`NativeSessionRegistry`, owned by the signed-in container in `RootView` and shared through
the environment, keeps one `DocumentReplicaSession` per replica scope. Each open leases a
surface on it; the replica closes after its last surface, and a scope's next replica is
restored only after the previous one closed, so two sessions never journal into one scope.
The scope's journal and save scheduler are shared by its surfaces. The scene going to the
background drains every replica and hands its debounced save over; a sign-out or any sign-in
change closes them all. Every surface sees every change and only its own results; the one
engine selection and the one composition belong to the surface that set them. Each surface
may have 256 deliveries waiting, in its stream or behind marked text; past that it gets one
reset to the canonical state under a new epoch, keeps only the answers of what came between,
and holds its keys until the reset, so nothing typed is lost. Multi-window stays off.

**PR09a Native live content over the same replica.** A `NativeCollaborationBinding` per
replica scope, kept by the registry, joins the document's room when the native switch, the
Live collaboration preference, a Docs 6 server's advertised socket and the document's update
ability all hold; the current editor's live switch (A5) is not consulted. The collaboration
manager only dials the socket. Inbound updates enter the replica through its mailbox and are
journaled before they are shown; an update that builds on structs the replica lacks is
refused untouched and fetched again with a fresh SyncStep1, and the number waiting is bounded
so typing always finds room. Outbound is only what was journaled: the journal publishes each
local update after its append, and the replica answers a peer's state request in mailbox
order into the same stream. The HTTP save keeps sending the same outbox and keeps owning
acknowledgment; the server takes both idempotently. Cursors are PR10.

**PR09b Reconnect, background and mid-session changes.** A dropped socket dials again after
an exponential backoff (1 s doubling to 30 s, counted again after a 30-second stable
connection, a foreground or the network's return). The collaboration manager tells native
sockets when the app goes to the background (they close) and comes back (they dial at once).
A server close for a permission change makes the editor ask for the document's abilities
again; a reader answer makes every view of the document read-only and closes the socket.
Turning Live collaboration off while a document is open closes its socket and leaves HTTP
saving as it was; turning it on joins again. Redials caused by refused updates are bounded in
a row and per open. HTTP stays the only acknowledgment, so an update a server already applied
is simply taken again.

**PR06d Subtree commands and the lossless clipboard.** A block menu (the formatting
bar's first button, a Block submenu in the long-press edit menu, and VoiceOver custom
actions on the text view) acts on the caret's block and its whole subtree: Move up, Move
down, Outdent, Indent, Insert block above/below, Duplicate, Copy block and Delete block.
Each is one validated `applyStructural` command (Copy only writes the pasteboard); the
menu disables what the engine's own dry run (`canApplyStructural`) would refuse. Moves
are BlockNote 0.56's `moveBlocksUp`/`moveBlocksDown` (past a sibling with children into
its nearest child, past a group's end out beside the parent, an emptied group removed),
checked against node captures, and like indent they copy every raw value and delete the
original: ids survive, identity does not, and a peer's concurrent edit inside a moved
block is lost. A folded toggle moves with its hidden children and stays folded. Opaque
content never moves or duplicates; it can be copied or deleted only when its subtree has
a proven lossless representation (plain BlockNote XML of known node types), otherwise
those commands are disabled too. The **transfer payload** is the copied subtrees as the
Yjs update of a scratch document (`BlockNoteSubtreePayload`, private pasteboard type
beside plain text), so it is lossless by construction. A copy of whole sibling subtrees,
or Copy block, writes it; a paste at a caret prefers it, inserting the subtrees after the
caret's block (replacing an empty paragraph) with fresh ids in one command, and over a
selection pastes the plain text. The pasteboard is untrusted: the payload is bounded
(2 MiB, 2,000 blocks, 100,000 decoded structs counted before integration, 16 levels where
it lands) and refused whole when it holds anything a BlockNote document cannot, before any
write; a pasted link with an href the editor would not write, or an unknown mark carrying a
URL, loses the mark, and a media URL that is not http(s) refuses the paste. Links in the native
view are tappable only for http(s), mailto and tel, whoever wrote them. Drag to reorder is not built yet.

**Selection.** `setSelection(EditorSelection?)` captures directed anchor/head
endpoints as `YRelativePosition`s. Each `EditorPosition` holds a block id,
block-relative UTF-16 offset, and affinity (`assoc`, default -1). Negative
affinity sticks to the character before the boundary, including when a peer
appends at end-of-text; non-negative affinity follows the character after it.
`currentSelection()` resolves both endpoints after any transaction, against the
replica even when composition intentionally freezes the surface. Capture rejects
invalid offsets (including a boundary inside a surrogate pair) and
non-canonical/opaque/multi-text blocks without changing the previous selection.
A simple, projectable text-capable element with no countable children accepts
offset 0 without creating an XmlText. Its capture names the element at child
index 0: left affinity stays at text offset 0 when a peer creates text, while
non-negative affinity follows the end of its sole XmlText. While still empty,
both resolve to 0. The writer creates the text on the first non-empty commit.
Resolution checks the original text or empty-element identity against the
current block index: deletion, type replacement under the same block id, or a
non-addressable shape returns nil. Only locally captured positions enter this
path; no arbitrary peer root names are resolved.

**Composition.** `compositionBegan(blockID:at:assoc:)` captures an insertion
anchor (the selection head if `at` is omitted); `compositionBegan(blockID:replacing:)`
captures both endpoints of a same-block replacement range (the native IME path),
and both signal surface deferral. `CompositionQueue` invalidates that block's
patches from every origin while updates continue integrating into the replica
(remote data is accepted during a composition; the queue defers only the composing
block). Independent block patches still flow. A list operation removing/reinserting the composing block, or any `.reset`,
defers the entire list and all subsequent patches because later transitions may
depend on the held structure. No stale deltas are replayed or retained.
`compositionCommitted(text:)` inserts the composed string at the resolved anchor
through `BlockNoteWriter` in one `.localUser` transaction, returns its update for
broadcast, and captures the collapsed selection after the inserted UTF-16 text
inside that same transaction, before observers or cleanup can edit it. The durable
`compositionCommitted(text:commandID:persist:)` holds delivery until `persist` journals
the command's bytes and returns `.committed(Data)` or `.orphaned` (the target was deleted or
replaced: no write, never redirected into a new text under the same block id). The
commit stamps `nativeCommand`, so its own echo is deduplicated and the durable
owner's unjournaled-transaction guard does not fire. Capture
errors propagate through the writer error/rebuild path; no failed capture is
silently replaced by nil (transactions have no rollback). Later edits remap the
captured caret, and later deletion/replacement invalidates it normally. The
write's own delta is discarded too. Commit and `compositionCancelled()` then
deliver one `.replaceBlock` projected from the replica (a fresh whole-list `.reset` for the
structural fallback) before clearing deferral. Cancel writes nothing and returns the
caret to the resolved start of the replaced span. A deleted,
replaced or non-addressable original text drops the commit write, returns the
empty update, and still rebuilds. Rebuild and deferral completion share the
serialized delivery queue so surface callbacks can transact without reentrant
patch delivery. Commit/cancel ends the logical composition immediately, allowing
`compositionBegan` from a relative selection inside the same `applyPatch` callback. Deferral stays
continuous until the newest composition's rebuild completes; generation-tagged
completion events prevent an older completion from ending a newer composition.
`compositionBegan`, `compositionCommitted`, and `compositionCancelled` require
`doc.transaction == nil` and an empty `doc.transactionCleanups` list. Otherwise
they throw `.insideTransaction` before touching composition, replica or surface.
This includes observer hooks, where the open transaction is nil but cleanup is
still pending. Calls from `applyPatch` remain allowed: the list is cleared
before `afterAllTransactions` invokes the engine's delivery hook.
All input offsets use replica coordinates. A frozen surface's offsets cannot be
submitted as if they referred to the replica, where peer edits already landed.
`setSelection` rejects either endpoint in a deferred block with `.composingBlock`;
`replaceText`, `formatRange`, `splitBlock`, `joinBlocks`, and `setBlockType` reject
that block too, with joins checking the source and destination's outer blocks.
Rejection leaves the replica, selection, patches and deferral history unchanged.
Locks persist through pending rebuild delivery until the final
`setCompositionDeferred(false)` signal; chained restarts retain earlier locks.
If `CompositionQueue.requiresReset` is set, **the whole list is frozen**: the same
`.composingBlock` error rejects input and selection endpoints for every block,
including an explicit `compositionBegan(..., at:)` on another block. The engine
latches that global lock beyond the queue's logical end, through pending reset
delivery and chained restarts, until the final deferral-complete signal. Normal
per-block deferral continues to allow input on independent blocks. Selection
queries and `setSelection(nil)` remain available in either mode.
An explicit `compositionBegan(..., at:)` into a locked block is rejected even
after logical commit/cancel, since its queued rebuild may not have reached the
surface. A restart without `at:` uses the existing relative selection and remains
safe even if it discards the previous composing-block rebuild. Queries and
`setSelection(nil)` remain allowed during deferral.
Every composition rebuild, including a successful commit's, has origin `.other`
and must always be applied by optimistic surfaces. Only the write transaction is
`.localUser`: tagging its catch-up snapshot that way would lose discarded peer
changes when a surface skips the local edit it already displayed.
Detach clears selection/deferral and drops deferred work without a rebuild;
later intents throw `.detached`. A deferred surface intentionally differs
from projection until commit/cancel restores equality. The engine contract is
proven headlessly; the native IME surface is the PR03 composition session above.

**Buffering.** `YDoc.afterTransaction` runs in the observer phase, where a text
delta is valid but the store is still pre-gc/pre-merge, so the engine only
buffers there. Delivery happens at `YDoc.afterAllTransactions` — yjs's
`'afterAllTransactions'`, fired once the outermost cleanup is done and
`doc.transaction` is nil. A surface that opens a transaction from `applyPatch`
is queued and drained by the same `transact` call.

**Local intents emit patches too.** The engine does not suppress the patch for
the edit it just made, because the same transaction may also carry a format
cleanup or a split's new block. A patch describes a transition from the
pre-transaction state, so a surface that already applied the keystroke itself
must reconcile. The rule is the patch's `origin`, not content inspection: a
displayed `"a"` plus a delete of `0..<1` cannot distinguish "already applied"
from "not yet applied". A surface that applied a local intent optimistically
skips `.localUser` patches for that edit (phase 2 may refine this with command
ids) and applies every `.remote` and `.other` patch; `.props`, `.replaceBlock`
and `.reset` assign and are idempotent either way, and `.insert`/`.remove` skip
ids already present/absent. `HeadlessSurface` never mutates on its own and
therefore applies every patch and always equals the projection. There is no
optimistic overlay.

**`.text` has exactly one shape.** A block at any depth gets `.text` only when its
container holds its content element (and at most one nested group), that element
has exactly one child — an `XmlText` with
no inline nodes, so the projection's runs *are* that text — and the only change
to it in this transaction is that text. Everything else touched in a block
escalates to `.replaceBlock` of that block, rebuilt from its projection: several
`XmlText` children (no sibling-offset math), a container replaced in place or
moved under the same id (the index tracks the container `YItem`, depth and
parent, not just the id), or props and text changed together. `.text` and `.props` also need the block to have projected
as-is before the transaction and after it (readable props, a text of strings and
marks with readable links; `BlockIndex.Entry.isProjectable`), because an
opaque block's surface copy came from a `.replaceBlock`. Any
group's membership change produces `.insert`/`.remove` from the preorder diff; a
reorder is a `.remove` + `.insert` of the moved span. A change to the fragment root, or a
root group that is not the one the index recorded, a container's `id` changed
in place, or any transaction while `BlockIndex.isCanonical` is false, is a
`.reset` of the projected document.
`TextDelta.marks` is never `nil` from the builder: `nil`
means *inherit* (the surface's local-keystroke form), and the builder always
sends the complete set, including `[]`, in the projection's format-item order.

**Cost.** Classification reads `transaction.changed` (direct child changes), so
a keystroke visits one `XmlText`, folds that one text to check its deltas
against the index's cached runs (`TextDelta.apply`; the index keeps one run
list per simple block) and again when the entry refreshes, projects no block, and the emit loop
iterates only the touched ids ordered by the index's position map — never
`index.order`. Text and prop changes are O(touched blocks). A tree change (any
group's membership or a container's children: split/join/move) rebuilds the index —
O(document), reading each block's text for `isProjectable` — and projects only the
touched blocks, one at a time (`NativeBlockProjection.projectBlock`); any other change
only refreshes its own entry. A replica the id-keyed index cannot mirror (`BlockIndex.isCanonical`
false: several root children, an id-less or non-container group child, a
repeated id) resets on every transaction until it is canonical again. `DocumentEnginePatchCostTests` and
`DocumentEngineNarrowedRuleTests.testTextTransactionVisitsOnlyTouchedEntries`
pin the counters and what they measure.

**Teardown.** `YDoc.onDestroy` fires at the start of `destroy()`; the engine
detaches there — hooks cleared, buffered patches dropped (even mid-delivery),
later intents throwing `DocumentEngineError.detached` — and releasing the engine
detaches it too (a plain `deinit`), so a fail-safe or suspend teardown can never leave a hook pointing at a
destroyed store.

**No UIKit in the model.** `Engine/` mentions no `NSRange`, `NSText*`, `UIView`,
`UITextView` or `UndoManager`; offsets are block-relative `Range<Int>` UTF-16
values, and `BlockNoteWriter` carries `Range<Int>` overloads so the engine never
spells `NSRange`.

### Two-way sync engine (C2a)

C1 wires the *read* side into the editor; B6 can turn an edit into bytes but has zero
runtime callers. **C2a wires the two together into a real bidirectional sync engine,
entirely inside `Core/Collaboration` (`DocumentCollaborationSession` +
`DocumentCollaborationManager`) — no editor or save-path code calls any of it yet.** It
replaces the earlier milestones' signal-only, empty-state-vector handshake with a real
one and adds the outbound write path on top of it.

- **A real handshake, in both directions.** `DocumentCollaborationSession.start()` no
  longer always sends the one-byte empty state vector for its own SyncStep1 — it calls
  the manager-supplied `initialSyncStep1()` closure, which returns
  `YStateEncoder.encodeStateVector(replica)` once a replica exists (still the empty
  vector before that), so a peer's `.step2` reply becomes an actual diff of what we
  lack, not a full-document dump. Symmetrically, the session answers a **peer's** own
  `.step1` through `onStateRequest`, which the manager wires to `stateReply(to:for:)`:
  decode the peer's state vector, `YStateEncoder.encodeStateAsUpdate(replica, since:)` a
  diff of everything they're missing, and send it back as a `.step2` frame. `stateReply`
  is deliberately **ungated on replica health** (only readers, without `abilities.update`, send no reply) — offering a subset of our own
  monotonic CRDT state is always safe, even mid-sync, so the room keeps converging
  regardless; only the save-snapshot path needs the stronger gate (below). Because an
  entry's replica survives session rebuilds, `stateReply` re-offers a reconnecting peer
  *everything accumulated so far* — including edits made while the app was suspended.
- **`initialSyncApplied` has exactly one setter.** The session's `onInitialSync` fires
  once per session, on the *first* inbound `.step2` — the reply to our own SyncStep1 —
  and only that callback (`markInitialSyncApplied`) flips the flag. An `.update` arriving
  before that reply still builds the replica and bumps `replicaVersion` (so the
  change-signal fallback keeps firing), but must leave `initialSyncApplied` false: a
  replica assembled from a partial incremental update is not the room's full state and
  is not yet safe to project, write to, or snapshot.
- **`DocumentCollaborationManager.applyLocalEdit(old:new:for:)` is the outbound write
  path.** It wraps B6's `BlockNoteWrite.applyEdit(old:new:to:)` on the manager-owned
  replica (inside that call's own local transaction), encodes only that finished
  transaction's structs and deletes with `YTransactionEncoder`, broadcasts the returned
  incremental update via the session's `broadcast(update:)`, and bumps a counter that is
  **deliberately separate from the inbound signals**: `localEditVersion`, never
  `replicaVersion`/`remoteChangeToken`. Those two are what a future editor integration
  would read as "a remote peer changed the document" — bumping them for our own edit
  would make something read-apply the keystroke we just made ourselves. This is
  local-echo suppression, and it is the load-bearing rule of the whole write path.
- **The replica also broadcasts the formatting-cleanup update it makes on its own.**
  yjs emits `'update'` for every transaction with content, including the second, local
  transaction `cleanupTransactions` opens with origin `null` when a remote update touches
  a formatted text (B4), and a provider broadcasts every update whose origin is not
  itself. `YDoc.onUpdate` mirrors that event at the yjs emit point (@3388-3392), with
  the origin and a lazy `encode` (`YTransactionEncoder.encodeUpdate(..., duringCleanup:
  true)`) so ignored origins are never encoded; the manager wires it per
  replica and sends origin-`nil` updates through the entry's session, re-reading the
  entry at fire time (it must still hold that replica, writable and not fail-safed). `.remote` is an echo and `.localUser` is already broadcast by
  `applyLocalEdit`, so neither is re-sent; a reader (`canUpdate == false`) never
  publishes; and the cleanup bumps none of `replicaVersion`/`remoteChangeToken`/
  `localEditVersion` — it is derived from an inbound update, not a new remote change or
  a local edit. A nil hook runs nothing, so every existing golden output is unchanged.
- **One health gate, shared by read and write.** `canProjectReplica` — a
  replica exists, its initial sync has landed, it carries no unintegrated
  `pendingStructs`/`pendingDs`, and it hasn't fail-safed — already gated
  `projectedReplica` (C1/B5); C2a reuses the identical predicate for `applyLocalEdit`
  (throws `CollaborationWriteError.notWritable`, mutating nothing, when it fails) and for
  `encodeSnapshotForSave(for:)` (returns `nil` instead of a snapshot); those two
  write paths also require the document's `abilities.update` (`canWriteReplica(for:)`),
  which projection does not. A
  `BlockNoteWrite.applyEdit` throw — a malformed replica — is handled exactly like an
  inbound decode/apply failure: the replica is destroyed, `replicaFailSafe` latches
  permanently (so this document's replica is never rebuilt or trusted again this
  session), and the error is rethrown, never trapped — clocks are peer/edit-influenced
  and this store must not crash on them.
- **A survivor whose content element holds an inline node is rebuilt, not spliced.**
  On the **legacy** path (`applyEditLegacy`, the Docs 6 save) `reconcileBlockLegacy`
  text-splices a changed block in place only when its content element holds exactly one
  `xmlText`; otherwise — a web document-link node (its text split around the inline
  node), or a web-created empty paragraph (y-prosemirror writes no `xmlText` for it) —
  it rebuilds the content element from the new runs. The **live** path (`applyEdit`)
  does not inherit that: an empty paragraph keeps its element and the writer creates the
  `xmlText`, and an element with several `xmlText` children but no inline node is
  spliced through `BlockNoteWriter.inline()`'s part walk. Only an element holding an
  inline node (whose run-space offsets do not map to live offsets) and the block types
  the writer does not edit (`quote`, `divider`, `image`) fall back to the legacy
  rebuild. So editing a block that holds a web document-link node here still
  **flattens that node to a plain markdown link** for every peer. `applyEdit` also
  refuses a nested `new` block on this path (`allowsNestedInserts` defaults to `false`;
  only the Docs 6 save opts in), so a nested list downgrades to classic rather than
  broadcasting a subtree.
- **`encodeSnapshotForSave(for:)`** is the other half of the eventual live-snapshot save
  path: a full `YStateEncoder.encodeStateAsUpdate(replica, since: [:])` of the document
  when `canWriteReplica(for:)` holds, `nil` otherwise ("no trustworthy snapshot"). Nothing
  calls it yet — the classic full-overwrite markdown-encode save is completely unchanged
  until C2c wires this in as its replacement source of truth.
- **Verification.** Deterministic two-peer integration tests (`LiveSyncConvergenceTests`)
  drive two real `DocumentCollaborationManager`s through a paired fake-socket relay and
  assert convergence at the **projected-document** level (never store bytes) across the
  handshake, one-way edit propagation, and concurrent edits from both peers. A
  differential-fuzz harness run once out of tree (per the zero-dependency
  rule) additionally drove roughly 25,000 seeds / 162,000 document-level comparisons
  against node yjs 13.6.31 across handshake-diff (including merged/gc'd-peer state
  vectors), broadcast/concurrent, and producer-shape lanes, with **0 divergences**; the
  harness itself was mutation-verified — a deliberately reintroduced bug in the
  diff-slicing path was confirmed to fail it before the real fix was restored.
- **Dormant only behind the flag, not behind missing callers.** At C2a, no
  `Features/Editor` or save-path code called any of this — that was the C2a boundary.
  C2b then added the save mechanism (`enqueueLiveSnapshot`/`saveLiveSnapshot`) with
  still no caller. **C2c is what closes the loop**: the editor now calls
  `applyLocalEdit` (via `LiveEditingBridge.forwardLocalEdit`) and `enqueueLiveSnapshot`
  (via `EditorViewModel.persistLiveSnapshot`) for real. Everything still runs only
  behind the default-off `schrift.liveCollaboration` flag — see "Editor wiring — the
  write path complete (C2c)".

### Live-snapshot save (C2b)

C2a produced `DocumentCollaborationManager.encodeSnapshotForSave(for:)` — a full-state
Yjs snapshot of a write-eligible replica — but nothing carried those bytes to the server.
**C2b adds the save *mechanism*: a new networking primitive and a new save-coordinator
entry point, both routed through the existing full-overwrite save pipeline so a live save
inherits every reconcile/baseline/hold invariant.** At C2b this was still dormant — no
editor or collaboration code bridged `encodeSnapshotForSave`'s bytes into it. **C2c
bridges it**: `LiveEditingBridge`'s ~60 s debounce calls `encodeSnapshotForSave` and, when
it succeeds, `EditorViewModel.persistLiveSnapshot` calls `enqueueLiveSnapshot` — see
"Editor wiring — the write path complete (C2c)" below.

- **`DocsAPIClient.saveLiveSnapshot(documentID:title:yjsUpdate:)`** mirrors
  `saveDocumentContent` exactly — two requests, the same half-land `DocsAPIError?` contract
  (throws ⇒ content unconfirmed; non-nil ⇒ content landed / title failed; nil ⇒ both landed)
  — but the content write sends the caller's snapshot **bytes verbatim** (never
  `MarkdownYjs.encode`). It routes exactly like the classic body save (`ContentSaveRoute`,
  `saveContentViaRoute`): on Docs 6 the bytes are PATCHed to yhub as `{"update": base64}` — a
  full-state Yjs update is a valid incremental update, and the bytes are already the replica's
  own state, so no GET/diff is needed — while a pre-Docs 6 server takes the legacy
  `documents/{id}/content/` PATCH tagged **`"websocket": true`**, which the docs backend uses
  to distinguish a live-collab snapshot from a REST full-overwrite. With nothing known the
  legacy route is tried first and only its `.routeNotFound` falls back, learning the org from
  config; the route is memoized once the collaboration PATCH succeeds. Docs 6 live sessions
  use the enabled y-websocket transport, and snapshot saves use this route. Its PATCH carries
  the whole snapshot and is subject to the deployment's request-size limit. With `viaWebSocket`
  false (the default) the classic content body is byte-identical to before.
- **`DocumentSaveCoordinator.enqueueLiveSnapshot(documentID:snapshot:projectedMarkdown:title:baseline:)`**
  queues that save. A live snapshot pushes CRDT **bytes**, but the reconcile machinery is
  markdown-based, so the coordinator carries the **projected markdown** (our replica's
  render of the snapshot) as the `PendingSave.markdown` and the draft body. That single
  choice makes `finish` unable to tell the two paths apart: the write-ahead draft, the
  enqueue-hold + single-writer conflict rule, latest-wins coalescing, the
  `lastConfirmedPushMarkdown` stamp, the content-cache write, and `.pendingSync`/`.failed`
  classification are all **reused unchanged**. The only branch is in `start`, which sees a
  non-nil `PendingSave.liveSnapshot` and calls `saveLiveSnapshot` instead of
  `saveDocumentContent`. On success the projected markdown is stamped as
  `lastConfirmedPushMarkdown`, so a later **downgrade to a classic markdown save of the same
  body** reconciles via rule 1 (or rule 2's body fallback), never a false conflict against
  pre-live state. **Revised 2026-11-04:** markdown-only drafts are today's behaviour, not a rule
  to preserve; persisting the raw replica bytes in the draft is approved and planned. Its
  constraints live in `AGENTS.md` ("Drafts will carry the replica bytes").

### Editor wiring — the write path complete (C2c)

C2a built the sync engine, C2b built the save mechanism; **C2c is what actually calls
either from the editor.** It is the last PR of the write path — after it, two-way live
editing (forward → broadcast → remote caret-preserving apply → periodic snapshot save →
graceful downgrade) is wired end to end, still entirely behind the default-off
`schrift.liveCollaboration` flag.

- **An id-stable `[BlockNoteBlock]` builder is the prerequisite.** `applyLocalEdit`
  diffs an `old`/`new` BlockNote block pair by id, so `old` must be the replica's
  current projection expressed with the *same* ids the editor is about to diff against
  — and those ids must survive across keystrokes, or every edit would look like a
  whole-document replace. `MarkdownYjs.blockNoteBlocks(from: [EditorBlock])` is that
  builder: it maps each `EditorBlock` straight to a `BlockNoteBlock` reusing
  `EditorBlock.id` as the BlockNote id, bypassing `parseEditorBlocks`'s markdown
  re-parse entirely (which mints a fresh id per call and would make every keystroke
  diff as insert-everything/remove-everything). The existing `blockNoteBlocks(from:
  markdown)` — used by the classic save — is unchanged; this is an additional overload,
  not a replacement.
- **The write-delegate seam mirrors C1's read seam.** `EditorLiveWriteCoordinating`
  (`forwardLocalEdit() -> Bool`, `flushPendingLiveSnapshot()`) is a small `@MainActor`
  protocol `LiveEditingBridge` conforms to; `EditorViewModel` holds it as `weak var
  liveWrite: EditorLiveWriteCoordinating?`, set once by `EditorView` after it lazily
  builds the bridge (the same call site that builds the C1 bridge — there is only one
  bridge instance, and it plays both roles). The manager itself never enters
  `EditorViewModel` — only this protocol does, exactly as C1 kept `LiveReplicaProviding`
  as the only seam for reads. `LiveReplicaProviding` gained the write-side members
  (`applyLocalEdit`, `encodeSnapshotForSave`, `replicaIsFailSafe`, `hasPendingStructs`)
  that `DocumentCollaborationManager` already exposed from C2a — no new adapter code was
  needed.
- **`canEngageLiveWrite` extends the C1 read gate with one more requirement.**
  `canEngageLiveEditing` (loaded, clean, no dirty/pending-save/draft/conflict,
  idle/saved) is necessary but not sufficient for writing: a `nil` projection already
  folds in "no replica / not initial-synced / pending structs / fail-safed" (the
  manager only returns a projection when `canProjectReplica` holds), and on top of that
  the write path additionally requires `canWriteReplica(for:)` (the update ability) and
  `projection.isFullyModeled` — a document with
  any lossy or opaque block (an `.unknown` block, a prop type mismatch, …) stays
  **read**-live but never engages the write path, because such a projection can't
  round-trip back through `blockNoteBlocks(from:)` without the tracked `old` baseline
  silently drifting from what the replica actually holds.
- **The mode split lives in `EditorViewModel.markDirty()`.** Every mutator already
  calls `markDirty()` after mutating `blocks` in place. Its first line is now `if
  liveWrite?.forwardLocalEdit() == true { … ; return }`: when live-write is engaged,
  the edit is forwarded to the replica (integrated + broadcast + a snapshot
  scheduled) and `markDirty` returns **without** touching `isDirty`, `dirtySince`, or
  the autosave timer — durability now belongs to the replica and the periodic
  snapshot, and staying clean is exactly what keeps `canEngageLiveEditing` true so
  the document *stays* live across a run of keystrokes. When `forwardLocalEdit()`
  returns `false` — `liveWrite` is `nil` (every existing test, and any screen
  without a bridge), the write gate declined, or the replica fail-safed —
  `markDirty` falls straight through to the classic body, byte-for-byte as before
  C2c. `nil?.forwardLocalEdit() == true` is `false` by Swift's optional-chain
  semantics, so the classic path needed no test changes to stay green.
- **The live branch still runs the conflict-aware stash drop.** A REST "Updated"
  stash (`pendingFreshContent`) can exist even while a live session is engaged — a
  pull-to-refresh is not suppressed by `isApplyingLiveContent` the way the A5
  change-signal is, and the stash may hold a co-author's REST-originated edit the
  live replica never saw (a classic client saving without joining the
  collaboration room). So the live branch calls the same `abandonPendingFreshContent()`
  the classic branch calls, not a bare `pendingFreshContent = nil`: a stash that
  diverges from `serverBaseline` records a conflict exactly as it would on the
  classic path, which flips `canEngageLiveEditing` false so the *next*
  `persistLiveSnapshot` is parked behind the coordinator's enqueue-hold instead of
  full-overwriting the co-author's edit, and the document downgrades to classic. A
  stash that turns out not to have diverged is still dropped silently, with no
  conflict — the common case is unchanged. This is the one piece of
  draft/conflict machinery the live branch *does* touch; everything else
  (`isDirty`, `dirtySince`, the autosave timer, the draft store) stays untouched,
  exactly as the paragraph above describes.
- **The mutate-then-`markDirty` order is what makes the downgrade lossless.** Every
  call site mutates `blocks` first and calls `markDirty()` after, so by the time
  `forwardLocalEdit()` declines, the on-screen edit is already there — the classic
  path that runs next persists exactly that content. No edit is ever lost to a
  declined live forward; at worst it takes one extra classic autosave cycle.
- **`LiveEditingBridge.forwardLocalEdit()`** re-checks `isHandlingLocalEditsLive`: the
  engagement and fully-modeled flags the last frame apply set, no pending frame, the
  update ability, and fresh fail-safe/pending-struct reads. It builds `new` from
  `viewModel.blocks` via the id-stable builder, and calls
  `collaboration.applyLocalEdit(old:new:for:)` with the bridge's tracked
  `lastAppliedBlocks` as `old`. A thrown `applyLocalEdit` (a malformed replica
  fail-safing) is swallowed and reported as `false` — downgrade, not a crash. On
  success the bridge advances `lastAppliedBlocks = new`, marks a snapshot pending, and
  (re)schedules the ~60 s debounce; it deliberately does **not** bump the inbound
  `replicaVersion`/`remoteChangeToken` (C2a's local-echo suppression), so the forward
  never loops back through `replicaDidChange()` and re-applies the user's own edit to
  themselves.
- **The `old` baseline (`lastAppliedBlocks`) is captured only when the editor is known
  to equal the projection**, and nowhere else: on every successful remote frame
  (including a no-op empty diff) and again after every `applyLiveRemoteChange`. A local
  forward advances it itself (to `new`). This is why a peer's edit landing between two
  of the user's own keystrokes never desyncs the next local diff — the baseline is
  re-synced the moment the remote change is folded in, before the next keystroke can
  read it.
- **Remote UI work is frame-coalesced; baseline protection is synchronous.**
  `DocumentCollaborationManager.applyReplicaUpdate` integrates every inbound update
  immediately, bumps `replicaVersion`, and fires its per-document observer in that same
  main-actor turn. The bridge synchronously invalidates `lastAppliedBlocks` and marks a
  frame pending: a pre-update baseline is never eligible for forwarding. The expensive
  projection/render, diff and `applyLiveRemoteChange` wait for one display-frame callback,
  reading the latest replica rather than capturing each message's intermediate state.
  `LiveRemoteApplyScheduling` is injected: a one-shot `CADisplayLink` in common run-loop
  modes in production, immediate/manual delivery in tests. No sleep or timer debounce is
  used. The observer and SwiftUI `.onChange` share a pending callback; a late duplicate
  for the applied version is ignored. UI/read-write gates use the last applied fidelity
  plus fresh safety flags, without projecting again. While a frame is pending the REST
  fallback is held; if that frame cannot render, the bridge requests A5 revalidation so
  an opaque update cannot strand the editor without either path.
- **A local mutation flushes a pending frame before it changes content.** The protocol's
  `prepareForLocalEdit` hook runs before local block/index/range mutations and composition
  publication. It is the only exception to waiting for the next frame. This restores the
  editor and `lastAppliedBlocks` to the integrated replica before `BlockNoteWrite` uses
  its positional alignment. `forwardLocalEdit` runs *after* mutation and must never flush
  there: a server-wins fold at that point would overwrite the un-forwarded keystroke.
  A UIKit text callback can still carry its pre-frame buffer; `rebasedLiveInput` replays
  its local replacement onto the flushed peer text while retaining concurrent peer
  insertions/replacements, using Characters for edits and UTF-16 for the caret. Return
  similarly transforms its offset. Pending-input and correction probes that decline
  leave the frame pending for the actual text callback. Composition (#226) retains its
  existing hold/rebase policy: a frame updates the held peer base, never the marked
  characters; a commit before the frame flushes before publishing from that base.
  Local forwards advance only `localEditVersions`, never inbound `replicaVersion` or
  `remoteChangeTokens`, preserving local-echo suppression.
- **The observer belongs to the per-document entry; the pending frame belongs to the
  editor bridge.** The weak observer is registered on every session (re)acquisition,
  never at construction, and removed at manager teardown. On disappearance, after
  flushing local durability work, `stopRemoteApplies` cancels the callback, invalidates
  its generation, clears the write baseline, and ignores notifications until
  reacquisition. It leaves the manager's observer slot alone, since another screen on
  the same document may already have registered there. This also neutralizes an
  already-delivered obsolete callback. Registration also schedules catch-up for a lingered replica without waiting for a new
  version edge. The retained SwiftUI bridge can therefore reopen after teardown without leaking
  observers for documents that never acquired sessions or losing its synchronous hook.
  Manual-frame tests pin burst/across-frame projection counts, cancellation, buffered
  text and marked-text commits; the real-replica structural-removal race test holds the
  frame until a local edit and checks the merged replica and local/inbound counters.
- **The snapshot debounce is bridge-owned, cancel-and-reschedule, ~60 s** (injectable
  for tests), mirroring the autosave debounce pattern elsewhere in the editor. When it
  fires (`fireSnapshot`) it re-derives everything fresh from the replica rather than
  trusting state captured at schedule time: `encodeSnapshotForSave` (nil ⇒ **skip, no
  PATCH** — the un-snapshotted edit is still safely on screen and a later classic save
  will persist it), a fresh `projectedReplica` re-checked for `isFullyModeled` (the
  projection can have gone lossy between the forward and the fire), and
  `YBlockProjection.projectedMarkdown` for the reconcile-facing body. Only when all
  three succeed does it call `EditorViewModel.persistLiveSnapshot`, which enqueues
  through `saveCoordinator.enqueueLiveSnapshot` (C2b) exactly as a classic save would,
  and advances the local dirty baseline (`savedMarkdown`, `serverBaseline`,
  `lastSyncedAt`) so a subsequent downgrade to a classic save reconciles via rule 1 —
  never a false conflict against the app's own live-pushed content.
  `flushPendingLiveSnapshot()` fires the same path immediately (Done / background /
  view teardown) instead of waiting out the debounce, and is a no-op when nothing is
  pending.
- **Verification.** An end-to-end integration test drives a scripted `LiveReplicaProviding`
  fake through a full session — engage, forward a local edit, apply a remote change,
  let the debounce fire a snapshot, then force a fail-safe and confirm the next edit
  downgrades to the classic autosave path — alongside the existing C2a differential
  fuzz (unchanged; C2c adds no new sync-engine surface, only editor callers of it).
  A separate deterministic **stale-baseline race regression** drives the *real* stack
  (`FakeWebSocket → session → manager → real replica → bridge → view model`): it delivers
  a remote update that removes a block (shifting the one the user edits), withholds the
  display frame and deferred `.onChange`, then mutates locally and asserts the manager's
  replica projects to the correctly merged document — no corruption reaching peers.
  A pending frame must flush before mutation; an unprotected stale baseline would produce
  editor `[Doc, First, Second!]` and replica `[Doc, Second, Second!]`. Manager tests pin
  same-turn observer delivery and silence on fail-safe; bridge tests pin synchronous
  baseline invalidation, pre-mutation flushing and one latest-state apply per frame. Every pre-existing `EditorViewModel*Tests` test passes unchanged, which is the
  standing proof that the classic path is untouched when `liveWrite` is `nil`.

**Docs 6 transport enabled (A5).** Docs 6 replaced Hocuspocus with yhub.
`CollaborationWireProtocol(config:)` selects plain y-websocket for
`usesCollaborationYDocServer`; all other servers retain Hocuspocus framing. The transport
uses `varUint(type) + payload` with no document-name prefix for yhub; the same session
handles sync step1/step2/update and awareness payloads. There is no auth message.
Hocuspocus's `SyncReply` type 4 remains Hocuspocus-only. yhub's empty awareness keepalive
is accepted without changing the replica or clearing known peers.

`CollaborationEndpoint` builds
`ws(s)://{API host}[:port]/collaboration/ws/v1/{org}/{lowercase document UUID}`, no trailing
slash, with the existing explicit origin and cookie headers. Only the validated org is
read from `COLLABORATION_WS_URL`; its host never determines the socket destination.
Awareness for yhub reads/writes `{"user":{"name":…, "color":…}}` (cursor fields are
ignored); the legacy Hocuspocus shape stays flat. A writer re-publishes its awareness every 15 s with a strictly higher clock (peers drop a state not renewed within 30 s); renewal stops on any disconnect. The editor supplies the document's
`abilities.update` from its existing metadata. Readers can receive/project updates but
never publish awareness, broadcast local edits, produce save snapshots, or report local
edits handled live. Replica read safety remains independent of write authorization.
Permission and replica survive suspension; a reconnect's step2 diff includes deletions,
even when a deletion-only edit left the state vector unchanged.
After a socket drop the session does not reconnect by itself; a network reachability
change or foreground resume is required. Until then peer edits stop arriving, while
local edits still reach yhub through the ~60 s HTTP snapshot.

**The production server gate is enabled:** `ServerConfig.yWebSocketLiveCollaborationEnabled`
is true, so a Docs 6 config with an advertised collaboration URL supports live collaboration.
The independent user preference `schrift.liveCollaboration` remains default off and still
gates session availability. Saves continue through the incremental HTTP collaboration-server
route for snapshots. Tests can still override the manager's support seam for isolated yhub
transport cases.
When `runSyncPass` sees a draft for a document whose live replica is held (a writable entry
whose replica has not fail-safed; checked before and after the GET), it skips replaying that
markdown so the same edits are not inserted again as new Yjs items. After the session's
initial step2 exchange, the bridge re-persists the replica snapshot through the normal save
coordinator path only when the draft's markdown is canonically equal to the replica's
projection and its title passes the classic replay's title rule (a co-author's rename the
user never made, two different renames, or no known server title leave the draft). Success
clears the write-ahead draft. `knownServerTitle` is session-only and updated by editor fetches
and landed saves; a co-author's title-only rename changes no Yjs content, so it does not refresh
over the live socket and the gate can still approve the old local title. This pre-existing
live-title gap is narrowed by the gate but not closed. `canonicalMarkdown` ignores leaf nesting,
so a draft differing
only by a leaf's indentation is re-persisted flat: content is kept and leaf structure follows
the replica. A draft that differs holds edits the
replica lacks, so it is left alone. Tearing down an idle held entry (`teardownIfIdle`, or the
idle drop in `suspend()`) fires `onHeldReplicaReleased`, wired to `syncPendingDrafts()`, so
that draft then replays through the classic path. A replica fail-safe does not fire
`onHeldReplicaReleased`, so a draft skipped while it was held waits for the next normal sync
trigger (reconnect, foreground, launch). Until then it waits while the editor holds
the replica, and classic saves outside `runSyncPass` (retry, autosave after live mode
disengages) can still race the socket, as on legacy servers. Details live in `AGENTS.md`.

**Switch-on evidence (S4/S5):** on the real yhub server,
snapshot and live sync for a document filled with every web block were byte-identical.
Schrift's core re-encoded them identically to yjs 13.6.33. The web cursor arrived as
y-prosemirror relative-position JSON and resolved correctly, and off-main decode passed.
The on-device end-to-end check is not yet verified with a TestFlight build.
Rollback is reverting `ServerConfig.yWebSocketLiveCollaborationEnabled` to `false`.

**C3 (shipped):** the user-facing toggle is a **Profile → Preferences → "Live
collaboration"** switch (`ProfileScreen`, a `ProfileTrailingRow` + `Switch` exactly like
the sibling Notifications/Work-offline rows) backed by
`@AppStorage(LiveCollaborationPreference.key)`. Writing that key is the *entire* wiring:
`RootView` builds the collaboration manager with `featureEnabled:
{ LiveCollaborationPreference.isEnabled() }`, a live closure re-evaluated on every
`availability` read — pinned by
`DocumentCollaborationManagerLifecycleTests.testAvailabilityTracksTheLivePreferenceFlagMidSession`,
which fails if anyone "optimizes" it into a captured Bool. **The preference default is OFF /
opt-in** (decision 2026-07-21). The real-server S4/S5 checks above support enabling the
Docs 6 server capability; the remaining on-device end-to-end WebSocket
check is not yet verified with a TestFlight build. Deliberate,
documented semantics: the flag is read lazily, so a flip affects **newly requested
sessions** (opening a document, reconnect, resume) — it does not retroactively open or
close sockets on screens already showing a document; fully consistent from the next
document-open or app launch. Still open as follow-ups: the on-device WS verification
(type on iPhone → see it in Safari, and back; non-gating) and any live-mode
header/status refinements (e.g. the "Synced X ago" caption is not yet advanced by a
landed live snapshot).

### Two Yjs models, deliberately

There are three representations of an "item", and conflating them is the easy
mistake:

- **`YEncoderItem`/`YEncoderContent`** (`YjsUpdateEncoder.swift`) — the *from-scratch
  encoder's* model. Every item in a newly built document is authored by one client,
  so it needs no origins, no parent pointer, and no left/right links. This is what
  the shipping full-overwrite save path uses, and its output is pinned by golden
  hex tests.
- **`YItemRecord`/`YContentRecord`** (`YUpdateDecoder.swift`) — the immutable *wire*
  record. It exists so a decoded update re-encodes byte-identically, and is
  deliberately never mutated.
- **`YItem`/`YContent`** (`YStruct.swift`, `YContent.swift`) — the *live* item, the
  full YATA operation. This is the real one, and the one **`YStateEncoder` encodes
  from** (B3): it derives the wire info byte from the live item's origin/rightOrigin/
  parentSub, never replaying a stored byte — `YItem.info` holds runtime flags
  (keep/countable/deleted/marker), *not* the wire byte.

### Transliterated, not reinterpreted

The store is a deliberately literal transliteration of **yjs 13.6.33** (the version
the Docs 6 frontend lockfile resolves; it was 13.6.31 under docs v5.4.1). Every
non-obvious branch carries the yjs function and its `yjs.cjs` line in 13.6.33
numbering. This is not stylistic: the output of this code
eventually becomes document state that real web clients render, so a "cleaner"
rewrite that disagrees with yjs about one ordering is silent corruption. **Do not
tidy `YItem.integrate`.** If a change seems warranted, it needs the differential
fuzz (below) to prove it, and human sign-off.

Three consequences worth knowing before touching this code:

- **A JS string is a UTF-16 code-unit array; a Swift `String` cannot be.**
  `ContentString.splice` transiently produces a *lone surrogate* before repairing it
  to U+FFFD (yjs#248), which no Swift `String` can represent. So `YContent.string`
  holds `[UInt16]`. This is forced, not a preference.
- **JS arrays are references; Swift arrays are values.** yjs hands a client's struct
  array around and splices into it, mutating the one array the store holds. A Swift
  `[YStruct]` would splice into a copy. `YStructList` boxes it to restore the
  reference semantics the algorithm assumes.
- **Merging is not optional.** yjs merges adjacent items on *every* transaction
  cleanup, so a store that skips it diverges from yjs's after the first update —
  three adjacent single-character inserts stay three items here and become one
  there.

### Pending structs and delete sets

Updates arrive out of order over a relay, so a struct whose causal dependency has
not arrived is stashed (`YStructStore.pendingStructs`) and replayed once it does;
likewise a delete range naming absent structs (`pendingDs`).

yjs stashes both as **V2-encoded updates**. Schrift stashes the decoded refs
instead. The V2 codec exists in yjs purely as an internal container for these two
fields — Schrift's wire is v1 end to end (y-protocols and the docs server both
speak v1) — so porting `UpdateEncoderV2` + `mergeUpdatesV2` + `diffUpdateV2` would
add a large codec with no wire consumer. **This is an internal representation
choice, not a protocol deviation:** nothing stashed is ever transmitted. The one
yjs behavior that does observe pending structs on the wire —
`encodeStateAsUpdate` folding them in — is exactly what the live design forbids
anyway: a replica with pending structs must never be snapshotted back to the
server.

Two consequences of that choice:

- yjs's stash is padded with `Skip` structs, because a *serialized* update's
  per-client structs must tile the clock range with no gaps. Schrift's has no holes
  to pad. Skips are never integrated either way.
- **Known deviation — accepted, 2026-07-17 (characterization refined by the B3
  fuzz, same day).** When the same client's clock range is stashed *pending* twice
  with different *tilings* — a merged item from one peer, the finer items it came
  from from another — yjs `mergeUpdatesV2` re-tiles to the finest decomposition by
  *splitting* structs (`sliceStruct`). Schrift keeps decoded refs and reproduces
  only `mergeUpdatesV2`'s greedy *coverage* resolution (`mergeClientRuns`: the run
  that reaches a clock first keeps writing; a later struct whose range is already
  covered is discarded), which cannot split. Left as-is deliberately: closing it
  means porting the byte-level re-tiling. A greedy coverage rule provably cannot
  reproduce it — the *same* collision shape has opposite correct outcomes (one
  range settles to `ContentDeleted`, another identically shaped one to the live
  `ContentString`), so no order- or content-preference heuristic satisfies both;
  every bounded attempt fixed one case and regressed the other (measured against
  the differential fuzz). Differing tilings are **common** (any peer that merged a
  run emits a coarser view than the incrementals it came from), and usually the two
  settle identically — but **not always**. This deviation *can* leave a settled
  content divergence on a **deleted** item's tombstone form (`ContentDeleted` vs a
  deleted `ContentString` — semantically identical, byte-different, so it moves an
  `encodeStateAsUpdate` snapshot's bytes). That is broader than the earlier claim,
  which named yjs#248 (a split surrogate pair destroyed by re-tiling) as the *only*
  content disagreement: the tombstone case needs no surrogate. It is a
  **synthetic-reordering artifact** — it requires a client's early clocks delivered
  *after* multiple out-of-order tilings of its later clocks, an adversarial
  full-shuffle signature. A realistic-relay fuzz (server persists via
  `mergeUpdatesV2`, mostly-in-order FIFO broadcast, join/reconnect snapshots) found
  **0 in 7000 seeds** while exercising the pending stash in 91% of them; the
  synthetic full-shuffle corpus finds ~1/800, and that rate collapses to 0 the
  moment the shuffle probability drops below 1. It is therefore unreachable from
  honest hocuspocus traffic, and B3 byte-identity holds everywhere a client will
  realistically reach.

The stash merge reproduces `mergeUpdatesV2`'s coverage resolution rather than a
content-blind dedup, because **content-blindness loses content** — a lesson this
store has now learned twice. First: `mergeUpdates`/`diffUpdate` pad a hole with a
`Skip`, so a held `Skip(5,3)` and the real `Item(5,3)` share a `(clock, length)`;
a `(clock, length)`-only key let the Skip swallow the item, its text was lost, and
the stash stalled forever (found in review — the corpus then contained no Skip).
Adding the struct's *kind* to the key fixed that, but not far enough: two
content-differing `YItem`s at the same `(clock, length)` — a live
`ContentType`/`ContentString` and a `ContentDeleted` tombstone from a gc'd peer —
share clock, length *and* kind, so the kind-keyed dedup dropped whichever arrived
second, a **settled** divergence whose winner depended on delivery order. The B3
differential fuzz caught it (8 settled divergences across 800 seeds — the first
settled divergences the fuzz had found); the coverage rule, which keeps the
first-reaching run and discards only a *covered* struct exactly as
`mergeUpdatesV2` does, resolves all eight and leaves only the different-tiling
re-tiling deviation above.

### Malformed input must throw, never trap

Updates arrive from the network, so every clock is attacker-controlled and Swift's
arithmetic traps where JS's silently goes negative. `YStructIntegrator.validate`
enforces one ingest invariant — **every struct has a non-empty clock range whose end
fits in a `UInt`** — and that is what makes `lastId`, `getItemCleanEnd`,
`tryMergeDeleteSet`, `addStruct` and `splitItem` provably free of overflow and
underflow downstream, since each is bounded by some struct's own `clock + length`.
A 10-byte malformed update used to crash the process here.

The invariant rejects only what a real peer cannot send *and* what would otherwise
trap. yjs cannot author a zero-length struct (`YText.insert("")` no-ops); its own
handling is incoherent (it integrates the degenerate item, then throws during
cleanup), and Swift would underflow instead of throwing.

It deliberately does **not** bound clocks at `Number.MAX_SAFE_INTEGER`, though that
is the largest a JS peer can hold exactly: lib0's guard sits inside `readVarUint`'s
*continuation* branch, so a terminating varUInt slips past it and yjs simply stashes
the struct as unreachably far ahead — verified against the oracle. Rejecting there
would be **stricter than yjs** for input that cannot hurt us. (`Lib0Decoder` accepts
the full 64-bit range because its encoder half must round-trip Swift's `UInt`;
`decodeStructs` guards the one place that arithmetic can overflow.)

A trap is not the only fatal fault the wire can trigger — **unbounded recursion**
is another, and the fail-safe `catch` in `DocumentCollaborationManager.applyReplicaUpdate`
cannot intercept a stack overflow (it is a machine fault, not a Swift error).
`Lib0Decoder.readAny`'s object/array tags nest, so a few KB of nested-container
bytes was thousands of stack frames; `Lib0Decoder.maxAnyNestingDepth` (64) now caps
it and throws `anyNestingTooDeep`. Unlike the clock rule this is a **deliberate
narrowing** rather than oracle parity — a JS decoder also refuses, but only in the
thousands — accepted because real `.any` content nests two or three deep and the
refusal simply fail-safes the update.

The delete and gc cascades are a second such recursion. They
(`YItem.delete → ContentType.delete → YType.deleteChildren → YItem.delete`,
and the `YItem.gc` twin) recurse once per nested `ContentType` level — a depth one
crafted inbound update fully controls. On the **simulator** (a large host stack) a
~20k-deep chain (~140 KB) overflows; the vulnerable path runs `@MainActor`, and a real
device's ~1 MB main-thread stack is ~8× smaller, so its floor is far lower.
Integration itself is iterative and safe far past that; only delete/gc recurse, which
matches yjs (it too accepts deep integration and refuses deep delete/gc with a catchable
`RangeError`). `YTransaction.maxTypeNestingDepth` (**256** — sized for the device stack,
≲800 native frames, ~25× above realistic content) bounds both cascades: `YItem.gc`
throws directly (already `throws`), while the non-throwing `YItem.delete` flags
`transaction.recursionLimitExceeded`, which `cleanupTransactions` — the single chokepoint
every transaction drains through — converts into a thrown `.recursionLimitExceeded`,
discarding the half-marked store before gc/merge read it (the two guards are symmetric,
so both delete-set orderings refuse at the same depth). It is a deliberate narrowing
(oracle-faithful at the accept/reject boundary and byte-identical below the cap — the
golden `deleteNestedType` fixture is unmoved — but stricter than V8 above it), accepted
because real documents nest ~2 type levels per visual indent and a deeper one merely
loses live collaboration, not data. The cap must be re-measured on a **real device**,
Release build (a simulator build has the host's large stack), and a deep-nesting
differential-fuzz lane run, before the live-collaboration flag is ever defaulted on.

### Teardown is the owner's job

The item graph is a mesh of strong cycles — `item.left ⇄ item.right`, and
`type.start`/`type.map` ⇄ `item.parent` — because yjs assumes a tracing collector.
ARC collects none of it, so **releasing a `YDoc` frees nothing**; a live session
opens one replica per document. `YDoc.destroy()` breaks the cycles and must be
called by the replica's owner — the main actor, through
`DocumentCollaborationManager` (C1), or `DocumentReplicaSession` for the
opt-in native route (PR08b) — whenever it drops a replica (entry teardown or a
fail-safe). No edge can be
`unowned` instead: the algorithm reads all of them in both directions, and none has
a target that provably outlives its source.

### Verification

Golden fixtures captured from real yjs pin each YATA branch
(`YIntegration*Tests`, and — for the B3 encode side — `YStateEncoderTests`), and a
**differential fuzz harness** compares this store against a node yjs oracle across
randomized op scripts and delivery orders — seeded, minimizing. It compares the
full store structure (not just the wire projection, so left/right/origin wiring is
checked too) after *every* update, **and, once B3 landed, the encoded bytes**: at
every settled step it asserts `YStateEncoder.encodeStateAsUpdate` (full and
diff-against-state-vector) and `encodeStateVector` are byte-identical to yjs's.
Bytes are compared only where **both sides are settled** — an unsettled store may
legitimately differ (an accepted re-tiling, a pending stash a `diffUpdate` never
resolves), and a settledness *disagreement* is itself a finding. The harness is
out-of-tree tooling (the zero-dependency rule); what it
finds is promoted to fixtures here. The same technique is proven in this repo on
`InlineMarkdown`.

One property it establishes is worth stating, because it is counterintuitive:
**yjs itself does not always converge.** Splitting a surrogate pair replaces it
with two U+FFFD, so whether a pair survives depends on delivery order (yjs#248).
The property to hold this store to is therefore *"it converges exactly when yjs
converges"*, not *"it converges"*.

A green fuzz run means nothing unless the corpus reaches the branch, so measure
coverage rather than assuming it (Swift source-based coverage reports region/line
counts, not a branch counter — confirm the *region* executes). Two corpus shapes
are needed, and they are not interchangeable: **random-position inserts** produce
the concurrent, interleaved origins that drive the conflict loop's case 2, while
**contiguous appends plus cumulative snapshots** are the only way to reach
`Item.integrate`'s offset>0 path — a struct overlapping a prefix the receiver
already holds exists only once a sender has *merged* a run, which incremental
updates alone never produce. B3's byte gate splits the corpus in two: a
**realistic-relay** lane (mostly-FIFO delivery, server persistence via
`mergeUpdatesV2`) is held to 0 divergences and is the honest byte-identity gate,
while a **synthetic full-shuffle** lane surfaces the one accepted re-tiling
deviation above (and *only* that exact shape — a mechanical four-element check
refuses to absorb anything else, so a real bug can never hide behind the
carve-out).

### Remote-change format cleanup (B4, landed 2026-07-17)

On a *remote* transaction touching a `YText` that has formatting, yjs runs
`cleanupYTextAfterTransaction`, deleting formatting items rendered redundant — e.g. a
mark wrapping text a concurrent edit deleted, or a duplicate concurrent mark. This is
reachable from real documents, not theoretical: BlockNote's schema is `XmlFragment >
blockContainer > XmlText`, bold/italic/link are `ContentFormat` items inside those
texts, and nested `XmlText` types arrive as real `YText` subclasses — so the trigger
(`YText._callObserver`, gated on `!transaction.local && _hasFormatting`) fires. **B4
was a prerequisite for the live write path (C2), not an optimization**, and it lands
together with gc (`YTextCleanup.swift`, `cleanupTransactions`'s observer phase). The
cleanup transaction is local with origin `null`, so yjs's `'update'` event fires for it
too and a provider broadcasts it; `YDoc.onUpdate` + the manager's origin-`nil` broadcast
do the same (see "Live editing (C1)" above), so peers delete the same redundant
`ContentFormat` items instead of each keeping their own copy.

Two subtleties the transliteration had to get right, both proven against the yjs
oracle by the differential fuzz's dedicated formatting lane (nested text, concurrent
redundant marks — the only shape that fires the trigger, since a bare root type is
never a concrete `YText`):

- **Format-value equality is JS `===`.** yjs compares parsed `ContentFormat.value`s
  with `===`; the store keeps raw `valueJSON`, so `YFormatAttrValue` reproduces that:
  primitives by parsed value (numbers numerically, strings by UTF-16 code units),
  objects/arrays by value-identity token (shared by restored/negated formats), and absent-key ⇔ JSON
  `null`. The token is in-memory only; decoding each format creates a new identity.
- **The cleanup's routing is not confluent across clients.** `iterateDeletedStructs`
  must walk the transaction's delete set in yjs `Map` **insertion order** (now
  `YDeleteSet.orderedClients`), not ascending: a client owning a *deleted*
  `ContentFormat`, processed first, adds its parent to `needFullCleanup` and thereby
  suppresses every later client's contextless cleanup on that type. Ascending order is
  deterministic but wrong. The fuzz found this (a live bold mark wrongly deleted);
  every other delete-set consumer (gc, merge, encode) is per-client and unaffected.

The fuzz that once quantified the *gap* (2 of 1500 seeds diverged, both formatting)
now confirms the *fix*: the formatting lane runs thousands of nested-text concurrent-
formatting scripts against the oracle with zero divergence, gc on and off, and
region coverage proves the cleanup code executes rather than being an honest negative.

### Format-aware text operations (B4)

`YTextOps` is the write side of a text: yjs's `ItemTextListPosition` cursor (@6284)
with its forward/format bookkeeping, `findPosition` (@6367), and the
`insertNegatedAttributes`/`insertAttributes`/`insertText`/`formatText`/`deleteText`
family, exposed as `YType.insert`/`insertEmbed`/`delete`/`format` (@7362–@7450). It
will be wired into the BlockNote writer in B5; the current writer still uses
`YWrite` and `TextSpanDiff`. `YXmlText` shares every one of these operations in
yjs, and Schrift has one `YType`, so both text kinds use them.

Three things are load-bearing and easy to "fix" wrongly:

- **Attribute maps are ordered.** `insertAttributes` mints one `ContentFormat` per
  changed key in iteration order, so the order decides the clock order of those items
  and therefore the update bytes. `YTextAttributes` keeps insertion order (a
  `dictionaryLiteral` keeps source order, which is JS object-literal order for the
  non-integer keys every schema uses); a Swift `Dictionary` would not.
- **Two different equality rules over the same map.** The ops path uses yjs's
  `equalAttrs` (@6282): `===` first, then lib0 `equalFlat` for any two containers
  (`YJSONValue.equalAttrs`). Arrays expose their index keys, so `[]` equals `{}`;
  flat values compare with `===`, so distinct nested containers remain unequal
  even with identical JSON text. The cleanup path uses only `===`
  (`YFormatAttrValue`). `YTextAttributeValue`
  carries both the raw JSON and a `YAttributeIdentity` token so each path gets its
  rule. `YItem.formatIdentity` holds the same token when an attribute is restored
  or negated; decoded items lazily mint their own tokens. Tokens are never encoded.
  The event delta also preserves these tokens in its attribute maps. Primitive
  numbers compare numerically, and string equality compares UTF-16 code units,
  including strings inside flat objects, so composed and decomposed Unicode remain distinct as in JS `===`.
- **Out-of-range indices are yjs's, not the editor's.** yjs does not clamp: an insert
  past the end appends, a delete past the end stops at the end, and a format past the
  end **pads the text with `'\n'`** (@6584, Quill's trailing-newline convention).
  Clamping for editor safety belongs to the caller (B5), not this layer — clamping
  here would change the bytes a real yjs client produces.

`deleteText` reuses `YTextCleanup.cleanupFormattingGap` (@6604) rather than
duplicating it. A locally minted `ContentFormat` sets its parent's `_hasFormatting`
through `YContent.integrate` (@8991), which already ran before this landed — the
cleanup trigger is unchanged. `YTextOpsTests` replays twelve yjs 13.6.33 captures
(plain inserts, typing inside a bold run, explicit attributes including `null`,
format add/remove/overlap, object-valued links, the C2 boundary delete, a whole
formatted run, embeds, surrogate pairs, a split inside a surrogate pair, out-of-range
ops, and a nested `XmlText`) op for op, asserting each op's state-vector diff update,
the transaction's own `'update'` bytes (what the editor broadcasts — a delete's diff
update repeats the store's whole delete set, the transaction encoder carries only its
own deletes), and the text's `toDelta()`.

The identity rule has a fixture consequence worth knowing: because the cleanup
compares object values by identity, a capture that reuses one `{href:…}` object
across ops makes two `ContentFormat` items share a value object, and that relation
does not survive JSON. Such a fixture stops replaying (a shared-object random lane
diverged at 1 of 100 sequences; deep-cloned per op, 0 of 3000 ops). Capture scripts
must deep-clone attribute objects per op.

Within an op, yjs hands the *same* value object to restored/negated format items.
Schrift carries that identity through the value and item tokens, so a later delete
can remove a redundant restored object format exactly as yjs does. After
`encodeStateAsUpdate` + `applyUpdate`, yjs parses separate objects and Schrift
mints separate tokens; both deliberately lose the in-memory sharing relation.
The named object-restoration, Unicode-equivalence and attribute-equality
regressions pin transaction update bytes, the visible delta and the full state
against yjs 13.6.33. The equality ones cover the two `equalFlat` edges a raw-JSON
comparison gets wrong: `[]` equals `{}` (arrays expose index keys), and two
distinct nested containers with identical JSON text are not `===`.

## Authentication

Launch-time preferences migrations write only when data actually needs migrating.
`SessionStore.init` preserves a valid image-cache namespace without rewriting it,
and `DocumentCacheStore.init` removes the retired shared-by-me key only when it
exists. SwiftUI may reconstruct stores while building a view; redundant defaults
writes invalidate `@AppStorage` and can feed back into that reconstruction before
the first scene finishes rendering. The launch regression hosts both stores under
an observed offline preference with a bounded render counter, alongside tests for
one-time migration and silent subsequent construction. This fixes the reproducible
preferences feedback loop matching the 0.63.4 scene-create watchdog reports; the
original affected physical device still needs verification with the shipped fix.

**WKWebView session-cookie login**, not native OAuth/PKCE. Rationale:

- The Connect screen (per the design handoff) accepts an arbitrary Docs server URL — the app cannot know that server's IdP endpoints in advance, and Docs' own `/api/v1.0/config/` does not expose them.
- A WKWebView pointed at `https://{server}/api/v1.0/authenticate/` runs the exact same redirect dance as a browser, requiring zero IdP-side configuration on the self-hosted instance.
- This matches the design's own Connect screen copy: "The app signs in with your existing session — no password stored."

Flow:
1. User enters/selects a server URL on the Connect screen, taps "Sign in to {host}".
2. App presents a `WKWebView` (in a sheet) loading `https://{server}/api/v1.0/authenticate/?next=...`. Every login web view (the Connect sign-in, the re-login sheet and the silent re-login, all built by `makeLoginWebView()`) is inspectable from Safari > Develop > device in Debug builds only; Release (TestFlight) builds never are.
3. `WKNavigationDelegate` watches for navigation back to a recognized "logged in" location (e.g. a successful `GET /api/v1.0/users/me/` no longer returning 401, or landing back on the SPA root) and dismisses the sheet.
4. The Django session cookie (`docs_sessionid`) is read from `WKWebsiteDataStore.default().httpCookieStore` and synced into `HTTPCookieStorage.shared` so the app's `URLSession` (default configuration) automatically attaches it on subsequent same-host requests.
5. `SessionStore.signIn` additionally snapshots the server's cookies into the Keychain (`dev.llun.Schrift.sessionCookies`, as Codable `StoredCookie`s) and `SessionStore.init` restores them synchronously on launch, before the API client is built — session-only cookies (nil `expiresDate`, e.g. Django's `sessionid`) are otherwise dropped from `HTTPCookieStorage` when iOS kills the process. Server URL + auth flag are persisted too; sign-out deletes both the snapshot and the live cookies. Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (never synchronizable), so a live session stays on the device that obtained it — the user-visible cost is one re-login after a device migration. `SessionStore.init` runs a best-effort `SecItemUpdate` to migrate items written by builds that predated this class.
   The snapshot is **refreshed when the app goes to the background** (`refreshPersistedSessionCookies`, written only when the cookies differ, never while a re-login is pending or a web login's cookies await confirmation — that state outlives a cancelled sheet — and never with an empty set). A snapshot taken only at sign-in restored the *sign-in-time* cookies on every cold launch, while the server had since rotated the session key or pushed its `Expires` forward with `Set-Cookie` — so the first request 401'd on a session that was still alive, and the app had to log in again at every launch.
6. On a real `401` from any API call, the shared `DocsAPIClient`'s `onSessionExpired` hook sets `SessionStore.needsReauthentication`. An expiry is first recovered **silently**: `SilentReauthenticationView` mounts the same WKWebView OIDC flow invisibly (1×1, transparent, hit-testing and accessibility off) behind the app. The IdP's own session lives in `WKWebsiteDataStore.default()`, so when it is still alive the redirect chain completes with no input and `ReauthenticationViewModel` confirms and re-persists the session exactly as the sheet does — presenting that as a sheet was the login popup that flashed up and closed itself at launch. When it gives up is `SilentReauthenticationAttempt`'s decision, fed by `WebLoginView`'s `WebLoginProgress`: it escalates to the visible re-login sheet (`escalateReauthentication(attempt:)`, which names the attempt so a leftover timer cannot escalate a later one) when the chain stays at rest off the server host — a finished IdP page or a failed load (a load merely superseded by a redirect, `NSURLErrorCancelled`/WebKit 102, is not a stop) — for a 2 s grace that any new load cancels (a self-submitting `form_post` page), when the confirmation fails, or after 15 s. Arriving back on the server (`.reachedServer`, reported before the cookie hand-off) stops both timers, so a slow confirmation cannot flash the sheet. Once a silent attempt has failed, later expiries in the same process go straight to the sheet, and so does a 401 within 60 s of a silent sign-in (a session refused again at once would otherwise loop). A 401 for a request *issued* before the last sign-in is ignored outright — `onSessionExpired` carries the request's start instant — since it was refused on the cookies that sign-in replaced. Server-host `/api/v1.0/` pages that are not a completion report no progress and fall to the timeout, whose timers pause when the scene leaves the foreground and restart on return (time suspended is not a stall). Like the sheet, every silent re-login forgets the signed-in identity and rotates the image-cache namespace — routine now at launch, so a launch that re-logs in re-downloads document images. Cached data keeps showing throughout; dismissing the sheet cancels non-destructively and the next failing request re-presents it. The app never drops back to the Connect screen on 401 — Connect is reached only via explicit sign-out.

Mutating requests (`POST`/`PATCH`/`PUT`/`DELETE`) must include Django's CSRF token (`X-CSRFToken` header, value read from the `csrftoken` cookie), matching the web frontend's own `fetchApi.ts` behavior.

**Known limitation:** session lifetime is still bounded by the server (`SESSION_COOKIE_AGE` / server-side invalidation) — the app persists the cookie across process death but cannot outlive the server's session; expiry is recovered by a silent web re-login while the IdP session lives, and otherwise surfaces as the re-login sheet, not a return to Connect. No refresh token in this flow.

## Networking & data model

`DocsAPIClient` wraps `URLSession`, base URL `https://{server}/api/v1.0/`. Key endpoints used in v1:

| Purpose | Endpoint |
|---|---|
| Bootstrap config | `GET /config/` *(the app still bootstraps from `GET /users/me/` alone — but as of 2026-07-11 this endpoint **is** called, best-effort, for the Profile server-version row (`RELEASE_VERSION`) — see `ServerConfig`/`serverConfig()`; it is not part of app bootstrap)* |
| Current user | `GET /users/me/` |
| Document list | `GET /documents/?is_favorite=&is_creator_me=&title=&ordering=&page=&page_size=` |
| Document detail | `GET /documents/{id}/` |
| Create document | `POST /documents/` |
| Update document metadata | `PATCH /documents/{id}/` |
| Soft delete | `DELETE /documents/{id}/` |
| Children (sub-pages) | `GET/POST /documents/{id}/children/` |
| Move in the tree | `POST /documents/{id}/move/` — `{target_document_id, position}`; `last-child` files it under the target, a sibling position against a **root** promotes it to the top level. Moves the whole subtree in one atomic transaction; every rejection is a 400 |
| Pin toggle | `POST`/`DELETE /documents/{id}/favorite/` |
| Pinned list | `GET /documents/favorite_list/` before Docs 5.7.0; `GET /documents/favorites/` from 5.7.0 |
| Search | `GET /documents/search/?q=` |
| Read rendered content | `GET /documents/{id}/formatted-content/?content_format=markdown` |
| Read raw content *(not used in v1; removed in Docs 6)* | `GET /documents/{id}/content/` |
| Write raw content, Docs < 6 | `PATCH /documents/{id}/content/` (full-overwrite base64 Yjs built on-device) |
| Read raw content, Docs 6 | `GET /collaboration/ydoc/v1/{org}/{id}?gc=true&awareness=false`, `Accept: application/json` → `{"doc": base64}` |
| Write raw content, Docs 6 | `PATCH /collaboration/ydoc/v1/{org}/{id}` `{"update": base64}` — applied incrementally |
| Version history | `GET /documents/{id}/versions/` (Docs < 6; removed in 6 — the sheet then says history is on the web) |
| Link sharing config | `PUT /documents/{id}/link-configuration/` |
| Accesses (members) | `GET/POST/PATCH/DELETE /documents/{id}/accesses/` |
| Invitations | `GET/POST/PATCH/DELETE /documents/{id}/invitations/` |
| User search (for invite) | `GET /users/?q=&document_id=` |

Pin/unpin persists its latest desired state in `PendingDocumentPinStore`, scoped to
server origin, account and server document. The app-scoped `DocumentPinCoordinator`
projects it over Home/Options/Shared/Search immediately and replays after deletions
through the existing sync triggers. Local UUIDs and pending deletes never reach a
favorite mutation. Retryable failures remain pending; terminal rejections restore the
last server state with pin wording. Settled projections and read revisions protect
stale responses and relaunch without vetoing newer server reads. Scoped known bits remain
durable for pagination gaps and older subpage metadata after Home releases cached
membership protection. Fresh favorites-page
membership is independent of metadata flags. Navigation retains real row metadata for
Options; landed moves update durable fallback placement without changing pin intent.
Fresh Search/Shared/children flags update older Options and rollback baselines without
consuming pending work. Successful identity recovery resumes retained pin work and
invalidates previously hidden projections. See
[`offline-and-sync.md`](offline-and-sync.md#offline-pin-and-unpin).

Favorites routing reads `config/`'s `RELEASE_VERSION` and compares numeric release
components against **5.7.0**, which renamed the action ([upstream #2540](https://github.com/suitenumerique/docs/pull/2540)).
Tagged (`v5.7.0`), prerelease (`5.7.0-rc.1`), and build-suffixed versions use their core
release's route. If config is absent, malformed, or unavailable, try the legacy route
first; config 401 still raises reauthentication. A JSON or HTML 404 from either collection
action permits one alternate GET; other favorites errors propagate. Only a successfully
decoded page establishes a cached route for this client/server. A later 404 clears that
selection and permits the alternate, supporting an upgrade during a running session.
The generic `documents/?is_favorite=true` list is not equivalent: its highest-ancestor
filter can omit pinned subpages. Home waits for favorites before applying either list,
so the route mismatch can also hide a successful Recent response and show “Offline.”

Codable models mirror `ListDocumentSerializer`/`DocumentSerializer` fields: `id, title, excerpt, abilities, link_reach, link_role, computed_link_reach, computed_link_role, is_favorite, depth, numchild, path, created_at, updated_at, user_role, creator`. The `abilities` dictionary (e.g. `update`, `destroy`, `link_configuration`, `accesses_manage`, `favorite`) drives which UI actions are shown/enabled per document — never hardcode permission logic client-side.

## Editing & save mechanism

A successful creation action opens the editor with a one-time entry intent: Home on iPhone
pushes `DocumentEditorRoute(createdDocument:)`, Home on iPad selects that route, and both
Subpages **Add a subpage** and the Pages drawer **New page** use the same creation callback.
Ordinary opens (including reopening a newly created document) carry no intent and start in
reading mode. Content must first initialize; only then does the view model consume the intent
through `canStartEditing` and `startEditing`. A document created on the server initializes
without waiting: its body is empty by construction, so the editor installs an empty body (with a
baseline that carries no server clock, so only body equality can prove a push) and enters
editing on the first frame, while the content fetch runs behind it under the ordinary revalidation
rules (an unexpected server body is stashed behind the "Updated" banner and the first edit
records a conflict, never an overwrite). Offline creation
restores its seed draft without fetching a local UUID. Ordinary opens with nothing cached show a
full-page skeleton of the header and first lines (`EditorLoadingPlaceholder`) until content lands.
The rendered shared header focuses the title once and selects its existing text, so typing
replaces the default without first deleting it. Selection alone never dirties the document.
Consumption is shared with the route so screen recreation, refresh, reconnect, and a changed
server identity cannot replay entry; the separate focus request belongs to the editing session.

Block focus is also synchronized when an `EditorUITextView` joins a window. The lazy
editing canvas may consume the new row's caret request before attachment, leaving no
later model update to acquire keyboard focus. The attachment callback checks the
coordinator's current focus intent through the same synchronous, delegate-suppressed
funnel used by model updates; it leaves block IDs, source offsets, and saving unchanged.
During a block-to-block handoff the old row retains first responder until the new
row can take it directly, so keyboard events still have a recipient while the
destination is detached. Clearing focus or leaving editing still resigns normally.
The row resolves text, focus, and cursor intent from the current view-model block
by that same stable ID during UIKit updates. Explicit body-time focus/cursor reads preserve SwiftUI's observation
dependencies even though the values passed to UIKit are read later. The text reader
bypasses SwiftUI's cached Binding value, so a queued row snapshot cannot overwrite
text entered since the snapshot was captured or
move the caret backward. Keyboard events that arrive between a structural edit
and UIKit reconciliation are applied as deltas to the model's current block and
pending source selection through `applyPendingKeyboardInput`. Stable block IDs
and the coordinator's consumed cursor token gate this handoff; ordinary input
continues through UIKit. The intent reuses the existing text/split/merge methods,
retains shortcut-corrected carets, and preserves hidden-syntax and composed-character
backspace rules. Ranged corrections still address the retained source block;
`applyPendingSourceReplacement` prevents the old UIKit buffer from duplicating a
suffix moved by Return or restoring removed leaf syntax. The coordinator publishes
typed text before restyling, because attribute edits/layout can reenter UIKit and
run a queued model update. Observation also notifies before the text write finishes:
a nesting counter defers text/caret reconciliation during delegate publication and
reconciles after the outermost call completes. Source corrections validate their
old-buffer coordinates; recognized consumed shortcuts supply the only prefix
translation, and corrections with obsolete correspondence are ignored. A handled
source correction invalidates further old-buffer ranges until UIKit reconciliation,
including repeated prefixes whose characters still match after their offsets changed.

IME input can begin immediately after Return, before the destination row has
reconciled. The model's stable block IDs remain unchanged; a separate session-local
input row identity transfers the existing native text view to the destination on
split/merge. The retained source gets its own native row. Stored scroll anchors and
recorded frames retain model block IDs; the editing canvas translates them to the
input row ID attached directly to each lazy row, keeping the caret reachable while
preserving its native view. Before `setMarkedText` starts, the coordinator prepares the
destination's current text, styling, and UTF-16 selection and resolves its callback
configuration by that captured ID. This semantic binding survives native commit and
immediate corrections until SwiftUI adopts the destination. It prevents both suffix
duplication and old-source correction coordinates after a committed composition.
UIKit retains control of marked characters, attributes, and selection throughout
composition; reconciliation only checks current focus while marking remains active.
Commit processes markdown shortcuts and slash queries even when provisional and
committed characters are identical. Input row overrides remain reserved during the
session so a remotely reintroduced model ID cannot collide with an inherited native
identity; installing replacement content resets them. Discarded row configurations
cannot acquire focus or publish changes for a model ID they no longer own.

**Reordering blocks.** In edit mode a leaf block (divider, image, attachment) can
be long-pressed and dragged to a new position, which is how a photo ends up under
a checklist item. Text rows are not draggable: their long press belongs to
`UITextView` (caret loupe, selection). The gesture is a UIKit long press
(`BlockReorderGesture`), so UIKit's own arbitration with the scroll view's pan
decides between scrolling and dragging; the canvas does not auto-scroll during a
drag, so a long move is several drags or VoiceOver's Move up / Move down actions.
The drop position comes from the pure `blockReorderDestination` over the rows'
recorded frames, and `EditorViewModel.moveBlock` applies it as an ordinary edit:
the block keeps its id, the full-overwrite save serializes the new order (no new
markdown or Yjs shape), and the live write path sends it as `BlockNoteWrite`'s
coarse delete + re-insert.

The same drag also nests. Sliding an **image or attachment** sideways (a divider
never nests, `blockNestsAsLeaf`) shifts its level by `round(dx / listIndentStep)`
(`leafDragIndentSteps`, sign-flipped in right-to-left layouts, where the indent
grows leftwards). The preview level is `leafDragPreviewIndent`: the level a plain
move to the **live** destination would give it (`movedLeafIndent`) plus those
steps, clamped into `leafIndentRange` evaluated in the array *after* the move
(`leafDragIndentRange`) — so a leaf can only nest under a list item that would
actually be above it, and can't orphan the nested siblings after it. The row
slides by the difference from its current level with a selection tick per level;
on release `moveBlock(blockID:to:indent:)` lands both (a slide with no new
position moves to the same index at the new level). VoiceOver gets Indent / Outdent
actions beside Move up / down (`indentLeaf` / `outdentLeaf`, the formatting bar's
labels), offered only where `canIndentLeaf` / `canOutdentLeaf` hold.

**Nested list items.** Bullet, numbered and checklist items nest. The editor keeps
its flat `[EditorBlock]`; nesting is `EditorBlock.indent`, read against the blocks
before it — an item is a child of the nearest earlier list item one level shallower,
which is the tree both markdown indentation and BlockNote's `blockGroup` children
describe. `normalizedListIndents` is the one invariant (only list items nest, never
more than one level below the list item directly above, at most `maxListIndent` = 6)
and `markDirty` re-applies it after every edit, so a conversion, deletion or move
never strands an item at a depth nothing reaches. Tab / Shift-Tab (hardware
keyboard) and the formatting bar's Indent / Outdent move an item **with its
subtree**; outdenting leaves its later siblings behind, so they become its children,
as BlockNote does. Return keeps the level, Return on an empty nested item steps out
one level, and backspace at the start of a nested item outdents it before anything
is deleted.

On the wire, `parseEditorBlocks` classifies a list line indented under the list item
directly above it (no blank line between, spaces only, at or past that item's
content column and less than four columns past it) as a nested item; anything else
stays verbatim, as it always has. `serializeMarkdown` writes a child at its parent's
content column — two spaces under `- `, three under `1. ` — matching the server's own
export (`* A\n  * B\n    * [ ] C\n  1. N`). `MarkdownYjs.blockNoteBlocks` folds the
flat blocks into `BlockNoteBlock.children`, and `BlockNoteYjs.encode` emits each
block's children as a nested `blockGroup` after its props and before its `id`, with
the content element as the group's left origin — byte-identical to
`blocksToYXmlFragment` (`YjsEncoderTests.testNestedListChildrenGoInANestedBlockGroup`).
This **changed saved bytes** for documents with nested lists, which used to be written
back as literal-text paragraphs (flattening every web-made outline on the first in-app
save); signed off for this change. Nesting has no live-write spelling — `BlockNoteWrite`
diffs a flat list and `YBlockProjection` reads a nested `blockGroup` as opaque — so
a nested document stays on the classic save path: `markDirty` sets
`hasUnmodelableLocalEdit` and never forwards an edit while any item is nested.

**Media leaves nest too.** An image, a file attachment, or a paragraph that is
exactly one `[label](url)` link (`blockNestsAsLeaf` — the attachment's origin-less
spelling, so nesting never depends on the origin) can sit under a list item, as
BlockNote nests any block as a child. In the flat model that is the same
`EditorBlock.indent`: `nestingBase(of:)` says how deep the block above lets the
next one go (a list item allows one level below itself, a nested leaf allows its
own level, anything else allows nothing), and `normalizedListIndents` clamps list
items and nestable leaves alike. A leaf has no subtree of its own, so a list item's
subtree (`listSubtreeEnd`) includes the leaves nested in it and Indent/Outdent of
the item carries them. A leaf moves with `indentingLeaf`/`outdentingLeaf`
(`EditorViewModel.indentLeaf`/`outdentLeaf`), whose allowed range
(`leafIndentRange`) never lets it strand the nested blocks that follow it: the
lower bound is the next block's depth when that block is a nested list child. An
outdent past that bound moves the leaf to the end of its parent's subtree instead.
`moveBlock(blockID:to:indent:)` places a dropped leaf at a depth the destination
allows (`movedLeafIndent`), and `numberedIndex` skips nested leaves so a photo under
item 1 does not restart the numbering of item 2. Reading and editing inset leaf rows
by the same `listIndentInset`.

A nested link line is the one leaf whose nestability its own text decides, so an
edit can take it away: typing past the link, Return inside it, merging prose into
it, an inline marker, removing the link, converting it to a heading. Zeroing such a
block in place would end the list there and flatten every nested sibling after it,
so the editor moves it to the top level just past the nested run that follows
(`detachingUnnestableBlocks`, applied before `markDirty` normalizes). An edit that
keeps it a link line keeps its level; Return at its end lands the new empty line past
the run (a nested paragraph has no markdown spelling); backspace at its start
outdents it first (`outdentingLeaf`), the way a nested list item steps out before it
merges. No content moves out of the document and no sibling loses its parent.

The app writes a nested leaf tight, at its parent's content column
(`- [ ] Task\n  ![photo.png](url)\n  [report.pdf](url)\n- [ ] Next\n`), and
`parseNestedLeaf` reads exactly that back: spaces only, the column must equal one of
the open items' content columns, no blank line before it, and the depth stays within
`maxListIndent`. A conservative lookahead (`nestedLeafRunEndsSafely`) scans the run
of sibling leaves and accepts it only when the run ends at a blank line, EOF, a
nested list line, or a line that classifies on its own. Prose after the run would
otherwise be a lazy continuation of the same paragraph, so in that case every line
of the run stays verbatim. (CommonMark itself would read the app's spelling as a
lazy continuation of the item's text; only the app's own parser ever reads it.)
Because the server's export never writes an image or link line at a list item's
content column directly under the item (it prints a nested leaf at column zero after
a blank line, on every shape in `LeafNestingOverlayTests`), only the app's own
spelling classifies here: server-authored content parses, and re-saves, to exactly
the bytes it did before nesting existed. The queued-photo rewriter and remover
(`markdownRewritingPendingAttachment`/`markdownRemovingPendingAttachment`) ask the
parser which lines are the record's image blocks (`pendingAttachmentImageLines`), so
they touch a nested placeholder line and no other indented one.
`MarkdownYjs.blockNoteBlocks` folds the leaves into the item's
`BlockNoteBlock.children`, and the encoder needed no change, since a nested
`blockGroup` of leaves is just a nested group
(`YjsEncoderTests.testListItemLeafChildrenGoInANestedBlockGroup`, generated with
`@blocknote/server-util@0.51.4` and yjs 13.6.33, the pinned version; the 13.6.31
goldens cover the same nested-group and media-prop paths with identical encoding).

**The server's export flattens it; the block tree restores it.** BlockNote 0.51.4's
`blocksToMarkdownLossy` prints a nested leaf at column zero after a blank line and
restarts the list it interrupted at the top level: `* a` with children
`[image, * b]` exports as `* a`, the image, `* b`, all flat. Items after the break
keep their depth relative to the first of them (`T{img, Sub{SubSub}}` exports `Sub`
flat and `SubSub` one level under it), and an item shallower than that shift
re-anchors it. `flattenedLikeServerExport` (`LeafNestingOverlay.swift`) is that
model, checked against `@blocknote/server-util` on every shape in
`LeafNestingOverlayTests`, and `canonicalMarkdown` runs both sides through it, so the
app's nested spelling and the server's flat export of the same body compare equal
(see `docs/offline-and-sync.md`).

The markdown read therefore carries a nested leaf flat, but the document's BlockNote
tree does not: `GET documents/{id}/formatted-content/?content_format=json` answers
the same envelope with `content` the block array, children included. The editor's
three content-fetch sites (open/revalidate, pull-to-refresh, "keep the server
version") pass each fetched body through `EditorViewModel.recoveringLeafNesting`
before `apply`/`installFetched`:

1. Only when the markdown could hide nesting (`markdownMayHideLeafNesting`: a leaf
   directly after a list item, the one shape the flattening produces) and the read
   is still permitted does it issue the second request
   (`DocsAPIClient.formattedContentTree`, decoded into a minimal, depth-capped
   `BlockNoteTreeNode`). A server that answers it with a missing route or a `400`
   is memoized per client (`contentTreeUnsupported`) and never asked again.
2. A tree whose `updated_at` differs from the markdown's describes another write and
   is ignored.
3. `leafNestingOverlay` overlays it, all or nothing, and answers three ways:
   `.recovered(markdown:)`, `.confirmedFlat` (the tree matches and nests nothing but
   list items the export already shows) or `.unknown`. List items (by
   kind), images (by url) and attachments (by url) are anchors; the markdown's
   anchors in block order and the tree's in pre-order must be the same sequence,
   every tree anchor must have only list items above it, and each anchored block
   takes its tree depth: the flattened leaves and the list items pulled up after
   them alike. `normalizedListIndents` must keep every target depth (a file
   caption, which exports as a paragraph between two children, makes it fail), the
   result must equal the markdown under `canonicalMarkdown`, which proves the tree
   explains the markdown rather than contradicting it, and it must round-trip
   through the parser. Media that export nothing (a docs `pdf` with the default
   preview, an empty placeholder) are not anchors; a `video` exports image syntax and
   anchors as an image.
4. Any failure, at any step, is `.unknown` and installs the flat export, which is
   the behaviour before the overlay existed. The helper never throws, so it cannot turn a successful read
   into a teardown, and every caller still re-checks its generation and availability
   after the extra await. The save marker taken before the first request covers
   both.

The overlaid body is what everything downstream sees: the install, the content
cache, the baseline and draft reconciliation. A body cached flat compares equal to
its restored revalidation, so `reconcileClean` installs a fetch that adds leaf
nesting on a clean screen outside an editing session
(`fetchedMarkdownRevealsLeafNesting`, compared against the blocks on screen, so a
reveal deferred by an editing session still applies on the first read after Done).
The reverse takes positive evidence: only a
`.confirmedFlat` read installs a flat body over a screen that nests a leaf (a
co-author un-nested it on the web), likewise only clean and outside an editing
session. An `.unknown` flat read, which is what every failure produces, never
un-nests the screen, and `serverCopyKeepingLeafNesting` keeps the nested spelling of
the same content in the cache and the baseline as well (including the body "Keep the
server version" installs), so a failed tree read can no longer rewrite a nested cached
copy flat for the next offline open. Saving a nested document writes real BlockNote children. On a
Docs 6 server a list item with nested children projects opaque, so
`BlockNoteAlignment` never anchors it; `BlockNotePreservation` keeps it when the user
left it untouched and the server's words and tree still match. Otherwise (edited, no
recorded base, or a co-author changed its words) it and its leaves are rebuilt, which
resets web-only media props (an image's `caption`, `previewWidth`, `textAlignment`; a
file's `caption`) to their defaults.

This is the part with no direct backend support, so it's called out explicitly:

1. **Read**: `GET /documents/{id}/formatted-content/?content_format=markdown`. Render natively as editable rich text, mapping Markdown constructs to the design's block types (paragraph, heading, bullet list, checklist, quote).
   Reading's optional **Hide completed** preference is session-local and off by
   default. `ChecklistReadingPresentation` derives visible rows from the complete
   `[EditorBlock]`, retaining IDs and source indices; only checked checklist blocks
   are omitted, together with everything nested under a hidden item (its `indent`
   subtree: list items, counted only when checked, and the photos, files and link
   lines nested among them) and the run of indent-zero image/attachment leaves
   directly after the item or its subtree (the server's export flattens a nested
   photo to exactly that). A nested leaf after the subtree belongs to another parent
   and stays. The run ends at the first block that is not flat media, a queued photo
   placeholder is never hidden, not even inside a subtree (its card carries
   Retry/Remove), and the hidden count reports items only. A hidden count and Show completed action remain when every checklist
   item is completed. Editing, serialization, drafts and the live replica always
   retain the full array. Preference changes never enter a dirty/save/live-write
   path, and remote updates recompute the projection instead of updating a second
   cached collection. Checklist reading/editing swaps restore a measured visible
   block ID because filtered and full layouts cannot share raw content offsets.
2. **Save** (full content replace, since v1 explicitly excludes real-time merge):
   a. Serialize the edited native content back to Markdown.
   b. Convert Markdown → a Yjs v1 update entirely **on-device** (`Core/Yjs`: `MarkdownYjs.encode`, backed by the hand-written `YjsUpdateEncoder`).
   c. `PATCH /documents/{id}/content/` with the base64-encoded Yjs bytes.
   d. `PATCH /documents/{id}/` to persist the title.

   (Two requests total; no temporary document and no server-side file conversion. This supersedes an earlier design that created a temp document via `POST /documents/` with a Markdown `file` field, read back its converted Yjs, PATCHed it onto the real doc, then deleted the temp — that path depended on the backend's file-upload-to-Yjs conversion, which is gated behind `CONVERSION_UPLOAD_ENABLED` and off on the target deployment.)

   **On Docs 6** step c has no route. The collaboration server applies a PATCHed update incrementally, so the from-scratch document of step b would be *appended* to the existing one. The save is therefore a diff against the server's own state instead (`saveContentBody` → `BlockNoteIncrementalSave`):
   c′. `GET /collaboration/ydoc/v1/{org}/{id}?gc=true&awareness=false` (JSON) and integrate the bytes into a throwaway `YDoc` (fresh client id; destroyed after).
   c″. Project it, align the markdown's blocks with it (`BlockNoteAlignment` — an LCS over identical visible content keeps those blocks untouched; edits between anchors reconcile in place only for fully modeled blocks; the rest is removed/inserted), and let `BlockNoteWrite.applyEdit` mint exactly the difference.
   c‴. `PATCH` `{"update": base64}` — skipped when the server already reads like the markdown.
   The title PATCH (d) is unchanged, as is `saveDocumentContent`'s half-land contract. The written content is still exactly the editor's markdown (the same overwrite semantics). **This is not a merge of co-author edits:** the save diffs the editor's whole document against the server's state at save time, so a concurrent edit survives only if it lands inside the GET→PATCH window; an edit a co-author made to a block after this user loaded the document is reverted by the save unless the draft/conflict rules (`draftSyncDecision`, keyed on `updated_at`) catch it first. Those rules depend on Docs 6 bumping the document's `updated_at` when the collaboration server stores content, which upstream's UPGRADE.md says happens only when the collaboration server is configured with `YHUB_JWT_PRIVATE_KEY` (without it `updated_at` stops following editor edits) — a **deployment requirement**. **Docs 6's `updated_at` is not a content clock:** it moves when yhub's compaction calls `content-updated` (`YHUB_TASK_DEBOUNCE_MS`, 10 s by default, best effort) and on any Django PATCH — the app's own title PATCH included — while `formatted-content` reads the live yhub state. So within that window rule 2's date shortcut (`serverUpdatedAt <= baseline`) can call a co-author's fresh edit "not written since the baseline" and the save reverts it. Known gap, not fixed: closing it needs a content version for the baseline (e.g. the yhub state vector), a design decision. Only blocks the alignment can anchor are left untouched: unchanged non-opaque blocks, plus `unknownNode:*` and document-link blocks. Server blocks the markdown cannot spell (a table, callout, toggle, video, coloured paragraph, PDF preview, page break) are also left untouched when the user did not change them: `BlockNotePreservation` recognises each one's markdown shadow in the new blocks, puts the original back, and forces the pair into the alignment. An untouched nested list item is left in place too (`Rule.listTree`: one untouched new block with the same text — exact runs, or only the words where the replica's inline content does not read as runs, and then only when unambiguous — the same tree of nodes and, node for node, the same expressible props, placed only where the user left the base block that server item was, so look-alike siblings cannot swap), so a co-author typing inside it no longer loses keystrokes that land between the save's GET and PATCH, and two saves from one state can no longer leave two copies of it (TestFlight 0.103.0's "Another bullet point" / "Another bullet poin"). Still rebuilt from markdown: a nested item the user edited (re-indented, ticked, re-worded, moved); every one when the save has no recorded base; one whose text, tree or expressible props a co-author changed on the server since the base; and one whose subtree holds no text. Without a recorded base, and for a changed opaque/lossy block, the block is still rewritten from markdown. Which route a server gets is decided by `/config/` (release major ≥ 6, or a `…/ws/v1/{org}` collaboration URL) or, with nothing known, by the legacy PATCH answering Django's route 404 — nothing written, so the fallback is safe; it then fetches `/config/` once to learn the org (`docs` only when `config/` itself 404s; any other config failure fails the save retryably rather than guess an org) — memoized once the collaboration route answers, never over a collaboration route already set. The rooted path is app-authored: a UUID plus an `org` validated to `[A-Za-z0-9._~-]`; the host is always the user's own server.

**Known limitation:** this is a full-document overwrite with no conflict detection (no ETag/version check in v1). If someone edits the same document live in the web app concurrently, the loser's changes are silently overwritten. This is an explicit, accepted trade-off of choosing non-realtime editing — not hidden from the user; the Editor screen should make clear this isn't live-collaborative.

## Displayed document images

`MarkdownImageView` is shared by reading and editing. Its former `AsyncImage`
failed-load branch drew a link; entering editing destroyed the first view and
started another request. The parser already produced an `.image` leaf on both
surfaces. A regression test covers mode entry/exit and exact URL preservation;
this fixture needs no parser or Yjs encoding change; a differently shaped reported
image would require its own source/reproduction before changing classification.

`ImageLoader` is app-scoped in `AuthenticatedHomeContainer`, injected through the
view environment alongside `AttachmentLoader`. It owns requests across view
teardown and joins duplicates by full URL and `ImageCacheScope`. Every appearance
checks disk first, including offline and previously failed loads. Failures remain
image cards with a status, original URL, explicit Retry when online, and a
secondary Open image URL action. An image transport failure is retried once automatically
when loading resumes with the network allowed. ImageIO decodes thumbnails at most 2048 pixels
on the long edge; shared metadata validation rejects sources above 48 megapixels
before decoding, on both downloaded bytes and cold disk reads. Invalid image
bytes are never cached. Disk reads and thumbnail
preparation run asynchronously, with a decoded-image NSCache limited to 12 entries /
48 MiB of bitmap cost. Each live leaf retains its prepared image for its URL and
scope so unrelated load completions never re-decode its pixels in SwiftUI body.
The coalesced task returns the prepared pixels directly to each waiter; NSCache
is only for reuse and cannot evict a result before its leaf receives it.

`ImageTransport` is a small facade over the existing `ImageDataClient`, the
intentional networking seam for absolute document image
URLs, including explicitly approved external URLs. Its ephemeral URLSession has
no cookie storage, credential storage, or URLCache. Same-origin requests receive
only a snapshot of cookies applicable to that URL; external requests receive none.
No CSRF, Authorization, or Referer header is added. Same-origin redirects
reselect only eligible cookies from that immutable snapshot for their destination
percent-encoded path, and HTTP authentication challenges cannot consult a credential store. Every redirect must retain the
initial scheme, host, and port; userinfo URLs and non-http(s) schemes are refused.
An image download stops at 12 MiB, with or without Content-Length, and cancelling
the stream task stops any remaining transfer. TLS validation stays standard.

External consent is memory-only, scoped to the exact URL and session namespace,
and survives reading/editing switches within that loader. A changed URL, a new
loader after relaunch, or a cookie handover cannot reuse it. Previously cached
external bytes can display without renewed consent because no request is made;
if those bytes are evicted, a cold reopen requires another tap before fetching.
Neither Retry nor an offline-to-online transition bypasses consent.

`SessionStore.imageCacheSessionID` is an opaque random identifier, not an account
id or credential. It persists across authenticated launches and rotates at
`forgetSignedInIdentity` (cookie replacement, sign-in, sign-out), rather than
waiting for `/users/me/`. Handover namespaces remain memory-only until signIn
successfully saves the replacement cookies; the old persisted namespace is removed
at handover. Failed confirmation or a failed Keychain cookie write therefore cannot
pair B's cached images with A's restored cookies on relaunch. A mere expiry or
cancelled login before cookie replacement retains the namespace. Observable
scope reads immediately hide old loaded images in a surviving editor, and every
request completion checks its captured scope before writing disk or publishing.
The full cache is cleared at every cookie handover, sign-in and sign-out through
SessionStore's injected clearImageCache callback, preserving the existing main
behavior. RootView also clears it on sign-out. Pending photos
still branch ahead of this loader at both surfaces, and their owner-scoped store,
placeholder URLs, insertion guards, upload replay, and save holds are unchanged.
See [image storage](offline-and-sync.md#8-displayed-image-bytes-imagecachestore).

## File attachments (read side)

*Added 2026-08-07.* Generic file attachments — PDFs, Office documents, archives —
render as inline cards with a QuickLook preview and work offline. This is a
**view-layer** feature: it adds no parser, serializer or encoder change, and no
byte of a saved document moves.

### How an attachment reaches the app

The web editor stores an attachment as a BlockNote **`file`** block (a download
chip) or as docs' own custom **`pdf`** block. The app reads markdown, and the
server's exporter (y-provider's `blocksToMarkdownLossy`, BlockNote 0.51.4)
flattens them:

| Web block | Exported markdown |
|---|---|
| `file` | `[name](url)` on its own line (a caption becomes a following paragraph) |
| `pdf`, `showPreview: false` | `[name](url)` |
| `pdf`, `showPreview: true` (the web default) | **nothing** |

The last row is a real gap and is **accepted, not worked around**: BlockNote's
HTML→markdown serializer has no `<iframe>` handler, so the preview-on variant of
the pdf block serializes to an empty string. The app therefore never receives
those blocks — and, note, an app save has *already* been silently dropping them
since long before this feature, because the markdown it re-encodes never
contained them. Nothing here makes that worse, and nothing here fixes it either.

The fix is one line **on the server**, not in the app: patch
`src/frontend/servers/y-provider/src/blockSpecs/Pdf.ts` so `toExternalHTML`
emits the `<a>` variant it already builds for `showPreview: false` instead of the
`<iframe>`. Every web PDF then exports `[name](url)` and this feature picks it up
with no app change. Worth proposing upstream — a markdown export that silently
loses content is arguably a bug in `suitenumerique/docs`.

### Classification (`AttachmentDisplay.swift`)

Nothing in the markdown marks a link as an attachment, so the **url shape and
the server origin** decide. `parseAttachmentLink` accepts only a paragraph whose
entire trimmed text is one `[label](url)` link where:

* the link shape is unambiguous (no bracket in the label, no whitespace or
  unbalanced parens in the url, nothing before or after it) — the same
  conservatism `parseImageLine` applies, so anything doubtful stays ordinary
  prose, which is lossless;
* `siteOrigin(for: url) == serverOrigin`, the true origin comparison
  `imageLoadPolicy` makes. **This is what makes auto-download safe without a
  consent flow**: an off-origin url is never an attachment, so no request is
  ever issued for one, and a `/media/…`-shaped link on someone else's host
  renders as the plain link it always was;
* the decoded path is exactly the server's storage layout —
  `/media/{document-uuid}/attachments/{file-uuid}(-unsafe)?.{ext}`, the backend's
  `MEDIA_STORAGE_URL_PATTERN` — with both UUIDs validated and the extension
  ASCII-alphanumeric, and re-composing that path must reproduce the url's own
  decoded path (which is what rejects a trailing slash or a doubled separator).

An `-unsafe` key is normal, not suspicious: the backend appends it when a file's
sniffed bytes and declared extension disagree or its mime type is blocklisted (a
`.docx` sniffing as `zip` is the routine case). Only the server's
`Content-Disposition` differs; the bytes download and preview like any other.

Classification is scoped to `.paragraph` blocks because that is the only kind a
standalone link parses into. An attachment line *adjacent* to prose is part of a
multi-line `.unknown` block and deliberately does not classify — it is not a
standalone link, and a card there would misrepresent what a save writes back.

### Download, cache, preview

`AttachmentLoader` (app-scoped, built once per authenticated session in
`RootView` beside the collaboration manager, injected through the environment)
owns the whole path: disk cache first, then one GET through
`DocsAPIClient.mediaData(path:)`, which re-checks `isSameOriginPath` before
issuing it. It is app-scoped so two cards showing the same attachment
de-duplicate one download instead of racing two writers over one cache file, and
its state is keyed by **url string** — `applyLiveRemoteChange` reuses a
surviving `EditorBlock.id`, so a live edit can swap the url under a card that
never re-rendered from scratch.

Four rules in that loader are less obvious than they look, and each was a real
defect first:

- **Offline withholds the network, never the disk** (`loadIfNeeded(_:
  allowsNetwork:)`). The loader is session-scoped, so on a cold launch in
  airplane mode its table is empty and the disk is the only thing that can
  answer. Skipping the whole call while offline — the obvious reading of "don't
  ask the network" — rendered "Available when online" over bytes sitting in the
  cache, defeating the entire feature. A disk read costs no request, which is the
  only thing offline is meant to suppress.
- **A cancelled download is not a failure.** Tapping a block swaps the reading
  surface for the editing one, which tears the card's `.task` down mid-flight.
  Recording `.failed` there stranded the card behind a retry nothing had asked
  for. `loadIfNeeded` never auto-retries a *content* failure; a transport failure (no connection) is retried once
  when loading resumes with the network allowed.
- **A `.cached` state is re-validated against the disk, not trusted.** Eviction
  can delete the file while its card is still on screen (the reading surface is
  not lazy, so an off-screen card never re-runs its `.task`), and the tap path
  re-validates too — QuickLook on a deleted path is a blank sheet with no way
  back. The same call bumps the file's mtime, which is what makes eviction
  least-recently-*used* rather than least-recently-first-loaded.
- **The cache is keyed by document *and* file id.** The server's identity for an
  attachment is `{document}/attachments/{file}` and its access check is per
  document. Keying on the file id alone let a co-author of document B name a file
  id the reader had cached from document C and be served C's bytes with **no
  request at all** — so the server never got to say whether B has that
  attachment.

Views do no networking of their own; this is the object they ask. Bytes land in
`AttachmentCacheStore` (see [`offline-and-sync.md`](offline-and-sync.md)), and
`AttachmentCardView` renders one of four states from the pure resolver
`attachmentCardState` — downloading, cached (thumbnail via `QLThumbnailGenerator`
plus a full-screen `.quickLookPreview` on tap), failed (tap to retry), or
offline-and-uncached (an inert note that issues no request). Cached bytes outrank
offline, which is the entire point of caching them.

**Markup types are downloaded but never previewed** (`attachmentIsPreviewable`).
QuickLook renders HTML through WebKit, which fetches remote subresources — so
previewing a co-author's `.html` would disclose the reader's IP, User-Agent and
reading time to a host the *author* chose, which is exactly the leak the origin
gate and `imageLoadPolicy` close, reached by another route. The server agrees: it
serves these with `Content-Disposition: attachment` precisely so they are never
rendered in its own origin. The rule keys on the **extension**, not the
`-unsafe` flag, which is far too broad — a `.docx` sniffs as `zip` and is flagged
routinely. Such a card renders inert with "Can't be previewed here" rather than
disappearing: the document does link that file, and saying so is honest.

**Accepted residuals.** (1) File attachment requests still use the API client's
`URLSession` and follow redirects, so a same-origin attachment path that the
trusted server 302s off-origin can still leak. Displayed images now use the
separate origin-pinned `ImageTransport`; migrating file attachments is a separate
change. (2) QuickLook previews
co-author-controlled bytes for the types it *does* handle; that is the same
exposure Mail and Files accept (QuickLook renders out-of-process). (3) There is
no per-file read-side size cap and the whole file is buffered in memory
(`getRawData`), so a deployment configured well above the 10 MB default upload
cap could make merely opening a document expensive — streaming to disk with a
ceiling (`URLSession.download`) is the fix and is a named follow-up. The cache's
byte cap bounds the disk *except* for one most-recently-used entry, which is
never evicted by design (evicting the file just written would make the loader
re-download it forever).

**A tapped attachment card previews rather than entering edit mode.** The reading
surface's tap-to-edit gesture loses to the card's own `Button`, exactly as it
does for an off-origin image's tap-to-load. The states that draw no button
(downloading, offline-and-uncached, and a markup type) still enter editing, and
the toolbar's Edit action always does.

**The Attachments list (Profile → Files → Attachments).** Docs has no endpoint
that lists a user's attachments, so the list is built from what this device
already holds: `AttachmentsViewModel` reads every `DocumentContentCacheStore`
entry and `attachmentLibraryGroups` runs each body through
`parseEditorBlocks(_:serverOrigin:)`, keeping the `.attachment` blocks. The read,
decode and parse run **off the main actor** (a detached task over
`allContentsReader()`, which captures only the directory) — up to 50 files decoded
and parsed on the main actor stalled the push into the screen — and the newest
`load()` alone applies its result (`loadGeneration`). It uses
the same classifier the editor does, so the list can never show a link the
editor would draw as text, nor one on another host. Groups are per document,
newest sync first, and a file linked twice in one document is listed once. A
document whose deletion is queued is withheld, as every other list hides or
strikes it. The rows are the editor's own `AttachmentCardView`, sharing the one
`AttachmentLoader`, so a file downloads, previews and fails exactly as it does
inside its document. They are flattened into one `LazyVStack` of header and
file rows (`attachmentLibraryRows`) rather than nested in per-document
`ListSection`s: a section lays its children out in a plain `VStack`, which
would realize — and start downloading — every card of a document at once. Row
ids are scoped by document, since one file linked from two documents appears
under both. Loading issues no request and runs on every appearance, so
documents opened since the last visit show up. Limits that follow from the
source: a document never opened on this device is absent; the content cache's
50-entry eviction and sign-out clear apply to the list too; and, like Home's
metadata caches, the content cache is not cleared when a *different* account
signs in through the re-login sheet, so until the next sign-out the list can
show the previous account's cached documents. The read and parse run on the
main actor at each appearance — bounded by those 50 entries.

**Not yet.** Modelling `file`/`pdf` nodes in `YBlockProjection` (they project
`.opaque` today, which correctly keeps a document holding one out of live
editing while the default-off flag is off).

## File attachments (write side)

*Added 2026-08-07.* An attachment stops being a paragraph that happens to hold a
link and becomes a first-class leaf block, so a document saved from the app
renders on the web as a real file chip rather than as text.

### `BlockKind.attachment`, and why classification lives where it does

`parseEditorBlocks(_:serverOrigin:)` mints `.attachment(name:url:)` for a
standalone link that `parseAttachmentLink` accepts. The origin parameter
**defaults to `""`, which classifies nothing** — so every existing caller keeps
today's behavior, and the parameter is passed only where the distinction
matters: the encoder, and the editor.

Classification happens in `flushPending`'s single-line branch, *not* in
`parseClassifiedLine`, and that placement is the whole design. (The one sanctioned
exception is a link line nested under a list item, which `parseNestedLeaf` reads
in the main loop. It keeps the identity below, because whether such a line nests
depends only on its shape: it becomes `.attachment` with an origin and a `.paragraph`
holding the same link without one, at the same indent, and both serialize back to
the same line.) A `.attachment`
serializes back to the identical line and joins its neighbours exactly as the
paragraph it came from would (it is deliberately not column-zero-classified), so:

> for every input, `serializeMarkdown(parse(md, origin))` ==
> `serializeMarkdown(parse(md))`

That identity — `testAttachmentClassificationNeverChangesSerializedMarkdown` — is
what lets `canonicalMarkdown`, `draftSyncDecision`, `markdownSurvivesRoundTrip`
and the whole save coordinator go on parsing without an origin and stay correct.
Classify in `parseClassifiedLine` instead and it breaks immediately: an
attachment line adjacent to prose would split into two blocks under one parse and
stay one `.unknown` under the other, and the sync machinery would start seeing
differences that aren't real.

The origin reaches the encoder without threading through the save coordinator at
all: `MarkdownYjs.encode(markdown:serverOrigin:)` is called from exactly one
production site, `saveDocumentContent`, which runs on the `DocsAPIClient` actor
and reads `serverOrigin` straight off its own `baseURL`. It is **not** defaulted
there — a boundary that moves saved bytes should be impossible to cross by
forgetting an argument.

### The `file` node, and why never `pdf`

`.attachment` encodes as BlockNote's stock **`file`** node — a leaf with four
props (`backgroundColor`, `name`, `url`, `caption`; no `textAlignment`, no
`textColor`, no `showPreview`, no `previewWidth`) — for **every** attachment
type, PDFs included.

docs' own `pdf` node is deliberately never written. Its `showPreview` defaults to
true, and a `pdf` block with preview on exports to *nothing* through the server's
markdown exporter (see the read-side section above), so emitting one would make
the block invisible to this app and the next full-overwrite save would destroy
it. A chip the web renders is the safe parity point until the upstream export is
fixed.

The golden fixture (`YjsEncoderTests.testFileBlockIsLeafWithProps`) was captured
from real yjs 13.6.31 driving `@blocknote/server-util@0.51.4`'s
`blocksToYXmlFragment` into a `Y.Doc` whose clientID was pinned before any
content existed — and the harness was validated by reproducing the committed
image fixture byte for byte first. **The bytes are the authority on prop order**,
not the image block's prop list, which is longer and differently ordered.

> ⚠️ **This changed saved bytes.** A document containing a standalone
> same-origin attachment link — exactly what the web's `file` block and a
> preview-off `pdf` block export — used to re-save as a paragraph plus a link and
> now re-saves as a `file` node. That is the intended round-trip repair, but it
> is a representation change to web-authored content, the same class as the
> `_`-emphasis change, and it was signed off as such. Every pre-existing golden
> fixture is unmoved (they parse with the origin-less default).

### Inserting

Slash-menu **File** → `.fileImporter` (out of process, so no usage description
and no `project.yml` change) → `loadPickedAttachmentFile` → the same
`attachment-upload` endpoint and media-check poll photos use →
`insertAttachmentBlock`.

`insertAttachmentBlock` is a structural twin of `insertImageBlock` and must stay
one: it never resurrects a discarded document, never re-parses the whole document
(which would re-mint every block id and make a live forward diff as delete-all +
reinsert), and verifies against the **saved** markdown before committing — a
neighbouring fence can swallow the line even when the block array looks right.

`sanitizedAttachmentFileName` enforces the union of two unrelated requirements:
multipart-header safety (no quote, CR, LF) *and* markdown-label safety (no
brackets or parens), because the picked name is interpolated into both. Size is
refused from the file system's own answer **before** the bytes are read; the
server's 10 MB default remains the cap users normally meet, and it gets its own
copy rather than a useless "please try again".

File insertion is withheld offline and on a document with no server id (a
photo queues instead, through `PendingAttachmentStore`). In the **slash menu**
that is expressed as `SlashMenuAction.requiresImmediateUpload`, so a third menu item cannot forget it; the
formatting bar has one **Attach** button whose tap swaps the row for Close,
Photo and File (the same in-row swap the list and quote families use), each
gated by its own pure function — `canOfferPhotoInsertion` and
`canOfferAttachmentInsertion`, which a test holds in agreement with the slash
menu — so a future bar affordance still has to remember. Any file type is
accepted: the server sniffs the content and stores e.g. a zip under an
`-unsafe` key rather than rejecting it. Only one upload runs at a time.

**An attachment insert always takes the classic save path**
(`markDirty(forcesClassicPath:)`). `canEngageLiveWrite` inspects the projection
*before* an edit, so an insert that introduces a `file` node — which the
projection does not model — would otherwise pass the gate, integrate into the
replica, broadcast to peers, and then find the snapshot's own `isFullyModeled`
re-check false and never PATCH; the live branch also leaves `isDirty` false, so
no classic save would run either. Forcing the classic path downgrades the
document out of live editing, which is where a document holding a `file` node
belongs anyway — the read side already refuses to engage on one.

## Screens

From the design handoff (`ui_kits/docs-ios/`), implemented as SwiftUI views using the DesignSystem components, not copied HTML/JS:

- **Connect** — logo, "Welcome to Docs", server URL `TextField`, recent servers list, "Sign in to {host}" button → WebView login.
- **Home** — a system large-title navigation bar (subtitle = server host, new-doc toolbar action), `SearchField`, a horizontal Pinned carousel of `PinnedCard`s (emoji, title, excerpt on a tinted card) over a Recent section of Ledger `DocRow`s (tile, title + date, excerpt, page count) — **each document renders in exactly one of the two**: the recents feed is fetched unfiltered, so `recentsExcludingPinned` subtracts whatever the Pinned section is already drawing (pinned wins, Recent is the residue; keyed on membership of the rendered pinned list, never on the `isFavorite` flag, which paginated favorites responses make disagree — see `AGENTS.md`) — the system `TabView` (Schrift/Shared/Profile, with Profile last). Pinned is ordered most-recently-edited first (`stablePinnedOrder`, id tie-break), applied to the server answer before the pin overlay, so revalidations don't reshuffle it; list changes animate with `.snappy`, off under Reduce Motion. Compact Home pushes Search on its own navigation stack; regular-width Home searches inline in its split sidebar. Search hits `GET /documents/search/?q=` with recent-search history, Shared lists documents shared *with* the user (`GET /documents/?is_creator_me=false`) with an offline metadata cache, each row enriched best-effort with its members' avatars and the sharer's name from that document's `accesses/` (the "shared by me" scope was removed — the list API has no distinct by-me shared query), Profile shows the current user via `GET /users/me/` in a row that pushes the **Account screen** (`AccountScreen`, trimmed to the fields `/users/me/` actually returns; it renders an explicit unavailable state rather than a placeholder name when the user hasn't loaded), with the independent appearance/theme/language pickers, server + server-version rows, sign-out, and the Work Offline toggle.
  - On a compact stack every editor is pushed with the system's standard slide: the stacks push a `DocumentEditorRoute` and register `navigationDestination(for: DocumentEditorRoute.self)` in `MainTabView`. Documents used to zoom open from their row (`.navigationTransition(.zoom)`), but popping the zoom on iOS 26 intermittently left the navigation bar in its collapsed large-title state, so Home's title went missing on return; the zoom was removed rather than worked around (2026-11-03). The iPad split view selects rather than pushes.
  - Search results push the same `DocumentEditorRoute` as Home rows. The editor hides the native tab bar; Back restores Search (with its retained query), then Home. Shared and Profile retain their own stacks, including Profile → Account. Search's system field is always exposed in the navigation bar, with its localized prompt; Home's shortcut is one VoiceOver button.
  - The shell retains `SearchViewModel` across pop/re-entry and tab switches (query, in-memory results, recent terms). Search remains server-backed. Shared `OnlineAvailability` reads Work Offline and the live network path: Home's compact shortcut, pushed Search field and iPad inline field disable with a localized explanation while offline. Home shows cached rows instead of treating retained search results as an offline index. Search and Quick Access suppress requests in their view models too; availability/request generations reject late results and errors across reconnect. Query state and the PR #148 navigation structure survive these transitions.

- **Offline editor controls** use the same injected availability state. Share is hidden in the toolbar and Options; Version history is disabled with an explanation, including in an already-open Options sheet. A transition dismisses a presented Share/history sheet. Reconnect restores controls without recreating the editor. Cache/draft restoration precedes the read guard; uncached content explains that it must first be opened online and cannot enter editing or show Empty document. A cached empty body remains editable. Transport load failures use that explanatory state; permission/authentication/conflict/save handling is preserved. Availability tokens reject stale editor/history responses and superseded loads cannot clear a newer spinner.
- **Editor** — one **system toolbar** in both modes (`.inline`, no navigation title, since the document title is an in-canvas header): back, then trailing Edit/Share/Options, with `editorToolbarActions` swapping **Edit** for **Done** (`finishEditing`) while editing. The save status lives in the shared document header's status slot (`SaveStatusIndicator`, driven by the unchanged `saveStatusDisplay` precedence, falling through to the reading sync caption when it is `.none`); it used to be a slim row pinned above the canvas, which had no reading-mode counterpart and appeared out of nothing on the first keystroke. Presence has one home rather than two: the shared header's `PresenceBar` draws it in **both** modes, so the Options button's editing-only count badge is gone — `presentedPeerCount` (was `presenceBadgeCount`) survives as the one rule for whether peer state is fresh enough to show at all, now applied on both surfaces (the reading one used to draw its avatars offline). The document title is a large content header (`DocsFont.title1`, `-0.02em` tracking) with `LinkReachPill` + the status slot + `PresenceBar` beneath it — `EditorDocumentHeader`, drawn identically by **both** canvases, editable only while editing — above the rendered/editable blocks; reading and editing share one style table (`EditorBlockStyle`: metrics, `blockTextAppearance`, `editorBlockDecoration`, `EditorBlockAdornment`) and one scroll anchor (`EditorScrollAnchorStore`, a content offset snapshotted at the swap — `EditorScrollTarget` only names the editing canvas's rows for its own `ScrollViewReader`), so tapping a block places a caret rather than re-flowing and re-scrolling the page — see `docs/design-system.md`; a Subpages section (hierarchy-glyph eyebrow, title-only rows); floating formatting toolbar (add block/text style/list/quote-or-code/attach — the text-style (bold/italic/link), list and quote/code buttons apply a remembered default on tap and offer their family on a long press; Attach swaps the row for Photo and File on a tap). The in-editor **Pages** drawer (`PagesTreeDrawer`) is back — the revised handoff specifies it: a leading slide-in tree of the document's nested subpages, opened from the toolbar, loading each level lazily through `GET documents/{id}/children/` and `DocumentChildrenCacheStore` (cache-first, so it works offline for levels already seen; "work offline" skips the network entirely, and creating a page never appends to — or caches — a level that was never loaded, which would hide the document's real children in the store the Subpages list shares). Pages created on this device are folded into the drawer's levels at **read** time (`mergedChildren`, from the session-scoped `pendingLocalDocumentsByParent`) rather than written into that shared cache, so they survive a level refetch and a view-model recreation without ever being served to the next account; the disclosure arrow follows `numchild > 0` **or** a level already held, since a locally-created page has no server bookkeeping to report one. Subpages remain reachable from the reading canvas's Subpages list as well. A separate **"In this document"** sheet (`DocumentOutlineSheet`, from the Options sheet's first row or Command-F) outlines the *open* document: its level 1-3 headings (`buildOutline`), find over the blocks' visible plain text (`findMatchingBlockIDs`, case- and diacritic-insensitive, inline markdown stripped by the same `InlineMarkdown.layout` scanner the editor uses), per-section match counts, and wrap-around previous/next (`steppedMatchIndex`). It scrolls whichever canvas is showing through a `DocumentScrollRequest` the editor hands to the reading surface's `ScrollViewReader` or to `BlockEditorView`, which resolves the model block id to its native input row. The outline keeps the canvas interactive behind it, so every other presentation the editor owns (sheets, pickers, alerts, the Pages drawer) is driven through an `OutlinePresentationGate`-held binding: a request made while the outline is on screen closes it and presents from its dismissal. That includes attachment cards' QuickLook previews (handed to the editor through the `attachmentPreview` environment action), and every navigation to another document goes through `navigate(_:)`, which closes the outline and, if it is on screen, runs the push from its dismissal (`OutlineHeldNavigation`). Reopening a document scrolls the reading surface back to the block the reader left at (`ReadingPositionStore` / `ReadingPositionSession`: a block id plus a text fingerprint per server-and-document, capped at 200 and cleared on sign-out) and offers a self-dismissing "Back to top" glass pill (`BackToTopPill`); a jump from the outline ends that pill and settles the restore, so content arriving later cannot pull the page away from where the outline sent it (`ReadingPositionSession.noteDeliberateJump`). `AvatarGroup` renders collaborator stacks in the Shared tab's rows (`SharedRow`) and the editor's live-presence bar (`PresenceBar`); the mock's in-editor emoji reactions were not implemented.
- **Share sheet** — invite by name/email (`GET /users/?q=`), member list (`ShareMemberRow` with role picker: Reader/Commenter/Editor/Administrator/Owner — Commenter included even though the mock only shows Admin/Editor/Reader, since it's a real backend role), link reach picker (Restricted/Authenticated/Public via `LinkReachPill`), Copy link.
- **Options sheet** — Pin/Unpin, Copy link, Share, Delete, and **Version history** (read-only list + "Restore on the web"; see [`design-system.md`](design-system.md)). Copy as Markdown and Duplicate were removed (the `duplicate/` endpoint with them). *Still deferred to a later iteration*: Download (PDF/Word/ODT — no mobile-appropriate endpoint investigated yet), Present.

**iPad**: the same `TabView` shell, whose documents tab hosts a `NavigationSplitView` (document list sidebar + detail/editor pane) instead of the iPhone single-column stack — extrapolated from the design's tokens/components since the handoff only mocked iPhone (390×844) layouts. iOS layout constants (status bar 54px, nav bar 44px, tab bar 49px, home indicator 34px, row min-height 44px, gutters 16/20px) are implemented as native safe-area-driven layout, not hardcoded pixel values, since real devices vary.

**iPhone Duo (foldable, iOS 27.1)**: no layout of its own — the size classes already pick the right shell. Folded, the cover screen is a compact-width iPhone, and iOS moves the status bar, navigation/toolbar items and tab bar into a vertical rail on one side (`UIVerticalBarBehavior.automatic`); the app keeps the system default and lets the rail compress its own items when space runs short. Unfolded, the inner screen is regular width, so the docs tab is `HomeSplitView`. The crease is reported as a `.division` reserved region (`FoldLayout`), queried with `.includeInactive` because a Duo lying flat unfolded reports its crease *inactive* and the default query drops it. The split view keeps the system sidebar width: in the ~867pt the split view gets beside the system side rail, a sidebar sized to end at the crease (~455pt) leaves only ~411pt of detail, and `NavigationSplitView` then refuses to tile, hiding the sidebar or overlaying it on the document. Instead the detail — the open document and the empty "Select a document" state — is padded onto whichever side of the crease is wider within it, so no line straddles the fold with the sidebar shown or hidden. A horizontal crease, or one outside the detail, leaves the layout alone. All 27.1 API sits behind `#if canImport(SwiftUI, _version: 8.0.85)` plus `#available(iOS 27.1, *)`, so older SDKs (CI's Xcode) compile it out and older OS versions skip it.

## Personal themes

White, Mist and Paper are local app-wide palettes, persisted independently of
System/Light/Dark appearance. `ThemeStore` defaults to White for new and existing
installs, reads without startup writes, and ignores unchanged selections.
`SchriftApp` owns the store and publishes a defaulted `AppTheme` environment value.
Views use `theme.colors`; pure component and editor resolvers receive the same theme
explicitly through `DocsPalette`, preserving semantic token identity even when two
legacy hex numbers coincide. Adaptive colors resolve system appearance through
native traits, with no global mutable palette.

Theme changes retain screen/navigation/view-model identity. The UIKit editor includes
the theme in `BlockTextStyling` and repaints the existing text view and link attributes;
it does not replace the source buffer, caret, focus or scroll state. Theme selection
never marks a document dirty, schedules a save, modifies authored content/exports,
writes server preferences or changes collaborator awareness colors. Profile and Account
use open sections rather than enclosing cards. The iPad sidebar uses the deeper neutral
surface while the full-width editor stays on the page surface. Native system materials,
authentication web content and keyboards keep platform behavior. See
[`design-system.md`](design-system.md) for the palettes, contrast adjustments and native
fixture verification.

## Design tokens

Ported from `tokens/*.css` in the handoff bundle into a `DesignSystem/Tokens` module (Color/Font assets + Swift constants), using the **default indigo theme** (not the DSFR "Bleu France" gov override):

- Brand fill `#5E5CD0`, hover `#4844AD`, soft `#DDE2F5`, subtle `#EEF1FA`
- Text: primary `#25252F`, secondary `#5D5D70`, tertiary `#69697D`, disabled `#A9A9BF`
- Surfaces: page `#FFFFFF`, sunken `#F8F8F9`, muted `#F0F0F3`
- Feedback: info `#0069CF`, success `#027B3E`, warning `#BC4200`, danger `#D7010E`
- Typography: Inter (system fallback), iOS HIG scale mapped ~1:1 to SwiftUI `.largeTitle/.title/.title2/.headline/.body/.callout/.subheadline/.footnote/.caption`
- Spacing: 4px base unit scale (`2xs`…`5xl`)
- Radius: 4px (controls) → 8px → 12px (badges/cards) → 16–24px (sheets/modals) → pill (avatars/segmented control)
- Icons: Google Material Symbols Outlined — **shipped 2026-07-11 by bundling the variable font** (a ~18KB Apache-2.0 subset of the 77 glyphs used, FILL axis only), referenced by the typed `MaterialIcon` enum and rendered by `MaterialSymbol`. An earlier pass mapped each glyph to an approximate SF Symbol, but that was a visible deviation from the handoff, so the app now ships the exact Material glyphs. See [`design-system.md`](design-system.md).

Static assets (logo, illustrations, doc-type icons) are copied from the handoff's `assets/` folder into the Xcode project's asset catalog during the scaffold PR.

## Error handling

- `401` → mapped to `.sessionExpired`; the shared client's `onSessionExpired` hook raises `SessionStore.needsReauthentication`; a hidden web re-login is tried first, and only if it cannot finish unattended is a re-login sheet presented over the current screen. List/editor view models keep showing cached/local content (401 is never rendered as "offline"); an already-open editor recovers on its next refresh or save. The Connect screen is not shown for 401 — only explicit sign-out returns there.
- `403` → permission-denied inline state; in practice this should be rare since UI affordances are gated by the `abilities` dict already.
- `404` → "not found / no longer available" state (covers soft-deleted-past-cutoff documents, which the backend intentionally 404s rather than 403s to avoid leaking existence).
- `429` → respect `Retry-After` if present; otherwise simple backoff with a banner ("Too many requests, try again shortly").
- Network failure → retry affordance on the failed view. Since 2026-07-03,
  previously-opened documents are content-cached on-device and readable offline,
  and document lists — Home (the unfiltered recent feed plus pinned), Shared,
  editor sub-pages — are metadata-cached and shown instantly with silent
  background revalidation. A **failed save is not a lost save**: a transport or
  5xx failure classifies to `.pendingSync`, keeping the write-ahead draft for the
  reconnect/foreground/launch replay, which is what makes editing offline safe
  (2026-08-01). Creating one offline landed 2026-08-02: it is minted with a client-side
  id and POSTed by the replay on reconnect.
- Save conflicts *are* detected and asked about (`draftSyncDecision` + the conflict pill,
  #72–#78); they are never auto-merged, and never silently swallowed.

## Testing

- Unit tests for `DocsAPIClient` and Codable models against mocked `URLSession` responses (fixture JSON matching the real serializer shapes documented above).
- Unit tests for the on-device Markdown→Yjs encoder (`Core/Yjs` — `YjsEncoderTests`, `MarkdownYjsTests`, `InlineMarkdownTests`, verifying valid Yjs-v1 update bytes) and for the save flow (`DocumentSaveTests` / `DocumentSaveCoordinator*Tests`, verifying `saveDocumentContent` issues `PATCH /content/` then `PATCH /{id}/` for the title; `CollaborationYDocSaveClientTests` for the Docs 6 route choice and request shapes, with `BlockNoteIncrementalSaveTests`/`BlockNoteAlignmentTests` checking at the document level that the incremental update makes the served state read exactly like the saved markdown).
- `BlockNote056*Tests` inline eight yjs 13.6.33 / BlockNote 0.56 captures from the phase 0 S3 spike (the editing-scenario harness, not object storage), checking seed XML and every incremental edit (17 steps) with nothing pending.
  These tests hold XML and update bytes only; the captures' text deltas are not committed yet. B2's cursor positions are pinned separately by `YRelativePositionTests` (relative positions captured from yjs 13.6.33).
- SwiftUI Previews for every DesignSystem component, serving as the visual QA catalog (mirrors the handoff's `*.card.html` files).
- No live integration tests against docs.llun.dev in CI — it's a personal server; verify manually against it during development instead.

## Build sequence

High-level phases; the implementation plan will break each into small, separately-reviewable PRs/commits per the user's request:

1. Xcode project scaffold, `.gitignore`, design tokens (colors/fonts/spacing/radius), copied static assets.
2. DesignSystem components + SwiftUI preview catalog.
3. Networking layer + WKWebView auth (SessionStore, DocsAPIClient, error types).
4. Connect screen, wired to real auth.
5. Home screen, wired to real document list/search/favorite APIs.
6. Editor screen — read-only rendering of `formatted-content`.
7. Editor screen — editing + save (on-device Markdown→Yjs encoding; `PATCH` content then `PATCH` title).
8. Share sheet + Options sheet, wired to real sharing/permissions APIs.
9. iPad adaptive layout (`NavigationSplitView`).
10. Polish: empty states, loading states, error states, pull-to-refresh.

## Open risks / known limitations (carried forward, not hidden)

- Save is a full-content overwrite with no conflict detection — concurrent edits in the web app can be clobbered.
- WebView-based login means periodic re-auth; no silent token refresh.
- Save depends on the on-device Yjs encoder (`Core/Yjs`) producing bytes the backend's Yjs content-validator accepts and BlockNote can interpret. If the backend's Yjs/BlockNote schema changes, saves could break — worth verifying against the target server and surfacing a clear error if the server rejects the content. (Byte-exact golden tests against the real Yjs library guard the encoder itself.)
- ~~Material Symbols vs SF Symbols decision deferred to implementation (visual fidelity vs native idiom trade-off).~~ **Resolved** — the app bundles the exact Material Symbols font (see the notes at the top of this document and the Icons bullet); no longer open.
- Download/export remains explicitly deferred past v1. Version history
  **browsing** shipped (read-only); **restoring** a version is still
  deferred — see [`design-system.md`](design-system.md) §9.3.
