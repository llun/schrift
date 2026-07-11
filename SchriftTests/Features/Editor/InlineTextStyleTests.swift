import SwiftUI
import UIKit
import XCTest

@testable import Schrift

final class InlineTextStyleTests: XCTestCase {

    // MARK: - InlineTextStyleResolver

    func testALinkMarkResolvesToTheAdaptiveTextBrandHexPair() {
        let style = InlineTextStyleResolver.style(for: [.link(href: "https://x.dev/")])
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.textBrand)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.textBrand)
        XCTAssertTrue(style.isUnderlined)
    }

    func testNoMarksLeavesTheForegroundHexesNilSoTheBlockColorIsInherited() {
        let style = InlineTextStyleResolver.style(for: [.bold])
        XCTAssertNil(style.foregroundLightHex)
        XCTAssertNil(style.foregroundDarkHex)
    }

    // MARK: - inlineTextAttributes

    /// The resolved `UIColor` must actually be dynamic — i.e. it must resolve
    /// to `textBrand`'s light hex under a light trait collection and to
    /// `textBrand`'s dark hex under a dark one. A `Color(hex:)`-built static
    /// color would return the same value for both and fail this test.
    func testLinkForegroundColorAdaptsToTheTraitCollection() throws {
        let attributes = inlineTextAttributes(for: [.link(href: "https://x.dev/")], base: .systemFont(ofSize: 17))
        let uiColor = try XCTUnwrap(attributes[.foregroundColor] as? UIColor)

        let light = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))

        XCTAssertEqual(rgba(light), rgba(UIColor(Color(hex: DocsColorHex.textBrand))))
        XCTAssertEqual(rgba(dark), rgba(UIColor(Color(hex: DocsColorHexDark.textBrand))))
        XCTAssertNotEqual(rgba(light), rgba(dark))
    }

    func testNoForegroundColorAttributeWhenNoMarkSetsOne() {
        let attributes = inlineTextAttributes(for: [.bold], base: .systemFont(ofSize: 17))
        XCTAssertNil(attributes[.foregroundColor])
    }

    private func rgba(_ color: UIColor?) -> [CGFloat]? {
        guard
            let components = color?.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components
        else { return nil }
        return components.map { ($0 * 255).rounded() }
    }
}
