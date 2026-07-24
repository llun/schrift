import Foundation

/// Whether an image embedded in document content may be fetched the moment its
/// block renders.
///
/// `![alt](url)` is authored by anyone who can write the document — a co-author, a
/// web client, a live-collaboration peer — and `AsyncImage` issues its GET on
/// appear. An off-server image therefore discloses the *reader's* IP address,
/// User-Agent and reading time to a host the reader never chose. Cookies are
/// domain-scoped so no session data goes with it: the request itself is the leak.
/// The reading surface amplifies it — `EditorView.readingSurface`'s `VStack` is
/// not lazy, so every image fires at once, below the fold included.
///
/// The decision is a true **origin** comparison (scheme + host + port), built by
/// composing `siteOrigin(for:)` — the app's single origin derivation, already used
/// for the REST CSRF `Origin` header and the collaboration socket handshake — on
/// both sides. That buys, for free and without a second implementation:
///   * lowercasing of scheme and host (load-bearing: `parseImageLine` preserves
///     the author's byte-for-byte spelling, so `HTTPS://Docs.Example.ORG/…` is a
///     real, legitimate `.image` block that must still match a lowercased server
///     origin);
///   * `URL.host` reading, never a string prefix, so
///     `https://docs.example.org@evil.com/x` is hosted at `evil.com` and
///     `docs.example.org.evil.com` cannot pass as a suffix;
///   * IPv6 re-bracketing and explicit-port handling;
///   * `nil` for a hostless/schemeless URL.
///
/// This is stricter than `documentLinkAction`, which compares host only and
/// ignores the port — defensible there because it merely decides whether to
/// *intercept* a tap, never to make a request. Here scheme and port count:
/// `http://host/x` and `https://host:8443/x` are different origins from
/// `https://host` and must confirm.
///
/// Fail-closed contract: everything unmatched — including anything the function
/// cannot parse — is `.confirm`. A wrong answer costs one extra tap, never a
/// silent request. Deliberate, documented false negatives (all safe): an origin
/// that spells an explicit default port (`https://host:443`, which
/// `normalizedServerURL` preserves) is a different string from the implicit one
/// and renders as tap-to-load; so does a trailing-dot host. Do not "fix" these by
/// normalizing ports here alone — `absoluteServerURL(for:)` treats them as
/// distinct origins too, and forking the definition of "same origin" is worse
/// than the papercut.
enum ImageLoadPolicy: Equatable {
    /// Same origin as the user's Docs server — every uploaded attachment
    /// (`https://<host>/media/<key>`) included. Auto-load, as before this gate.
    case allow
    /// Any other origin, or one we cannot make sense of. Placeholder; fetch only
    /// on tap.
    case confirm
}

/// Classifies `imageURL` against the signed-in server's origin.
///
/// `serverOrigin` is the caller's `siteOrigin(for: serverURL) ?? ""`. The empty
/// guard makes an unknown server fail closed (mirroring `documentLinkAction`'s
/// empty-host guard), and stops a hostless image URL — whose `siteOrigin` is also
/// nil — from ever reading as a match.
func imageLoadPolicy(for imageURL: URL, serverOrigin: String) -> ImageLoadPolicy {
    guard !serverOrigin.isEmpty, let imageOrigin = siteOrigin(for: imageURL) else { return .confirm }
    return imageOrigin == serverOrigin ? .allow : .confirm
}
