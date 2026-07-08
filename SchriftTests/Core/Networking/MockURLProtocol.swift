import Foundation

final class MockURLProtocol: URLProtocol {
    struct Stub: @unchecked Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?
        /// Holds this response open without blocking anything else. A stub that
        /// stalls with `Thread.sleep` blocks URLSession's single protocol thread,
        /// which silently serializes every other in-flight request — the concurrent
        /// GET+PATCH flows some tests exist to exercise then never overlap. Delivery
        /// is deferred instead, so overlapping requests stay genuinely overlapping.
        let delay: TimeInterval

        init(statusCode: Int, headers: [String: String], body: Data, error: Error?, delay: TimeInterval = 0) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
            self.delay = delay
        }
    }

    nonisolated(unsafe) static var stubHandler: (@Sendable (URLRequest) -> Stub)?

    private static let responseQueue = DispatchQueue(
        label: "dev.llun.Schrift.MockURLProtocol", attributes: .concurrent)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastRequest: URLRequest?

    /// Only meaningful for single-request tests; concurrent flows record requests
    /// through `RequestRecorder` instead.
    static var lastRequest: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastRequest
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastRequest = newValue
        }
    }

    private let cancelLock = NSLock()
    private var isCancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        guard let handler = MockURLProtocol.stubHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = handler(request)
        // Zero delay keeps the original synchronous path exactly as it was.
        guard stub.delay > 0 else {
            deliver(stub)
            return
        }
        MockURLProtocol.responseQueue.asyncAfter(deadline: .now() + stub.delay) { [weak self] in
            guard let self else { return }
            self.cancelLock.lock()
            let cancelled = self.isCancelled
            self.cancelLock.unlock()
            guard !cancelled else { return }
            self.deliver(stub)
        }
    }

    /// Best-effort: a delivery already past its cancellation check still runs.
    /// Tests must therefore await every delayed request they start rather than
    /// let one outlive the test — otherwise it reports to a torn-down client.
    override func stopLoading() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
    }

    private func deliver(_ stub: Stub) {
        guard let client else { return }

        if let error = stub.error {
            client.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: stub.body)
        client.urlProtocolDidFinishLoading(self)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
