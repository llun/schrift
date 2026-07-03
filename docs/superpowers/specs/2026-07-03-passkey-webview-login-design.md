# Passkey-Capable WebView Login via Associated Domains — Design

- **Date:** 2026-07-03
- **Status:** Approved design (pre-implementation)
- **Author:** Claude Code + Maythee (pairing)
- **Scope:** Make passkey (WebAuthn) sign-in work inside Schrift's existing
  `WKWebView` login, for a self-hosted stack where **Docs (`docs.llun.dev`)
  federates OIDC to a better-auth identity provider at `llun.social`**.

## Problem

Signing in with a passkey from the in-app login web view does nothing — tapping
the passkey button produces no system prompt and no login. Password/OIDC login in
the same web view works.

## Root cause (verified)

Passkeys are WebAuthn. better-auth's passkey plugin (which wraps SimpleWebAuthn)
runs the ceremony **purely in-page** via `navigator.credentials.get()/create()`,
so the ceremony is bound to the page's origin (`llun.social`). On iOS, a **bare
`WKWebView` only performs a WebAuthn ceremony for a relying-party domain the
embedding app has declared in its Associated Domains entitlement**. Schrift's
login is a bare `WKWebView()` ([`WebLoginView.swift:10`](../../../Schrift/Features/Connect/WebLoginView.swift))
and the app declares **no** associated domains (no `.entitlements` file; no
`webcredentials` entry anywhere). With no association, iOS never presents the
passkey sheet and the JS call fails/no-ops — hence "nothing happens."

Apple (Developer Forums, DTS): *"In iOS 16, passkeys can be used in a `WKWebView`
if the client app is using Associated Domains for the relying party. For other
relying parties, you can use passkeys in `SFSafariViewController` or
`ASWebAuthenticationSession`."*

## Decision & alternatives considered

**Chosen: Option A — declare Associated Domains for the better-auth IdP
(`llun.social`) and keep the existing WebView + cookie flow unchanged.**

Why not the alternatives:

- **`ASWebAuthenticationSession` (Safari context).** It is the only way to get
  passkeys *without* Associated Domains, but it **cannot return cookies to the
  app** — Apple isolates the Safari service process by design (RFC 8252). Schrift's
  entire authenticated state *is* the `docs_sessionid` cookie scraped from the web
  view. `ASWebAuthenticationSession` only hands back a callback URL, and **La Suite
  Docs has no token endpoint and no custom-scheme redirect** (it is strictly
  browser cookie-session via `mozilla-django-oidc`/`django-lasuite`). So this path
  is a dead end for this backend without forking Docs.
- **`ASWebAuthenticationSession` + a native handoff endpoint on Docs.** Works for
  arbitrary servers with no baked-in domain, but requires extending/forking Docs
  (a third-party project) to mint a one-time code and redirect to `schrift://…`,
  plus significant app rework — heavier, with ongoing maintenance. Rejected for now.

Option A is almost entirely configuration: the existing passkey button starts
working once the app and `llun.social` are associated. Trade-off accepted: passkeys
work only for servers whose IdP domain is baked into the entitlement (i.e. your own
stack); other servers still log in via password in the web view (graceful
degradation).

## Established facts (evidence)

- **Schrift session model:** after WebView login, cookies are synced from the web
  view into `HTTPCookieStorage.shared`
  ([`WebLoginView.swift:38`](../../../Schrift/Features/Connect/WebLoginView.swift));
  `SessionStore` persists only the server URL + a keychain boolean flag
  ([`SessionStore.swift:21`](../../../Schrift/Core/Auth/SessionStore.swift)); the
  real credential is the cookie. `DocsAPIClient` relies on
  `HTTPCookieStorage.shared` + the `csrftoken` cookie → `X-CSRFToken` header for
  mutations.
- **Docs backend:** session cookie is **`docs_sessionid`** (`SESSION_COOKIE_NAME`);
  CSRF cookie is Django-default **`csrftoken`**; session lifetime ~12h. External
  OIDC provider is fully env-configurable (`OIDC_OP_*` / `OIDC_RP_*`), so
  `docs.llun.dev` → better-auth-at-`llun.social` is a supported configuration. No
  native/token/custom-scheme auth path exists without a fork.
- **better-auth passkeys** are in-page `navigator.credentials.*`; server config is
  `rpID` / `origin` / `rpName`. better-auth *can* also be a full OIDC provider
  (`oidcProvider()` plugin), but that path is not needed for Option A.

## Design

The change has three collaborating parts. Only part 1 touches this repo.

### 1. App entitlement (source of truth: `project.yml`)

Add an `entitlements` block to the `Schrift` target so XcodeGen generates the
entitlements file (keeping `project.yml` the source of truth, per repo convention —
never hand-edit the `.xcodeproj`):

```yaml
targets:
  Schrift:
    entitlements:
      path: Schrift/Schrift.entitlements
      properties:
        com.apple.developer.associated-domains:
          - webcredentials:$(SCHRIFT_IDP_DOMAIN)
```

The IdP host is supplied through a build variable rather than a literal in the
target spec, and its value is committed **once** in `Signing.xcconfig`:

