import XCTest

@testable import Schrift

// Fixture values are obviously fake — never anything resembling a real
// session token — and no test prints cookie values.
final class SessionCookiesTests: XCTestCase {
    private func makeCookie(
        name: String = "docs_sessionid",
        value: String = "fake-session-value",
        expiresDate: Date? = nil,
        isSecure: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: "docs.example.org",
            .path: "/",
            .name: name,
            .value: value,
        ]
        if let expiresDate { properties[.expires] = expiresDate }
        if isSecure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    // MARK: - Capture from HTTPCookie

    func testStoredCookieCapturesAllFields() {
        // Compare against the cookie's own expiresDate, not the raw fixture
        // date: HTTPCookie(properties:) clamps expiry to the ~400-day cookie
        // lifetime cap, and the snapshot must be faithful to the cookie.
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let cookie = makeCookie(name: "csrftoken", value: "fake-csrf-value", expiresDate: expiry, isSecure: true)

        let stored = StoredCookie(cookie)

        XCTAssertEqual(stored.name, "csrftoken")
        XCTAssertEqual(stored.value, "fake-csrf-value")
        XCTAssertEqual(stored.domain, "docs.example.org")
        XCTAssertEqual(stored.path, "/")
        XCTAssertNotNil(stored.expiresDate)
        XCTAssertEqual(stored.expiresDate, cookie.expiresDate)
        XCTAssertTrue(stored.isSecure)
    }

    func testStoredCookieFromSessionOnlyCookieHasNilExpiry() {
        let stored = StoredCookie(makeCookie(expiresDate: nil))
        XCTAssertNil(stored.expiresDate)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesSessionOnlyCookie() throws {
        let stored = StoredCookie(makeCookie(expiresDate: nil))

        let data = try JSONEncoder().encode([stored])
        let decoded = try JSONDecoder().decode([StoredCookie].self, from: data)

        XCTAssertEqual(decoded, [stored])
        XCTAssertNil(decoded[0].expiresDate)
    }

    func testCodableRoundTripPreservesExpiringCookie() throws {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let stored = StoredCookie(makeCookie(expiresDate: expiry, isSecure: true))

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredCookie.self, from: data)

        XCTAssertEqual(decoded, stored)
    }

    // MARK: - HTTPCookie reconstruction

    func testHTTPCookieReconstructionRoundTripsCoreFields() {
        // Round-trip fidelity is against the original cookie's (possibly
        // 400-day-clamped) expiresDate — see testStoredCookieCapturesAllFields.
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let original = makeCookie(name: "csrftoken", value: "fake-csrf-value", expiresDate: expiry, isSecure: true)

        let rebuilt = StoredCookie(original).httpCookie

        XCTAssertNotNil(rebuilt)
        XCTAssertEqual(rebuilt?.name, "csrftoken")
        XCTAssertEqual(rebuilt?.value, "fake-csrf-value")
        XCTAssertEqual(rebuilt?.domain, "docs.example.org")
        XCTAssertEqual(rebuilt?.path, "/")
        XCTAssertEqual(rebuilt?.expiresDate, original.expiresDate)
        XCTAssertEqual(rebuilt?.isSecure, true)
    }

    func testSessionOnlyCookieReconstructsAsSessionOnly() {
        let rebuilt = StoredCookie(makeCookie(expiresDate: nil)).httpCookie

        XCTAssertNotNil(rebuilt)
        XCTAssertNil(rebuilt?.expiresDate)
        XCTAssertEqual(rebuilt?.isSessionOnly, true)
    }

    // MARK: - validStoredCookies

    func testValidStoredCookiesDropsExpiredKeepsSessionOnlyAndFuture() {
        let now = Date(timeIntervalSince1970: 1_500_000_000)
        let expired = StoredCookie(makeCookie(name: "expired", expiresDate: now.addingTimeInterval(-60)))
        let future = StoredCookie(makeCookie(name: "future", expiresDate: now.addingTimeInterval(60)))
        let sessionOnly = StoredCookie(makeCookie(name: "session", expiresDate: nil))

        let valid = validStoredCookies([expired, future, sessionOnly], now: now)

        XCTAssertEqual(valid.map(\.name), ["future", "session"])
    }
}
