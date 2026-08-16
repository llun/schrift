import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// The editor draws the same document twice — SwiftUI `Text` while reading, a
/// UIKit `UITextView` while editing — and the two copies used to drift, so
/// tapping a block re-laid-out the page instead of placing a caret.
///
/// `EditorBlockStyle` makes that structural: one appearance table, one
/// decoration modifier, one adornment view, one set of metrics. These tests pin
/// the parts a shared table cannot guarantee on its own — that the SwiftUI and
/// UIKit *conversions* of one appearance land on the same font and colour, that
/// the decoration and adornment measure what they claim, and that a completed
/// to-do is struck through on both surfaces.
///
/// Geometry is measured with `UIHostingController.sizeThatFits(in:)`, the same
/// instrument as `SaveStatusIndicatorTests` and `MarkdownBlockAttachmentTests`,
/// and every measurement carries a negative control — a measurement that cannot
/// fail is not evidence.
@MainActor
final class EditorSurfaceParityTests: XCTestCase {
    private let proposal = CGSize(width: 370, height: 4000)
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "EditorSurfaceParityTests")
        defaults.removePersistentDomain(forName: "EditorSurfaceParityTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "EditorSurfaceParityTests")
        defaults = nil
        super.tearDown()
    }

    private func english() -> LocalizationStore {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        return store
    }

    /// Every kind that carries text. `.unknown` appears twice on purpose: its
    /// appearance is chosen from its *text*, so prose and verbatim are two
    /// different cases of one kind.
    private var textBlocks: [EditorBlock] {
        [
            EditorBlock(kind: .paragraph, text: "Some prose."),
            EditorBlock(kind: .heading(level: 1), text: "Title"),
            EditorBlock(kind: .heading(level: 2), text: "Section"),
            EditorBlock(kind: .heading(level: 3), text: "Subsection"),
            EditorBlock(kind: .bulletItem, text: "Bullet"),
            EditorBlock(kind: .numberedItem, text: "Numbered"),
            EditorBlock(kind: .checklistItem(checked: false), text: "Open"),
            EditorBlock(kind: .checklistItem(checked: true), text: "Done"),
            EditorBlock(kind: .quote, text: "Quoted"),
            EditorBlock(kind: .codeBlock(language: "swift"), text: "let x = 1"),
            EditorBlock(kind: .unknown, text: "one\ntwo"),
            EditorBlock(kind: .unknown, text: "| a | b |"),
        ]
    }

    private func rgba(_ color: UIColor?) -> [CGFloat]? {
        guard
            let components = color?.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components
        else { return nil }
        return components.map { ($0 * 255).rounded() }
    }

    // MARK: - One appearance, two conversions

    /// The reading surface builds a SwiftUI `Font` from the appearance and the
    /// editing surface a `UIFont`; nothing but this checks that the two land in
    /// the same place.
    func testTheSwiftUIAndUIKitFontsAgreeForEveryBlockKind() {
        for block in textBlocks {
            let appearance = blockTextAppearance(for: block.kind, text: block.text)
            let uiFont = blockTextStyling(for: block, dynamicTypeSize: .large).font

            XCTAssertEqual(
                uiFont.pointSize, appearance.spec.size, accuracy: 0.01,
                "\(block.kind) editing font is not its token's reference size at the Large content size")

            let traits = uiFont.fontDescriptor.symbolicTraits
            XCTAssertEqual(
                traits.contains(.traitMonoSpace), appearance.design == .monospaced,
                "\(block.kind) disagrees about the monospaced face")
            XCTAssertEqual(
                traits.contains(.traitItalic), appearance.isItalic,
                "\(block.kind) disagrees about italics")

            // The `.traitBold` flag is too coarse to read a weight off: UIKit
            // sets it for `.semibold` too, so a heading-3 (semibold) and a
            // heading-1 (bold) are indistinguishable by it. The descriptor's
            // numeric weight is what actually differs — and asserting it is a
            // real claim about `scaledUIFont`, which round-trips the font
            // through `UIFontMetrics` and could drop it.
            //
            // Italics are the documented exception: `.italicSystemFont(ofSize:)`
            // takes no weight, and the one italic token (quote) is `.regular`
            // anyway.
            if !appearance.isItalic {
                XCTAssertEqual(
                    weight(of: uiFont), uiFontWeight(appearance.spec.weight).rawValue, accuracy: 0.01,
                    "\(block.kind) disagrees about weight")
            }
        }
    }

    private func weight(of font: UIFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? .nan
    }

    func testTheSwiftUIAndUIKitColoursAgreeForEveryBlockKind() {
        for block in textBlocks {
            let appearance = blockTextAppearance(for: block.kind, text: block.text)
            let editing = blockTextStyling(for: block, dynamicTypeSize: .large).textColor
            XCTAssertEqual(
                rgba(UIColor(appearance.color)), rgba(editing), "\(block.kind) is drawn in two different colours")
        }
    }

    /// The negative control for the two above: the table really does distinguish
    /// kinds, so "they always agree" is not the trivial consequence of every
    /// kind being identical.
    func testTheAppearanceTableActuallyDistinguishesKinds() {
        let body = blockTextAppearance(for: .paragraph, text: "x")
        let heading = blockTextAppearance(for: .heading(level: 1), text: "x")
        let quote = blockTextAppearance(for: .quote, text: "x")
        let code = blockTextAppearance(for: .codeBlock(language: ""), text: "x")

        XCTAssertGreaterThan(heading.spec.size, body.spec.size)
        XCTAssertTrue(quote.isItalic)
        XCTAssertFalse(body.isItalic)
        XCTAssertEqual(code.design, .monospaced)
        XCTAssertNil(body.design)
        XCTAssertNotEqual(quote.colorLightHex, body.colorLightHex)
        // Two distinct non-regular weights, so the weight assertion above is
        // reading something that actually varies.
        XCTAssertNotEqual(
            uiFontWeight(heading.spec.weight).rawValue,
            uiFontWeight(blockTextAppearance(for: .heading(level: 3), text: "x").spec.weight).rawValue)
    }

    /// `.unknown` is the reason every entry point takes the block's text: a
    /// paragraph that merely spilled across lines is prose on both surfaces,
    /// where the editing side used to make *every* `.unknown` monospaced code.
    func testAProseUnknownBlockIsBodyTextAndAVerbatimOneIsCode() {
        let prose = EditorBlock(kind: .unknown, text: "Line one\nLine two")
        let table = EditorBlock(kind: .unknown, text: "| a | b |\n| - | - |")

        XCTAssertFalse(blockRendersVerbatim(prose.kind, text: prose.text))
        XCTAssertEqual(blockDecoration(for: prose.kind, text: prose.text), .none)
        XCTAssertNil(blockTextAppearance(for: prose.kind, text: prose.text).design)
        XCTAssertEqual(
            blockTextAppearance(for: prose.kind, text: prose.text).spec.size, DocsTypographySpec.body.size)

        XCTAssertTrue(blockRendersVerbatim(table.kind, text: table.text))
        XCTAssertEqual(blockDecoration(for: table.kind, text: table.text), .verbatimPanel)
        XCTAssertEqual(blockTextAppearance(for: table.kind, text: table.text).design, .monospaced)
    }

    /// Appearance follows the text; the *input* rules follow the kind. A prose
    /// `.unknown` still holds literal markdown across several lines, so
    /// autocorrect must stay off and Return must still insert a newline even
    /// though it is drawn as body text.
    func testAProseUnknownBlockStillBehavesLikeLiteralMultiLineText() {
        let styling = blockTextStyling(for: EditorBlock(kind: .unknown, text: "Line one\nLine two"))
        XCTAssertTrue(styling.isCodeLike)
        XCTAssertTrue(styling.allowsNewlines)
        XCTAssertFalse(styling.rendersInlineMarkdown)
    }

    // MARK: - Strikethrough on both surfaces

    func testACompletedToDoIsStruckThroughOnBothSurfaces() {
        let done = EditorBlock(kind: .checklistItem(checked: true), text: "Ship it")
        let open = EditorBlock(kind: .checklistItem(checked: false), text: "Ship it")

        // The one flag both surfaces read.
        XCTAssertTrue(blockTextAppearance(for: done.kind, text: done.text).isStruckThrough)
        XCTAssertFalse(blockTextAppearance(for: open.kind, text: open.text).isStruckThrough)

        // …and the editing surface's use of it, on the *block-wide* attributes.
        // `setAttributes` replaces the whole range on every keystroke's restyle,
        // so a strikethrough applied anywhere else would be wiped a character
        // later.
        XCTAssertEqual(
            baseTextAttributes(for: blockTextStyling(for: done))[.strikethroughStyle] as? Int,
            NSUnderlineStyle.single.rawValue)
        XCTAssertNil(baseTextAttributes(for: blockTextStyling(for: open))[.strikethroughStyle])
    }

    /// End to end through the real text view, over the whole buffer — including
    /// the characters no inline mark covers, which is what the previous fix
    /// attempt (typing attributes only) would have missed.
    func testTheEditingTextViewStrikesEveryCharacterOfACompletedToDo() {
        let text = "Ship **it** now"
        let view = EditorUITextView.textKit1()
        view.text = text
        view.applyInlineStyling(blockTextStyling(for: EditorBlock(kind: .checklistItem(checked: true), text: text)))

        for offset in 0..<(text as NSString).length {
            let value = view.textStorage.attribute(.strikethroughStyle, at: offset, effectiveRange: nil) as? Int
            XCTAssertEqual(value, NSUnderlineStyle.single.rawValue, "character \(offset) is not struck through")
        }

        // Negative control: the same text in an unchecked item is struck
        // nowhere, so the assertion above is reading the flag and not a
        // constant.
        let open = EditorUITextView.textKit1()
        open.text = text
        open.applyInlineStyling(blockTextStyling(for: EditorBlock(kind: .checklistItem(checked: false), text: text)))
        for offset in 0..<(text as NSString).length {
            XCTAssertNil(open.textStorage.attribute(.strikethroughStyle, at: offset, effectiveRange: nil))
        }
    }

    /// A completed to-do's strikethrough must not change the row's height, or
    /// checking a box would shuffle everything below it.
    func testStrikingAToDoThroughDoesNotResizeTheReadingRow() {
        let done = height(of: EditorBlock(kind: .checklistItem(checked: true), text: "Ship it"))
        let open = height(of: EditorBlock(kind: .checklistItem(checked: false), text: "Ship it"))
        XCTAssertEqual(done, open, accuracy: 0.5)
    }

    // MARK: - The adornment

    /// The checkbox is bigger than either surface used to draw it (reading 20pt,
    /// editing 17pt) — it is the document's one touchable adornment.
    func testTheCheckboxIsLargerThanEitherSurfaceUsedToDrawIt() {
        XCTAssertGreaterThan(EditorBlockMetrics.checkboxSize, 20)
    }

    /// The padded box the `contentShape` is taken from clears the 44pt floor —
    /// **in isolation**, which is the honest scope of this measurement.
    ///
    /// Two things it does not say. It is a **reproduction** of the shipped
    /// modifier chain, not the shipped view: `EditorBlockAdornment` follows the
    /// padding with `.contentShape(Rectangle())` and a matching *negative*
    /// padding, so the real adornment's layout box is the bare glyph again and
    /// `sizeThatFits` can never see the shape at all (the same reason
    /// `PagesTreeDrawerTests` measures a replica — keep this one in step with
    /// `checkbox(checked:)`). And in a *checklist*, consecutive rows sit
    /// `blockSpacing` apart, so each row's shape overlaps its neighbours' and the
    /// unambiguous per-checkbox target is bounded by the row pitch — glyph +
    /// gap ≈ 35pt, not 47. That is still well over the ~22pt pitch these rows
    /// had before, which is the improvement being claimed; 44pt on a dense list
    /// would need a taller row, and the row is shared with the reading
    /// surface.
    ///
    /// **Measured, not computed**, and the history is the argument. This began
    /// as `checkboxSize + 2 * checkboxHitPadding == rowMinHeight`, with the
    /// padding *defined* as `(rowMinHeight - checkboxSize) / 2` — which
    /// substitutes to `rowMinHeight == rowMinHeight`, true for every value of
    /// both symbols, so the assertion could not fail for any change to either.
    /// Hosting the padded glyph asks the question that can, and it answered
    /// **43pt**: a `MaterialSymbol` is a `Text`, so it occupies its glyph's
    /// typographic box (23pt for a 24pt symbol), not its point size, and the
    /// arithmetic was a point short of the floor it was written to guarantee.
    /// `checkboxHitPadding` is a token with headroom now.
    func testTheCheckboxHitRectReachesTheRowMinimum() {
        let padded = UIHostingController(
            rootView: MaterialSymbol(.check_box_outline_blank, size: EditorBlockMetrics.checkboxSize)
                .padding(EditorBlockMetrics.checkboxHitPadding)
        ).sizeThatFits(in: CGSize(width: 300, height: 300))

        XCTAssertGreaterThanOrEqual(padded.height, DocsSpacing.rowMinHeight)
        XCTAssertGreaterThanOrEqual(padded.width, DocsSpacing.rowMinHeight)

        // Negative control: the padding is doing the work — the bare glyph is
        // short of the floor on its own, which is why it needs growing at all.
        let bare = UIHostingController(
            rootView: MaterialSymbol(.check_box_outline_blank, size: EditorBlockMetrics.checkboxSize)
        ).sizeThatFits(in: CGSize(width: 300, height: 300))
        XCTAssertLessThan(bare.height, DocsSpacing.rowMinHeight)
    }

    /// Wrapping the glyph in the editing surface's toggle button adds nothing to
    /// its footprint, so the text column starts at the same x on both surfaces.
    ///
    /// Narrower than it looks, and deliberately so: both surfaces draw the same
    /// `checkbox(checked:)` helper, so this cannot catch a change to the glyph or
    /// its padding — `testTheCheckboxHitPaddingIsGivenBackToTheLayout` is what
    /// covers that. What it does catch is a `Button`/`buttonStyle` that starts
    /// contributing chrome of its own.
    func testWrappingTheCheckboxInItsToggleButtonAddsNoFootprint() {
        let reading = adornmentSize(.checklistItem(checked: false), interactive: false)
        let editing = adornmentSize(.checklistItem(checked: false), interactive: true)
        XCTAssertEqual(reading.width, editing.width, accuracy: 0.5)
        XCTAssertEqual(reading.height, editing.height, accuracy: 0.5)

        // Negative control: the instrument does discriminate — a bullet is a
        // narrower adornment than a checkbox.
        XCTAssertLessThan(adornmentSize(.bulletItem, interactive: false).width, reading.width)
    }

    /// The grown hit rect is given back to the layout in full, so the checkbox
    /// occupies exactly its glyph and the text column starts where it would
    /// without a tap target at all. Measured against a bare `MaterialSymbol` of
    /// the same size: drop the trailing negative padding and the adornment grows
    /// by `2 * checkboxHitPadding` in each axis.
    func testTheCheckboxHitPaddingIsGivenBackToTheLayout() {
        let glyph = UIHostingController(
            rootView: MaterialSymbol(.check_box_outline_blank, size: EditorBlockMetrics.checkboxSize)
        ).sizeThatFits(in: CGSize(width: 300, height: 300))
        let adornment = adornmentSize(.checklistItem(checked: false), interactive: true)

        XCTAssertEqual(adornment.width, glyph.width, accuracy: 0.5)
        XCTAssertEqual(adornment.height, glyph.height, accuracy: 0.5)
        // Control: the padding it is giving back is not zero.
        XCTAssertGreaterThan(EditorBlockMetrics.checkboxHitPadding, 0)
    }

    private func adornmentSize(_ kind: BlockKind, interactive: Bool) -> CGSize {
        let host = UIHostingController(
            rootView: EditorBlockAdornment(
                kind: kind, numberedIndex: 1, onToggleChecklist: interactive ? {} : nil
            )
            .environment(english()))
        return host.sizeThatFits(in: CGSize(width: 300, height: 300))
    }

    // MARK: - The decoration

    /// A quote and a verbatim panel really are decorated, and by the amounts the
    /// metrics claim — with an undecorated block as the control.
    func testTheDecorationAddsExactlyTheMetricsItClaims() {
        let inner = CGSize(width: 100, height: 20)
        let plain = decoratedSize(.none, inner: inner)
        let quote = decoratedSize(.quote, inner: inner)
        let panel = decoratedSize(.verbatimPanel, inner: inner)

        XCTAssertEqual(plain.height, inner.height, accuracy: 0.5)
        XCTAssertEqual(
            quote.height, inner.height + 2 * EditorBlockMetrics.quoteVerticalPadding, accuracy: 0.5)
        XCTAssertEqual(
            panel.height, inner.height + 2 * EditorBlockMetrics.decorationPadding, accuracy: 0.5)
    }

    private func decoratedSize(_ decoration: EditorBlockDecoration, inner: CGSize) -> CGSize {
        let host = UIHostingController(
            rootView: Color.clear
                .frame(width: inner.width, height: inner.height)
                .editorBlockDecoration(decoration))
        return host.sizeThatFits(in: CGSize(width: 370, height: 1000))
    }

    func testOnlyQuotesAndVerbatimBlocksAreDecorated() {
        XCTAssertEqual(blockDecoration(for: .quote, text: "x"), .quote)
        XCTAssertEqual(blockDecoration(for: .codeBlock(language: ""), text: "x"), .verbatimPanel)
        XCTAssertEqual(blockDecoration(for: .paragraph, text: "x"), .none)
        XCTAssertEqual(blockDecoration(for: .heading(level: 1), text: "x"), .none)
        XCTAssertEqual(blockDecoration(for: .checklistItem(checked: true), text: "x"), .none)
    }

    /// The reading surface draws that decoration too — before this it drew a
    /// panel for `.codeBlock` only, so a quote lost its card and a verbatim
    /// `.unknown` never had one.
    func testTheReadingSurfaceDrawsTheQuoteAndPanelChrome() {
        let paragraph = height(of: EditorBlock(kind: .paragraph, text: "Quoted"))
        let quote = height(of: EditorBlock(kind: .quote, text: "Quoted"))
        let table = height(of: EditorBlock(kind: .unknown, text: "| a | b |"))
        let prose = height(of: EditorBlock(kind: .unknown, text: "Quoted"))

        XCTAssertEqual(
            quote, paragraph + 2 * EditorBlockMetrics.quoteVerticalPadding, accuracy: 1,
            "a quote must carry its own vertical padding")
        XCTAssertGreaterThan(table, prose, "a verbatim `.unknown` must sit in a panel and a prose one must not")
    }

    // MARK: - The document header

    /// The header is the PR's largest single claim — it is where the body used
    /// to lurch ~38pt up on tap — so it is measured rather than argued.
    ///
    /// The two differ in exactly two ways by construction: the title is a
    /// `TextField` while editing and a `Text` while reading, and the status slot
    /// holds a `SaveStatusIndicator` rather than the sync caption. Neither may
    /// change the header's height.
    ///
    /// The tolerance is the same line-box artefact the row test bounds — a
    /// `TextField` reserves ~1.7pt more than a `Text` for the same title-sized
    /// font. Unlike the per-block residual this one is paid *once*, at the top of
    /// the document, so it shifts everything by under 2pt rather than
    /// accumulating.
    func testTheReadingAndEditingHeadersAreTheSameHeight() {
        let reading = headerHeight(title: "Weekend plan", editable: false)
        let editing = headerHeight(title: "Weekend plan", editable: true)
        XCTAssertEqual(reading, editing, accuracy: Self.headerLineBoxResidual)
    }

    /// One title line's worth of the same leading residual measured on the rows.
    /// Small enough to be paid once; a regression that dropped the metadata row
    /// or the placeholder would be tens of points and fail loudly.
    private static let headerLineBoxResidual: CGFloat = 2

    /// An **untitled** document is the case that used to differ most: reading
    /// rendered an empty `Text` and editing a full-height placeholder, so the
    /// whole body moved by a title's height on the swap. Both show the same
    /// placeholder now.
    func testAnUntitledDocumentsHeaderIsTheSameHeightOnBothSurfaces() {
        let reading = headerHeight(title: "", editable: false)
        let editing = headerHeight(title: "", editable: true)
        XCTAssertEqual(reading, editing, accuracy: Self.headerLineBoxResidual)

        // …and it is a real title line on both, not a collapsed one: an untitled
        // header is as tall as a titled one.
        XCTAssertEqual(reading, headerHeight(title: "Weekend plan", editable: false), accuracy: 1)
    }

    /// The status slot is floored at the row minimum on both surfaces, so
    /// swapping the sync caption (a footnote, ~16pt on its own) for the
    /// `SaveStatusIndicator` cannot move anything below it — which is the jump
    /// that used to land on the *first keystroke*, when the old strip appeared
    /// out of nothing above the canvas.
    func testTheStatusSlotIsFlooredSoSwappingItMovesNothing() {
        let caption = headerHeight(title: "T", editable: false)
        let indicator = headerHeight(title: "T", editable: true, status: .save)
        let passive = headerHeight(title: "T", editable: true, status: .savedOnDevice)

        XCTAssertEqual(caption, indicator, accuracy: Self.headerLineBoxResidual)
        XCTAssertEqual(caption, passive, accuracy: Self.headerLineBoxResidual)

        // Negative control: the floor is what makes those equal — a bare
        // footnote is far shorter than the row minimum, so without it the
        // caption row would be the short one.
        let bareCaption = UIHostingController(
            rootView: Text("Synced just now").font(DocsFont.footnote)
        ).sizeThatFits(in: headerProposal).height
        XCTAssertLessThan(bareCaption, DocsSpacing.rowMinHeight)
    }

    private var headerProposal: CGSize {
        CGSize(width: 402 - 2 * EditorBlockMetrics.gutter, height: 4000)
    }

    /// Hosts the real `EditorDocumentHeader`. `status` picks which slot content
    /// to measure: `nil` stands in for the reading surface's sync caption (a
    /// plain footnote `Text`, which is what `syncCaptionLabel` renders in every
    /// non-retry state), any case for the editing surface's indicator.
    private func headerHeight(
        title: String, editable: Bool, status: SaveStatusDisplay? = nil
    ) -> CGFloat {
        let host = UIHostingController(
            rootView: EditorDocumentHeader(
                title: title, onEditTitle: editable ? { _ in } : nil, reach: .restricted, peers: []
            ) {
                if let status {
                    SaveStatusIndicator(display: status, onTap: {})
                } else {
                    Text("Synced just now").font(DocsFont.footnote).foregroundStyle(DocsColor.textTertiary)
                }
            }
            .environment(english()))
        return host.sizeThatFits(in: headerProposal).height
    }

    // MARK: - Metrics

    /// Both surfaces top the inter-block gap up to the header-to-body gap with
    /// `headerToBodySpacing - blockSpacing`. A negative result would be a
    /// negative padding — the header would overlap the first block.
    func testTheHeaderGapIsWiderThanTheBlockGap() {
        XCTAssertGreaterThan(EditorBlockMetrics.headerToBodySpacing, EditorBlockMetrics.blockSpacing)
    }

    /// The document body is inset by the app's page gutter, like every other
    /// screen and like the editor's own chrome (error banner, formatting bar).
    /// The reading surface used to inset by 22pt — 6pt more than its own error
    /// banner, and 6pt more than the editing canvas.
    func testTheBodyUsesTheAppsPageGutter() {
        XCTAssertEqual(EditorBlockMetrics.gutter, DocsSpacing.gutter)
    }

    // MARK: - The rows themselves

    /// The end-to-end claim, measured on the real views: a block occupies the
    /// same vertical space whether it is being read or edited, so tapping into
    /// the document does not shuffle everything below the tap.
    ///
    /// A shared style table proves the two surfaces read the same values; it
    /// cannot prove SwiftUI and TextKit then lay them out the same way. Only
    /// hosting `MarkdownBlockView` against the real `BlockEditorRow` does that —
    /// which is why the row is internal.
    ///
    /// **The bound is not zero, and the residual is real.** A SwiftUI `Text`
    /// carries a little more leading than the same font in a `UITextView` with
    /// `lineFragmentPadding` and `textContainerInset` zeroed — measured at the
    /// Large content size: ~3.7pt at body, ~7.3pt at title1. It is a uniform
    /// tightening, not a re-flow (nothing moves horizontally and no line
    /// re-wraps), and closing it would mean reverse-engineering SwiftUI's
    /// internal line metrics into the text container's insets. Rows carrying a
    /// SwiftUI adornment — every list kind — are exactly equal, because the
    /// adornment sets the row height on both sides.
    ///
    /// What the band *does* catch is a per-kind divergence, and both historical
    /// offenders were re-measured by reverting the fix under it: a quote was
    /// **19.7pt** taller while reading, against a 5.95pt allowance, because its
    /// panel padding had no editing counterpart; and a **prose** `.unknown` was
    /// **14.7pt** taller while *editing*, tripping the `delta >= 0` side,
    /// because the editing side wrapped every `.unknown` in a code panel where
    /// the reading side panelled only the verbatim ones. (Verbatim `.unknown`
    /// blocks agreed on `main` — the panel was the one thing both surfaces gave
    /// them.)
    func testEveryBlockOccupiesTheSameHeightOnBothSurfaces() {
        // Each fixture carries the number of text lines it wraps to at the row
        // width, because the residual below is per *line*, not per block.
        let fixtures: [(block: EditorBlock, lines: CGFloat)] = [
            (EditorBlock(kind: .paragraph, text: "Some prose."), 1),
            (EditorBlock(kind: .heading(level: 1), text: "Title"), 1),
            (EditorBlock(kind: .heading(level: 2), text: "Section"), 1),
            (EditorBlock(kind: .heading(level: 3), text: "Subsection"), 1),
            (EditorBlock(kind: .bulletItem, text: "Bullet"), 1),
            (EditorBlock(kind: .numberedItem, text: "Numbered"), 1),
            (EditorBlock(kind: .checklistItem(checked: false), text: "Open"), 1),
            (EditorBlock(kind: .checklistItem(checked: true), text: "Done"), 1),
            (EditorBlock(kind: .quote, text: "Quoted"), 1),
            (EditorBlock(kind: .codeBlock(language: "swift"), text: "let x = 1"), 1),
            // Deliberately free of inline markdown: an `.unknown` block shows
            // its syntax while editing and hides it while reading (it is the one
            // kind `rendersInlineMarkdown` refuses, and that refusal is
            // pre-existing and untouched), so `**bold**` here would wrap
            // differently on the two surfaces and could make the editing row the
            // taller one — a character-width difference, not the chrome
            // difference `delta >= 0` is written to catch.
            (EditorBlock(kind: .unknown, text: "one\ntwo"), 2),
            (EditorBlock(kind: .unknown, text: "| a | b |"), 1),
        ]
        let viewModel = makeViewModel(blocks: fixtures.map(\.block))

        for (index, fixture) in fixtures.enumerated() {
            let block = fixture.block
            let reading = rowHeight(of: block)
            let editing = editingRowHeight(of: block, index: index, viewModel: viewModel)
            let delta = reading - editing
            let allowed =
                Self.leadingResidualRatio * blockTextAppearance(for: block.kind, text: block.text).spec.size
                * fixture.lines

            XCTAssertGreaterThanOrEqual(
                delta, 0,
                "\(block.kind) is TALLER while editing (reading \(reading)pt, editing \(editing)pt) — "
                    + "the editing surface has grown chrome the reading one lacks")
            XCTAssertLessThanOrEqual(
                delta, allowed,
                "\(block.kind) differs by \(delta)pt (reading \(reading)pt, editing \(editing)pt), "
                    + "more than the \(allowed)pt text-leading residual for \(fixture.lines) line(s)")
        }
    }

    /// Every kind whose row height is set by a SwiftUI adornment rather than by
    /// the text view agrees *exactly*, so the band above is not hiding a
    /// difference in the rows users see most.
    func testListRowsAgreeExactly() {
        let listBlocks = [
            EditorBlock(kind: .bulletItem, text: "Bullet"),
            EditorBlock(kind: .numberedItem, text: "Numbered"),
            EditorBlock(kind: .checklistItem(checked: false), text: "Open"),
            EditorBlock(kind: .checklistItem(checked: true), text: "Done"),
        ]
        let viewModel = makeViewModel(blocks: listBlocks)
        for (index, block) in listBlocks.enumerated() {
            XCTAssertEqual(
                rowHeight(of: block), editingRowHeight(of: block, index: index, viewModel: viewModel),
                accuracy: 0.5, "\(block.kind)")
        }
    }

    /// The negative control for both of the above: the instrument does
    /// discriminate between rows, on both surfaces, so "they always match" is
    /// not the trivial consequence of every row measuring the same.
    func testTheRowInstrumentDiscriminates() {
        let paragraph = EditorBlock(kind: .paragraph, text: "Some prose.")
        let heading = EditorBlock(kind: .heading(level: 1), text: "Some prose.")
        let quote = EditorBlock(kind: .quote, text: "Some prose.")
        let viewModel = makeViewModel(blocks: [paragraph, heading, quote])

        XCTAssertGreaterThan(rowHeight(of: heading), rowHeight(of: paragraph))
        XCTAssertGreaterThan(rowHeight(of: quote), rowHeight(of: paragraph))
        XCTAssertGreaterThan(
            editingRowHeight(of: heading, index: 0, viewModel: viewModel),
            editingRowHeight(of: paragraph, index: 0, viewModel: viewModel))
        XCTAssertGreaterThan(
            editingRowHeight(of: quote, index: 0, viewModel: viewModel),
            editingRowHeight(of: paragraph, index: 0, viewModel: viewModel))
    }

    /// The accepted text-leading residual, as a fraction of the block's own font
    /// size, per wrapped line.
    ///
    /// Expressed that way because that is how the artefact behaves: SwiftUI adds
    /// its extra leading once per line and in proportion to the type. Measured at
    /// the Large content size it is ~0.22 of the point size (3.67pt at body 17,
    /// 7.33pt at title1 28, 4.67pt per line for a two-line block); 0.35 is that
    /// with headroom, and still far below the divergences it exists to catch —
    /// a quote's missing panel padding was ~20pt on a single 17pt line, where
    /// this allows 5.95.
    private static let leadingResidualRatio: CGFloat = 0.35

    /// The width a row is actually offered: the screen less the body gutter.
    private var rowProposal: CGSize {
        CGSize(width: 402 - 2 * EditorBlockMetrics.gutter, height: 4000)
    }

    private func rowHeight(of block: EditorBlock) -> CGFloat {
        let host = UIHostingController(
            rootView: MarkdownBlockView(block: block, serverOrigin: "https://docs.example.org", numberedIndex: 1)
                .environment(english())
                .environment(AttachmentLoader.inert()))
        return host.sizeThatFits(in: rowProposal).height
    }

    private func editingRowHeight(of block: EditorBlock, index: Int, viewModel: EditorViewModel) -> CGFloat {
        let host = UIHostingController(
            rootView: BlockEditorRow(
                viewModel: viewModel, block: block, index: index, serverOrigin: "https://docs.example.org",
                isOffline: false
            )
            .environment(english())
            .environment(AttachmentLoader.inert()))
        return host.sizeThatFits(in: rowProposal).height
    }

    /// Isolated down to **every** store, and the file-backed ones into a
    /// throwaway directory.
    ///
    /// Not belt-and-braces: a coordinator holding any default store can find a
    /// replayable record another suite left on the simulator and block on a real
    /// `/users/me/` until it times out, which reads as the whole suite hanging
    /// rather than as a failure. Injecting only three of them leaves four
    /// pointing at `.standard`, so the doc comment has to be true, not
    /// aspirational — and `EditorViewModel` carries three of its own
    /// (`signedInUser`, `contentCache`, `childrenCache`) that the coordinator's
    /// parameters do not cover.
    ///
    /// `blocks` is not decoration: `BlockEditorRow` resolves a numbered item's
    /// position against the view model's own array, so hosting a row at index
    /// *n* over an empty one traps.
    private func makeViewModel(blocks: [EditorBlock]) -> EditorViewModel {
        let suite = "EditorSurfaceParityTests.viewModel"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorSurfaceParityTests-\(UUID().uuidString)", isDirectory: true)
        let contentCache = DocumentContentCacheStore(directory: directory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: store)
        let client = DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: PendingDraftStore(userDefaults: store),
            contentCache: contentCache,
            createStore: PendingDocumentCreateStore(userDefaults: store),
            deleteStore: PendingDocumentDeleteStore(userDefaults: store),
            attachmentStore: PendingAttachmentStore(userDefaults: store, directory: directory),
            listCache: DocumentCacheStore(userDefaults: store),
            childrenCache: childrenCache,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client, documentID: UUID(), title: "Parity", saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: store),
            contentCache: contentCache, childrenCache: childrenCache)
        viewModel.blocks = blocks
        return viewModel
    }

    // MARK: - Helper

    private func height(of block: EditorBlock) -> CGFloat {
        let host = UIHostingController(
            rootView: MarkdownBlockView(block: block, serverOrigin: "https://docs.example.org")
                .environment(english())
                .environment(AttachmentLoader.inert()))
        return host.sizeThatFits(in: proposal).height
    }
}
