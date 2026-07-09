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
