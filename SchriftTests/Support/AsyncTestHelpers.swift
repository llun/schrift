import Foundation
import XCTest

/// Thread-safe request recorder for MockURLProtocol stub handlers.
final class RequestLog: @unchecked Sendable {
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
}

/// Polls a condition on the main actor until it holds or the timeout passes.
@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(25))
    }
}
