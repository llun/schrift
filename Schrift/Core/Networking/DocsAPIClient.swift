import Foundation

actor DocsAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let cookieProvider: @Sendable () -> [HTTPCookie]
    /// Fired on every real 401 (before `.sessionExpired` is thrown) so the app
    /// can raise its re-login flow. Consumers must be idempotent — concurrent
    /// requests can all 401 at once. Production default is a no-op.
    /// Given the instant the refused request was *issued*, so a 401 for a request that
    /// predates a re-login can be told apart from the new session being refused.
    private let onSessionExpired: @Sendable (ContinuousClock.Instant) -> Void
    /// Fired on every non-2xx response (before the mapped error is thrown) with
    /// the status and the server's own explanation, which `DocsAPIError` drops.
    /// Called synchronously, so a caller's `catch` can quote it. Production
    /// default is a no-op.
    private let onRequestFailure: @Sendable (RequestFailure) -> Void
    /// Fired when a request proves the server reachable (any HTTP response, whatever
    /// its status) or proves it unreachable (a connectivity-class `URLError`). Feeds
    /// `ConnectivityMonitor`'s display-only "server unreachable" evidence. Production
    /// default is a no-op.
    private let onTransportOutcome: @Sendable (TransportOutcome, ContinuousClock.Instant) -> Void
    /// Set once a server has proved it has no `formatted-content/` route *and* that
    /// `content/` answers, so every later content load skips the detection instead of paying
    /// for it per document. Both halves matter: pinning this to a route that cannot answer
    /// would break every content read for the rest of the client's life, with no way back but
    /// a relaunch. See `formattedContent(documentID:format:)`.
    var prefersLegacyContentRoute = false

    /// Set once this server has answered the BlockNote tree read (`formattedContentTree`) with
    /// a missing route or a `400` — a server whose `formatted-content/` does not speak
    /// `content_format=json` — so every later content read skips a second request that can
    /// only fail the same way. Safe to pin, unlike a content route: the tree is best-effort,
    /// and its absence costs only the leaf-nesting overlay, never a read. Scoped to this
    /// client, so an upgraded server is asked again after the next sign-in or launch.
    var contentTreeUnsupported = false

    /// A favorites route that returned a decoded page. Scoped to this server/client;
    /// discarded on a later 404 so a server upgrade can be detected without signing out.
    var favoriteListPath: String?

    /// Where `saveDocumentContent` writes a document's body on this server: the legacy
    /// `documents/{id}/content/` PATCH, or Docs 6's collaboration server
    /// (`/collaboration/ydoc/v1/{org}/{id}`). nil until something proved which one —
    /// `serverConfig()` (release version / collaboration URL shape), or a legacy PATCH
    /// answering Django's HTML 404 followed by a collaboration GET that answered. See
    /// `ContentSaveRoute` (`CollaborationYDocEndpoints.swift`).
    var contentSaveRoute: ContentSaveRoute?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        cookieProvider: (@Sendable () -> [HTTPCookie])? = nil,
        onSessionExpired: @escaping @Sendable (ContinuousClock.Instant) -> Void = { _ in },
        onRequestFailure: @escaping @Sendable (RequestFailure) -> Void = { _ in },
        onTransportOutcome: @escaping @Sendable (TransportOutcome, ContinuousClock.Instant) -> Void = { _, _ in }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieProvider = cookieProvider ?? { HTTPCookieStorage.shared.cookies(for: baseURL) ?? [] }
        self.onSessionExpired = onSessionExpired
        self.onRequestFailure = onRequestFailure
        self.onTransportOutcome = onTransportOutcome
    }

    /// The bare site origin (scheme + host [+ port]) derived from `baseURL`, used
    /// for the CSRF `Origin`/`Referer` headers. Note this is *not* `baseURL`,
    /// which includes the `/api/v1.0/` path. The derivation is the shared pure
    /// `siteOrigin(for:)` (`SiteOrigin.swift`), also used by the collaboration
    /// WebSocket so both pin to the same origin.
    ///
    /// Django compares `Origin` against its own host and answers a mismatch with
    /// `403 CSRF Failed: Origin checking failed`, which kills **every** non-GET while
    /// GETs — which carry no Origin — keep working, making the app look mysteriously
    /// read-only.
    private var siteOrigin: String? { Schrift.siteOrigin(for: baseURL) }

    /// The signed-in server's origin, for the encoder's attachment
    /// classification (`MarkdownYjs.encode(markdown:serverOrigin:)`).
    ///
    /// Lives here for the same reason `absoluteServerURL` does — `baseURL` is
    /// private — and it means the origin never has to be threaded through the
    /// save coordinator to reach the one place that encodes.
    nonisolated var serverOrigin: String { Schrift.siteOrigin(for: baseURL) ?? "" }

    /// Resolves a server-relative path (e.g. the `/media/…` value returned by
    /// media-check) against the **server origin**, not the `/api/v1.0/` base.
    /// Lives here because `baseURL` is private.
    ///
    /// `path` is **server-controlled**, and `URL(string:relativeTo:)` happily
    /// escapes the origin: `//evil.com/x` resolves to `https://evil.com/x`, and
    /// `http://evil.com/x` even downgrades the scheme. The resolved URL would be
    /// embedded in the document and persisted for every collaborator, so pin it
    /// to the same origin as `baseURL` and return nil otherwise.
    func absoluteServerURL(for path: String) -> URL? {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
            url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port
        else { return nil }
        return url
    }

    /// `accept` sets the `Accept` header; nil (the default) sends none, exactly as every
    /// Django route has always been called. Only the collaboration server's document route
    /// needs it, to choose its JSON representation over raw bytes.
    func get<T: Decodable>(_ path: String, accept: String? = nil) async throws -> T {
        try await send(path: path, method: "GET", body: nil, accept: accept)
    }

    func getRawData(_ path: String) async throws -> Data {
        try await performRequest(path: path, method: "GET", body: nil, contentType: nil)
    }

    func send<T: Decodable>(
        path: String, method: String, body: Data?, contentType: String? = "application/json", accept: String? = nil
    ) async throws -> T {
        let data = try await performRequest(
            path: path, method: method, body: body, contentType: contentType, accept: accept)
        do {
            return try JSONDecoder.docsAPI.decode(T.self, from: data)
        } catch {
            throw DocsAPIError.decoding("\(error)")
        }
    }

    func sendVoid(path: String, method: String, body: Data?, contentType: String? = "application/json") async throws {
        _ = try await performRequest(path: path, method: method, body: body, contentType: contentType)
    }

    private func performRequest(
        path: String, method: String, body: Data?, contentType: String?, accept: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DocsAPIError.network("Invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        if let body {
            request.httpBody = body
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        if method != "GET" {
            if let token = csrfToken(from: cookieProvider()) {
                request.setValue(token, forHTTPHeaderField: "X-CSRFToken")
            }
            // Django's CsrfViewMiddleware requires an Origin (or, failing that, a
            // Referer) header that matches the host on HTTPS. URLSession sends
            // neither, so every unsafe request 403s with "CSRF Failed: Referer
            // checking failed - no Referer." until we set the site origin here.
            // Origin is checked first and is sufficient; Referer is sent too in
            // case the platform strips a custom Origin header.
            if let origin = siteOrigin {
                request.setValue(origin, forHTTPHeaderField: "Origin")
                request.setValue(origin + "/", forHTTPHeaderField: "Referer")
            }
        }

        let data: Data
        let response: URLResponse
        // Captured before the await: a request issued on a dead link reports only when its
        // timeout fires, and the monitor needs to know it began long before that.
        let startedAt = ContinuousClock.now
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if isConnectivityFailure(error) {
                onTransportOutcome(.unreachable, startedAt)
            }
            throw DocsAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DocsAPIError.network("Response was not an HTTP response")
        }
        // Any status proves the server answered; only the status handling below differs.
        onTransportOutcome(.reachedServer, startedAt)

        guard (200..<300).contains(httpResponse.statusCode) else {
            onRequestFailure(
                RequestFailure(method: method, path: path, statusCode: httpResponse.statusCode, body: data))
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            let error = DocsAPIErrorMapper.map(statusCode: httpResponse.statusCode, headers: headers)
            if error == .sessionExpired {
                onSessionExpired(startedAt)
            }
            throw error
        }

        return data
    }
}
