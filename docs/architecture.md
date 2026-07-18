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
- **Persistent sessions.** Session cookies persist in the Keychain across app
  kills, and a real 401 presents an in-place re-login sheet instead of dropping
  back to the Connect screen.
- **Rich editor content.** A standalone `![alt](url)` line with an absolute
  http(s) URL is a first-class image block through the whole editor/save
  pipeline, and photos can be inserted from the library (uploaded, then embedded
  on success).
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

- Real-time collaborative editing (live cursors, multi-user simultaneous edit) — no Hocuspocus WebSocket / live-sync client. (The app *does* build Yjs CRDT updates on-device — a hand-written encoder in `Core/Yjs` — but only to save content via a single HTTP PATCH; there is no persistent collaborative connection. See "Editing & save mechanism".)
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
│   ├── Collaboration/    — Hocuspocus/Yjs live-collaboration layer (wire codecs, WebSocket transport, session state machine, presence), dormant behind the default-off `schrift.liveCollaboration` flag
│   └── Yjs/              — the Yjs layer, two halves: the on-device Markdown→BlockNote→Yjs *encoder* (hand-written lib0/Yjs-v1 wire format) that builds the base64 content payload for saves, and the *CRDT core* (lib0 decoder, update decoder, struct store + YATA integration, and the B3 store encoder `YStateEncoder`) — see "The Yjs CRDT core"
├── Features/
│   ├── Connect/          — server URL entry, recent servers, WebLoginView (WKWebView OIDC login sheet), session-expiry re-login sheet
│   ├── Home/             — document list: pinned/recent, segmented filter (All/Shared/Pinned), favorite toggle, offline list cache
│   ├── Search/ Shared/ Profile/ — the other three tabs (all real features)
│   ├── Editor/           — read rendering + edit + save, drafts, content cache
│   ├── Share/            — Share sheet (members, invite, link reach)
│   └── Options/          — Options sheet (pin, copy link, duplicate, delete, etc.)
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
peer's state vector, or a state vector — byte-identical to yjs, and **garbage-collect
and clean up formatting** on remote transactions (B4). The replica runs with **gc on
by default** (`YDoc(gc: true)`, matching a real yjs client and the live write path):
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
5. `SessionStore.signIn` additionally snapshots the server's cookies into the Keychain (`dev.llun.Schrift.sessionCookies`, as Codable `StoredCookie`s) and `SessionStore.init` restores them synchronously on launch, before the API client is built — session-only cookies (nil `expiresDate`, e.g. Django's `sessionid`) are otherwise dropped from `HTTPCookieStorage` when iOS kills the process. Server URL + auth flag are persisted too; sign-out deletes both the snapshot and the live cookies.
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
| Duplicate | `POST /documents/{id}/duplicate/` |

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
- **Editor** — **reading mode** shows the standard `NavBar` (back, no center title; trailing Edit/Share/Options). **Editing mode** hides that nav bar entirely and promotes the save bar (`EditorSaveBar`) to the sole header — live save status on the left, a **Done** button (`finishEditing`) on the right — because the nav bar's back button popped the whole document to the list instead of ending the edit, and its bottom border stacked with the save bar's into a double hairline. The document title is a large content header (`DocsFont.title1`) inside the reading canvas — separate from the bar, matching the handoff — with `LinkReachPill` + a live "Synced X ago" caption beneath it, above the rendered/editable blocks; a Subpages section (hierarchy-glyph eyebrow, title-only rows); floating formatting toolbar (add block/bold/italic/bulleted list/checklist/quote/code block). The earlier in-editor "Pages" document-tree panel (`DocTreePanel`) was removed — the handoff has no such surface; subpages are reached through the reading canvas's Subpages list. The mock's collaborator `AvatarGroup` and emoji were not implemented (the component exists in the DesignSystem but is unused by features).
- **Share sheet** — invite by name/email (`GET /users/?q=`), member list (`ShareMemberRow` with role picker: Reader/Commenter/Editor/Administrator/Owner — Commenter included even though the mock only shows Admin/Editor/Reader, since it's a real backend role), link reach picker (Restricted/Authenticated/Public via `LinkReachPill`), Copy link.
- **Options sheet** — Pin/Unpin, Copy link, Share, Copy as Markdown, Duplicate, Delete, ~~Version history~~ **Version history shipped** (read-only list + "Restore on the web"; see [`design-system.md`](design-system.md)). *Still deferred to a later iteration*: Download (PDF/Word/ODT — no mobile-appropriate endpoint investigated yet), Present.

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
