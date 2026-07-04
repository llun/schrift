# Persist session cookies + re-login sheet on real 401

**Date:** 2026-07-04
**Status:** Implemented

## Problem

After iOS terminated the backgrounded app, Schrift showed a fake "Offline"
banner and the user had to manually sign out and back in.

Two root causes:

1. **Session cookies were never persisted by the app.** Login copied the
   WKWebView's cookies into `HTTPCookieStorage.shared` only. Session-scoped
   cookies (nil `expiresDate` — e.g. Django's `sessionid` under
   `SESSION_EXPIRE_AT_BROWSER_CLOSE`) are dropped from the shared storage when
   the process dies. `SessionStore` persisted only the server URL and an
   `isAuthenticated` flag byte — so on relaunch the app *looked* signed in
   while its actual session credential was gone.
2. **401 was mislabeled as offline.** `DocsAPIErrorMapper` maps 401 →
   `.sessionExpired`, but `HomeViewModel`/`SharedViewModel` set
   `isOffline = true` on *any* load error, and nothing ever routed to
   re-login. The only escape was the manual Sign out button.

## Fix

### A. Session cookies persist in the Keychain

- New `StoredCookie` (`Core/Auth/SessionCookies.swift`): a Codable snapshot of
  `HTTPCookie` (which is not Codable itself), preserving nil `expiresDate` so
  a session-only cookie reconstructs as session-only. Plus pure
  `validStoredCookies(_:now:)` which drops already-expired entries.
- `SessionStore` (now `@MainActor @Observable`) snapshots
  `cookieStorage.cookies(for: serverURL)` into the Keychain
  (`dev.llun.Schrift.sessionCookies`) on every `signIn`, restores them into
  `HTTPCookieStorage.shared` **synchronously in `init`** (before RootView
  builds the API client), and deletes both the Keychain entry and the live
  server cookies on `signOut`. Cookies are never logged and never marked
  `kSecAttrSynchronizable`.
- `CookieStoring` gained `cookies(for:)` / `deleteCookie(_:)` (still satisfied
  by `HTTPCookieStorage` with an empty conformance).

### B. Real 401 → re-login sheet (not "offline")

- `DocsAPIClient` gained `onSessionExpired: @Sendable () -> Void = {}`, fired
  just before `.sessionExpired` is thrown. The **one shared client** built in
  `AuthenticatedHomeContainer.init` wires it to
  `SessionStore.noteSessionExpired()`, so every endpoint — including
  background saves — reports through a single seam. Chosen over injecting
  `SessionStore` into all ~8 view models: zero per-VM churn and no way for a
  future endpoint to forget the check. The flag is idempotent, so concurrent
  401s present the sheet once.
- `SessionStore.needsReauthentication` (observable, never persisted) drives a
  `.sheet` in `AuthenticatedHomeContainer` hosting
  `ReauthenticationSheetView` + `ReauthenticationViewModel` — the same OIDC
  `WebLoginView` as first sign-in. `WKWebsiteDataStore.default()` still holds
  the IdP's cookies, so re-login usually completes without typing. Completion
  confirms with `GET users/me/` then `sessionStore.signIn(serverURL:)`, which
  re-persists the fresh cookies and clears the flag; the Home list reloads
  (which also re-runs draft recovery, retrying any save that 401ed).
- `HomeViewModel`/`SharedViewModel` no longer treat `.sessionExpired` as
  offline: cached rows keep showing silently while the sheet handles
  recovery. `.network`/`.server`/etc. keep the existing offline behavior.

## Decisions & accepted limitations

- **Cancel is non-destructive:** dismissing the sheet keeps cached data
  visible with no banner; the next failing request re-presents it. Manual
  Sign out remains the escape hatch.
- **An already-open editor doesn't auto-refresh** after re-login; it recovers
  on pull-to-refresh or its next save (the save coordinator retries via draft
  recovery on the Home reload).
- The re-login confirmation client deliberately has **no** `onSessionExpired`
  hook — a still-401 confirmation shows the sheet's inline error instead of
  re-poking the flag mid-flow.
- Metadata caches keep their existing sign-out behavior (not cleared) — the
  recorded decision from the 2026-07-03 instant-local-doc-lists plan stands.
- How *long* a session lives is server config (Django `SESSION_COOKIE_AGE`,
  `SESSION_EXPIRE_AT_BROWSER_CLOSE`); the app can persist a cookie across
  process death but cannot outlive the server's invalidation.
