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

    /// A link to another document on the server is a page chip: brand ink, no
    /// underline. An external link on the same call keeps its underline, and so
    /// does the document link when no server is named.
    func testADocumentLinkIsNotUnderlinedButAnExternalLinkIs() {
        let page = InlineMark.link(href: "https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/")
        let chip = InlineTextStyleResolver.style(for: [page], serverHost: "docs.example.org")
        XCTAssertFalse(chip.isUnderlined)
        XCTAssertEqual(chip.foregroundLightHex, DocsColorHex.textBrand)
        XCTAssertEqual(chip.foregroundDarkHex, DocsColorHexDark.textBrand)

        let external = InlineTextStyleResolver.style(
            for: [.link(href: "https://example.com/docs/11111111-1111-4111-8111-111111111111/")],
            serverHost: "docs.example.org")
        XCTAssertTrue(external.isUnderlined)
        XCTAssertTrue(InlineTextStyleResolver.style(for: [page]).isUnderlined)

        let attributes = inlineTextAttributes(
            for: [page], base: .systemFont(ofSize: 17), serverHost: "docs.example.org")
        XCTAssertNil(attributes[.underlineStyle])
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
