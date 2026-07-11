# Docs iOS — Design Spec

Date: 2026-06-30
Status: Approved (v1 scope)
Revised: 2026-07-02 — the save mechanism section was updated to match the shipped
implementation. The original design created a temporary document to reuse the
backend's file→Yjs conversion; the app now builds the Yjs update **on-device**
(a hand-written encoder in `Core/Yjs`) and PATCHes it directly. Everything else is
as originally approved.
Revised: 2026-07-03 — offline **reading** was added: previously-opened
documents are cached on-device and render instantly with background
revalidation (see
`docs/superpowers/specs/2026-07-03-instant-local-doc-content-design.md`).
Offline *editing* remains out of scope.
Revised: 2026-07-03 (later the same day) — document **lists** (Home
pinned/recent per-filter, the Shared tab, and editor sub-page lists) are also
cached on-device and readable offline with silent background revalidation (see
`docs/superpowers/plans/2026-07-03-instant-local-doc-lists.md`). A user-facing
**Work Offline** toggle (`schrift.workOffline`, Profile screen) forces
read-only offline mode.
Revised: 2026-07-04 — session cookies now persist in the Keychain across app
kills, and a real 401 presents an in-place re-login sheet instead of returning
to the Connect screen (see
`docs/superpowers/plans/2026-07-04-persist-session-cookies-and-reauth.md`).
Revised: 2026-07-07 — realigned with the shipped implementation: directory
tree, Screens section (all four tabs are real features; the shipped Editor
header), and the endpoint table (`GET /config/` was never implemented).
Revised: 2026-07-07 (later) — a standalone `![alt](url)` line with an absolute
http(s) URL is now a first-class `.image` block through the whole editor/save
pipeline (parse → serialize → Yjs encode → render), so a web-authored image
survives an in-app edit-and-save instead of being flattened to literal text.
The Yjs encoder now supports leaf blocks that still carry props; the image byte
layout is locked by a golden fixture captured from `@blocknote/core@0.51.4`. See
`docs/superpowers/plans/2026-07-07-image-block-round-trip.md`.
Revised: 2026-07-08 — users can **insert photos** from their library. A new
multipart `attachment-upload` endpoint plus a bounded media-check readiness poll
yield the absolute `/media/{key}` URL the web client persists; the picked photo
is downscaled and re-encoded to JPEG on device, and the `.image` block is
inserted only on upload success. Entry points: the slash-menu "Photo" item and a
formatting-bar button. See
`docs/superpowers/plans/2026-07-07-photo-upload-insert.md`.
Revised: 2026-07-11 — a design-system refresh shipped four features this spec
predates: a **complete adaptive dark theme** (`DocsColorHexDark`, a Light/Dark/
System picker in Profile); **in-app localization** covering 10 languages with
live switching (an in-code catalog, not `.lproj` — see `CLAUDE.md`); a
**Profile restructure** (the appearance/language pickers, the removal of
`AccountScreen` in favor of a static email row, and a server-version row from
`GET /config/`); layout fidelity work (nav-bar large-title collapse,
dividerless tab-screen list sections, sheet detents); and **read-only version
history browsing** (a "Version history" row in the Options sheet, `GET
documents/{id}/versions/`) — see the "Non-goals" and "Screens" reconciliation
notes below and
`docs/superpowers/specs/2026-07-11-ios-design-update-design.md` for the full
design. Document content translation and in-app version **restore** remain
out of scope (restore is a "Restore on the web" link instead — see §9.3 of
that spec for why: the app has a Yjs encoder but no decoder, and the
restore-response shape couldn't be verified end-to-end in a headless
environment before this pass shipped).

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
- ~~Document version history browsing/restore.~~ **Superseded 2026-07-11 for
  browsing**: a read-only version-history list shipped (see the 2026-07-11
  `Revised:` note above). **Restore** remains a non-goal — it hands off to the
  web app instead.
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
├── DesignSystem/         — tokens ported from tokens/*.css (indigo theme), and components: Button, IconButton, Avatar, AvatarGroup, Badge, DocIcon, SearchField, SegmentedControl, Switch, TextField, NavBar, TabBar, ListRow, ListSection, DocRow, LinkReachPill, ShareMemberRow, OfflineBanner
├── DesignSystemCatalog/  — visual QA catalog of every component
├── Core/
│   ├── Networking/       — DocsAPIClient (URLSession + async/await), endpoint definitions, Codable models mirroring DRF serializers, error types
│   ├── Auth/             — SessionStore (Keychain-backed session-cookie + server URL persistence, re-auth flag), SessionCookies (Codable HTTPCookie snapshot), WebLogin free functions (login-URL/completion detection, cookie sync), KeychainStore
│   └── Yjs/              — on-device Markdown→BlockNote→Yjs encoder (hand-written lib0/Yjs-v1 wire format) that builds the base64 content payload for saves
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

The app *constructs* Yjs binary updates to save (see "Editing & save mechanism" below), but does so with a small hand-written lib0/Yjs-v1 encoder (`Core/Yjs`) rather than pulling in a CRDT library. It never needs to *parse* incoming Yjs — reads go through `formatted-content`. This keeps third-party dependencies at zero for v1.

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
- **Home** — `NavBar` (large title, subtitle = server host, new-doc action), `SearchField`, `SegmentedControl` (All/Shared/Pinned), Pinned + Recent sections of `DocRow`s, `TabBar` (Docs/Search/Shared/Profile — all four tabs are fully implemented: Search hits `GET /documents/search/?q=` with recent-search history, Shared lists documents shared with/by me with an offline metadata cache, Profile shows the current user via `GET /users/me/` as a static email row (the tappable Account screen was removed 2026-07-11 — see the `Revised:` note at the top), with the appearance/language pickers, server + server-version rows, sign-out, and the Work Offline toggle).
- **Editor** — standard `NavBar` (back, no center title; trailing Edit/Share/Options in reading mode, a Done checkmark while editing). The document title is a large content header (`DocsFont.title1`) inside the reading canvas — separate from the bar, matching the handoff — with `LinkReachPill` + a live "Synced X ago" caption beneath it, above the rendered/editable blocks; a Subpages section (hierarchy-glyph eyebrow, title-only rows); floating formatting toolbar (add block/bold/italic/bulleted list/checklist/quote/code block). The earlier in-editor "Pages" document-tree panel (`DocTreePanel`) was removed — the handoff has no such surface; subpages are reached through the reading canvas's Subpages list. The mock's collaborator `AvatarGroup` and emoji were not implemented (the component exists in the DesignSystem but is unused by features).
- **Share sheet** — invite by name/email (`GET /users/?q=`), member list (`ShareMemberRow` with role picker: Reader/Commenter/Editor/Administrator/Owner — Commenter included even though the mock only shows Admin/Editor/Reader, since it's a real backend role), link reach picker (Restricted/Authenticated/Public via `LinkReachPill`), Copy link.
- **Options sheet** — Pin/Unpin, Copy link, Share, Copy as Markdown, Duplicate, Delete, ~~Version history~~ **Version history shipped 2026-07-11** (read-only list + "Restore on the web"; see the `Revised:` note above). *Still deferred to a later iteration*: Download (PDF/Word/ODT — no mobile-appropriate endpoint investigated yet), Present.

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
- Icons: Google Material Symbols Outlined — evaluate bundling the variable font vs. mapping each glyph name to an SF Symbols equivalent during implementation (design system assumes the Material font; SF Symbols would be more native but is a visual deviation worth a deliberate call when we get there).

Static assets (logo, illustrations, doc-type icons) are copied from the handoff's `assets/` folder into the Xcode project's asset catalog during the scaffold PR.

## Error handling

- `401` → mapped to `.sessionExpired`; the shared client's `onSessionExpired` hook raises `SessionStore.needsReauthentication` and a re-login sheet is presented over the current screen. List/editor view models keep showing cached/local content (401 is never rendered as "offline"); an already-open editor recovers on its next refresh or save. The Connect screen is not shown for 401 — only explicit sign-out returns there.
- `403` → permission-denied inline state; in practice this should be rare since UI affordances are gated by the `abilities` dict already.
- `404` → "not found / no longer available" state (covers soft-deleted-past-cutoff documents, which the backend intentionally 404s rather than 403s to avoid leaking existence).
- `429` → respect `Retry-After` if present; otherwise simple backoff with a banner ("Too many requests, try again shortly").
- Network failure → retry affordance on the failed view; no offline edit/sync
  queue in v1 (since 2026-07-03, previously-opened documents are content-cached
  on-device and readable offline, and document lists — Home per-filter, Shared,
  editor sub-pages — are metadata-cached and shown instantly with silent
  background revalidation).
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
- Material Symbols vs SF Symbols decision deferred to implementation (visual fidelity vs native idiom trade-off).
- Download/export remains explicitly deferred past v1. Version history
  **browsing** shipped 2026-07-11 (read-only); **restoring** a version is still
  deferred — see the `Revised:` note above and
  `docs/superpowers/specs/2026-07-11-ios-design-update-design.md` §9.3.
