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

    /// Every offset `snappedSelection` yields is a hidden-run boundary or was
    /// never interior — so a caret dropped anywhere inside the url comes back out.
    func testTheCaretNeverRestsStrictlyInsideHiddenSyntax() {
        let view = makeView("See [Review](https://x.dev/) now")
        let length = view.textStorage.length
        for offset in 0...length {
            let snapped = snappedSelection(NSRange(location: offset, length: 0), hidden: view.hiddenRanges)
            let interior = view.hiddenRanges.contains { range in
                snapped.location > range.location && snapped.location < range.location + range.length
            }
            XCTAssertFalse(interior, "caret \(offset) snapped to \(snapped.location), which is hidden")
        }
    }

    // MARK: - Tap hit-testing

    /// The point at the centre of the link's rendered label.
    private func labelCentre(_ view: EditorUITextView, labelRange: NSRange) -> CGPoint {
        view.layoutManager.ensureLayout(for: view.textContainer)
        let glyphRange = view.layoutManager.glyphRange(forCharacterRange: labelRange, actualCharacterRange: nil)
        let rect = view.layoutManager.boundingRect(forGlyphRange: glyphRange, in: view.textContainer)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testTappingTheLabelFindsTheLink() throws {
        let view = makeView("See [Review](https://x.dev/) now")
        let span = try XCTUnwrap(view.linkSpans.first)
        XCTAssertEqual(view.linkSpan(at: labelCentre(view, labelRange: span.labelRange))?.url, "https://x.dev/")
    }

    /// The syntax is zero-width, so it sits on the same pixels as the text next
    /// to it. Hit-testing the link's *full* range would open the menu when the
    /// user taps the space after it.
    func testTappingBesideTheLabelFindsNothing() throws {
        let view = makeView("See [Review](https://x.dev/) now")
        let span = try XCTUnwrap(view.linkSpans.first)
        let centre = labelCentre(view, labelRange: span.labelRange)

        // The word "See", well before the label.
        XCTAssertNil(view.linkSpan(at: CGPoint(x: 2, y: centre.y)))
        // Far to the right of all the text.
        XCTAssertNil(view.linkSpan(at: CGPoint(x: 1500, y: centre.y)))
    }

    func testTappingABlockWithNoLinksFindsNothing() {
        let view = makeView("Just some prose.")
        XCTAssertNil(view.linkSpan(at: CGPoint(x: 10, y: 5)))
    }

    func testTheSecondOfTwoLinksIsFoundByItsOwnLabel() throws {
        let view = makeView("[one](https://a.dev/) and [two](https://b.dev/)")
        XCTAssertEqual(view.linkSpans.count, 2)
        let second = view.linkSpans[1]
        XCTAssertEqual(view.linkSpan(at: labelCentre(view, labelRange: second.labelRange))?.url, "https://b.dev/")
    }

    // MARK: - Blocks that style nothing keep nothing stale

    /// Converting a block that held a link into a code block must drop its hidden
    /// ranges, or the syntax stays invisible in a block that renders verbatim.
    func testConvertingToACodeBlockClearsTheHiddenRanges() {
        let view = makeView("See [Review](https://x.dev/) now")
        XCTAssertFalse(view.hiddenRanges.isEmpty)
        restyle(view, kind: .codeBlock(language: ""))
        XCTAssertEqual(view.hiddenRanges, [])
        XCTAssertEqual(view.linkSpans, [])
    }
}
