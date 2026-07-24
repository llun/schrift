# Schrift — Architecture & Design

> **Living design document.** This is the full architecture and design rationale
> behind Schrift, kept current with the shipped app — update it in place when
> behavior changes. [`CLAUDE.md`](../CLAUDE.md) is the shorter operational
> "how we write code here" companion. Two sibling docs go deep on areas this one
> only summarizes: [`offline-and-sync.md`](offline-and-sync.md) (on-device
> caching and background revalidation) and
> [`design-system.md`](design-system.md) (the design-system refresh — adaptive
> dark theme, in-app localization, and read-only version history).

Notable behavior that post-dates the original v1 scope and is reflected below:

- **Saving is fully on-device.** The app builds a byte-exact Yjs update with a
  hand-written encoder in `Core/Yjs` and `PATCH`es it directly — no temporary
  document is created.
- **Offline reading and lists.** Previously-opened documents and every document
  list are cached on-device and render instantly with silent background
  revalidation; a **Work Offline** toggle (`schrift.workOffline`, Profile) forces
  read-only offline mode. Offline *editing* is out of scope. See
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
  chose (`imageLoadPolicy`). Redirect-after-load — a same-origin URL the trusted
  server 302s off-origin — is a known accepted residual.
- **Design-system refresh.** A complete adaptive dark theme, in-app localization
  across 11 languages with live switching, a restructured Profile, layout-fidelity
  work, and read-only version history browsing. In-app version *restore* and
  document-content translation remain out of scope (restore is a "Restore on the
  web" link). See [`design-system.md`](design-system.md).
- **Iconography.** The app bundles the exact Material Symbols font (a ~18KB
  Apache-2.0 subset, FILL axis only), rendered via `MaterialIcon`/`MaterialSymbol`.

## Summary

A native SwiftUI iOS/iPadOS app that acts as a client for [La Suite Numérique Docs](https://github.com/suitenumerique/docs) ("Impress"), targeting a self-hosted instance at `docs.llun.dev`. Visual design comes from the `Docs iOS Design System` Claude Design handoff bundle (imported from `Docs iOS Design System-handoff.zip`). v1 scope: browse/search documents, view rendered content, basic non-realtime editing (save replaces content), and sharing/permissions management. No real-time collaborative editing.

## Goals

- Browse, search, pin/favorite documents from docs.llun.dev on iPhone and iPad.
- View a document's rendered content natively.
- Edit a document's text and save changes back to the server.
- View and manage sharing: member roles and link visibility.
- Match the visual design system from the handoff bundle (indigo theme, iOS-native chrome).
- Install directly to the user's own devices via Xcode (no App Store distribution required).

## Non-goals (v1)

- Real-time collaborative *writing* (typing that other clients see live) — the two-way write path is now **fully wired end to end** (C2a's sync engine + C2b's snapshot-save mechanism + **C2c**'s editor wiring: a keystroke forwards to the replica and broadcasts, a peer's edit applies caret-preservingly, and a ~60 s debounce PATCHes a full-state snapshot), but it is **opt-in** — everything above runs only behind the default-off `schrift.liveCollaboration` flag, so shipped behavior is unchanged until a user enables it via **Profile → Preferences → "Live collaboration"** (C3; default off pending the on-device WebSocket verification). Presence avatars are live. See "The Yjs CRDT core" → "Live editing (C1)", "Two-way sync engine (C2a)", "Live-snapshot save (C2b)", and "Editor wiring — the write path complete (C2c)". With the flag off, outbound edits keep saving via the single full-overwrite HTTP PATCH exactly as before.
- Offline editing/sync queue. (Offline *reading* of previously-opened documents
  was added 2026-07-03; editing still requires connectivity.)
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
- The backend exposes `GET /documents/{id}/formatted-content/?content_format=markdown|html|json` for **reading** a converted snapshot, and `PATCH /documents/{id}/content/` for **writing** — but the write endpoint requires raw base64 Yjs bytes, not markdown/HTML.
- File-to-Yjs conversion (`Converter().convert(..., accept=YJS)`) is wired into document **creation only** (`POST /documents/` with a `file` field) — confirmed NOT present in the update path (`perform_update`/`DocumentSerializer.update`).
- Sharing model: document roles `reader < commenter < editor < administrator < owner` (`RoleChoices`); link reach `restricted < authenticated < public` (`LinkReachChoices`); link role `reader < commenter < editor` (`LinkRoleChoices`). Matches the design system's `LinkReachPill`/`ShareMemberRow` components exactly.
- API base path `/api/v1.0/`, `PageNumberPagination` (default page size 20, max 200), DRF throttle scope `document` at 80/min default.

## Architecture

Native SwiftUI app, iOS 18+ minimum deployment target, universal (iPhone + iPad). MVVM-ish: SwiftUI views + `@Observable` view models + an async/await networking layer. No third-party dependencies planned for v1 beyond what's needed for Markdown parsing/rendering (evaluate Apple's `AttributedString(markdown:)` first before reaching for a package).

```
Schrift/                  (originally planned as "DocsIOS/"; renamed 2026-07-01)
├── App/                  — app entry point, root navigation (NavigationStack on iPhone-width, NavigationSplitView on iPad/regular-width), swipe-back restorer
├── DesignSystem/         — tokens ported from tokens/*.css (indigo theme), and components: Button, IconButton, Avatar, AvatarGroup, Badge, DocIcon, SearchField, Switch, TextField, NavBar, TabBar, ListRow, ListSection, DocRow, LinkReachPill, ShareMemberRow, OfflineBanner
├── DesignSystemCatalog/  — visual QA catalog of every component
├── Core/
│   ├── Networking/       — DocsAPIClient (URLSession + async/await), endpoint definitions, Codable models mirroring DRF serializers, error types
│   ├── Auth/             — SessionStore (Keychain-backed session-cookie + server URL persistence, re-auth flag), SessionCookies (Codable HTTPCookie snapshot), WebLogin free functions (login-URL/completion detection, cookie sync), KeychainStore
│   ├── Collaboration/    — Hocuspocus/Yjs live-collaboration layer (wire codecs, WebSocket transport, session state machine, presence, and — C1 — a manager-owned per-document Yjs replica fed by inbound updates + the `LiveEditingBridge` that reflects it into the editor), dormant behind the default-off `schrift.liveCollaboration` flag
│   └── Yjs/              — the Yjs layer, two halves: the on-device Markdown→BlockNote→Yjs *encoder* (hand-written lib0/Yjs-v1 wire format) that builds the base64 content payload for saves, and the *CRDT core* (lib0 decoder, update decoder, struct store + YATA integration, the B3 store encoder `YStateEncoder`, and the B5 replica→editor projection `YBlockProjection`/`InlineMarkdownWriter`) — see "The Yjs CRDT core"
├── Features/
│   ├── Connect/          — server URL entry, recent servers, WebLoginView (WKWebView OIDC login sheet), session-expiry re-login sheet
│   ├── Home/             — document list: pinned/recent, segmented filter (All/Shared/Pinned), favorite toggle, offline list cache
│   ├── Search/ Shared/ Profile/ — the other three tabs (all real features)
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
replica back into the editor's block/markdown vocabulary (B5), and turn a **local**
editor edit into local Yjs operations plus the incremental update they mint (B6). The
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
| `YContent` | the live, mutable content model (splice, merge) |
| `YStruct` / `YItem` / `YGC` / `YSkip`, `YType`, `YDoc` | the document graph |
| `YStructStore` | structs per client, binary search, splits |
| `YDeleteSet` | delete ranges, and applying an update's delete set |
| `YTransaction` | transaction lifecycle + the merge cleanup that runs after every update |
| `YStructIntegrator` | the driver: dependency ordering, pending structs, retry |
| `YBlockProjection` / `InlineMarkdownWriter` | the **read-out** side (B5): projects an integrated replica into BlockNote-vocabulary `ProjectedBlock`s and then into the editor's markdown. See "Projecting the replica" below |
| `YWrite` / `TextSpanDiff` / `BlockNoteWrite` | the **write-in** side (B6): local list/map mutation primitives, a char-level self-describing text-span diff, and the block-level edit driver that turns old/new BlockNote blocks into local ops + an incremental update. See "Local-edit transactions" below |

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
  `replicaDidChange()`, which — only when the editor is engageable — resolves the replica to
  `(rendered blocks, markdown)` via `YBlockProjection.renderedEditorDocument` (the escalated
  rendering `projectedMarkdown` settled on, so the applied blocks and the baseline are
  consistent by construction), diffs it against the current blocks by BlockNote id
  (`liveChangeSet`), and applies the change through the editor's surgical funnel. Surviving
  blocks keep their `EditorBlock.id`, so SwiftUI identity, focus, and scroll survive.
- **`EditorViewModel.applyLiveRemoteChange` is the one content-swap funnel that is NOT
  `install(...)`.** `install` re-mints every block id and nulls the caret (correct for a
  full server-wins swap); the live funnel instead mutates blocks in place, recomputes the
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

### Local-edit transactions (B6)

C1 wires the *read* side into the editor; **B6 is the write side** — a pure `Core/Yjs`
layer that turns an editor edit (old blocks → new blocks) into local Yjs operations
against a replica and encodes only the incremental update those operations minted. It
has **zero runtime effect on its own**: nothing calls it until C2 threads it through
the collaboration session, transport, and save coordinator.

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
  inside one transaction, and returns `YStateEncoder.encodeStateAsUpdate(doc, since:
  <the state vector snapshotted before the transaction>)` — an update containing only
  the structs this edit minted. **Move is v1-coarse**: a survivor whose relative order
  changed is rebuilt whole (delete + re-insert after its new `left`) rather than
  relocated in place; reorders are rare in practice and remain covered by
  full-snapshot fixtures, so this trades minimality for simplicity.
- **The from-empty byte-identity anchor.** `applyEdit(old: [], new: blocks)` must be
  byte-identical to `BlockNoteYjs.encode(blocks, clientID:)` — the shipping golden
  encoder, itself already pinned to real yjs. This is B6's strongest correctness gate:
  it proves the builder reproduces the exact document shape yjs authors (item order,
  origins, parents, clocks) for every block type, because both encode the same store
  shape. It holds because `insertBlock` mints items in the same order the golden
  encoder does — blockGroup, then per block the container, the content element, the
  `xmlText` and its run pieces, the element's props, then the container's `id` — and
  each `YWrite` primitive mints sequentially, so clocks/origins/parents (and therefore
  the encoded bytes) coincide.
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
- **Verification.** A session-local differential-fuzz harness (never committed — the
  zero-dependency rule) drove roughly 26,000 seeds / 400,000 oracle-verified renders
  against node yjs 13.6.31 across three lanes — BMP text edits, concurrent multi-peer
  convergence, and interop with `mergeUpdates`/gc/`diffUpdate` — and found zero
  divergences after fixing one bug: an early version diffed at raw UTF-16-unit
  boundaries and could split a surrogate pair, which the fuzz caught; the code-point
  snap described above is the fix.

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
  is deliberately **ungated on `canWriteReplica`** — offering a subset of our own
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
  replica (inside that call's own local transaction), broadcasts the returned
  incremental update via the session's `broadcast(update:)`, and bumps a counter that is
  **deliberately separate from the inbound signals**: `localEditVersion`, never
  `replicaVersion`/`remoteChangeToken`. Those two are what a future editor integration
  would read as "a remote peer changed the document" — bumping them for our own edit
  would make something read-apply the keystroke we just made ourselves. This is
  local-echo suppression, and it is the load-bearing rule of the whole write path.
- **One write-eligibility gate, shared by read and write.** `canWriteReplica` — a
  replica exists, its initial sync has landed, it carries no unintegrated
  `pendingStructs`/`pendingDs`, and it hasn't fail-safed — already gated
  `projectedReplica` (C1/B5); C2a reuses the identical predicate for `applyLocalEdit`
  (throws `CollaborationWriteError.notWritable`, mutating nothing, when it fails) and for
  `encodeSnapshotForSave(for:)` (returns `nil` instead of a snapshot). A
  `BlockNoteWrite.applyEdit` throw — a malformed replica — is handled exactly like an
  inbound decode/apply failure: the replica is destroyed, `replicaFailSafe` latches
  permanently (so this document's replica is never rebuilt or trusted again this
  session), and the error is rethrown, never trapped — clocks are peer/edit-influenced
  and this store must not crash on them.
- **`encodeSnapshotForSave(for:)`** is the other half of the eventual live-snapshot save
  path: a full `YStateEncoder.encodeStateAsUpdate(replica, since: [:])` of the document
  when `canWriteReplica` holds, `nil` otherwise ("no trustworthy snapshot"). Nothing
  calls it yet — the classic full-overwrite markdown-encode save is completely unchanged
  until C2c wires this in as its replacement source of truth.
- **Verification.** Deterministic two-peer integration tests (`LiveSyncConvergenceTests`)
  drive two real `DocumentCollaborationManager`s through a paired fake-socket relay and
  assert convergence at the **projected-document** level (never store bytes) across the
  handshake, one-way edit propagation, and concurrent edits from both peers. A
  session-local differential-fuzz harness (never committed, per the zero-dependency
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
  — but the content PATCH sends the caller's snapshot **bytes verbatim** (never
  `MarkdownYjs.encode`) and tags the JSON body with **`"websocket": true`**, which the docs
  backend uses to distinguish a live-collab snapshot from a REST full-overwrite. It reuses
  `setContent(…, viaWebSocket:)`; with `viaWebSocket` false (the default) the classic content
  body is byte-identical to before.
- **`DocumentSaveCoordinator.enqueueLiveSnapshot(documentID:snapshot:projectedMarkdown:title:baseline:)`**
  queues that save. A live snapshot pushes CRDT **bytes**, but the reconcile machinery is
  markdown-based, so the coordinator carries the **projected markdown** (what the server
  renders from the snapshot) as the `PendingSave.markdown` and the draft body. That single
  choice makes `finish` unable to tell the two paths apart: the write-ahead draft, the
  enqueue-hold + single-writer conflict rule, latest-wins coalescing, the
  `lastConfirmedPushMarkdown` stamp, the content-cache write, and `.pendingSync`/`.failed`
  classification are all **reused unchanged**. The only branch is in `start`, which sees a
  non-nil `PendingSave.liveSnapshot` and calls `saveLiveSnapshot` instead of
  `saveDocumentContent`. On success the projected markdown is stamped as
  `lastConfirmedPushMarkdown`, so a later **downgrade to a classic markdown save of the same
  body** reconciles via rule 1 (or rule 2's body fallback), never a false conflict against
  pre-live state.

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
  manager only returns a projection when `canWriteReplica` holds), and on top of that
  the write path additionally requires `projection.isFullyModeled` — a document with
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
- **`LiveEditingBridge.forwardLocalEdit()`** re-checks `canEngageLiveWrite` against a
  freshly read projection (never a cached engagement flag), builds `new` from
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
  to equal the projection**, and nowhere else: on every engage (`replicaDidChange`,
  including a no-op empty diff) and again after every `applyLiveRemoteChange`. A local
  forward advances it itself (to `new`). This is why a peer's edit landing between two
  of the user's own keystrokes never desyncs the next local diff — the baseline is
  re-synced the moment the remote change is folded in, before the next keystroke can
  read it.
- **That "before the next keystroke" guarantee needs the read-apply to be _synchronous_
  with the integrate — a deferred re-apply is a correctness bug.** `replicaDidChange` is
  driven two ways. The obvious one is the view's `.onChange(of: collaboration
  .replicaVersion(for:))`, but that fires on a *later* SwiftUI turn than the one in which
  `DocumentCollaborationManager.applyReplicaUpdate` integrated the update and bumped the
  version. A keystroke slotting into that gap runs `forwardLocalEdit` with `old` still
  describing the *pre-update* projection while the replica has already moved — and
  `BlockNoteWrite.applyEdit` maps each `old[index]` to the replica's live container **by
  position**, so a structural remote change in the window (a block removed or inserted,
  shifting positions) mis-applies the local edit and broadcasts a corrupt update to every
  peer (concretely, a phantom duplicate block). The fix makes the re-apply run in the
  **same main-actor turn** as the integrate: the bridge registers a per-document observer
  with the manager (`setReplicaObserver`), and `applyReplicaUpdate` fires it immediately
  after bumping `replicaVersion`, so the editor and `lastAppliedBlocks` are caught up to
  the integrated replica before any keystroke can run. Approaches that instead "catch up
  the remote change first, then forward" were rejected: a `replicaDidChange` run *after*
  the keystroke would overwrite `blocks` with the projection and lose the un-forwarded
  keystroke (`applyLiveRemoteChange` is a server-wins fold, not a three-way merge); the
  synchronous re-apply avoids the merge entirely because it always runs while the editor
  holds no un-forwarded local edit. The observer fires only on a clean integrate (never a
  fail-safed/non-bumped update), holds the bridge weakly (no retain cycle), and is cleared
  on the document's teardown; the deferred `.onChange` is retained as an idempotent
  backstop (firing `replicaDidChange` twice is a proven empty-diff no-op). Its lifecycle is
  the **per-document entry's**, not the bridge's: the bridge registers it
  (`registerReplicaObserver`) on every live-session **(re)acquisition** from
  `EditorView.requestCollaborationSessionIfNeeded` — deliberately *not* at construction —
  and `teardownIfIdle` drops it, so it exists exactly while a live entry does. Registering
  at construction would be wrong at both ends: the bridge lives in the view's `@State` and
  outlives a linger-teardown, so a reopen would keep a now-dropped observer and silently
  degrade to the deferred path (reopening the race); and a document that never opens a
  session (the default flag-off path) would register an observer no teardown ever clears (a
  leak). This lifecycle contract is pinned by a manager test (teardown clears it, a bare
  reopen fires nothing, re-registration restores it) and the boundary between read-live and
  write-live by a bridge test (a lossy-but-renderable projection engages the read side yet
  downgrades a local edit to classic).
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
  deferred `.onChange` re-sync, then forwards a local edit and asserts the manager's own
  replica projects to the correctly merged document — no corruption reaching peers. It
  fails against a deferred-only re-apply (editor `[Doc, First, Second!]`, replica `[Doc,
  Second, Second!]`) and passes with the synchronous observer. Manager- and bridge-level
  unit tests pin the two halves (the manager fires the observer in the same turn it bumps
  the version and stays silent on a fail-safe; the bridge registers it in `init` and a
  remote change delivered *only* through the observer re-syncs `old` before the next
  forward). Every pre-existing `EditorViewModelTests` test passes unchanged, which is the
  standing proof that the classic path is untouched when `liveWrite` is `nil`.

**C3 (shipped):** the user-facing toggle is a **Profile → Preferences → "Live
collaboration"** switch (`ProfileScreen`, a `ProfileTrailingRow` + `Switch` exactly like
the sibling Notifications/Work-offline rows) backed by
`@AppStorage(LiveCollaborationPreference.key)`. Writing that key is the *entire* wiring:
`RootView` builds the collaboration manager with `featureEnabled:
{ LiveCollaborationPreference.isEnabled() }`, a live closure re-evaluated on every
`availability` read — pinned by
`DocumentCollaborationManagerTests.testAvailabilityTracksTheLivePreferenceFlagMidSession`,
which fails if anyone "optimizes" it into a captured Bool. **The default is OFF /
opt-in** (decision 2026-07-21): the write path is CI-verified but the on-device
end-to-end WebSocket check against a real collaboration-capable server is still owed, so
users must opt in; flipping the default waits for that verification. Deliberate,
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

The store is a deliberately literal transliteration of **yjs 13.6.31** (the version
the docs v5.4.1 lockfile resolves). Every non-obvious branch carries the yjs
function and line it mirrors. This is not stylistic: the output of this code
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
crafted inbound update fully controls — so a ~20k-deep nested-type chain (~140 KB)
overflows the stack. Integration itself is iterative and safe far past that; only
delete/gc recurse, which matches yjs (it too accepts deep integration and refuses deep
delete/gc with a catchable `RangeError`). `YTransaction.maxTypeNestingDepth` (2048)
bounds both cascades: `YItem.gc` throws directly (already `throws`), while the
non-throwing `YItem.delete` flags `transaction.recursionLimitExceeded`, which
`cleanupTransactions` — the single chokepoint every transaction drains through —
converts into a thrown `.recursionLimitExceeded`, discarding the half-marked store
before gc/merge read it. It is a deliberate narrowing (oracle-faithful at the
accept/reject boundary and byte-identical below the cap — the golden `deleteNestedType`
fixture is unmoved — but stricter than V8 between the cap and its ~4000 limit),
accepted because real documents nest ~2 type levels per visual indent. The cap should
be re-measured on a Release build, and a deep-nesting differential-fuzz lane run,
before the live-collaboration flag is ever defaulted on.

### Teardown is the owner's job

The item graph is a mesh of strong cycles — `item.left ⇄ item.right`, and
`type.start`/`type.map` ⇄ `item.parent` — because yjs assumes a tracing collector.
ARC collects none of it, so **releasing a `YDoc` frees nothing**; a live session
opens one replica per document. `YDoc.destroy()` breaks the cycles and must be
called by whatever owns the replica (the collaboration session, C1). No edge can be
`unowned` instead: the algorithm reads all of them in both directions, and none has
a target that provably outlives its source.

### Verification

Golden fixtures captured from real yjs pin each YATA branch
(`YIntegrationTests`, and — for the B3 encode side — `YStateEncoderTests`), and a
**differential fuzz harness** compares this store against a node yjs oracle across
randomized op scripts and delivery orders — seeded, minimizing. It compares the
full store structure (not just the wire projection, so left/right/origin wiring is
checked too) after *every* update, **and, once B3 landed, the encoded bytes**: at
every settled step it asserts `YStateEncoder.encodeStateAsUpdate` (full and
diff-against-state-vector) and `encodeStateVector` are byte-identical to yjs's.
Bytes are compared only where **both sides are settled** — an unsettled store may
legitimately differ (an accepted re-tiling, a pending stash a `diffUpdate` never
resolves), and a settledness *disagreement* is itself a finding. The harness is
session-local scratch tooling, never committed (the zero-dependency rule); what it
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
together with gc (`YTextCleanup.swift`, `cleanupTransactions`'s observer phase).

Two subtleties the transliteration had to get right, both proven against the yjs
oracle by the differential fuzz's dedicated formatting lane (nested text, concurrent
redundant marks — the only shape that fires the trigger, since a bare root type is
never a concrete `YText`):

- **Format-value equality is JS `===`.** yjs compares parsed `ContentFormat.value`s
  with `===`; the store keeps raw `valueJSON`, so `YFormatAttrValue` reproduces that:
  primitives by JSON text, objects/arrays by owning-item identity (never structurally
  equal), and absent-key ⇔ JSON `null`.
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

## Authentication

**WKWebView session-cookie login**, not native OAuth/PKCE. Rationale:

- The Connect screen (per the design handoff) accepts an arbitrary Docs server URL — the app cannot know that server's IdP endpoints in advance, and Docs' own `/api/v1.0/config/` does not expose them.
- A WKWebView pointed at `https://{server}/api/v1.0/authenticate/` runs the exact same redirect dance as a browser, requiring zero IdP-side configuration on the self-hosted instance.
- This matches the design's own Connect screen copy: "The app signs in with your existing session — no password stored."

Flow:
1. User enters/selects a server URL on the Connect screen, taps "Sign in to {host}".
2. App presents a `WKWebView` (in a sheet) loading `https://{server}/api/v1.0/authenticate/?next=...`.
3. `WKNavigationDelegate` watches for navigation back to a recognized "logged in" location (e.g. a successful `GET /api/v1.0/users/me/` no longer returning 401, or landing back on the SPA root) and dismisses the sheet.
4. The Django session cookie (`docs_sessionid`) is read from `WKWebsiteDataStore.default().httpCookieStore` and synced into `HTTPCookieStorage.shared` so the app's `URLSession` (default configuration) automatically attaches it on subsequent same-host requests.
5. `SessionStore.signIn` additionally snapshots the server's cookies into the Keychain (`dev.llun.Schrift.sessionCookies`, as Codable `StoredCookie`s) and `SessionStore.init` restores them synchronously on launch, before the API client is built — session-only cookies (nil `expiresDate`, e.g. Django's `sessionid`) are otherwise dropped from `HTTPCookieStorage` when iOS kills the process. Server URL + auth flag are persisted too; sign-out deletes both the snapshot and the live cookies. Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (never synchronizable), so a live session stays on the device that obtained it — the user-visible cost is one re-login after a device migration. `SessionStore.init` runs a best-effort `SecItemUpdate` to migrate items written by builds that predated this class.
6. On a real `401` from any API call, the shared `DocsAPIClient`'s `onSessionExpired` hook sets `SessionStore.needsReauthentication`, which presents a re-login sheet (the same WKWebView OIDC flow) over the current UI. Cached data keeps showing; dismissing the sheet cancels non-destructively and the next failing request re-presents it. The app never drops back to the Connect screen on 401 — Connect is reached only via explicit sign-out.

