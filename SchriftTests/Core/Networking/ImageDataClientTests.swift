import XCTest

@testable import Schrift

final class ImageDataClientTests: XCTestCase {
    private let origin = "https://docs.example.org"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testExternalRequestHasNoCookiesCSRFOriginOrAuthorization() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data([1]), error: nil) }
        let client = ImageDataClient(
            session: MockURLProtocol.makeSession(),
            cookieProvider: { _ in
                XCTFail("External images must not even consult app cookies")
                return []
            })
        _ = try await client.data(for: URL(string: "https://external.example/photo.png")!, serverOrigin: origin)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        for header in ["Cookie", "Authorization", "X-CSRFToken", "Origin"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header))
        }
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testSameServerRequestReceivesOnlyApplicableCookies() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data([1]), error: nil) }
        let client = ImageDataClient(
            session: MockURLProtocol.makeSession(),
            cookieProvider: { url in
                XCTAssertEqual(url.path, "/media/photo.png")
                return [
                    HTTPCookie(properties: [
                        .domain: "docs.example.org", .path: "/", .name: "sessionid", .value: "fake",
                    ])!
                ]
            })
        _ = try await client.data(for: URL(string: "\(origin)/media/photo.png")!, serverOrigin: origin)
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"), "sessionid=fake")
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-CSRFToken"))
    }

    func testInvalidURLAndErrorBodyAreRefused() async {
        let client = ImageDataClient(session: MockURLProtocol.makeSession(), cookieProvider: { _ in [] })
        do {
            _ = try await client.data(
                for: URL(string: "https://user:secret@docs.example.org/photo")!, serverOrigin: origin)
            XCTFail("URL credentials must be refused")
        } catch {}
        XCTAssertNil(MockURLProtocol.lastRequest)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data([1]), error: nil) }
        do {
            _ = try await client.data(for: URL(string: "\(origin)/photo")!, serverOrigin: origin)
            XCTFail("Error body must not reach cache")
        } catch {}
    }

    func testRedirectDelegateRefusesOriginChangesAndDowngrades() async throws {
        let session = MockURLProtocol.makeSession()
        let delegate = ImageRequestDelegate(origin: origin)
        let source = URL(string: "\(origin)/photo")!
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for target in [
            "https://evil.example/photo", "http://docs.example.org/photo", "https://docs.example.org:8443/photo",
            "https://user:secret@docs.example.org/photo",
        ] {
            let result: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session, task: session.dataTask(with: source), willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: URL(string: target)!)
                ) { continuation.resume(returning: $0) }
            }
            XCTAssertNil(result)
        }
        let allowed = URLRequest(url: URL(string: "\(origin)/other-photo")!)
        let result: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session, task: session.dataTask(with: source), willPerformHTTPRedirection: response,
                newRequest: allowed
            ) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(result?.url, allowed.url)
        XCTAssertFalse(imageRedirectAllowed(fromOrigin: "https://external.example", to: source))
    }

    func testStreamingLimitAppliesWithoutContentLength() async {
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:], body: Data(repeating: 7, count: ImageDataClient.maximumBytes + 1),
                error: nil)
        }
        let client = ImageDataClient(session: MockURLProtocol.makeSession(), cookieProvider: { _ in [] })
        do {
            _ = try await client.data(for: URL(string: "\(origin)/photo")!, serverOrigin: origin)
            XCTFail("An undeclared oversized stream must be stopped")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }

    func testOversizedDeclaredResponseIsRefused() async {
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200,
                headers: ["Content-Length": "\(ImageDataClient.maximumBytes + 1)"], body: Data(), error: nil)
        }
        let client = ImageDataClient(session: MockURLProtocol.makeSession(), cookieProvider: { _ in [] })
        do {
            _ = try await client.data(for: URL(string: "\(origin)/photo")!, serverOrigin: origin)
            XCTFail("Oversized response must be refused")
        } catch {}
    }
}
