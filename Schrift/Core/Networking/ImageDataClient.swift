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
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
        self.cookieProvider = cookieProvider
    }

    func data(for url: URL, serverOrigin: String) async throws -> Data {
        guard let origin = siteOrigin(for: url), url.user == nil, url.password == nil else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if imageLoadPolicy(for: url, serverOrigin: serverOrigin) == .allow {
            let cookies = cookieProvider(url)
            if !cookies.isEmpty { request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies) }
        }
        let delegate = ImageRequestDelegate(origin: origin)
        let (stream, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            response.url.flatMap(siteOrigin(for:)) == origin,
            response.expectedContentLength <= Int64(Self.maximumBytes)
        else {
            stream.task.cancel()
            throw URLError(.badServerResponse)
        }
        var data = Data()
        do {
            for try await byte in stream {
                guard data.count < Self.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
        } catch {
            stream.task.cancel()
            throw error
        }
        return data
    }
}

func imageRedirectAllowed(fromOrigin: String, to url: URL) -> Bool {
    url.user == nil && url.password == nil && siteOrigin(for: url) == fromOrigin
}

final class ImageRequestDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: String
    init(origin: String) { self.origin = origin }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, imageRedirectAllowed(fromOrigin: origin, to: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
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
