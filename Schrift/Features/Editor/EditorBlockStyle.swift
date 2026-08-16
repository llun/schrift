import SwiftUI
import UIKit

/// How a document block is drawn — the **one** table the editor's two surfaces
/// both read.
///
/// The editor renders the same `[EditorBlock]` twice: as SwiftUI `Text` on the
/// reading surface (`MarkdownBlockView`) and as a UIKit `UITextView` on the
/// editing surface (`BlockTextView`). Those are different frameworks with
/// different font and layout APIs, so for a long time each carried its own copy
/// of "a quote is italic secondary text behind a sunken panel" — and the copies
/// drifted: the gutter, the inter-block gap, the quote chrome, the checkbox
/// size, the strikethrough on a completed to-do and the title's tracking all
/// disagreed. Tapping a block to edit it therefore re-laid-out the whole
/// document, which reads as *navigating somewhere* rather than as placing a
/// caret.
///
/// The fix is structural rather than a round of matched constants: every value
/// that decides how a block looks lives here once, and each surface converts it
/// into its own framework's types at the very end (`font`/`color` for SwiftUI,
/// `uiFont(dynamicTypeSize:)`/`uiColor` for UIKit). A new block kind, or a
/// changed one, cannot make the two disagree without changing this file — and
/// `EditorSurfaceParityTests` asserts the conversions land on the same values.
///
/// Concurrency: pure value code with no annotations, per the project's rule for
/// style resolvers — callable from any isolation domain.

// MARK: - Metrics

/// The measurements the document body is laid out with, shared by both surfaces.
///
/// These are *not* free constants: each was a place the two surfaces disagreed.
/// Keep them here rather than inlining a token at a call site, so a future edit
/// moves both surfaces together.
enum EditorBlockMetrics {
    /// The document body's horizontal page inset.
    ///
    /// `DocsSpacing.gutter`, matching every other screen in the app *and* the
    /// editor's own chrome (the error banner, the formatting bar, the pending
    /// delete notice). The reading surface used to inset its body by
    /// `spaceMD - space4xs` (22pt) — 6pt more than its own error banner, and
    /// 6pt more than the editing canvas, so every line of text re-wrapped and
    /// slid left the instant edit mode opened.
    static let gutter = DocsSpacing.gutter

    /// The vertical gap between two blocks. Reading used 12, editing 6, so a
    /// ten-block document pulled ~54pt upward on the swap.
    static let blockSpacing = DocsSpacing.spaceSM

    /// The gap between a list adornment (bullet, number, checkbox) and its text.
    static let adornmentSpacing = DocsSpacing.spaceXS

    /// The checklist checkbox glyph. One size for both surfaces, and larger than
    /// either used to be (reading 20pt, editing 17pt) — it is the document's one
    /// touchable adornment. It still scales with Dynamic Type, because
    /// `MaterialSymbol` scales by default.
    static let checkboxSize: CGFloat = 24

    /// Padding that grows the *editing* checkbox's hit rect past
    /// `DocsSpacing.rowMinHeight`, and is then given back to the layout with
    /// matching negative padding so the glyph does not move.
    ///
    /// **Not** `(rowMinHeight - checkboxSize) / 2`. That arithmetic looks right
    /// and lands at 43pt: a `MaterialSymbol` is a `Text`, so what it occupies is
    /// its glyph's typographic box (23pt for a 24pt symbol), not its point size.
    /// The derived value was also untestable — substituting the definition into
    /// `checkboxSize + 2 * padding == rowMinHeight` gives an identity that holds
    /// for any pair of values. A token with headroom is both correct and
    /// checkable; `EditorSurfaceParityTests` measures the padded box.
    static let checkboxHitPadding = DocsSpacing.spaceSM

    /// The quote's leading accent bar.
    static let quoteBarWidth: CGFloat = 4

    /// Inner padding for the two decorated blocks (quote, verbatim panel).
    static let decorationPadding = DocsSpacing.spaceSM

