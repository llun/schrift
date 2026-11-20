# Networking (`Core/Networking`)

- Everything goes through `DocsAPIClient`'s four primitives
  (`get`/`getRawData`/`send`/`sendVoid`) over one private `performRequest`.
  Endpoint code **never** builds a `URLRequest` or touches `URLSession`. (One
  intentional exception: absolute document images use `ImageLoader` and
  `ImageTransport`, whose ephemeral, origin-pinned session supports explicitly
  consented external URLs without sharing credentials.)
- `performRequest` retries a `GET` **once** on `URLError.networkConnectionLost`
  (-1005: a pooled connection that went stale while the app slept, common on the
  first request after a resume). Unsafe methods are never retried, since the server
  may have acted on the first attempt; a second failure throws as before.
- Add each feature's endpoints as an `extension DocsAPIClient` in **its own file**.
- **Repeat reads are de-duplicated, not cached.** Only `serverConfig()` shares a request already on the wire
  (`inFlightServerConfig`; the slot clears when it settles), so the launch task, Profile and favorites route
  discovery cost one `GET` when they overlap. `currentUser()` deliberately **never** shares: identity must come
  from a live fetch per call, made with the cookies in force now (a joined request could have been sent with the
  previous account's cookies across a login handover), and it is forgotten when cookies change hands. There is
  **no TTL** either. Screens add a 30 s `LoadFreshness` window on their *passive* on-appear entry only
  (`HomeViewModel.loadIfStale()`, `SharedViewModel.loadIfStale(sessionGeneration:)`,
  `ProfileViewModel.loadIfStale(sessionGeneration:)`): keyed on the availability token and, for Shared and
  Profile, the sign-in generation (`SessionStore.signInGeneration`), so a re-login never reads the previous
  account's list as fresh. Shared's passive freshness also compares `lastFetchedOwner` against
  `signedInUser.userID`, so a fetch stamped before the id was known is not fresh however recent it is.
  Pull-to-refresh, replay, migration and delete reloads call `load()` and always fetch,
  and so does returning from a pushed screen: `MainTabView` reacts when the compact docs `NavigationPath`
  shrinks, and `HomeSplitView` when the selection switches from one document to another (a deletion reloads
  through `onDeleted`), by calling `HomeViewModel.markListStale()` and then `loadIfStale()` — one fetch even if
  another passive trigger also fires — so a rename made in the editor shows at once. First appearance and tab switches stay on `loadIfStale()`.
- **Decode** with the shared `JSONDecoder.docsAPI` (snake_case + dual ISO8601 date
  handling) — never a bare `JSONDecoder` for API responses. **Encoding** uses a
  bare `JSONEncoder` with no key strategy, so a request body with multi-word
  fields **must** declare explicit `CodingKeys` mapping camelCase → snake_case.
- Paths are relative, lowercase, and end in a **trailing slash**; interpolate
  UUIDs as `documentID.uuidString.lowercased()` — the Django backend requires
  lowercase UUIDs and the trailing slash. Paths resolve against the client's
  `baseURL`, which **already contains `/api/v1.0/`** (appended in `RootView`) —
  never repeat the prefix, and never start a path with `/` (a leading slash
  resolves against the host root and silently drops `/api/v1.0/`). The **one
  intentional exception** is `checkMedia(path:)`, which replays a rooted
  `/api/v1.0/…` path the *server* handed us verbatim; `absoluteServerURL(for:)`
  relies on the same rule to resolve `/media/…` against the origin. Because those
  two are the **only** places a non-app-authored string becomes a URL, both pin it
  to the server origin: `isSameOriginPath` rejects `//evil.com/x` and any scheme
  before a request is issued, and `absoluteServerURL` returns nil unless
  scheme+host+port match `baseURL`. `URL(string:relativeTo:)` does **not** do this
  for you — `//evil.com/x` resolves to `https://evil.com/x`. Keep the guards if
  either ever becomes non-GET: `performRequest` would send the CSRF token and
  `Origin` to whatever host the path names.
  A **second, app-authored rooted path** exists for Docs 6: the collaboration
  server's document route `collaborationYDocPath(org:documentID:)` →
  `/collaboration/ydoc/v1/{org}/{uuid}` (no trailing slash — it is not a Django
  route), resolved against the server origin. It is safe without
  `isSameOriginPath` because nothing in it is server-supplied text that could name
  a host: the uuid is a `UUID`, and `org` is the only config-derived part —
  `ServerConfig.collaborationOrg` takes it from `COLLABORATION_WS_URL`'s
  `…/ws/v1/{org}` path only when it matches `^[A-Za-z0-9._~-]+$` and is not
  `.`/`..`, else `docs`. The **host is never taken from config.** Keep that
  validation if you touch it; the PATCH carries the CSRF token and `Origin`.
- **Docs 6 moved document content to the collaboration server ("yhub"), and every
  content save picks its route per server** (`ContentSaveRoute`,
  `CollaborationYDocEndpoints.swift`, memoized as `DocsAPIClient.contentSaveRoute`;
  `saveContentViaRoute` is the one routing helper, shared by the classic body save and
  the live snapshot).
  Docs 6 removed `GET`/`PATCH documents/{id}/content/` (Django HTML 404 →
  `.routeNotFound`); `formatted-content/` (the read path) and the title `PATCH
  documents/{id}/` still work. Content now lives at
  `/collaboration/ydoc/v1/{org}/{id}` on the same origin, authenticated by the same
  session cookie: `GET …?gc=true&awareness=false` with **`Accept:
  application/json`** (`get(_:accept:)`, the only caller that passes a non-nil
  `accept:`) answers `{"doc": "<base64 Yjs v1 update>"}`, and `PATCH`
  with `{"update": "<base64>"}` applies an **incremental** update — so a
  from-scratch document would be *appended* and duplicate everything; see
  [Editor & the on-device save](editor-save.md#editor--the-on-device-save-coreyjs) for the diff.
  The route is decided by `serverConfig()` as a side effect whenever config is
  definitive (release major ≥ 6, or a yhub-shaped `…/ws/v1/{org}` collaboration
  URL ⇒ collaboration; a parsable pre-6 version ⇒ legacy) — `RootView`'s launch
  task fetches config, so a Docs 6 server is normally known before the first save.
  **The save path does not fetch config up front** (that would add a request to every
  client's first save). With nothing known it tries the legacy PATCH, and on
  **`.routeNotFound` only** — Django's route 404 proves nothing was written — falls
  back to the collaboration route; `.notFound`, `.forbidden` and everything else are
  answers about the document and propagate. The fallback **fetches config once** first
  to learn the org (`fallbackCollaborationOrg`; only a 404 of `config/` itself means
  `docs` — every other failure propagates, retryably for transport/5xx, rather than
  guess an org that could then be memoized), because a save into the wrong org lands
  in a room nobody reads, silently. It is memoized only once the collaboration route has
  **answered** — the classic save's GET, or the live snapshot's successful PATCH — a server
  with neither route must not be pinned to one that cannot answer (the
  `prefersLegacyContentRoute` lesson) — and never over a `.collaborationYDoc` route
  already set (re-read after the await), so a config-derived org that landed
  concurrently is not replaced. The release
  version parse is the shared `releaseVersionComponents` (favorites uses it too).
- **Attachments** (`AttachmentEndpoints.swift`): `POST documents/{id}/attachment-upload/`
  is multipart with **exactly one field, `file`** — `file_name`/`content_type`/
  `expected_extension`/`is_unsafe` are computed server-side and are *not* client
  fields. Its `201` returns a server-relative **media-check path**, not a media
  URL: `GET` that path until `{"status":"ready","file":"/media/{key}"}`, then embed
  the **absolute** `https://{host}/media/{key}` (what the web client persists, and
  what `extract_attachments()` regex-matches). The multipart body builder is a pure
  free function with a caller-supplied boundary — never interpolate user data into
  it. The uploaded bytes must be a real JPEG named `photo.jpg`: the backend
  magic-sniffs the content and stores a mismatched file under an `-unsafe` key that
  never renders inline. **Reading** an attachment's bytes back is
  `mediaData(path:)` — `isSameOriginPath` + `getRawData`, the same rooted-path
  contract as `checkMedia`, because its path also derives from a string the app
  did not author (see the attachment rules under
  [Editor](editor-save.md#editor--the-on-device-save-coreyjs)).
- **Version history is read-only; in-app restore is deferred.**
  `VersionEndpoints.swift`'s `documentVersions(documentID:)` is
  `GET documents/{id}/versions/` — **removed in Docs 6**, which moved history into
  the collaboration server; the route's `.routeNotFound` sets
  `VersionHistoryViewModel.isHistoryOnWebOnly` (no error, the sheet says history is
  on the web and keeps its "Restore on the web" row), while every other failure keeps
  `versions_error`. Pre-6 servers decode the backend's `{versions: [...]}`
  wrapper into `[DocumentVersion]` (`isCurrent` via `decodeIfPresent ?? false`).
  `VersionHistoryViewModel` loads it best-effort into the read-only
  `VersionHistorySheetView` (Options sheet → "Version history"): newest first,
  the current version labeled, and a **"Restore on the web"** row that hands
  off to `documentShareURL` instead of restoring in-app. Restoring would mean
  re-PATCHing a version's own stored Yjs bytes back as the content — feasible
  without a Yjs *decoder* since the app never has to interpret them — but it
  touches the safety-critical full-overwrite save path (see
  [Editor & the on-device save](editor-save.md#editor--the-on-device-save-coreyjs)) and the
  exact `versions/{id}/` response shape couldn't be verified end-to-end in this
  headless environment. Don't wire up a "Restore" button without that
  on-device verification first.
- One error type `DocsAPIError`; status is translated centrally by
  `DocsAPIErrorMapper` (401→`sessionExpired`, 403→`forbidden`, 404→`notFound` **or
  `routeNotFound`**, 429→`rateLimited(retryAfter:)`, else `server`). Wrap
  `URLSession`/decoder failures into `.network`/`.decoding`; never rethrow raw
  errors.
- Because that flattening plus the view models' friendly copy makes a CSRF 403, a
  validation 400, and a decoding bug **indistinguishable on a device**, every
  non-2xx also fires the client's injected `onRequestFailure` hook with a
  `RequestFailure` (method, path, status, bounded response-body prefix — and
  **never** headers, cookies, or the CSRF token). It is called **synchronously,
  before the error is thrown**, so a caller's `catch` can read it; that is why
  `APIDiagnosticsLog` is lock-guarded rather than `@Observable @MainActor` (an
  actor hop would land after the catch). Callers snapshot `marker()` before the
  request and read `failure(after:)` in the catch — without the marker, an
  offline `.network` failure would quote an unrelated earlier response. A caller
  that issues a second request *concurrently* (the editor reads the sub-page list
  beside the body) passes `failure(after:where:)` a filter (`isBodyReadFailure`),
  because the other request's failure can be recorded first.
  `HomeViewModel.errorDetail` surfaces it under the error message; RootView wires
  the one shared client and the one log together.
  A failed save explains itself even when no response exists to quote:
  `DocumentSaveCoordinator` enters `.failed` only through `markFailed(_:reason:detail:)`, which
  records a reason built by `safeErrorSummary` (error type and case, never the payload —
  for a `DecodingError` the kind and coding path, ids elided, never its `debugDescription`,
  which embeds the server's values) or a fixed phrase naming the refused guard
  (`ReplicaSaveError.otherServerOrAccount`, `.quarantinedDrafts`, `.pendingCreate`, …).
  `failureReport(for:)` joins that reason with the save's own `RequestFailure` detail
  (`EditorViewModel.saveFailureDetail`), so `SaveStatusIndicator` (classic and native)
  shows the "Couldn't save" alert, with Retry and Cancel, for every `.failed` state. The
  reason, request and no-retry flag are cleared by `clearFailure` on every reset or drop of a
  document's state (a save starting or landing, keep-server, a delete, a discarded create), not just
  when a save runs. `markFailed` replaces the request with the `detail` it is given (nil for every
  failure that is not a save run), so a newer failure never quotes an older request. A rejected
  create and a frozen native capture pass `offersRetry: false` (`saveNow` is a no-op there), so
  `failureOffersRetry(for:)` hides Retry and the alert offers Cancel only. Never put a raw `\(error)` or a
  `.network` payload (it can hold a URL) into a reason; `DocsAPIError.decoding`'s payload is
  already a `safeErrorSummary`.
- A real 401 additionally fires the client's injected `onSessionExpired` hook
  **before** `.sessionExpired` is thrown (wired to
  `SessionStore.noteSessionExpired()` by the one shared client built in
  RootView), which presents the app-level re-login sheet. Never construct a
  second client for feature work without wiring the hook — the only intentional
  hook-less clients are the pre-auth sign-in confirmation clients in
  `ConnectViewModel` and `ReauthenticationViewModel` (no session exists / re-auth
  is already in progress, so a 401 there must not re-raise the sheet). View
  models must therefore **never treat `.sessionExpired` as offline** — keep
  cached rows silently and let the sheet handle recovery; only
  `.network`/`.server`/etc. get the offline treatment.
- Models conform to `Codable, Equatable` (add `Hashable` when they're used in
  collections or as navigation values, `Identifiable` when they carry an `id`,
  and `Sendable` explicitly when they cross async — several existing structs
  rely on implicit `Sendable` inference). Server-immutable fields are `let`,
  client-editable fields `var`, absent fields Optional. Decode server
  "abilities"/flag dictionaries **defensively** (`decodeIfPresent(...) ?? false`)
  so added keys don't break decoding.
- **A 404 for the object and a 404 for the route are different things.** DRF
  answers a missing **object** with JSON (`{"detail": "Not found."}`); Django
  answers a missing **route** with its plain HTML page. `DocsAPIErrorMapper` maps
  the latter to **`.routeNotFound`** — but only on *positive* evidence of HTML in
  `Content-Type` (matched case-insensitively; `HTTPURLResponse` does not normalize
  header names). An empty or unlabelled 404 stays `.notFound`, because the delete
  and cache-purge paths key off it and must not silently stop firing.
  `.routeNotFound` deliberately does **not** match the editor's
  `error == .notFound || error == .forbidden` teardown: a missing route is no
  evidence about any document, so a proxy hiccup now reads as transient instead of
  as a deletion.
- **Not every deployment has every route.** Content is read through
  `formattedContent(documentID:format:)`, which tries
  `documents/{id}/formatted-content/?content_format=markdown` and falls back to
  `documents/{id}/content/?content_format=markdown` — the same
  `{id, title, content, created_at, updated_at}` payload on older docs releases,
  which have no `formatted-content/` route at all. Before this, every 404 read as
  "deleted", so such a server rendered *every* document as "This document is no
  longer available." The fallback is gated **twice**: only `.routeNotFound`
  qualifies (never `.notFound`, never `.forbidden`), and the route's absence is
  then **confirmed** against a document id that cannot exist, where a registered
  route still answers DRF's JSON 404. Both gates are load-bearing: a reverse proxy
  can serve HTML for a path it swallowed on a server that *does* have the route,
  and `FormattedDocumentContent.content` is a plain `String?`, so a base64 Yjs
  body would decode into it silently and the full-overwrite save would push that
  blob back as the document's markdown. A transport failure during the
  confirmation probe **propagates** — "I couldn't ask" must never read as "it
  isn't there" — while a probe `.forbidden` or 5xx proves nothing and is
  *swallowed*, since it concerns a document the user never opened and would
  otherwise trip the editor's teardown. When the probe says the route exists, the
  error rethrown is `.routeNotFound`, never `.notFound`. Absence is a fact about
  the **server**, so `prefersLegacyContentRoute` is memoized as soon as the probe
  confirms it — before the document fetch, or a first document that happens to be
  deleted would make every later load re-run the detection.
  **Known limitation:** the split keys off `Content-Type` containing `html`. A
  legacy deployment whose missing-route 404 is unlabelled, `text/plain`, or
  `application/xhtml+xml` will not trigger the fallback and will report its
  documents as deleted. Django's default 404 page is `text/html`, and that is what
  the one legacy server this was tested against returns.
- **The block tree is a best-effort second read, never a content source.**
  `formattedContentTree(documentID:)` GETs
  `documents/{id}/formatted-content/?content_format=json` (same envelope, `content`
  the BlockNote block array) into `FormattedDocumentTree`/`BlockNoteTreeNode` — only
  `type`, `props.url`, `props.showPreview` and `children` are kept, decoded
  defensively, nesting capped at 64. It has no route detection of its own: on a
  server `formattedContent` has already proven legacy (`prefersLegacyContentRoute`)
  it throws `.routeNotFound` without a request, and it never tries `content/`. A
  server that answers the tree read itself with `.routeNotFound` or a `400` (a
  `formatted-content/` without the `json` format) is memoized per client
  (`contentTreeUnsupported`) and never asked again — the tree is best-effort, so
  pinning its absence costs only the overlay; a JSON 404, a 403, a 5xx or a transport
  failure memoizes nothing. Its
  one caller treats every failure as "no tree", so nothing here may ever reach a
  teardown catch or put tree data on screen; it only re-levels blocks the markdown
  already has (see the leaf-nesting bullet under [Editor](editor-save.md#editor--the-on-device-save-coreyjs)).
- **Favorites routes are versioned.** Docs **5.7.0** renamed
  `documents/favorite_list/` to `documents/favorites/` (upstream #2540).
  `favoriteDocuments()` checks `config/`'s `RELEASE_VERSION` with a numeric
  comparison: older releases use the legacy action, 5.7.0+ use the renamed one.
  Missing, malformed, or unavailable config starts with the legacy route; a
  config 401 still propagates and raises reauthentication. A collection GET's
  JSON or HTML 404 permits **one** attempt at the alternate action, including
  backported/custom servers. No other favorites error qualifies. Cache only a
  route that returned a decoded page, scoped to the client; a later 404 clears
  it and tries the alternate so an in-session upgrade can recover. Do not replace
  the action with `documents/?is_favorite=true`: the generic list keeps only
  highest ancestors and can omit pinned subpages that the favorites action includes.
  Home awaits this list before applying Recent, so a wrong action also blanks Recent
  and marks Home offline even when its standard list GET succeeded.
- **A field the *list* endpoints return is not necessarily a field the *create*
  endpoints return.** `is_favorite` is a queryset **annotation**: the list views
  add it, while `POST documents/` and `POST documents/{id}/children/` serialize a
  freshly built instance that has no such attribute, so the key is simply absent
  from both 201 bodies. Decoding it as a required `Bool` made every create fail
  with `keyNotFound` **after the server had already created the document** — the
  app said "Couldn't create a document. Please try again." while quietly
  littering the server with them. `Document.isFavorite` therefore decodes with
  `decodeIfPresent(...) ?? false` (a new document is never a favorite), locked by
  `DocumentDecodingTests.testDecodesACreateResponseThatOmitsIsFavorite`, whose
  fixture is a verbatim capture of a real `POST documents/` response. When you
  add a field, check it against the *create* response too — and note
  `Document`'s `init(from:)` lives in an **extension** so the memberwise
  initializer survives for `SubpageRow`'s preview.
- **Not every list endpoint is paginated — check the viewset, not just the
  serializer.** Most list routes return DRF's `{count, next, previous, results}`
  envelope (decode as `PaginatedResponse<T>`), but a viewset that **overrides
  `list()`** can bypass pagination entirely. The document **accesses** endpoint
  does exactly this: `DocumentAccessViewSet.list()` builds the ancestor-aware
  access list by hand and `return`s a bare JSON array (`[…]`), so
  `listAccesses` decodes `[DocumentAccess]` directly (like `searchUsers`), **not**
  a `PaginatedResponse`. Decoding it as a `PaginatedResponse` threw on every call
  — which is why the Share sheet showed "Couldn't load members" for every
  document and the Shared tab's row enrichment silently no-op'd. **Invitations
  *are* paginated** (`InvitationViewset` uses `ListModelMixin` + `Pagination`), so
  `listInvitations` stays `PaginatedResponse<Invitation>`. The matching test
  fixtures must use the **real** shape (bare array for accesses); a hand-written
  paginated envelope hid this bug for as long as the feature existed
  (`ShareEndpointsClientTests.testListAccessesDecodesBareArrayResponse` pins it).
- **Permission logic is driven by the server `abilities` dict** — never hardcode
  client-side permission rules.
- CSRF/`Origin`/`Referer` headers are attached only on non-GET requests inside
  `performRequest`. New mutating endpoints must go through `send`/`sendVoid` so
  those headers are applied — see [Safety](../../AGENTS.md#safety--never-add-anything-dangerous).
- **The server host must be lowercase everywhere.** Hostnames are case-insensitive
  per DNS, but nothing that compares them is. iOS autocapitalizes the first letter
  of a plain text field, so a user typing their address gets `Docs.llun.dev`, and
  that single capital broke two things at once: `isLoginNavigationComplete`
  compared `url.host == serverHost` against WebKit's always-lowercase `url.host`
  and never matched, so the **login sheet never closed** and sat on the signed-in
  web app; and `siteOrigin` sent `Origin: https://Docs.llun.dev`, which Django
  answers with `403 CSRF Failed: Origin checking failed`, killing **every** non-GET
  while GETs — which carry no `Origin` — kept working, so the app looked
  mysteriously read-only. `normalizedServerURL` is the single canonicalization
  point and lowercases scheme + host (never the path — paths *are* case-sensitive);
  `isLoginNavigationComplete` compares case-insensitively (still an **exact** host
  match, never a suffix one); and `siteOrigin` lowercases too, because a
  `serverURL` persisted by an earlier launch still carries the capital. The Connect
  field also sets `.textInputAutocapitalization(.never)`. A read-only-looking app
  whose GETs all work is this bug until proven otherwise.
