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
    func testScaledUIFontGrowsWithTheTextSizeAndIsNeutralAtLarge() {
        let spec = DocsTypographySpec.body
        let base = UIFont.systemFont(ofSize: spec.size)

        let atLarge = scaledUIFont(base, for: spec, dynamicTypeSize: .large)
        let atAccessibility = scaledUIFont(base, for: spec, dynamicTypeSize: .accessibility3)

        XCTAssertEqual(atLarge.pointSize, spec.size)
        XCTAssertGreaterThan(atAccessibility.pointSize, atLarge.pointSize)
    }

    /// The size the editor renders at is an argument, not ambient state — which
    /// is what lets the SwiftUI row that calls it depend on the environment and
    /// re-run when the user changes their text size mid-document.
    func testScaledUIFontIsDrivenOnlyByItsArgument() {
        let spec = DocsTypographySpec.body
        let base = UIFont.systemFont(ofSize: spec.size)
        let sizes = DynamicTypeSize.allCases.map { scaledUIFont(base, for: spec, dynamicTypeSize: $0).pointSize }

        XCTAssertEqual(sizes, sizes.sorted(), "a larger text size must never render smaller text")
        XCTAssertGreaterThan(try XCTUnwrap(sizes.last), try XCTUnwrap(sizes.first))
    }

    func testUIContentSizeCategoryMapsEveryDynamicTypeSize() {
        XCTAssertEqual(uiContentSizeCategory(for: .xSmall), .extraSmall)
        XCTAssertEqual(uiContentSizeCategory(for: .small), .small)
        XCTAssertEqual(uiContentSizeCategory(for: .medium), .medium)
        XCTAssertEqual(uiContentSizeCategory(for: .large), .large)
        XCTAssertEqual(uiContentSizeCategory(for: .xLarge), .extraLarge)
        XCTAssertEqual(uiContentSizeCategory(for: .xxLarge), .extraExtraLarge)
        XCTAssertEqual(uiContentSizeCategory(for: .xxxLarge), .extraExtraExtraLarge)
        XCTAssertEqual(uiContentSizeCategory(for: .accessibility1), .accessibilityMedium)
        XCTAssertEqual(uiContentSizeCategory(for: .accessibility2), .accessibilityLarge)
        XCTAssertEqual(uiContentSizeCategory(for: .accessibility3), .accessibilityExtraLarge)
        XCTAssertEqual(uiContentSizeCategory(for: .accessibility4), .accessibilityExtraExtraLarge)
        XCTAssertEqual(uiContentSizeCategory(for: .accessibility5), .accessibilityExtraExtraExtraLarge)
    }

    /// Every block kind the editor renders has to scale, not just the one the
    /// spot-check happens to use.
    ///
    /// `.unknown` appears twice: its appearance is chosen from its *text*
    /// (`blockRendersVerbatim`), so a prose one and a verbatim one take
    /// different type ramps and both have to scale.
    func testEveryBlockKindsEditorFontScalesWithTheTextSize() {
        let blocks: [EditorBlock] = [
            EditorBlock(kind: .paragraph, text: "a"),
            EditorBlock(kind: .heading(level: 1), text: "a"),
            EditorBlock(kind: .heading(level: 2), text: "a"),
            EditorBlock(kind: .heading(level: 3), text: "a"),
            EditorBlock(kind: .quote, text: "a"),
            EditorBlock(kind: .codeBlock(language: ""), text: "a"),
            EditorBlock(kind: .bulletItem, text: "a"),
            EditorBlock(kind: .numberedItem, text: "a"),
            EditorBlock(kind: .checklistItem(checked: false), text: "a"),
            EditorBlock(kind: .checklistItem(checked: true), text: "a"),
            EditorBlock(kind: .unknown, text: "one\ntwo"),
            EditorBlock(kind: .unknown, text: "| a | b |"),
        ]
        for block in blocks {
            let atLarge = blockTextStyling(for: block, dynamicTypeSize: .large).font.pointSize
            let atAccessibility = blockTextStyling(for: block, dynamicTypeSize: .accessibility3).font.pointSize
            XCTAssertGreaterThan(atAccessibility, atLarge, "\(block.kind) does not scale with Dynamic Type")
        }
    }
}