    /// A quote's text is padded less vertically than a code panel's — it is
    /// prose in an aside, not a block of source.
    static let quoteVerticalPadding = DocsSpacing.spaceXS

    static let decorationRadius = DocsRadius.md

    /// A divider's breathing room above and below.
    static let dividerVerticalPadding = DocsSpacing.spaceXS

    /// Title → metadata row, inside the document header.
    static let titleToMetadataSpacing = DocsSpacing.spaceXS

    /// Document header → first block.
    static let headerToBodySpacing = DocsSpacing.spaceMD
}

// MARK: - Decoration

/// The chrome a block draws *around* its text.
///
/// Applied through one `ViewModifier` (`editorBlockDecoration(_:)`) so the
/// reading `Text` and the editing `UITextView` cannot be decorated differently.
enum EditorBlockDecoration: Equatable {
    case none
    /// A brand-coloured leading bar over a sunken panel.
    case quote
    /// A sunken panel for text that is shown verbatim (code, and `.unknown`
    /// markdown that is not plain prose).
    case verbatimPanel
}

/// True when a block's text is shown **verbatim in a panel** rather than as
/// prose.
///
/// `.unknown` is the only kind whose answer depends on its *text*: a paragraph
/// that merely spilled across lines is prose (`unknownRendersAsProse`), while a
/// table or an HTML fragment is not. That is why every function here takes the
/// text as well as the kind — the reading surface has always made this
/// distinction, and the editing surface used to ignore it and put *every*
/// `.unknown` block in a monospaced panel.
func blockRendersVerbatim(_ kind: BlockKind, text: String) -> Bool {
    switch kind {
    case .codeBlock:
        return true
    case .unknown:
        return !unknownRendersAsProse(text)
    case .heading, .paragraph, .bulletItem, .numberedItem, .checklistItem, .quote, .divider, .image, .attachment:
        return false
    }
}

func blockDecoration(for kind: BlockKind, text: String) -> EditorBlockDecoration {
    if case .quote = kind { return .quote }
    return blockRendersVerbatim(kind, text: text) ? .verbatimPanel : .none
}

// MARK: - Text appearance

/// The typography and colour a block's text is drawn with, as raw tokens.
///
/// Raw `TypographySpec`/hex rather than `Font`/`Color`/`UIFont`: this stays a
/// pure `Equatable` value the parity tests can compare directly, and each
/// surface converts it at render time — the same split the design-system style
/// resolvers use.
struct BlockTextAppearance: Equatable {
    let spec: TypographySpec
    let design: Font.Design?
    let isItalic: Bool
    /// A completed to-do. Drawn on **both** surfaces: the strikethrough used to
    /// exist only while reading, so tapping into a checklist un-struck every
    /// finished item at once.
    let isStruckThrough: Bool
    let colorLightHex: UInt32
    let colorDarkHex: UInt32
}

func blockTextAppearance(for kind: BlockKind, text: String) -> BlockTextAppearance {
    switch kind {
    case .heading(let level):
        return BlockTextAppearance(
            spec: headingSpec(level: level), design: nil, isItalic: false, isStruckThrough: false,
            colorLightHex: DocsColorHex.textPrimary, colorDarkHex: DocsColorHexDark.textPrimary)

    case .quote:
        return BlockTextAppearance(
            spec: DocsTypographySpec.body, design: nil, isItalic: true, isStruckThrough: false,
            colorLightHex: DocsColorHex.textSecondary, colorDarkHex: DocsColorHexDark.textSecondary)

    case .checklistItem(let checked):
        return BlockTextAppearance(
            spec: DocsTypographySpec.body, design: nil, isItalic: false, isStruckThrough: checked,
            colorLightHex: DocsColorHex.textPrimary, colorDarkHex: DocsColorHexDark.textPrimary)

    case .codeBlock, .unknown:
        // The `.unknown` branch is why this takes the text: a prose `.unknown`
        // is body text on both surfaces, only a verbatim one is monospaced.
        let monospaced = blockRendersVerbatim(kind, text: text)
        return BlockTextAppearance(
            spec: monospaced ? DocsTypographySpec.code : DocsTypographySpec.body,
            design: monospaced ? .monospaced : nil, isItalic: false, isStruckThrough: false,
            colorLightHex: DocsColorHex.textPrimary, colorDarkHex: DocsColorHexDark.textPrimary)

    case .paragraph, .bulletItem, .numberedItem, .divider, .image, .attachment:
        // `.divider`/`.image`/`.attachment` are leaves that host no text at all;
        // grouped here only to keep the switch exhaustive with a sane default.
        return BlockTextAppearance(
            spec: DocsTypographySpec.body, design: nil, isItalic: false, isStruckThrough: false,
            colorLightHex: DocsColorHex.textPrimary, colorDarkHex: DocsColorHexDark.textPrimary)
    }
}

