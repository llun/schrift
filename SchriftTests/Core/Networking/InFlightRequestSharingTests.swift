import XCTest

@testable import Schrift

/// `currentUser()` and `serverConfig()` share a request that is already on the wire, and nothing
/// more: no cache, so a call made after one settles always asks the server.
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

    func testConcurrentCurrentUserCallsShareOneRequest() async throws {
        let recorder = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(
                statusCode: 200, headers: [:], body: Data(#"{"email": "me@example.com"}"#.utf8), error: nil,
                releasedBy: gate)
        }
        let client = makeClient()

        async let first = client.currentUser()
        async let second = client.currentUser()
        await waitUntil { MockURLProtocol.deferredDeliveryCount >= 1 }
        await waitAndConfirmNever { recorder.count(ofMethod: "GET") > 1 }
        gate.open()

        let users = try await [first, second]
        XCTAssertEqual(users.map(\.email), ["me@example.com", "me@example.com"])
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "users/me/"), 1)
    }

    func testSequentialCurrentUserCallsEachHitTheNetwork() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
        }
        let client = makeClient()

        _ = try await client.currentUser()
        _ = try await client.currentUser()

        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "users/me/"), 2)
    }

    func testAFailedCurrentUserDoesNotPoisonTheNextCall() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            if recorder.count(ofMethod: "GET") == 1 {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(#"{"email": "me@example.com"}"#.utf8), error: nil)
        }
        let client = makeClient()

        do {
            _ = try await client.currentUser()
            XCTFail("expected the first call to fail")
        } catch {}
        let user = try await client.currentUser()

        XCTAssertEqual(user.email, "me@example.com")
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2)
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
