import Foundation
import XCTest

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
        ///
        /// A delay expresses a **duration**. When what the test means is an
        /// **ordering** — "this response may only land once that other request has
        /// resolved" — use `releasedBy:` instead; see `ResponseGate`.
        let delay: TimeInterval
        /// Holds this response until the test opens the gate. Takes precedence over
        /// `delay`, which a gated stub ignores.
        let gate: ResponseGate?

        init(
            statusCode: Int,
            headers: [String: String],
            body: Data,
            error: Error?,
            delay: TimeInterval = 0,
            releasedBy gate: ResponseGate? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
            self.delay = delay
            self.gate = gate
        }
    }

    /// Holds a response until the test says the thing it was waiting for has happened.
    ///
    /// `Stub.delay` can only defer delivery by a fixed interval, so a test whose subject
    /// is an *ordering* — "the stale list snapshot may only land once the create has
    /// resolved" — has to approximate it by betting that interval against the machine.
    /// On a loaded runner the bet loses: the held response delivers first, the test sees
    /// a state it never meant to exercise, and it fails for a reason no one can act on.
    /// It happened (`PagesTreeViewModelTests`, CI run 31885836238, on a PR touching
    /// neither the view model nor its tests). A gate states the ordering instead — the
    /// response is delivered when `open()` is called, however long that takes — so the
    /// only thing the test still waits on is the event it actually cares about.
    ///
    /// It **latches**: a request reaching an already-open gate is delivered straight
    /// away rather than waiting for an `open()` that has already been and gone.
    final class ResponseGate: @unchecked Sendable {
        /// How long a still-shut gate is given before it is treated as a wiring bug
        /// rather than a slow machine. It is **not** part of any ordering — a correctly
        /// written test opens its gate as soon as the request it was gating on returns.
        ///
        /// What it buys, stated exactly, because the obvious claim is wrong: a gate that
        /// is never opened does **not** stall forever. `makeSession()` builds an ephemeral
        /// configuration, whose `timeoutIntervalForRequest` defaults to 60 s (measured), so
        /// the request is eventually released with `URLError(.timedOut)`. The failsafe
        /// halves that wait, releases the request immediately so the body fails on its own
        /// assertions, and — the part that actually matters — names the gate *and the line
        /// it was built on*, where the bare timeout surfaces as an opaque `-1001`
        /// attributed to nothing. 30 s is under the timeout it pre-empts, and the failsafe
        /// is worthless if it is not.
        static let defaultFailsafeTimeout: TimeInterval = 30

        /// Injectable **only** so the failsafe itself can be tested — 30 s is otherwise
        /// impractical to pin, and a backstop nothing exercises is a backstop nobody
        /// knows is broken. Never shorten it to express an ordering; that is the bet
        /// this whole type exists to stop taking.
        let failsafeTimeout: TimeInterval
        /// Where the gate was built. The failsafe fires from a queue, so without this it
        /// blames `MockURLProtocol.swift` rather than the test that miswired the gate —
        /// and a gate is constructed once per test, on the line beside the ordering it
        /// expresses, which is exactly where a reader needs to be sent.
        private let file: StaticString
        private let line: UInt

        init(
            failsafeTimeout: TimeInterval = ResponseGate.defaultFailsafeTimeout,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            self.failsafeTimeout = failsafeTimeout
            self.file = file
            self.line = line
        }

        private let lock = NSLock()
        private var isOpen = false
        private var held: [DispatchWorkItem] = []

        /// Deliver every response this gate holds — and any that arrive afterwards.
        func open() {
            lock.lock()
            isOpen = true
            let items = held
            held = []
            lock.unlock()
            for item in items { DispatchQueue.main.async(execute: item) }
        }

        /// The failsafe's "this gate was never opened" test. Sound because `isOpen`
        /// latches permanently, so a non-empty `held` can only mean never-opened.
        fileprivate var isHoldingAnything: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !held.isEmpty
        }

        /// Fails the test that built this gate, naming it and the request it stranded,
        /// then releases everything so the body fails on its own assertions rather than
        /// sitting out the rest of URLSession's 60s request timeout.
        fileprivate func failUnopened(holding description: String) {
            XCTFail(
                "MockURLProtocol: a ResponseGate holding \(description) was never opened",
                file: file, line: line)
            open()
        }

        fileprivate func hold(_ item: DispatchWorkItem) {
            lock.lock()
            guard !isOpen else {
                lock.unlock()
                DispatchQueue.main.async(execute: item)
                return
            }
            held.append(item)
            lock.unlock()
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

    nonisolated(unsafe) private static var _deferredDeliveryCount = 0

    /// How many deferred deliveries — timed or gated — have been **registered** since the
    /// last `reset()`.
    ///
    /// This, not `lastRequest`, is what a test polls to know a deferred response is really
    /// in hand. `startLoading` sets `lastRequest` *before* the handler runs and before
    /// anything is registered, so a test that polls it can proceed while the delivery is
    /// still unregistered — and a `reset()` issued from inside that window would drain
    /// nothing, which is precisely the case the drain tests exist to pin. Polling this
    /// instead means the registration has provably happened.
    static var deferredDeliveryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _deferredDeliveryCount
    }

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
        if let gate = stub.gate {
            hold(stub, until: gate)
            return
        }
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
        // `self` is captured strongly on purpose: a dropped delivery would strand the
        // awaiting `session.data(for:)` until URLSession's own 60s request timeout.
        let item = DispatchWorkItem {
            guard !self.isCancelled else { return }
            self.deliver(stub)
        }
        guard register([item]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + stub.delay, execute: item)
    }

    /// Puts deferred work items where `reset()` can cancel them, and answers whether this
    /// request may still be served at all. Returns false — having scheduled nothing, and
    /// having failed the request — when the session's token was retired while we were away.
    ///
    /// The window it closes is narrow but real, and shared by both deferred paths:
    /// `startLoading` checks the token, then calls `handler(request)`, which is arbitrary
    /// test code (lock-taking recorders, fixture building). A `reset()` landing in that gap
    /// drains an empty list, and whatever is registered afterwards can never be cancelled —
    /// a timer that fires into a torn-down session, or a gate failsafe that reports
    /// `XCTFail` inside whatever unrelated test is running when it comes due. Re-checking
    /// under the *same* lock as the append means `reset()` either precedes it (nothing is
    /// scheduled) or follows it (everything is cancelled), with no third case.
    private func register(_ items: [DispatchWorkItem]) -> Bool {
        // No token means a session not from `makeSession()`, which `startLoading` leaves
        // alone; keep leaving it alone rather than inventing a liveness answer for it.
        let token = request.value(forHTTPHeaderField: MockURLProtocol.sessionTokenHeader)
        MockURLProtocol.lock.lock()
        let isLive = token.map { MockURLProtocol.liveSessionTokens.contains($0) } ?? true
        if isLive {
            MockURLProtocol.pendingDeliveries.append(contentsOf: items)
            MockURLProtocol._deferredDeliveryCount += 1
        }
        MockURLProtocol.lock.unlock()
        guard isLive else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return false
        }
        return true
    }

    /// Registers this delivery with the gate instead of with a timer.
    ///
    /// Delivery still runs on the **main queue**, for the reason the delayed path above
    /// documents, and is still tracked in `pendingDeliveries`, so `reset()` cancels a gated
    /// response exactly as it cancels a delayed one — an unopened gate must be no more able
    /// to fire into the next test's session than an unexpired timer is.
    private func hold(_ stub: Stub, until gate: ResponseGate) {
        // The delivery captures a **gate-free** copy. `deliver` reads only the status,
        // headers, body and error, and carrying the gate would close a retain cycle
        // (`gate → held → item → stub → gate`) that `cancel()` does not break — so a gate
        // nothing ever opens would leak itself, the work item, this `URLProtocol` instance
        // and the body `Data`, for as long as the process lives.
        let payload = Stub(statusCode: stub.statusCode, headers: stub.headers, body: stub.body, error: stub.error)
        // `self` is captured strongly on purpose, as on the delayed path: a dropped delivery
        // would strand the awaiting `session.data(for:)` until URLSession's own 60s request
        // timeout releases it as an opaque `-1001`.
        let item = DispatchWorkItem {
            guard !self.isCancelled else { return }
            self.deliver(payload)
        }
        // A gate nothing ever opens stalls the test body until that same 60s timeout, and
        // `reset()` cannot help — the stalled body has not reached its `tearDown` yet. Bound
        // it sooner, so a miswired gate arrives as a failure that names the gate rather than
        // as a minute of silence ending in `-1001`.
        let description = "\(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")"
        let failsafe = DispatchWorkItem { [weak gate] in
            guard let gate, gate.isHoldingAnything else { return }
            gate.failUnopened(holding: description)
        }
        guard register([item, failsafe]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + gate.failsafeTimeout, execute: failsafe)
        gate.hold(item)
    }

    override func stopLoading() {
        isCancelled = true
    }

    /// Call from every `tearDown`. Cancels deliveries still scheduled — timed and
    /// gated alike, plus the gates' failsafes — so none can
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
        _deferredDeliveryCount = 0
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
        // into a later test's log. A UUID keeps the token unique for the life of the
        // process, so a token retired at `reset()` is never reissued to a later
        // session — the "never reissued" property is structural, with no shared
        // counter that a future `reset()` could accidentally roll back.
        let token = UUID().uuidString
        lock.lock()
        liveSessionTokens.insert(token)
        lock.unlock()
        configuration.httpAdditionalHeaders = [sessionTokenHeader: token]
        return URLSession(configuration: configuration)
    }
}
