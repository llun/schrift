import SwiftUI
import UIKit
import XCTest

@testable import Schrift

final class DocsTypographySpecTests: XCTestCase {
    func testLargeTitleMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.largeTitle, TypographySpec(size: 34, weight: .bold, textStyle: .largeTitle))
    }

    func testTitle1MatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.title1, TypographySpec(size: 28, weight: .bold, textStyle: .title))
    }

    func testTitle2MatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.title2, TypographySpec(size: 22, weight: .bold, textStyle: .title2))
    }

    func testHeadlineMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.headline, TypographySpec(size: 17, weight: .semibold, textStyle: .headline))
    }

    func testBodyMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.body, TypographySpec(size: 17, weight: .regular, textStyle: .body))
    }

    func testCalloutMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.callout, TypographySpec(size: 16, weight: .regular, textStyle: .callout))
    }

    func testSubheadMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.subhead, TypographySpec(size: 15, weight: .regular, textStyle: .subheadline))
    }

    func testFootnoteMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.footnote, TypographySpec(size: 13, weight: .regular, textStyle: .footnote))
    }

    func testCaptionMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.caption, TypographySpec(size: 12, weight: .regular, textStyle: .caption))
    }

    func testCodeMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.code, TypographySpec(size: 15, weight: .regular, textStyle: .subheadline))
    }

    /// The handoff's point sizes are the HIG defaults at the Large content size,
    /// which is what lets every token ride a system text style without changing
    /// how the app looks at the default text size. If a token's size and its
    /// style's default ever disagree, the app silently stops matching the
    /// handoff at the size most users run.
    func testEveryTokenSizeEqualsItsTextStyleDefaultAtTheLargeContentSize() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let specs: [(String, TypographySpec)] = [
            ("largeTitle", DocsTypographySpec.largeTitle),
            ("title1", DocsTypographySpec.title1),
            ("title2", DocsTypographySpec.title2),
            ("headline", DocsTypographySpec.headline),
            ("body", DocsTypographySpec.body),
            ("callout", DocsTypographySpec.callout),
            ("subhead", DocsTypographySpec.subhead),
            ("footnote", DocsTypographySpec.footnote),
            ("caption", DocsTypographySpec.caption),
            ("code", DocsTypographySpec.code),
        ]
        for (name, spec) in specs {
            let system = UIFont.preferredFont(
                forTextStyle: uiFontTextStyle(for: spec.textStyle), compatibleWith: traits)
            XCTAssertEqual(spec.size, system.pointSize, "\(name) drifted from its text style's default size")
        }
    }

    func testUIFontTextStyleMapsEverySwiftUITextStyle() {
        XCTAssertEqual(uiFontTextStyle(for: .largeTitle), .largeTitle)
        XCTAssertEqual(uiFontTextStyle(for: .title), .title1)
        XCTAssertEqual(uiFontTextStyle(for: .title2), .title2)
        XCTAssertEqual(uiFontTextStyle(for: .title3), .title3)
        XCTAssertEqual(uiFontTextStyle(for: .headline), .headline)
        XCTAssertEqual(uiFontTextStyle(for: .subheadline), .subheadline)
        XCTAssertEqual(uiFontTextStyle(for: .body), .body)
        XCTAssertEqual(uiFontTextStyle(for: .callout), .callout)
        XCTAssertEqual(uiFontTextStyle(for: .footnote), .footnote)
        XCTAssertEqual(uiFontTextStyle(for: .caption), .caption1)
        XCTAssertEqual(uiFontTextStyle(for: .caption2), .caption2)
    }

    /// The editor's UIKit fonts must grow with the user's text-size setting;
    /// at the default size they must still be exactly the handoff's size.
    func testScaledUIFontGrowsWithTheContentSizeCategoryAndIsNeutralAtLarge() {
        let spec = DocsTypographySpec.body
        let base = UIFont.systemFont(ofSize: spec.size)
        let atLarge = UIFontMetrics(forTextStyle: uiFontTextStyle(for: spec.textStyle))
            .scaledFont(for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let atAccessibility = UIFontMetrics(forTextStyle: uiFontTextStyle(for: spec.textStyle))
            .scaledFont(
                for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge))

        XCTAssertEqual(atLarge.pointSize, spec.size)
        XCTAssertGreaterThan(atAccessibility.pointSize, atLarge.pointSize)
    }
}
