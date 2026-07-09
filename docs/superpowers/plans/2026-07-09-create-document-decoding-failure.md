# Create document / subpage fail: `is_favorite` is absent from create responses

*2026-07-09*

## Symptom

Tapping **+** on Home showed `Couldn't create a document. Please try again.`, and the
message never went away. Creating a subpage failed too — silently, with no message at all.

## Wrong turns worth recording

Two early observations pointed hard at CSRF and were both misleading:

- "Pull-to-refresh shows no new *Untitled document*" suggested the POST never reached the
  server. It had. The document **was** created every time; the app only failed to decode the
  201 response, so every failed tap quietly littered the server with documents.
- "Pin/unpin and saving fail too" suggested a systemic non-GET failure — the shape of a
  missing `csrftoken` cookie or a rejected `Origin`. Reproducing the app's exact request
  against a live backend disproved it: with the app's headers, `POST documents/` returns
  **201**. Omitting `X-CSRFToken` gives `403 {"detail":"CSRF Failed: CSRF token missing."}`,
  and omitting `Origin`/`Referer` gives `403 … Referer checking failed`, but the app sends
  all three. A probe driving the real `WKWebView` login also confirmed the whole cookie
  chain is intact: WebKit → `syncCookies` → `HTTPCookieStorage` → Keychain round-trip →
  `csrfToken(from:)` all keep `csrftoken`.

The lesson: the app's one generic error sentence absorbed four distinct failure modes, so
the reporter's mental model of *which* had occurred was guesswork. Evidence, not inference,
settled it.

## Root cause

`is_favorite` is a **queryset annotation** the list endpoints add. `POST documents/` and
`POST documents/{id}/children/` serialize a freshly built instance that has no such
attribute, so the key is absent from both 201 bodies. Captured verbatim, the create
response's keys differ from a list row's by exactly this:

```
in LIST but MISSING from POST: ['is_favorite']
in POST but not in LIST      : ['content']
```

`Document.isFavorite` was a required `Bool`, so `JSONDecoder.docsAPI` threw
`keyNotFound("isFavorite")`. `DocsAPIClient.send` wrapped that as `DocsAPIError.decoding`,
and `HomeViewModel.createDocument` turned it into the friendly sentence — *after* the
server had already created the document. `EditorViewModel.addSubpage` hit the identical
failure on the identical missing key, but swallowed it with `try?`, which is why subpages
failed silently.

`link_reach` / `link_role` are present and concrete in both create responses; they were an
early suspect and are innocent.

## The fix