private func headingSpec(level: Int) -> TypographySpec {
    switch level {
    case 1: return DocsTypographySpec.title1
    case 2: return DocsTypographySpec.title2
    default: return DocsTypographySpec.headline
    }
}

extension BlockTextAppearance {
    /// The SwiftUI font the reading surface draws with.
    var font: Font {
        let base = Font.system(spec.textStyle, design: design, weight: spec.weight)
        return isItalic ? base.italic() : base
    }

    var color: Color {
        Color(lightHex: colorLightHex, darkHex: colorDarkHex)
    }

    /// The UIKit font the editing surface draws with.
    ///
    /// Built at the token's reference size and then scaled through
    /// `UIFontMetrics`, so the editor tracks Dynamic Type like the SwiftUI
    /// labels around it. Scaling changes only the rendered size — never the
    /// buffer — so every `NSRange` in the editor stays the source offset it
    /// always was.
    func uiFont(dynamicTypeSize: DynamicTypeSize) -> UIFont {
        let weight = uiFontWeight(spec.weight)
        let base: UIFont
        if design == .monospaced {
            base = .monospacedSystemFont(ofSize: spec.size, weight: weight)
        } else if isItalic {
            base = .italicSystemFont(ofSize: spec.size)
        } else {
            base = .systemFont(ofSize: spec.size, weight: weight)
        }
        return scaledUIFont(base, for: spec, dynamicTypeSize: dynamicTypeSize)
    }

    var uiColor: UIColor { UIColor(color) }
}

/// The UIKit twin of the weights the typography table actually uses.
///
/// Deliberately not exhaustive over `Font.Weight` (which is not enumerable):
/// anything outside the table falls back to `.regular`, which is what a token
/// with no weight would draw as anyway.
func uiFontWeight(_ weight: Font.Weight) -> UIFont.Weight {
    switch weight {
    case .bold: return .bold
    case .semibold: return .semibold
    case .medium: return .medium
    default: return .regular
    }
}

// MARK: - Decoration modifier

extension View {
    /// Draws a block's panel/quote chrome around its text.
    ///
    /// One modifier for both surfaces: the reading `Text` and the editing
    /// `BlockTextView` are decorated by the same code, so they cannot drift.
    func editorBlockDecoration(_ decoration: EditorBlockDecoration) -> some View {
        modifier(EditorBlockDecorationModifier(decoration: decoration))
    }
}

/// The chrome is expressed as **value-varying modifiers on one structural
/// shape**, never as a branch that swaps the decorated view.
///
/// That is load-bearing on the editing surface: converting the focused block's
/// kind (a "> " shortcut, a slash command, a toolbar tap) must not recreate the
/// `UITextView`, or the keyboard drops mid-conversion. Only the *overlay's*
/// content is conditional, and the text view is a sibling of it — its identity
/// in the modifier chain is unchanged.
private struct EditorBlockDecorationModifier: ViewModifier {
    let decoration: EditorBlockDecoration