Mutating requests (`POST`/`PATCH`/`PUT`/`DELETE`) must include Django's CSRF token (`X-CSRFToken` header, value read from the `csrftoken` cookie), matching the web frontend's own `fetchApi.ts` behavior.

**Known limitation:** session lifetime is still bounded by the server (`SESSION_COOKIE_AGE` / server-side invalidation) — the app persists the cookie across process death but cannot outlive the server's session; expiry surfaces as the re-login sheet, not a return to Connect. No silent refresh token in this flow.

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
| Favorite toggle | `POST`/`DELETE /documents/{id}/favorite/` |
| Favorites list | `GET /documents/favorite_list/` |
| Search | `GET /documents/search/?q=` |
| Read rendered content | `GET /documents/{id}/formatted-content/?content_format=markdown` |
| Read raw content *(not used in v1)* | `GET /documents/{id}/content/` |
| Write raw content | `PATCH /documents/{id}/content/` (base64 Yjs built on-device) |
| Link sharing config | `PUT /documents/{id}/link-configuration/` |
| Accesses (members) | `GET/POST/PATCH/DELETE /documents/{id}/accesses/` |
| Invitations | `GET/POST/PATCH/DELETE /documents/{id}/invitations/` |
| User search (for invite) | `GET /users/?q=&document_id=` |

