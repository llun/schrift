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

    /// A per-session token, retired at `reset()`, that lets `startLoading` reject a
    /// leaked request without invalidating its session. A coordinator's unstructured
    /// save `Task` deliberately outlives its test; under load it can *initiate* its
    /// content PATCH after the test tore down, while a **later** test's global
    /// `stubHandler` is installed — recording a phantom `PATCH …/content/` into the
    /// later test's `RequestRecorder` and flaking its `waitAndConfirmNever` /
    /// `savesInFlight` assertions.
    ///
    /// Invalidating the session at teardown does stop the recording, but creating a
    /// *new* task on an invalidated `URLSession` raises an uncatchable Objective-C
    /// `NSException` ("Task created in a session that has been invalidated") that
    /// terminates the **test process** — the very failure mode this file exists to
    /// avoid. The leaked task hits it because its `session.data(for:)` runs on the
    /// `DocsAPIClient` actor concurrently with the main-actor `reset()`. So instead
    /// each session is tagged (via `httpAdditionalHeaders`) with a token that
    /// `reset()` retires, and `startLoading` fails a retired-token request *before*
    /// it reads `stubHandler` — the session stays valid, so nothing ever traps.
    private static let sessionTokenHeader = "X-MockURLProtocol-Session"
    nonisolated(unsafe) private static var sessionTokenCounter = 0
    nonisolated(unsafe) private static var liveSessionTokens: Set<String> = []

    /// Written from `stopLoading()` on URLSession's loading thread, read from the
    /// deferred delivery on the main queue — guarded so TSan stays quiet.
    private let cancelLock = NSLock()
    private var _isCancelled = false
    private var isCancelled: Bool {
        get {
            cancelLock.lock()
            defer { cancelLock.unlock() }
            return _isCancelled
        }
        set {
            cancelLock.lock()
            defer { cancelLock.unlock() }
            _isCancelled = newValue
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // A request whose session token was retired at `reset()` is a leaked task
        // from an earlier test. Fail it *before* touching `lastRequest`/`stubHandler`,
        // so it can never record a phantom request into a later test's
        // `RequestRecorder`. The session is never invalidated, so this can't raise
        // the "task created in an invalidated session" NSException that crashes the
        // process. (A request with no token — a session not from `makeSession()` —
        // is left alone.)
        if let token = request.value(forHTTPHeaderField: MockURLProtocol.sessionTokenHeader) {
            MockURLProtocol.lock.lock()
            let isLive = MockURLProtocol.liveSessionTokens.contains(token)
            MockURLProtocol.lock.unlock()
            if !isLive {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
        }
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
    /// fire into the next test's session, and retires every session token
    /// `makeSession()` handed out so a save `Task` that outlived its test has its
    /// leaked request rejected by `startLoading` instead of recording into the next
    /// test's `stubHandler`. Safe without a drain: deliveries run on the main queue,
    /// and `tearDown` is already on it.
    static func reset() {
        stubHandler = nil
        lastRequest = nil
        lock.lock()
        let items = pendingDeliveries
        pendingDeliveries = []
        liveSessionTokens.removeAll()
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
        // Tag every request from this session with a token `reset()` can retire, so a
        // leaked task's request is rejected at `startLoading` rather than recording
        // into a later test's log. A monotonic counter keeps tokens unique for the
        // life of the process, so a retired token is never reissued as live.
        lock.lock()
        sessionTokenCounter += 1
        let token = String(sessionTokenCounter)
        liveSessionTokens.insert(token)
        lock.unlock()
        configuration.httpAdditionalHeaders = [sessionTokenHeader: token]
        return URLSession(configuration: configuration)
    }
}
