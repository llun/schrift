import XCTest

@testable import Schrift

/// `serverConfig()` shares a request that is already on the wire, and nothing more: no cache, so a
/// call made after one settles always asks the server. `currentUser()` never shares.
@MainActor
final class InFlightRequestSharingTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func testConcurrentCurrentUserCallsEachHitTheNetwork() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
        }
        let client = makeClient()

        async let first = client.currentUser()
        async let second = client.currentUser()
        _ = try await [first, second]

        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "users/me/"), 2)
    }

    func testConcurrentServerConfigCallsShareOneRequestAndSequentialOnesDoNot() async throws {
        let recorder = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(
                statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"5.4.1"}"#.utf8), error: nil,
                releasedBy: gate)
        }
        let client = makeClient()

        async let first = client.serverConfig()
        async let second = client.serverConfig()
        await waitUntil { MockURLProtocol.deferredDeliveryCount >= 1 }
        await waitAndConfirmNever { recorder.count(ofMethod: "GET") > 1 }
        gate.open()

        let configs = try await [first, second]
        XCTAssertEqual(configs.map(\.version), ["5.4.1", "5.4.1"])
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "config/"), 1)

        _ = try await client.serverConfig()
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "config/"), 2)
    }
}
