import Foundation

/// Images may be external after an explicit tap. This transport therefore deliberately does
/// not use the REST client's credentials, CSRF headers, shared URL cache or automatic cookies.
/// Same-server requests receive only cookies applicable to their exact URL. Redirects remain
/// on the initial origin, including for consented external requests; HTTP auth never consults
/// a credential store. The streaming read bounds bytes even without Content-Length.
actor ImageDataClient {
    private let session: URLSession
    private let cookieProvider: @Sendable (URL) -> [HTTPCookie]
    static let maximumBytes = 12 * 1024 * 1024

    init(
        session: URLSession? = nil,
        cookieProvider: @escaping @Sendable (URL) -> [HTTPCookie] = { HTTPCookieStorage.shared.cookies(for: $0) ?? [] }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = Self.configuration()
            self.session = URLSession(configuration: configuration)
        }
        self.cookieProvider = cookieProvider
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    /// Immutable cookies captured by the session-scoped loader. A redirect
    /// re-applies only snapshot cookies eligible for its destination path.
    func data(for url: URL, cookies: [HTTPCookie], byteLimit: Int = ImageDataClient.maximumBytes) async throws -> Data {
        try await data(
            for: url,
            cookieProvider: { destination in
                cookies.filter { imageCookieApplies($0, to: destination) }
            }, byteLimit: byteLimit)
    }

    func data(for url: URL, serverOrigin: String) async throws -> Data {
        let provider: @Sendable (URL) -> [HTTPCookie]
        if imageLoadPolicy(for: url, serverOrigin: serverOrigin) == .allow {
            provider = cookieProvider
        } else {
            provider = { _ in [] }
        }
        return try await data(for: url, cookieProvider: provider, byteLimit: Self.maximumBytes)
    }

    private func data(for url: URL, cookieProvider: @escaping @Sendable (URL) -> [HTTPCookie], byteLimit: Int)
        async throws -> Data
    {
        guard let origin = siteOrigin(for: url), url.user == nil, url.password == nil, byteLimit > 0 else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let cookies = cookieProvider(url)
        if !cookies.isEmpty { request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies) }
        let delegate = ImageRequestDelegate(origin: origin, cookieProvider: cookieProvider)
        let (stream, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            response.url.flatMap(siteOrigin(for:)) == origin
        else {
            stream.task.cancel()
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= Int64(min(Self.maximumBytes, byteLimit)) else {
            stream.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        do {
            for try await byte in stream {
                guard data.count < min(Self.maximumBytes, byteLimit) else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
        } catch {
            stream.task.cancel()
            throw error
        }
        return data
    }
}

func imageCookieApplies(_ cookie: HTTPCookie, to url: URL) -> Bool {
    guard let host = url.host?.lowercased(), cookie.expiresDate.map({ $0 > Date() }) ?? true,
        !cookie.isSecure || url.scheme?.lowercased() == "https"
    else { return false }
    let domain = cookie.domain.lowercased()
    let hostMatches =
        domain.hasPrefix(".")
        ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
    let encodedPath = url.path(percentEncoded: true)
    let path = encodedPath.isEmpty ? "/" : encodedPath
    let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
    let pathMatches =
        path == cookiePath
        || (path.hasPrefix(cookiePath)
            && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
    return hostMatches && pathMatches
}

func imageRedirectAllowed(fromOrigin: String, to url: URL) -> Bool {
    url.user == nil && url.password == nil && siteOrigin(for: url) == fromOrigin
}

final class ImageRequestDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: String
    private let cookieProvider: @Sendable (URL) -> [HTTPCookie]
    init(origin: String, cookieProvider: @escaping @Sendable (URL) -> [HTTPCookie] = { _ in [] }) {
        self.origin = origin
        self.cookieProvider = cookieProvider
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, imageRedirectAllowed(fromOrigin: origin, to: url) else {
            completionHandler(nil)
            return
        }
        // URLSession can retain manually supplied headers. Re-select cookies for the
        // destination rather than carrying a path-scoped cookie outside its Path.
        var redirected = request
        redirected.httpShouldHandleCookies = false
        for header in ["Cookie", "Authorization", "Proxy-Authorization", "Origin", "X-CSRFToken"] {
            redirected.setValue(nil, forHTTPHeaderField: header)
        }
        let cookies = cookieProvider(url)
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            redirected.setValue(value, forHTTPHeaderField: name)
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
