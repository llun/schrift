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
                systemImage: "lock.fill", labelKey: .reach_restricted, hintKey: .linkreach_hint_restricted))
    }

    func testAuthenticatedUsesInfoStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .authenticated)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundLightHex: DocsColorHex.infoSoft, backgroundDarkHex: DocsColorHexDark.infoSoft,
                foregroundLightHex: DocsColorHex.info650, foregroundDarkHex: DocsColorHexDark.info650,
                systemImage: "network.badge.shield.half.filled", labelKey: .reach_connected,
                hintKey: .linkreach_hint_authenticated))
    }

    func testPublicUsesBrandStyle() {
        let style = LinkReachPillStyleResolver.style(reach: .public)
        XCTAssertEqual(
            style,
            LinkReachPillStyleHex(
                backgroundLightHex: DocsColorHex.brandFillSoft, backgroundDarkHex: DocsColorHexDark.brandFillSoft,
                foregroundLightHex: DocsColorHex.textBrandSecondary,
                foregroundDarkHex: DocsColorHexDark.textBrandSecondary,
                systemImage: "globe", labelKey: .reach_public, hintKey: .linkreach_hint_public))
    }

    func testRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(LinkReach.restricted.rawValue, "restricted")
        XCTAssertEqual(LinkReach.authenticated.rawValue, "authenticated")
        XCTAssertEqual(LinkReach.public.rawValue, "public")
    }
}
