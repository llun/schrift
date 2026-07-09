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
    /// which includes the `/api/v1.0/` path.
    private var siteOrigin: String? {
        guard let scheme = baseURL.scheme, var host = baseURL.host else { return nil }
        // URL.host strips the brackets from an IPv6 literal; restore them so the
        // Origin/Referer stay valid URLs for self-hosted IPv6 servers.
        if host.contains(":") { host = "[\(host)]" }
        var origin = "\(scheme)://\(host)"
        if let port = baseURL.port { origin += ":\(port)" }
        return origin
    }

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
