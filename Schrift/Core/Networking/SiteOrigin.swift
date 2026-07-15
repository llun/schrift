import Foundation

/// The bare site origin (scheme + host [+ port]) of a URL — lowercased, with an
/// IPv6 host re-bracketed. This is the value Django's CSRF middleware checks in
/// the `Origin`/`Referer` headers, and the origin the collaboration WebSocket is
/// pinned to. Returns nil when the URL has no scheme or host.
///
/// Pure, side-effect-free value code (no concurrency annotations): it is the
/// single implementation of the app's origin derivation, shared by
/// `DocsAPIClient` (REST CSRF) and `Core/Collaboration` (the socket handshake),
/// so a captured session cookie can only ever be scoped to the user's own
/// server. Scheme and host are lowercased because DNS is case-insensitive but
/// nothing comparing them is, and a `serverURL` persisted by an earlier launch
/// may still carry an autocapitalized first letter (see `normalizedServerURL`).
func siteOrigin(for url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), var host = url.host?.lowercased() else { return nil }
    // URL.host strips the brackets from an IPv6 literal; restore them so the
    // origin stays a valid URL for self-hosted IPv6 servers.
    if host.contains(":") { host = "[\(host)]" }
    var origin = "\(scheme)://\(host)"
    if let port = url.port { origin += ":\(port)" }
    return origin
}
