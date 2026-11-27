import Foundation
import Synchronization

/// The most one tap downloads to play a video or audio file, another site's or an upload on this server.
let mediaDownloadByteLimit = 200 * 1024 * 1024

/// Streams one GET to `destination` on disk, never into memory, and refuses a body over `byteLimit`
/// (announced or counted) with `URLError(.dataLengthExceedsMaximum)`. Answers the response whatever its
/// status; only a 2xx body is moved to `destination`.
///
/// `external` is another site's file: a redirect must stay https with no userinfo, and every
/// authentication challenge but server trust is refused. Which cookies go is the session's business:
/// `RemoteMediaClient`'s has no cookie storage at all.
func downloadMediaFile(
    _ request: URLRequest, session: URLSession, to destination: URL, byteLimit: Int, external: Bool
) async throws -> HTTPURLResponse {
    let delegate = MediaDownloadDelegate(destination: destination, byteLimit: byteLimit, external: external)
    let task = session.downloadTask(with: request)
    task.delegate = delegate
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            delegate.begin(continuation)
            task.resume()
        }
    } onCancel: {
        task.cancel()
    }
}

/// A redirect another site's media may follow: https, a host, no userinfo.
func mediaRedirectAllowed(to url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
}

final class MediaDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<HTTPURLResponse, any Error>?
        var refusal: (any Error)?
        var response: HTTPURLResponse?
    }

    private let destination: URL
    private let byteLimit: Int
    private let external: Bool
    private let state = Mutex(State())

    init(destination: URL, byteLimit: Int, external: Bool) {
        self.destination = destination
        self.byteLimit = byteLimit
        self.external = external
    }

    func begin(_ continuation: CheckedContinuation<HTTPURLResponse, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    private func refuse(_ error: any Error, _ task: URLSessionTask) {
        state.withLock { $0.refusal = $0.refusal ?? error }
        task.cancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > byteLimit || totalBytesExpectedToWrite > byteLimit else { return }
        refuse(URLError(.dataLengthExceedsMaximum), downloadTask)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            return refuse(URLError(.badServerResponse), downloadTask)
        }
        // The file at `location` is deleted when this returns: move it now or never.
        if (200..<300).contains(response.statusCode) {
            let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard size <= byteLimit else { return refuse(URLError(.dataLengthExceedsMaximum), downloadTask) }
            do {
                let manager = FileManager.default
                try? manager.removeItem(at: destination)
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: location, to: destination)
            } catch {
                return refuse(error, downloadTask)
            }
        }
        state.withLock { $0.response = response }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, refusal, response) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.refusal, state.response)
        }
        if let failure = refusal ?? error {
            continuation?.resume(throwing: failure)
        } else if let response {
            continuation?.resume(returning: response)
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // A refused redirect ends the task on the 3xx itself, which the caller treats as a failure.
        guard external else { return completionHandler(request) }
        completionHandler(request.url.map { mediaRedirectAllowed(to: $0) } == true ? request : nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let isServerTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        completionHandler(isServerTrust || !external ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// Another site's video or audio, downloaded on the user's tap to a file the player opens.
///
/// The player is never handed a remote URL: `AVURLAsset` attaches matching cookies from
/// `HTTPCookieStorage.shared`, where the session lives, whatever `AVURLAssetHTTPCookiesKey` says,
/// so this server's other paths, an explicit `:443`, a parent-domain cookie, or a redirect or
/// playlist hop back to the server would all carry the session. This session has no cookie,
/// credential or URL-cache storage (`ImageDataClient.configuration()`), follows only https
/// redirects, and stops at `mediaDownloadByteLimit`.
struct RemoteMediaClient: Sendable {
    static let shared = RemoteMediaClient()

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = ImageDataClient.configuration()
        // Up to `mediaDownloadByteLimit` on a slow link.
        configuration.timeoutIntervalForResource = 10 * 60
        return configuration
    }

    /// Downloads `url` (https only) to `destination` and answers the response's MIME type.
    func download(_ url: URL, to destination: URL, byteLimit: Int = mediaDownloadByteLimit) async throws -> String? {
        guard mediaRedirectAllowed(to: url) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let response = try await downloadMediaFile(
            request, session: session, to: destination, byteLimit: byteLimit, external: true)
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return response.mimeType
    }
}
