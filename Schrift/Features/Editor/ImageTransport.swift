import Foundation

func isFetchableImageURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
        url.host != nil, url.user == nil, url.password == nil
    else { return false }
    return true
}

/// Both trusted and explicitly approved requests stay on their original origin.
/// In particular, approval of one external URL is never approval of a redirect
/// to a second host (or of a downgrade to HTTP).
func imageRedirectIsAllowed(from initialURL: URL, to redirectURL: URL) -> Bool {
    isFetchableImageURL(redirectURL) && siteOrigin(for: initialURL) != nil
        && siteOrigin(for: initialURL) == siteOrigin(for: redirectURL)
}

/// Displayed-image loading uses the existing credential-aware media client.
/// The facade accepts an immutable cookie snapshot from the scoped loader.
struct ImageTransport: Sendable {
    static let byteLimit = ImageDataClient.maximumBytes
    private let client: ImageDataClient
    init(session: URLSession? = nil) { client = ImageDataClient(session: session) }
    static func configuration() -> URLSessionConfiguration { ImageDataClient.configuration() }
    func data(for url: URL, cookies: [HTTPCookie], byteLimit: Int = Self.byteLimit) async throws -> Data {
        guard isFetchableImageURL(url) else { throw URLError(.badURL) }
        return try await client.data(for: url, cookies: cookies, byteLimit: byteLimit)
    }
}