```
// Signing.xcconfig (committed)
SCHRIFT_IDP_DOMAIN = llun.social
```

Rationale for committing the value (decided with the user): `llun.social` is a
public instance and this yields identical behavior in on-device dev **and**
CI/TestFlight with no per-environment injection. A fork can override
`SCHRIFT_IDP_DOMAIN` in the git-ignored `Local.xcconfig`; document that override in
`Local.xcconfig.example`.

The generated `Schrift/Schrift.entitlements` is a build artifact produced from
`project.yml` (like the `.xcodeproj`), so it is **git-ignored**, not committed.

**No Swift code changes are expected.** The WebView, cookie scraping, CSRF, and
`DocsAPIClient` are untouched. (A `WKUIDelegate` on `WebLoginView` is intentionally
*not* added unless on-device verification shows a popup-based passkey path needs
it — the ceremony is a modal, not a popup.)

### 2. Associated-domain file (AASA) on `llun.social`

Served at `https://llun.social/.well-known/apple-app-site-association`, over HTTPS,
`Content-Type: application/json`, with **no redirect**:

```json
{ "webcredentials": { "apps": ["<TEAM_ID>.dev.llun.Schrift"] } }
```

`<TEAM_ID>` is the same 10-character Apple Developer Team ID used for signing (kept
out of this repo — it lives in `Local.xcconfig` / `match`). This file is added to
the activities.next app that serves `llun.social` (the user's infra, not this repo).

### 3. better-auth passkey config (on `llun.social`)

Confirm the `passkey()` plugin is configured with `rpID: "llun.social"` and
`origin: "https://llun.social"` — they must equal the associated domain and the
page origin. Expected to already be correct since the login page is served from
`llun.social`; this is a one-line verification, not a change.

### 4. Signing / provisioning capability (required)

Because the entitlement is present in **every** build (the domain is committed),
the App ID `dev.llun.Schrift` must have the **Associated Domains** capability
enabled, or signing fails:

- **On-device dev** (`CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM` from
  `Local.xcconfig`): Xcode adds the capability to the development profile
  automatically when it sees the entitlement — normally seamless.
- **CI / TestFlight** (`match`, manual signing): enable **Associated Domains** on
  the App ID in the Apple Developer portal, then re-run `match` to regenerate the
  distribution provisioning profile with the capability. Until this is done, the
  next TestFlight build will fail to sign. Verify the fastlane `beta` lane still
  succeeds after the entitlement is added.

## Verification

This is a platform capability, so it is verified **on-device**, not by unit tests
(there is no new Swift logic to unit-test — consistent with keeping the change
config-only). Fast-iteration path that avoids waiting on Apple's AASA CDN cache:

1. Temporarily set the entitlement value to `webcredentials:llun.social?mode=developer`.
2. On the test device enable **Settings ▸ Developer ▸ Associated Domains
   Development**.
3. Build/run on device, open login, tap the passkey button.
4. **Expected:** the system Face ID / passkey sheet appears; after authentication
   the WebView completes the OIDC round-trip, `docs_sessionid` is scraped, the
   `GET users/me/` probe succeeds, and the app lands authenticated.
5. Remove `?mode=developer` before release.

Also confirm the pre-existing password/OIDC login still works (regression check),
and that a normal (non-`?mode=developer`) build authenticates once the AASA is live
on `llun.social`.

## Out of scope

- Switching to `ASWebAuthenticationSession` (dead end for this cookie model).
- Any change to the Docs backend.
- CI-side domain injection (unnecessary — the value is committed).
- `WKUIDelegate` / popup handling (add only if verification proves it necessary).

## Safety alignment

No change to TLS validation, CSRF headers, cookie handling, Keychain usage, or
logging; the cookie-scraping session flow is untouched. The only new surface is a
`webcredentials` entitlement scoped to the user's own IdP (`llun.social`) — a
signing/capability change explicitly signed off by the user. No secrets are
committed; the Team ID stays in `Local.xcconfig` / `match` and the AASA lives on
the user's server.

## Open items / follow-ups

- Enable Associated Domains on the App ID + regenerate `match` profiles **before**
  the next TestFlight release (blocking for CI signing).
- Host and validate the AASA on `llun.social` (validate with Apple's
  `swcutil dl -d llun.social` on-device, or an AASA validator).
- If on-device testing reveals the passkey path opens a popup, add a minimal
  `WKUIDelegate` to `WebLoginView` (separate, small change).

## Sources

- Apple Developer Forums 723273 (passkeys in WKWebView require Associated Domains):
  https://developer.apple.com/forums/thread/723273
- passkeys.dev iOS reference (WebView vs system WebView WebAuthn):
  https://passkeys.dev/docs/reference/ios/
- Apple Developer Forums 663533 (ASWebAuthenticationSession cookie isolation):
  https://developer.apple.com/forums/thread/663533
- better-auth passkey plugin: https://www.better-auth.com/docs/plugins/passkey
- better-auth OIDC provider plugin:
  https://www.better-auth.com/docs/plugins/oidc-provider
- La Suite Docs / django-lasuite OIDC login (mozilla-django-oidc wrapper):
  https://github.com/suitenumerique/docs · https://github.com/suitenumerique/django-lasuite
