# Docs iOS — Design Spec

Date: 2026-06-30
Status: Approved (v1 scope)

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

- Real-time collaborative editing (live cursors, multi-user simultaneous edit). No Yjs/Hocuspocus client.
- Offline editing/sync queue.
- Comments/threads.
- AI features (proxy/transform/translate endpoints exist server-side but are out of scope).
- Document version history browsing/restore.
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
DocsIOS/
├── App/                  — app entry point, root navigation (NavigationStack on iPhone-width, NavigationSplitView on iPad/regular-width)
├── DesignSystem/         — Color/Font assets + spacing/radius constants ported from tokens/*.css (indigo theme), and components: Button, IconButton, Avatar, AvatarGroup, Badge, DocIcon, SearchField, SegmentedControl, Switch, TextField, NavBar, TabBar, ListRow, ListSection, DocRow, LinkReachPill, ShareMemberRow
├── Core/
│   ├── Networking/       — DocsAPIClient (URLSession + async/await), endpoint definitions, Codable models mirroring DRF serializers, error types
│   ├── Auth/             — SessionStore (Keychain-backed cookie + server URL persistence), WebLoginController (WKWebView-driven OIDC login)
├── Features/
│   ├── Connect/          — server URL entry, recent servers, sign-in
│   ├── Home/             — document list: pinned/recent, search, segmented filter (All/Shared/Pinned), favorite toggle
│   ├── Editor/           — read rendering + edit + save
│   └── Sharing/          — Share sheet (members, invite, link reach), Options sheet (pin, copy link, duplicate, delete, etc.)
└── DocsIOSTests/         — unit tests for Networking, Auth, and the edit-save conversion flow
```

### Why no third-party CRDT/networking dependencies

Given the Non-goals above (no real-time collaboration), the app never needs to parse or construct Yjs binary data directly — see "Editing & save mechanism" below for how writes are achieved without it. This keeps the dependency surface at zero for v1.

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
5. Server URL + a flag that we're authenticated is persisted (Keychain for anything sensitive; server URL can be UserDefaults).
6. On `401` from any API call, drop back to the Connect screen and re-trigger login.

Mutating requests (`POST`/`PATCH`/`PUT`/`DELETE`) must include Django's CSRF token (`X-CSRFToken` header, value read from the `csrftoken` cookie), matching the web frontend's own `fetchApi.ts` behavior.

**Known limitation:** session cookie expiry means periodic re-login; exact interval depends on the server's `SESSION_COOKIE_AGE`. No silent refresh token in this flow.

## Networking & data model

`DocsAPIClient` wraps `URLSession`, base URL `https://{server}/api/v1.0/`. Key endpoints used in v1:

| Purpose | Endpoint |
|---|---|
| Bootstrap config | `GET /config/` |
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
| Read raw content | `GET /documents/{id}/content/` |
| Write raw content | `PATCH /documents/{id}/content/` |
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
   b. `POST /documents/` with a `file` field containing that Markdown (uses the backend's existing "create from file" conversion, which the update path doesn't have) — creates a **temporary** document whose content is now valid converted Yjs.
   c. `GET /documents/{temp_id}/content/` — read the resulting raw base64 Yjs bytes.
   d. `PATCH /documents/{id}/content/` — write those bytes onto the *real* document, preserving its id/title/sharing/metadata.
   e. `DELETE /documents/{temp_id}/` — clean up the temporary document (soft-delete; lands in trash, not left visible).

**Known limitation:** this is a full-document overwrite with no conflict detection (no ETag/version check in v1). If someone edits the same document live in the web app concurrently, the loser's changes are silently overwritten. This is an explicit, accepted trade-off of choosing non-realtime editing — not hidden from the user; the Editor screen should make clear this isn't live-collaborative.

## Screens

From the design handoff (`ui_kits/docs-ios/`), implemented as SwiftUI views using the DesignSystem components, not copied HTML/JS:

- **Connect** — logo, "Welcome to Docs", server URL `TextField`, recent servers list, "Sign in to {host}" button → WebView login.
- **Home** — `NavBar` (large title "Docs", subtitle = server host, search + new-doc actions), `SearchField`, `SegmentedControl` (All/Shared/Pinned), Pinned + Recent sections of `DocRow`s, `TabBar` (Docs/Search/Shared/Profile — Search/Shared/Profile tabs are presentational placeholders in v1 beyond Docs).
- **Editor** — `NavBar` with back, `AvatarGroup` (collaborators — static list from accesses, not live presence), Share + Options `IconButton`s; emoji + title + `LinkReachPill` + rendered/editable blocks; floating formatting toolbar (bold/italic/bullet list/checklist/image/code — subset implemented based on what the native editor supports).
- **Share sheet** — invite by name/email (`GET /users/?q=`), member list (`ShareMemberRow` with role picker: Reader/Commenter/Editor/Administrator/Owner — Commenter included even though the mock only shows Admin/Editor/Reader, since it's a real backend role), link reach picker (Restricted/Authenticated/Public via `LinkReachPill`), Copy link.
- **Options sheet** — Pin/Unpin, Copy link, Share, Copy as Markdown, Duplicate, Delete. *Deferred to a later iteration*: Download (PDF/Word/ODT — no mobile-appropriate endpoint investigated yet), Version history, Present.

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

- `401` → treat session as expired, return to Connect screen, re-trigger WebView login.
- `403` → permission-denied inline state; in practice this should be rare since UI affordances are gated by the `abilities` dict already.
- `404` → "not found / no longer available" state (covers soft-deleted-past-cutoff documents, which the backend intentionally 404s rather than 403s to avoid leaking existence).
- `429` → respect `Retry-After` if present; otherwise simple backoff with a banner ("Too many requests, try again shortly").
- Network failure → retry affordance on the failed view; no offline queue/cache in v1.
- Save conflicts are not detected (see Editing & save mechanism) — documented limitation, not silently swallowed.

## Testing

- Unit tests for `DocsAPIClient` and Codable models against mocked `URLSession` responses (fixture JSON matching the real serializer shapes documented above).
- Unit tests for the markdown-edit → temp-document-conversion save flow, with a mocked API verifying the create → fetch-content → patch → delete call sequence (including the delete happening even if a later step fails, to avoid orphaned temp docs).
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
7. Editor screen — editing + save (temp-document conversion technique).
8. Share sheet + Options sheet, wired to real sharing/permissions APIs.
9. iPad adaptive layout (`NavigationSplitView`).
10. Polish: empty states, loading states, error states, pull-to-refresh.

## Open risks / known limitations (carried forward, not hidden)

- Save is a full-content overwrite with no conflict detection — concurrent edits in the web app can be clobbered.
- WebView-based login means periodic re-auth; no silent token refresh.
- The temp-document save technique depends on backend behavior (file-upload-to-Yjs conversion on create) that isn't a documented-stable public contract — if a future Docs backend version changes this, saving breaks. Worth a lightweight capability check (e.g. verify on first use) and a clear error if it stops working.
- Material Symbols vs SF Symbols decision deferred to implementation (visual fidelity vs native idiom trade-off).
- Download/export and version history are explicitly deferred past v1.
