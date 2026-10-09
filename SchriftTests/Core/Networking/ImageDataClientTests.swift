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

    func testRedirectDropsInheritedCookiesAndAuthenticationHeaders() async throws {
        let session = MockURLProtocol.makeSession()
        let delegate = ImageRequestDelegate(origin: origin)
        let source = URL(string: "\(origin)/media/photo")!
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var inherited = URLRequest(url: URL(string: "\(origin)/other/photo")!)
        inherited.httpShouldHandleCookies = true
        inherited.allHTTPHeaderFields = [
            "Cookie": "pathScoped=original", "Authorization": "Basic original",
            "Proxy-Authorization": "Basic original", "Origin": origin, "X-CSRFToken": "original",
        ]
        let request = inherited
        let result: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session, task: session.dataTask(with: source), willPerformHTTPRedirection: response,
                newRequest: request
            ) { continuation.resume(returning: $0) }
        }
        let redirected = try XCTUnwrap(result)
        for header in ["Cookie", "Authorization", "Proxy-Authorization", "Origin", "X-CSRFToken"] {
            XCTAssertNil(redirected.value(forHTTPHeaderField: header))
        }
        XCTAssertFalse(redirected.httpShouldHandleCookies)
    }

    func testServerRedirectReSelectsOnlyCookiesApplicableToDestination() async throws {
        let session = MockURLProtocol.makeSession()
        let scoped = HTTPCookie(properties: [
            .domain: "docs.example.org", .path: "/media", .name: "mediaOnly", .value: "fake",
        ])!
        let delegate = ImageRequestDelegate(
            origin: origin,
            cookieProvider: { url in
                url.path.hasPrefix("/media/") ? [scoped] : []
            })
        let source = URL(string: "\(origin)/media/photo")!
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for path in ["/other/photo", "/media/other"] {
            var request = URLRequest(url: URL(string: "\(origin)\(path)")!)
            request.setValue("mediaOnly=inherited", forHTTPHeaderField: "Cookie")
            let proposed = request
            let result: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session, task: session.dataTask(with: source), willPerformHTTPRedirection: response,
                    newRequest: proposed
                ) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(
                result?.value(forHTTPHeaderField: "Cookie"), path.hasPrefix("/media/") ? "mediaOnly=fake" : nil)
        }
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

    // MARK: - imageCookieApplies

    private func cookie(
        domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path, .name: "sessionid", .value: "fake",
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testHostOnlyCookieMatchesOnlyItsExactHost() {
        let cookie = cookie(domain: "docs.example.org")
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/a.png")!))
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://DOCS.example.org/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "https://sub.docs.example.org/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "https://example.org/a.png")!))
    }

    func testDotDomainCookieMatchesTheDomainAndItsSubdomainsButNotLookalikes() {
        let cookie = cookie(domain: ".example.org")
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://example.org/a.png")!))
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "https://evilexample.org/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "https://example.org.evil.com/a.png")!))
    }

    func testPathMatchRespectsSegmentBoundaries() {
        let cookie = cookie(domain: "docs.example.org", path: "/media")
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/media")!))
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/media/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/mediaplayer/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/other/a.png")!))
    }

    func testTrailingSlashCookiePathMatchesAnythingBeneathIt() {
        let cookie = cookie(domain: "docs.example.org", path: "/media/")
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/media/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/media")!))
    }

    func testRootPathCookieMatchesEveryPathIncludingAnEmptyOne() {
        let cookie = cookie(domain: "docs.example.org", path: "/")
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org")!))
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/deep/er/a.png")!))
    }

    func testSecureCookieIsWithheldFromPlainHTTP() {
        let cookie = cookie(domain: "docs.example.org", secure: true)
        XCTAssertTrue(imageCookieApplies(cookie, to: URL(string: "https://docs.example.org/a.png")!))
        XCTAssertFalse(imageCookieApplies(cookie, to: URL(string: "http://docs.example.org/a.png")!))
    }

    func testExpiredCookieNeverApplies() {
        let past = cookie(domain: "docs.example.org", expires: Date(timeIntervalSinceNow: -60))
        let future = cookie(domain: "docs.example.org", expires: Date(timeIntervalSinceNow: 3600))
        let url = URL(string: "https://docs.example.org/a.png")!
        XCTAssertFalse(imageCookieApplies(past, to: url))
        XCTAssertTrue(imageCookieApplies(future, to: url))
    }
}
