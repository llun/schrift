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
