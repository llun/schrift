# Fix: 2FA sign-in leaves the WKWebView login sheet stuck open

**Date:** 2026-07-03
**Area:** `Features/Connect` (WKWebView OIDC login), `Core/Auth`

## Symptom

Signing in to `docs.llun.dev` with **2FA** enabled: after entering the OTP code
and pressing continue, the sign-in sheet does **not** close — the app stays on
the web view instead of returning to the native UI. Non-2FA logins worked.

## Root cause

Login completion was detected from a **single** navigation callback,
`WKNavigationDelegate.webView(_:didFinish:)`, evaluating the (correct) host-bound
predicate `isLoginNavigationComplete` = `url.host == serverHost && !url.path.hasPrefix("/api/v1.0/")`.

The redirect chain is **identical with and without 2FA** (verified against the
upstream sources — `suitenumerique/docs`, `django-lasuite` `oidc_login`,
`mozilla-django-oidc`, and Keycloak):

```
GET /api/v1.0/authenticate/  →(302) external IdP authorization endpoint (different host)
   →(user authenticates; OTP is an extra step INSIDE the IdP, before the auth code is minted)
   →(302)→ /api/v1.0/callback/?code=…&state=…   (docs host, always a 302 — never a 200 page)
   →(302)→ LOGIN_REDIRECT_URL = the docs host root (e.g. https://docs.llun.dev, same host)
```

So the target URL the app waits for is correct and 2FA-agnostic. What differs on
the 2FA path is the *navigation timing*: the extra interactive IdP step, plus the
docs Next.js SPA's immediate client-side `/` → `/home/` redirect, can supersede or
drop the final full page-load event. A `didFinish`-only detector then never sees a
qualifying event and the sheet waits forever.

Notes that shaped the fix:

- The callback is **always** a 302, never a 200 under `/api/v1.0/`, so the
  `!hasPrefix("/api/v1.0/")` guard is not the blocker.
- The Django session cookie is `docs_sessionid` (hardcoded in docs settings),
  host-scoped — **but it is set on the very first `/authenticate/` request** (an
  anonymous session stores the OIDC state), so *cookie presence is not a valid
  "logged-in" trigger*; it would fire prematurely. The URL-landing signal is the
  right trigger. `csrftoken` is likewise set for anonymous users.

## Fix

Evaluate the **same** host-bound predicate across the navigation lifecycle —
`didCommit` **and** `didFinish` — routed through one shared core,
`Coordinator.handleNavigation(to:)`. A cross-site navigation back to the server
host always *commits*, and `didCommit` fires earlier and survives an immediate
client-side redirect that would cancel the matching `didFinish`. This makes
detection robust to the 2FA/SPA timing **without changing which URL we accept**.

Safety is preserved:

- Detection stays bound to the exact `serverHost` (the CLAUDE.md safety rule);
  the accepted-URL predicate `isLoginNavigationComplete` is unchanged.
- The view model's native `GET /api/v1.0/users/me/` confirmation still rejects any
  false positive before persisting auth.
- Cookie capture/sync (`docs_sessionid` → `HTTPCookieStorage.shared`), CSRF
  handling, Keychain hygiene, and the zero-dependency posture are unchanged.

## Testability

The completion logic was extracted behind two seams so it is unit-testable
without a live WebKit stack, following the repo's dependency-injection convention:

- `handleNavigation(to:)` takes the observed URL directly (the delegate methods
  pass `webView.url`).
- `captureCookies` is an injected closure that syncs cookies then runs a
  `@MainActor` (hence `Sendable`) completion — so no non-`Sendable` `HTTPCookie`
  value crosses a concurrency boundary. Its production default reads
  `WKWebsiteDataStore.default().httpCookieStore`, identical to the prior behavior.

New tests (`SchriftTests/Features/Connect/WebLoginCoordinatorTests.swift`) were
written test-first (watched RED, then GREEN): a committed navigation back to the
app completes; the bare server root (`https://docs.llun.dev`, empty path — the
default `LOGIN_REDIRECT_URL`) completes; the IdP host, `/api/v1.0/callback/`, and
a `nil` URL do **not** complete; and completion fires exactly once across the
multiple callbacks a single login produces. Plus a pure-predicate regression test
in `WebLoginTests.swift` for the bare-root landing. Full suite: 417 tests, 0
failures on iPhone 17 (iOS 18).
