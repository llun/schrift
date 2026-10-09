import SwiftUI
import UIKit
import XCTest

@testable import Schrift

final class DocsTypographySpecTests: XCTestCase {
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
    func testScaledUIFontNeverShrinksAsTheTextSizeGrows() {
        let spec = DocsTypographySpec.body
        let base = UIFont.systemFont(ofSize: spec.size)
        let sizes = DynamicTypeSize.allCases.map { scaledUIFont(base, for: spec, dynamicTypeSize: $0).pointSize }

        XCTAssertEqual(sizes, sizes.sorted(), "a larger text size must never render smaller text")
        XCTAssertGreaterThan(try XCTUnwrap(sizes.last), try XCTUnwrap(sizes.first))
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
