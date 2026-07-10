import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// The design rests on one claim: markdown syntax can be drawn at **zero width**
/// while its characters stay in the text storage. That is what keeps every
/// `NSRange` in the editor a source offset and spares the caret subsystem an
/// offset map — and what keeps the full-overwrite save re-parsing exactly the
/// characters the user is looking at.
///
/// If these ever fail, the fix is not to relax them: it is to fall back to
/// drawing the syntax dimmed but visible.
@MainActor
final class BlockTextRenderingTests: XCTestCase {

    private func makeView(_ text: String, kind: BlockKind = .paragraph) -> EditorUITextView {
        let view = EditorUITextView.textKit1()
        view.frame = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Pin the container so `usedRect` measures the text, not the layout pass.
        view.textContainer.widthTracksTextView = false
        view.textContainer.size = CGSize(width: 2000, height: CGFloat.greatestFiniteMagnitude)
        view.text = text
        restyle(view, kind: kind)
        return view
    }

    private func restyle(_ view: EditorUITextView, kind: BlockKind) {
        let styling = blockTextStyling(for: kind)
        view.applyInlineStyling(
            font: styling.font, textColor: styling.textColor, rendersInlineMarkdown: styling.rendersInlineMarkdown)
    }

    private func renderedWidth(_ view: EditorUITextView) -> CGFloat {
        view.layoutManager.ensureLayout(for: view.textContainer)
        return view.layoutManager.usedRect(for: view.textContainer).width
    }

    private func rgba(_ color: UIColor?) -> [CGFloat]? {
        guard
            let components = color?.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components
        else { return nil }
        return components.map { ($0 * 255).rounded() }
    }

    // MARK: - The load-bearing claim

    /// A link renders exactly as wide as its label alone: the `[`, `](` , url and
    /// `)` contribute nothing at all.
    func testLinkSyntaxIsDrawnAtZeroWidth() {
        let styled = makeView("See [Review](https://x.dev/) now")
        let plain = makeView("See Review now")
        XCTAssertEqual(renderedWidth(styled), renderedWidth(plain), accuracy: 0.5)
    }

    /// Strikethrough keeps the base font, so its delimiters are the clean case
    /// for measuring: `~~` must add no advance whatsoever.
    func testEmphasisDelimitersAreDrawnAtZeroWidth() {
        let styled = makeView("a ~~b~~ c")
        let plain = makeView("a b c")
        XCTAssertEqual(renderedWidth(styled), renderedWidth(plain), accuracy: 0.5)
    }

    /// Escaped delimiters are *not* syntax for the mark — the backslash is, and
    /// the `~` it escapes stays visible. Guards against hiding too much.
    func testEscapedDelimitersStayVisibleAndOnlyTheBackslashIsHidden() {
        let styled = makeView("a \\~b\\~ c")
        let plain = makeView("a ~b~ c")
        XCTAssertEqual(renderedWidth(styled), renderedWidth(plain), accuracy: 0.5)
    }

    func testTheBufferKeepsEveryCharacterThatWasHidden() {
        let source = "See [Review](https://x.dev/) now"
        let view = makeView(source)
        XCTAssertEqual(view.text, source)
        XCTAssertEqual(view.textStorage.length, (source as NSString).length)
        // Glyph indexes survive too — the characters are laid out, just not drawn.
        XCTAssertEqual(view.layoutManager.numberOfGlyphs, (source as NSString).length)
    }

    func testHiddenRangesAndLinksComeFromTheScanner() {
        let source = "See [Review](https://x.dev/) now"
        let view = makeView(source)
        XCTAssertEqual(view.hiddenRanges, InlineMarkdown.layout(of: source).syntax)
        XCTAssertEqual(view.linkSpans.map(\.label), ["Review"])
        XCTAssertEqual(view.linkSpans.map(\.url), ["https://x.dev/"])
    }

    // MARK: - Blocks whose text is literal

    func testACodeBlockHidesNothingAndStylesNothing() {
        let view = makeView("let x = **not bold** // [a](b)", kind: .codeBlock(language: "swift"))
        XCTAssertEqual(view.hiddenRanges, [])
        XCTAssertEqual(view.linkSpans, [])
        XCTAssertNil(view.textStorage.attribute(.underlineStyle, at: 24, effectiveRange: nil))
    }

    func testAnUnknownBlockHidesNothing() {
        let view = makeView("| a | [b](c) |", kind: .unknown)
        XCTAssertEqual(view.hiddenRanges, [])
        XCTAssertEqual(view.linkSpans, [])
    }

    // MARK: - Attributes

    func testTheLinkLabelIsPaintedWithTheBrandColor() {
        let view = makeView("See [Review](https://x.dev/) now")
        // Index 5 is the "R" of "Review"; index 4 is the hidden "[".
        let color = view.textStorage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? UIColor
        XCTAssertEqual(rgba(color), rgba(UIColor(Color(hex: DocsColorHex.textBrand))))
        let underline = view.textStorage.attribute(.underlineStyle, at: 5, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
    }

    func testTextOutsideALinkKeepsTheBlockColor() {
        let view = makeView("See [Review](https://x.dev/) now")
        let color = view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(rgba(color), rgba(UIColor(DocsColor.textPrimary)))
        XCTAssertNil(view.textStorage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testBoldInsideAHeadingStaysHeadingSized() throws {
        let view = makeView("A **big** title", kind: .heading(level: 1))
        let font = try XCTUnwrap(view.textStorage.attribute(.font, at: 4, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, DocsTypographySpec.title1.size)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testInlineCodeTakesTheMonospacedFace() throws {
        let view = makeView("a `b` c")
        let font = try XCTUnwrap(view.textStorage.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    func testStrikethroughIsApplied() {
        let view = makeView("a ~~b~~ c")
        let value = view.textStorage.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) as? Int
        XCTAssertEqual(value, NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Backspace over hidden characters

    func testBackspaceAfterALinkDeletesTheLabelsLastLetter() {
        let view = makeView("[Review](https://x.dev/)")
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
        view.deleteBackward()
        XCTAssertEqual(view.text, "[Revie](https://x.dev/)")
    }

    func testBackspaceInsideALabelIsOrdinary() {
        let view = makeView("[Review](https://x.dev/)")
        view.selectedRange = NSRange(location: 4, length: 0)  // after "Rev"
        view.deleteBackward()
        XCTAssertEqual(view.text, "[Reiew](https://x.dev/)")
    }

    /// Emptying a label stops it parsing as a link and reveals its syntax rather
    /// than destroying anything. The buffer is always exactly the saved markdown.
    func testReducingALabelToNothingRevealsTheSyntaxInsteadOfLosingContent() {
        let view = makeView("[R](https://x.dev/)")
        view.selectedRange = NSRange(location: 2, length: 0)
        view.deleteBackward()
        XCTAssertEqual(view.text, "[](https://x.dev/)")
        restyle(view, kind: .paragraph)
        XCTAssertEqual(view.hiddenRanges, [], "an unparseable link must show its own syntax")
    }

    // MARK: - Selection

    func testTheCaretNeverRestsInsideHiddenSyntax() {
        let view = makeView("See [Review](https://x.dev/) now")
        // Drop the caret in the middle of the hidden url.
        let snapped = snappedSelection(NSRange(location: 20, length: 0), hidden: view.hiddenRanges)
        XCTAssertFalse(
            view.hiddenRanges.contains { NSLocationInRange(snapped.location, $0) && $0.location != snapped.location })
    }
}
