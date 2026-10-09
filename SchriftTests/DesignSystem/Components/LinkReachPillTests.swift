import XCTest

@testable import Schrift

final class LinkReachPillTests: XCTestCase {
    private let reaches: [LinkReach] = [.restricted, .authenticated, .public]

    func testEveryReachHasItsOwnStyleCopyAndIcon() {
        let styles = reaches.map { LinkReachPillStyleResolver.style(reach: $0) }
        for (index, style) in styles.enumerated() {
            for other in styles[(index + 1)...] {
                XCTAssertNotEqual(style.icon, other.icon)
                XCTAssertNotEqual(style.labelKey, other.labelKey)
                XCTAssertNotEqual(style.hintKey, other.hintKey)
                XCTAssertNotEqual(style.backgroundLightHex, other.backgroundLightHex)
            }
            XCTAssertNotEqual(style.backgroundLightHex, style.backgroundDarkHex, "\(reaches[index])")
        }
    }

    func testInkIsReadableOnThePillInBothModes() {
        for reach in reaches {
            let style = LinkReachPillStyleResolver.style(reach: reach)
            XCTAssertGreaterThanOrEqual(
                contrastRatio(style.foregroundLightHex, style.backgroundLightHex), 4.5, "\(reach) light")
            XCTAssertGreaterThanOrEqual(
                contrastRatio(style.foregroundDarkHex, style.backgroundDarkHex), 4.5, "\(reach) dark")
        }
    }

    func testRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(LinkReach.restricted.rawValue, "restricted")
        XCTAssertEqual(LinkReach.authenticated.rawValue, "authenticated")
        XCTAssertEqual(LinkReach.public.rawValue, "public")
    }
}
