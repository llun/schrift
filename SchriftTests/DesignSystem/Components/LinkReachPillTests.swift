import XCTest

@testable import Schrift

final class LinkReachPillTests: XCTestCase {
    func testRestrictedUsesNeutralStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .restricted)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundLightHex: DocsColorHex.surfaceMuted, backgroundDarkHex: DocsColorHexDark.surfaceMuted,
                foregroundLightHex: DocsColorHex.textSecondary, foregroundDarkHex: DocsColorHexDark.textSecondary,
                systemImage: "lock.fill", label: "Restricted", hint: "Only invited people"))
    }

    func testAuthenticatedUsesInfoStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .authenticated)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundLightHex: DocsColorHex.infoSoft, backgroundDarkHex: DocsColorHexDark.infoSoft,
                foregroundLightHex: DocsColorHex.info650, foregroundDarkHex: DocsColorHexDark.info650,
                systemImage: "network.badge.shield.half.filled", label: "Connected", hint: "Anyone in the org"))
    }

    func testPublicUsesBrandStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .public)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundLightHex: DocsColorHex.brandFillSoft, backgroundDarkHex: DocsColorHexDark.brandFillSoft,
                foregroundLightHex: DocsColorHex.textBrandSecondary,
                foregroundDarkHex: DocsColorHexDark.textBrandSecondary,
                systemImage: "globe", label: "Public", hint: "Anyone with the link"))
    }

    func testRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(LinkReach.restricted.rawValue, "restricted")
        XCTAssertEqual(LinkReach.authenticated.rawValue, "authenticated")
        XCTAssertEqual(LinkReach.public.rawValue, "public")
    }
}