    func body(content: Content) -> some View {
        content
            .padding(.vertical, verticalPadding)
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            // The bar is overlaid *before* the clip, so the panel's rounded
            // corners cut it exactly as they did when the reading surface drew
            // the bar as a sibling inside its clipped `HStack`. Clipping first
            // and overlaying after leaves a square-cornered bar sitting proud of
            // a rounded panel.
            .overlay(alignment: .leading) {
                if decoration == .quote {
                    RoundedRectangle(cornerRadius: DocsRadius.xs)
                        .fill(DocsColor.brandFill)
                        .frame(width: EditorBlockMetrics.quoteBarWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var verticalPadding: CGFloat {
        switch decoration {
        case .none: return 0
        case .quote: return EditorBlockMetrics.quoteVerticalPadding
        case .verbatimPanel: return EditorBlockMetrics.decorationPadding
        }
    }

    /// A quote's text clears its own accent bar; a panel's does not have one.
    private var leadingPadding: CGFloat {
        switch decoration {
        case .none: return 0
        case .quote: return EditorBlockMetrics.quoteBarWidth + EditorBlockMetrics.decorationPadding
        case .verbatimPanel: return EditorBlockMetrics.decorationPadding
        }
    }

    private var trailingPadding: CGFloat {
        decoration == .none ? 0 : EditorBlockMetrics.decorationPadding
    }

    private var background: Color {
        decoration == .none ? .clear : DocsColor.surfaceSunken
    }

    private var cornerRadius: CGFloat {
        decoration == .none ? 0 : EditorBlockMetrics.decorationRadius
    }
}

// MARK: - Adornment

/// A list block's leading adornment — bullet, number, or checkbox.
///
/// Shared by both surfaces so the text column starts at the same x on each. The
/// checkbox is a real control only where `onToggle` is supplied (the editing
/// surface); while reading, the whole row's tap enters the editor, so the glyph
/// is drawn plain and the *state* is spoken instead of implied by a hidden
/// glyph.
struct EditorBlockAdornment: View {
    let kind: BlockKind
    let numberedIndex: Int
    /// Non-nil makes the checkbox a button. The bullet and the number are never
    /// interactive on either surface.
    var onToggleChecklist: (() -> Void)?

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        switch kind {
        case .bulletItem:
            Text("•")
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)

        case .numberedItem:
            Text("\(numberedIndex).")
                .font(DocsFont.body)
                .monospacedDigit()
                .foregroundStyle(DocsColor.textPrimary)

        case .checklistItem(let checked):
            if let onToggleChecklist {
                Button(action: onToggleChecklist) { checkbox(checked: checked) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        checked ? loc[.editor_checklist_not_done_a11y] : loc[.editor_checklist_done_a11y])
            } else {
                checkbox(checked: checked)
            }

        default:
            EmptyView()
        }
    }

    /// Grow the hit rect, then give the growth back to the layout.
    ///
    /// A plain `.frame(44)` would work for the target, but this is the adornment
    /// of a `.top`-aligned row, so the taller box would centre the glyph below
    /// the first line of the text it is meant to sit beside. The pair leaves the
    /// glyph exactly where it is and takes the target to `rowMinHeight` — and,
    /// because the two paddings cancel, the plain reading glyph occupies exactly
    /// the same space as the editing button.
    private func checkbox(checked: Bool) -> some View {
        MaterialSymbol(checked ? .check_box : .check_box_outline_blank, size: EditorBlockMetrics.checkboxSize)
            .foregroundStyle(checked ? DocsColor.brandFill : DocsColor.textTertiary)
            .padding(EditorBlockMetrics.checkboxHitPadding)
            .contentShape(Rectangle())
            .padding(-EditorBlockMetrics.checkboxHitPadding)
    }
}

/// True when the kind draws a leading adornment, i.e. when the row needs the
/// `adornmentSpacing` gap at all.
func blockHasAdornment(_ kind: BlockKind) -> Bool {
    switch kind {
    case .bulletItem, .numberedItem, .checklistItem:
        return true
    case .heading, .paragraph, .quote, .codeBlock, .divider, .image, .attachment, .unknown:
        return false
    }
}
