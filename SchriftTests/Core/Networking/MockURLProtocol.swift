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
        /// is deferred to the main queue instead, so overlapping requests stay
        /// genuinely overlapping. Tests must `await` every delayed request they
        /// start; `MockURLProtocol.reset()` cancels any that are left.
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

    /// Deferred deliveries still scheduled, so `reset()` can cancel them. One that
    /// outlives its test reports into a torn-down `URLSession`, which hangs or kills
    /// the test *process* and blames whichever unrelated test was running.
    nonisolated(unsafe) private static var pendingDeliveries: [DispatchWorkItem] = []

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
        // Deferred deliveries run on the **main queue**, the one thread that is
        // certainly alive and that `tearDown` also runs on. A private background
        // queue looked tidier but delivered into whatever state the process was in,
        // which hung the test process roughly one run in twenty. Main is serial, so
        // by the time `reset()` cancels a work item, no delivery is half-done — no
        // lock, no drain, and nothing can outlive its test.
        //
        // `self` is captured strongly on purpose: a dropped delivery would leave the
        // awaiting `session.data(for:)` suspended forever.
        let item = DispatchWorkItem {
            guard !self.isCancelled else { return }
            self.deliver(stub)
        }
        MockURLProtocol.lock.lock()
        MockURLProtocol.pendingDeliveries.append(item)
        MockURLProtocol.lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + stub.delay, execute: item)
    }

    override func stopLoading() {
        isCancelled = true
    }

    /// Call from every `tearDown`. Cancels deliveries still scheduled so none can
    /// fire into the next test's session. Safe without a drain: deliveries run on
    /// the main queue, and `tearDown` is already on it.
    static func reset() {
        stubHandler = nil
        lastRequest = nil
        lock.lock()
        let items = pendingDeliveries
        pendingDeliveries = []
        lock.unlock()
        for item in items { item.cancel() }
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
