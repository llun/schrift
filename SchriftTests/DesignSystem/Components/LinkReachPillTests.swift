import XCTest

@testable import Schrift

final class LinkReachPillTests: XCTestCase {
    func testRestrictedUsesNeutralStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .restricted)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary,
                systemImage: "lock.fill", label: "Restricted", hint: "Only invited people"))
    }

    func testAuthenticatedUsesInfoStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .authenticated)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info650,
                systemImage: "network.badge.shield.half.filled", label: "Connected", hint: "Anyone in the org"))
    }

    func testPublicUsesBrandStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .public)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary,
                systemImage: "globe", label: "Public", hint: "Anyone with the link"))
    }

    func testRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(LinkReach.restricted.rawValue, "restricted")
        XCTAssertEqual(LinkReach.authenticated.rawValue, "authenticated")
        XCTAssertEqual(LinkReach.public.rawValue, "public")
    }
}
