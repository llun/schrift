import Foundation

/// Pure, origin-pinned builders for the Hocuspocus collaboration WebSocket.
///
/// Every dialed URL is derived from the user's own server origin — never from a
/// server-supplied config value — so a captured session cookie stays scoped to
/// the server the user chose, the same rule `siteOrigin`/`absoluteServerURL`
/// enforce for REST. Side-effect-free value code; no concurrency annotations.
enum CollaborationEndpoint {
    /// `ws(s)://<host>[:port]/collaboration/ws/?room=<doc-uuid>` derived from the
    /// REST `baseURL`. `https`→`wss`, `http`→`ws`; any other scheme (or a
    /// scheme/host-less URL) yields nil, so a `javascript:`/`file:`/`data:` base
    /// can never be dialed. The room UUID is lowercased to match the Django
    /// backend and is also the Hocuspocus `documentName` inside every frame.
    ///
    /// The origin (scheme mapping aside) comes straight from `siteOrigin(for:)`,
    /// so host lowercasing, port, and IPv6 bracketing stay identical to the REST
    /// CSRF origin.
    static func webSocketURL(serverBaseURL: URL, documentID: UUID) -> URL? {
        guard let origin = siteOrigin(for: serverBaseURL) else { return nil }
        let wsOrigin: String
        if origin.hasPrefix("https://") {
            wsOrigin = "wss://" + origin.dropFirst("https://".count)
        } else if origin.hasPrefix("http://") {
            wsOrigin = "ws://" + origin.dropFirst("http://".count)
        } else {
            return nil
        }
        // The room value is a UUID, which is already URL-safe.
        return URL(string: "\(wsOrigin)/collaboration/ws/?room=\(documentID.uuidString.lowercased())")
    }

    /// The `Origin` header for the handshake — the server origin, matching the
    /// allowed origin y-provider checks (the same value as the REST CSRF Origin).
    static func originHeader(serverBaseURL: URL) -> String? {
        siteOrigin(for: serverBaseURL)
    }

    /// The `Cookie` header, assembled explicitly from the stored cookies for the
    /// origin. The Django session cookie is what authenticates the socket, but
    /// its name is deployment-specific, so forward all of them. Returns nil when
    /// there are no cookies (nothing to send).
    static func cookieHeader(cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// The full `URLRequest` for the collaboration WebSocket upgrade: the
    /// origin-pinned `wss` URL, an explicit `Origin` header (URLSession does not
    /// add one for a WebSocket, and y-provider requires it), and an explicit
    /// `Cookie` header assembled from the stored cookies. Cookie handling is
    /// turned **off** so URLSession does not *also* attach cookies (which would
    /// duplicate them); we forward exactly the origin's cookies ourselves.
    /// Returns nil when the base URL can't be pinned to a `ws(s)` origin.
    static func webSocketRequest(serverBaseURL: URL, documentID: UUID, cookies: [HTTPCookie]) -> URLRequest? {
        guard let url = webSocketURL(serverBaseURL: serverBaseURL, documentID: documentID) else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if let origin = originHeader(serverBaseURL: serverBaseURL) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let cookie = cookieHeader(cookies: cookies) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }
}