`Document.isFavorite` decodes with `decodeIfPresent(...) ?? false` — a brand-new document is
never a favorite. The hand-written `init(from:)` lives in an **extension** so the memberwise
initializer survives (`SubpageRow`'s preview uses it), and a round-trip test pins that the
bare-`JSONEncoder` caches still read it back.

Landed alongside three things that made the bug invisible in the first place:

1. **`RequestFailure` + `APIDiagnosticsLog` + the client's `onRequestFailure` hook.** Every
   non-2xx now records its status and the server's own reason, surfaced under the error as
   `HTTP 403: CSRF Failed: …`. Recorded synchronously before the throw, so a `catch` can
   read it; marker-gated so a transport error can't quote an unrelated response. Carries no
   headers, cookies, or CSRF token by construction.
2. **The error message can be dismissed**, and a retry clears it first. `createDocument`'s
   failure path never reached `load()`, which was the only thing that cleared it.
3. **`addSubpage()` reports its failure** instead of swallowing it — and deliberately does
   *not* call `becomeUnavailable()`: a 403 there means "you may not add children here", not
   "this document was taken away from you".

## Verification

- `DocumentDecodingTests.testDecodesACreateResponseThatOmitsIsFavorite` — fixture is a
  verbatim capture of a real `POST documents/` 201 body.
- End-to-end against a live backend, driving the app's real `DocsAPIClient` after a real
  `WKWebView` OIDC login: `createDocument` → 201, `createChild` → 201, zero non-2xx
  responses recorded.
- Full suite: 721 tests, 0 failures.

---

## Amendment, same day: a second, independent bug — host case

The "pin/unpin and saving fail too" report above was dismissed as a misreport. It was not.
There was a **second** bug, and it produces exactly that symptom.

The user typed `Notes.liiib.re` — iOS autocapitalizes the first letter of a plain text
field. `normalizedServerURL` canonicalized the scheme and stripped the path but left the
host's case alone, and two consumers compare hosts without normalizing:

- `isLoginNavigationComplete` compared `url.host == serverHost`. WebKit always reports
  `url.host` lowercased, so `notes.liiib.re != Notes.liiib.re`, detection never fired, and
  the **login sheet never closed** — it just sat there showing the signed-in web app.
- `DocsAPIClient.siteOrigin` sent `Origin: https://Notes.liiib.re`. Confirmed against the
  live backend:

  | `Origin` header | Result |
  |---|---|
  | `https://notes.liiib.re` | `201 Created` |
  | `https://Notes.liiib.re` | `403 {"detail":"CSRF Failed: Origin checking failed - https://Notes.liiib.re does not match any trusted origins."}` |

  Django compares `Origin` against its own host, so **every** non-GET 403s while GETs —
  which carry no `Origin` — keep working. The app looks read-only for no visible reason.

Fixed at three layers: `normalizedServerURL` lowercases scheme and host (the single
canonicalization point, and never the path — paths are case-sensitive);
`isLoginNavigationComplete` compares case-insensitively while staying an exact host match;
and `siteOrigin` lowercases too, since a `serverURL` persisted by an earlier launch still
carries the capital. The Connect field now sets `.textInputAutocapitalization(.never)`.

Verified against the live backend by feeding the literal string `Notes.liiib.re` through
`normalizedServerURL` → the real `WebLoginView.Coordinator` → `DocsAPIClient`: login
completes, and `createDocument`, `createChild` and `setFavorite` all return 2xx.

**Method note.** The first bug was found by instrumenting the request path; this one only
surfaced by instrumenting the *app itself* and reading `serverHost=Notes.liiib.re` in its
own log. Two probes that reproduced the login flow in a harness both passed, because the
harness passed a lowercase host it had constructed itself. The harness confirmed the code
worked on the input the harness chose — not on the input the user typed.

---

## Amendment 2, same day: a third bug — the read route doesn't exist on every backend

Opening any document on `notes.liiib.re` showed **"This document is no longer available."**
while the same document rendered fine in the web client.

`GET documents/{id}/formatted-content/?content_format=markdown` returns a plain **HTML 404**
on that server — the route does not exist. `DocsAPIErrorMapper` flattens every 404 to
`.notFound`, and `EditorViewModel` reads `.notFound` as "this document was deleted", so it
called `becomeUnavailable()`. It happened for *every* document, not one.

An unauthenticated probe distinguishes a missing route (HTML 404) from a missing object
(JSON 404):

| | `formatted-content/` | `content/` |
|---|---|---|
| `notes.liiib.re` | missing (HTML 404) | exists |
| `docs.llun.dev` | exists | exists |

The older release serves the markdown projection at `content/?content_format=markdown`, with
the identical `{id, title, content, created_at, updated_at}` payload.

`formattedContent` now tries the modern route and falls back **only on `.notFound`**. A 403
does not retry (revoked access is not a missing route); a genuinely deleted document 404s on
both routes and still surfaces `.notFound`, which the editor's teardown depends on; and the
actor memoizes `prefersLegacyContentRoute` only once the fallback has actually *succeeded* —
a 404 alone proves nothing. Keeping `formatted-content/` primary matters: `content/` is only
assumed to hold markdown on a server that has proved it lacks the modern route, so a backend
where `content/` returns raw base64 Yjs can never be misread — which, given the
full-overwrite save, would have pushed the corruption straight back to the server.

The editor also no longer asserts a deletion it cannot prove: `EditorViewModel` now takes the
`APIDiagnosticsLog` and shows the server's own response (`HTTP 404: Not found.`) beneath the
message, marker-gated so an offline failure never quotes an unrelated earlier response.

Verified against the live backend: 6 documents listed, exactly **one** 404 for the session
(then the memo skips it), every document opens, and a document with real content comes back
as markdown (`# Fix Preact Security Vulnerability…`, 6903 chars) rather than base64 Yjs.

---

## Amendment 3: review found the fallback itself was unsafe

The first version of the fallback fired on any `.notFound`. This file's own guidance already
said every 404 maps to `.notFound` — *"including a proxy hiccup"*. Since
`FormattedDocumentContent.content` is a plain `String?`, a base64 Yjs body from `content/`
decodes into it silently, and the full-overwrite save would push that blob back as the
document's markdown. The reassurance that "keeping `formatted-content/` primary makes this
safe" was wrong: one transient 404 on a modern server was enough.

The two 404s are distinguishable, measured against a live backend:

```
missing route  -> 404 text/html          (Django's plain page)
missing object -> 404 application/json   (DRF's {"detail": "Not found."})
```

So `DocsAPIErrorMapper` gained `.routeNotFound`, on *positive* evidence of HTML only — an
unlabelled 404 stays `.notFound`, since delete and cache-purge key off it. And because a
proxy can serve HTML for a path it swallowed on a server that *does* have the route, the
fallback additionally **confirms** the absence against a document id that cannot exist, where
a registered route still answers DRF's JSON 404. A transport failure during that probe
propagates rather than being read as "the route isn't there".

Worth remembering: two review agents read this diff. One found no correctness issues at all.
The other raised this exact scenario and then talked itself down to ~50% confidence and
*didn't report it*. The hazard was real. A finding that would be catastrophic if true deserves
to be checked against the server, not scored against a confidence threshold.
