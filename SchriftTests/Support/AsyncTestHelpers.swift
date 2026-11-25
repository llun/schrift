import Foundation
import XCTest

/// Thread-safe request recorder for MockURLProtocol stub handlers.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(method: String, url: String)] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((request.httpMethod ?? "", request.url?.absoluteString ?? ""))
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.method)
    }

    func count(ofMethod method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.method == method }.count
    }

    func count(ofMethod method: String, urlContaining substring: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.method == method && $0.url.contains(substring) }.count
    }

    /// Where a request sits in the recorded sequence — for asserting the **order** two things
    /// happened in, which a count cannot express. nil when nothing matched.
    func indexOfFirstRequest(method: String, urlContaining substring: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries.firstIndex { $0.method == method && $0.url.contains(substring) }
    }
}

/// Thread-safe monotonic counter for stub handlers that must distinguish the
/// nth concurrent request (MockURLProtocol calls them off the main actor).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    /// Gate on this, not on a `RequestRecorder` count, when a stub picks its branch
    /// from `next()`: the recorder pins *recording* order, which need not be the
    /// order the branches were taken.
    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Polls a condition on the main actor until it holds or the timeout passes.
/// A timeout fails the test where it happened: returning silently turns a stalled
/// wait into a confusing assertion failure further down.
@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(25))
    }
    if !condition() {
        XCTFail("waitUntil timed out after \(timeout)s", file: file, line: line)
    }
}

/// The negative counterpart: polls for `timeout` and fails if the condition ever
/// becomes true. Use it for "assert nothing more happened" — `waitUntil` means
/// "this must become true", and its timeout is a failure.
@MainActor
func waitAndConfirmNever(
    timeout: TimeInterval = 0.3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            XCTFail("condition became true within \(timeout)s", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(25))
    }
}

/// A fake `sleep` for tests: records each requested duration and suspends until
/// released. Cancellation resumes the waiter by throwing `CancellationError`,
/// matching `Task.sleep`.
final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [Duration] = []
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID = 0
    private var cancelledIDs: Set<Int> = []

    var durations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func sleep(_ duration: Duration) async throws {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            requested.append(duration)
            nextID += 1
            return nextID
        }()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledIDs.contains(id) {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let match = waiters.first { $0.id == id }
            waiters.removeAll { $0.id == id }
            if match == nil { cancelledIDs.insert(id) }
            lock.unlock()
            match?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Lets the oldest suspended sleep run to completion.
    func releaseNext() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        next?.continuation.resume()
    }

    /// Lets every sleep currently suspended run to completion.
    func releaseAll() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.continuation.resume() }
    }
}

/// A `sleep` that suspends until cancelled without arming a real timer, so tests
/// that do not opt in to background retries never send stray requests through `MockURLProtocol`.
@Sendable
func neverSleep(_: Duration) async throws {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled = false
    }
    let box = Box()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.lock.lock()
            if box.cancelled {
                box.lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                box.continuation = continuation
                box.lock.unlock()
            }
        }
    } onCancel: {
        box.lock.lock()
        box.cancelled = true
        let continuation = box.continuation
        box.continuation = nil
        box.lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
