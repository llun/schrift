import Foundation

actor DocsAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let cookieProvider: @Sendable () -> [HTTPCookie]
    /// Fired on every real 401 (before `.sessionExpired` is thrown) so the app
    /// can raise its re-login flow. Consumers must be idempotent — concurrent
    /// requests can all 401 at once. Production default is a no-op.
    private let onSessionExpired: @Sendable () -> Void
    /// Fired on every non-2xx response (before the mapped error is thrown) with
    /// the status and the server's own explanation, which `DocsAPIError` drops.
    /// Called synchronously, so a caller's `catch` can quote it. Production
    /// default is a no-op.
    private let onRequestFailure: @Sendable (RequestFailure) -> Void
    /// Set once a server has proved it has no `formatted-content/` route *and* that
    /// `content/` answers, so every later content load skips the detection instead of paying
    /// for it per document. Both halves matter: pinning this to a route that cannot answer
    /// would break every content read for the rest of the client's life, with no way back but
    /// a relaunch. See `formattedContent(documentID:format:)`.
    var prefersLegacyContentRoute = false

    init(
        baseURL: URL,
        session: URLSession = .shared,
        cookieProvider: (@Sendable () -> [HTTPCookie])? = nil,
        onSessionExpired: @escaping @Sendable () -> Void = {},
        onRequestFailure: @escaping @Sendable (RequestFailure) -> Void = { _ in }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieProvider = cookieProvider ?? { HTTPCookieStorage.shared.cookies(for: baseURL) ?? [] }
        self.onSessionExpired = onSessionExpired
        self.onRequestFailure = onRequestFailure
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

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "GET", body: nil)
    }

    func getRawData(_ path: String) async throws -> Data {
        try await performRequest(path: path, method: "GET", body: nil, contentType: nil)
    }

    func send<T: Decodable>(path: String, method: String, body: Data?, contentType: String? = "application/json")
        async throws -> T
    {
        let data = try await performRequest(path: path, method: method, body: body, contentType: contentType)
        do {
            return try JSONDecoder.docsAPI.decode(T.self, from: data)
        } catch {
            throw DocsAPIError.decoding("\(error)")
        }
    }

    func sendVoid(path: String, method: String, body: Data?, contentType: String? = "application/json") async throws {
        _ = try await performRequest(path: path, method: method, body: body, contentType: contentType)
    }

    private func performRequest(path: String, method: String, body: Data?, contentType: String?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DocsAPIError.network("Invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

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
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DocsAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DocsAPIError.network("Response was not an HTTP response")
        }

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
                onSessionExpired()
            }
            throw error
        }

        return data
    }
}
