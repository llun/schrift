import XCTest

@testable import Schrift

@MainActor final class ImageTransportTests: XCTestCase {
    private let url = URL(string: "https://docs.example.org/media/photo.png")!

    override func tearDown() { MockURLProtocol.reset() }

    func testTransportHasNoAmbientCredentialCookieOrCacheStorage() {
        let configuration = ImageTransport.configuration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testExplicitCookieSnapshotIsTheOnlyCredentialOnTheGET() async throws {
        let bytes = testPNGData(width: 10, height: 10)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: bytes, error: nil) }
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org", .path: "/", .name: "sessionid", .value: "fixture-only",
        ])!
        let data = try await ImageTransport(session: MockURLProtocol.makeSession()).data(for: url, cookies: [cookie])
        XCTAssertEqual(data, bytes)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, url)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-CSRFToken"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    }

    func testNoCookieSnapshotMeansNoCookiesEvenForAnApprovedExternalURL() async throws {
        let bytes = testPNGData(width: 10, height: 10)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: bytes, error: nil) }
        _ = try await ImageTransport(session: MockURLProtocol.makeSession()).data(
            for: URL(string: "https://external.example.org/photo.png")!, cookies: [])
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"))
    }

    func testSnapshotCookieEligibilityPreservesEncodedPathAndSecureBoundaries() {
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org", .path: "/media", .name: "sessionid", .value: "fixture-only", .secure: "TRUE",
        ])!
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/media/photo")!))
        for destination in [
            "http://docs.example.org/media/photo", "https://other.example.org/media/photo",
            "https://docs.example.org/media-other", "https://docs.example.org/media%2Fphoto",
            "https://docs.example.org/medi%61/photo",
        ] {
            XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: destination)!))
        }
    }

    func testRedirectPolicyPinsHostSchemeAndPortAndRejectsUserInfo() {
        XCTAssertTrue(imageRedirectIsAllowed(from: url, to: URL(string: "https://docs.example.org/other.png")!))
        for destination in [
            "https://evil.example/photo", "http://docs.example.org/photo", "https://docs.example.org:8443/photo",
            "https://user:pass@docs.example.org/photo", "file:///tmp/photo",
        ] {
            XCTAssertFalse(imageRedirectIsAllowed(from: url, to: URL(string: destination)!))
        }
        let external = URL(string: "https://external.example.org/image")!
        XCTAssertFalse(
            imageRedirectIsAllowed(from: external, to: url),
            "an external request must not enter the credential origin either")
    }

    func testRejectsRedirectResponseRatherThanCachingItAsAnImage() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 302, headers: ["Location": "https://evil.example/image"], body: Data(), error: nil)
        }
        do {
            _ = try await ImageTransport(session: MockURLProtocol.makeSession()).data(for: url, cookies: [])
            XCTFail("Expected rejected redirect")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        } catch { XCTFail("Expected URLError") }
    }

    func testStreamingLimitRejectsBytesWithoutContentLength() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data([1, 2, 3]), error: nil) }
        do {
            _ = try await ImageTransport(session: MockURLProtocol.makeSession()).data(
                for: url, cookies: [], byteLimit: 2)
            XCTFail("Expected bounded download")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        } catch { XCTFail("Expected URLError") }
    }

    func testDeclaredOversizedResponseIsRefused() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: ["Content-Length": "100"], body: Data([1]), error: nil)
        }
        do {
            _ = try await ImageTransport(session: MockURLProtocol.makeSession()).data(
                for: url, cookies: [], byteLimit: 2)
            XCTFail("Expected bounded download")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        } catch { XCTFail("Expected URLError") }
    }
}