Codable models mirror `ListDocumentSerializer`/`DocumentSerializer` fields: `id, title, excerpt, abilities, link_reach, link_role, computed_link_reach, computed_link_role, is_favorite, depth, numchild, path, created_at, updated_at, user_role, creator`. The `abilities` dictionary (e.g. `update`, `destroy`, `link_configuration`, `accesses_manage`, `favorite`) drives which UI actions are shown/enabled per document — never hardcode permission logic client-side.

## Editing & save mechanism

This is the part with no direct backend support, so it's called out explicitly:

1. **Read**: `GET /documents/{id}/formatted-content/?content_format=markdown`. Render natively as editable rich text, mapping Markdown constructs to the design's block types (paragraph, heading, bullet list, checklist, quote).
2. **Save** (full content replace, since v1 explicitly excludes real-time merge):
   a. Serialize the edited native content back to Markdown.
   b. Convert Markdown → a Yjs v1 update entirely **on-device** (`Core/Yjs`: `MarkdownYjs.encode`, backed by the hand-written `YjsUpdateEncoder`).
   c. `PATCH /documents/{id}/content/` with the base64-encoded Yjs bytes.
   d. `PATCH /documents/{id}/` to persist the title.

   (Two requests total; no temporary document and no server-side file conversion. This supersedes an earlier design that created a temp document via `POST /documents/` with a Markdown `file` field, read back its converted Yjs, PATCHed it onto the real doc, then deleted the temp — that path depended on the backend's file-upload-to-Yjs conversion, which is gated behind `CONVERSION_UPLOAD_ENABLED` and off on the target deployment.)

**Known limitation:** this is a full-document overwrite with no conflict detection (no ETag/version check in v1). If someone edits the same document live in the web app concurrently, the loser's changes are silently overwritten. This is an explicit, accepted trade-off of choosing non-realtime editing — not hidden from the user; the Editor screen should make clear this isn't live-collaborative.

## Screens

From the design handoff (`ui_kits/docs-ios/`), implemented as SwiftUI views using the DesignSystem components, not copied HTML/JS:

- **Connect** — logo, "Welcome to Docs", server URL `TextField`, recent servers list, "Sign in to {host}" button → WebView login.
- **Home** — `NavBar` (large title, subtitle = server host, new-doc action), `SearchField`, Pinned + Recent sections of `DocRow`s, `TabBar` (Docs/Search/Shared/Profile — all four tabs are fully implemented: Search hits `GET /documents/search/?q=` with recent-search history, Shared lists documents shared *with* the user (`GET /documents/?is_creator_me=false`) with an offline metadata cache, each row enriched best-effort with its members' avatars and the sharer's name from that document's `accesses/` (the "shared by me" scope was removed — the list API has no distinct by-me shared query), Profile shows the current user via `GET /users/me/` as a static email row (the tappable Account screen was removed in the design-system refresh — see the notes at the top of this document), with the appearance/language pickers, server + server-version rows, sign-out, and the Work Offline toggle).
- **Editor** — **reading mode** shows the standard `NavBar` (back, no center title; trailing Edit/Share/Options). **Editing mode** hides that nav bar entirely and promotes the save bar (`EditorSaveBar`) to the sole header — live save status on the left, a **Done** button (`finishEditing`) on the right — because the nav bar's back button popped the whole document to the list instead of ending the edit, and its bottom border stacked with the save bar's into a double hairline. The document title is a large content header (`DocsFont.title1`) inside the reading canvas — separate from the bar, matching the handoff — with `LinkReachPill` + a live "Synced X ago" caption beneath it, above the rendered/editable blocks; a Subpages section (hierarchy-glyph eyebrow, title-only rows); floating formatting toolbar (add block/bold/italic/bulleted list/checklist/quote/code block). The earlier in-editor "Pages" document-tree panel (`DocTreePanel`) was removed — the handoff has no such surface; subpages are reached through the reading canvas's Subpages list. `AvatarGroup` renders collaborator stacks in the Shared tab's rows (`SharedRow`) and the editor's live-presence bar (`PresenceBar`); the mock's in-editor emoji reactions were not implemented.
- **Share sheet** — invite by name/email (`GET /users/?q=`), member list (`ShareMemberRow` with role picker: Reader/Commenter/Editor/Administrator/Owner — Commenter included even though the mock only shows Admin/Editor/Reader, since it's a real backend role), link reach picker (Restricted/Authenticated/Public via `LinkReachPill`), Copy link.
- **Options sheet** — Pin/Unpin, Copy link, Share, Delete, and **Version history** (read-only list + "Restore on the web"; see [`design-system.md`](design-system.md)). Copy as Markdown and Duplicate were removed (the `duplicate/` endpoint with them). *Still deferred to a later iteration*: Download (PDF/Word/ODT — no mobile-appropriate endpoint investigated yet), Present.

**iPad**: `NavigationSplitView` (document list sidebar + detail/editor pane) instead of the iPhone single-column stack — extrapolated from the design's tokens/components since the handoff only mocked iPhone (390×844) layouts. iOS layout constants (status bar 54px, nav bar 44px, tab bar 49px, home indicator 34px, row min-height 44px, gutters 16/20px) are implemented as native safe-area-driven layout, not hardcoded pixel values, since real devices vary.

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

- `401` → mapped to `.sessionExpired`; the shared client's `onSessionExpired` hook raises `SessionStore.needsReauthentication` and a re-login sheet is presented over the current screen. List/editor view models keep showing cached/local content (401 is never rendered as "offline"); an already-open editor recovers on its next refresh or save. The Connect screen is not shown for 401 — only explicit sign-out returns there.
- `403` → permission-denied inline state; in practice this should be rare since UI affordances are gated by the `abilities` dict already.
- `404` → "not found / no longer available" state (covers soft-deleted-past-cutoff documents, which the backend intentionally 404s rather than 403s to avoid leaking existence).
- `429` → respect `Retry-After` if present; otherwise simple backoff with a banner ("Too many requests, try again shortly").
- Network failure → retry affordance on the failed view; no offline edit/sync
  queue in v1 (since 2026-07-03, previously-opened documents are content-cached
  on-device and readable offline, and document lists — Home (the unfiltered
  recent feed plus pinned), Shared, editor sub-pages — are metadata-cached and
  shown instantly with silent background revalidation).
- Save conflicts are not detected (see Editing & save mechanism) — documented limitation, not silently swallowed.

## Testing

- Unit tests for `DocsAPIClient` and Codable models against mocked `URLSession` responses (fixture JSON matching the real serializer shapes documented above).
- Unit tests for the on-device Markdown→Yjs encoder (`Core/Yjs` — `YjsEncoderTests`, `MarkdownYjsTests`, `InlineMarkdownTests`, verifying valid Yjs-v1 update bytes) and for the save flow (`DocumentSaveTests` / `DocumentSaveCoordinatorTests`, verifying `saveDocumentContent` issues `PATCH /content/` then `PATCH /{id}/` for the title).
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
