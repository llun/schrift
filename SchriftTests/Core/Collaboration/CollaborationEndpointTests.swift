import XCTest

@testable import Schrift

/// The origin-pinned WebSocket URL / header builders. The dialed URL must always
/// derive from the user's server origin (never a config value), map the scheme
/// to ws(s), and refuse anything that isn't http(s).
final class CollaborationEndpointTests: XCTestCase {
    private let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    func testHTTPSMapsToWSSWithLowercasedRoom() {
        let url = CollaborationEndpoint.webSocketURL(
            serverBaseURL: URL(string: "https://docs.example.org/api/v1.0/")!, documentID: docID)
        XCTAssertEqual(
            url?.absoluteString,
            "wss://docs.example.org/collaboration/ws/?room=11111111-1111-4111-8111-111111111111")
    }

    func testHTTPMapsToWSAndKeepsPort() {
        let url = CollaborationEndpoint.webSocketURL(
            serverBaseURL: URL(string: "http://localhost:8000/api/v1.0/")!, documentID: docID)
        XCTAssertEqual(
            url?.absoluteString,
            "ws://localhost:8000/collaboration/ws/?room=11111111-1111-4111-8111-111111111111")
    }

    func testUppercaseHostIsLowercased() {
        let url = CollaborationEndpoint.webSocketURL(
            serverBaseURL: URL(string: "HTTPS://Docs.Example.ORG/api/")!, documentID: docID)
        XCTAssertEqual(url?.host, "docs.example.org")
        XCTAssertEqual(url?.scheme, "wss")
    }

    func testIPv6HostIsBracketed() {
        let url = CollaborationEndpoint.webSocketURL(
            serverBaseURL: URL(string: "https://[fe80::1]:8443/api/")!, documentID: docID)
        XCTAssertEqual(
            url?.absoluteString,
            "wss://[fe80::1]:8443/collaboration/ws/?room=11111111-1111-4111-8111-111111111111")
    }

    func testUppercaseDocumentIDIsLowercasedInRoom() {
        let upper = UUID(uuidString: "ABCDEF01-1111-4111-8111-111111111111")!
        let url = CollaborationEndpoint.webSocketURL(
            serverBaseURL: URL(string: "https://docs.example.org/")!, documentID: upper)
        XCTAssertEqual(url?.query, "room=abcdef01-1111-4111-8111-111111111111")
    }

    func testNonHTTPSchemeYieldsNil() {
        for base in ["ftp://docs.example.org/", "wss://docs.example.org/", "file:///x", "javascript:alert(1)"] {
            XCTAssertNil(
                CollaborationEndpoint.webSocketURL(serverBaseURL: URL(string: base)!, documentID: docID),
                "\(base) must not produce a socket URL")
        }
    }

    func testOriginHeaderMatchesSiteOrigin() {
        let base = URL(string: "https://docs.example.org/api/v1.0/")!
        XCTAssertEqual(CollaborationEndpoint.originHeader(serverBaseURL: base), "https://docs.example.org")
    }

    func testCookieHeaderJoinsAllCookies() {
        let cookies = [
            makeCookie(name: "sessionid", value: "abc"),
            makeCookie(name: "csrftoken", value: "xyz"),
        ]
        XCTAssertEqual(CollaborationEndpoint.cookieHeader(cookies: cookies), "sessionid=abc; csrftoken=xyz")
    }

    func testCookieHeaderIsNilWhenEmpty() {
        XCTAssertNil(CollaborationEndpoint.cookieHeader(cookies: []))
    }

    private func makeCookie(name: String, value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: "docs.example.org", .path: "/", .name: name, .value: value,
        ])!
    }
}
