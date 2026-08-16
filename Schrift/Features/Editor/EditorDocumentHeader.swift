import SwiftUI

/// A position in the document body that both editor surfaces can name.
///
/// The reading and editing canvases are two different `ScrollView`s, so the
/// swap between them used to throw the scroll offset away: tapping a paragraph
/// three screens down opened the editor at the very top, with the block the
/// user touched nowhere on screen. Naming the same rows in both layouts lets
/// `.scrollPosition(id:anchor:)` carry the anchor across (see
/// `EditorScrollAnchorStore`).
///
/// An enum rather than a bare `UUID?`, so the header and the trailing tap
/// target are expressible without minting sentinel ids that could be mistaken
/// for a block's.
///
/// **Both canvases must name the same set of cases**, or the anchor stops
/// round-tripping: a surface handed an id it does not contain scrolls nowhere,
/// and the handoff silently degrades to "open at the top" — precisely on the
/// long documents where that is the thing the user notices. So `.trailer` is the
/// editing canvas's tap-to-append space *and* the reading canvas's Subpages
/// section: the space after the last block, whatever each surface puts there.
enum EditorScrollTarget: Hashable {
    case header
    case block(UUID)
    /// The space after the last block: the editing canvas's tap-to-append area,
    /// the reading canvas's Subpages section.
    case trailer
}

/// Holds the document body's scroll anchor across the reading ↔ editing swap.
///
/// **Deliberately not `@Observable`, and this is the point.** `.scrollPosition`
/// writes its binding as the user scrolls; routing that through `@State` would
/// invalidate `EditorView` on every change, and the reading surface rebuilds
/// every `MarkdownBlockView` — each of which runs `AttributedString(markdown:)`
/// and an `NSDataDetector` pass — so a scroll would re-parse the whole document
/// repeatedly. A plain reference type stores the anchor without invalidating
/// anything; the value is only ever *read* at the moment a surface appears,
/// which is exactly when it is needed.
@MainActor final class EditorScrollAnchorStore {
    var target: EditorScrollTarget? = .header
}

/// The document's title and its metadata row — one view, drawn by **both**
/// editor surfaces.
///
/// Reading and editing used to have entirely different headers: a `Text` title
/// with tight tracking over a reach/sync/presence row, versus a bare `TextField`
/// with no tracking and no row at all, plus a save-status strip pinned *above*
/// the canvas. The first block therefore moved ~38pt up on tap, and moved back
/// down ~52pt again on the first keystroke when that strip materialised. Sharing
/// the header makes both of those unrepresentable.
///
/// The `status` slot is what each surface still gets to choose: the reading
/// surface puts its sync caption there, the editing surface its
/// `SaveStatusIndicator`. Both are floored to the same row height, so swapping
/// one for the other cannot move anything below.
struct EditorDocumentHeader<Status: View>: View {
    let title: String
    /// Non-nil draws the title as an editable field. Same font, tracking and
    /// colour either way — only the caret differs.
    let onEditTitle: ((String) -> Void)?
    let reach: LinkReach
    let peers: [CollaborationPeer]
    @ViewBuilder var status: () -> Status

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: EditorBlockMetrics.titleToMetadataSpacing) {
            titleView
                .font(DocsFont.title1)
                .docsTracking(DocsTypographySpec.title1, DocsTracking.tight)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DocsSpacing.spaceXS) {
                LinkReachPill(reach: reach)
                status()
                Spacer(minLength: DocsSpacing.spaceXS)
                PresenceBar(peers: peers, size: 22, max: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A floor, never a fixed height (which would clip at larger text
            // sizes). It equalises the two surfaces' status slots — a footnote
            // caption against a `SaveStatusIndicator` that floors itself at
            // `rowMinHeight` — so swapping one for the other moves nothing below.
            //
            // It does **not** give anything in the row a tap target: a `Button`
            // hit-tests the shape its label draws, so a row floored at 44pt
            // around a one-line `Text` is still a one-line target. Each
            // interactive thing in this slot floors its own label
            // (`SaveStatusIndicator` does; `syncCaptionLabel`'s retry does).
            .frame(minHeight: DocsSpacing.rowMinHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var titleView: some View {
        if let onEditTitle {
            // The placeholder doubles as the field's accessibility label, which
            // is why this needs none of its own.
            TextField(loc[.common_untitled], text: Binding(get: { title }, set: onEditTitle))
                .foregroundStyle(DocsColor.textPrimary)
        } else {
            // The same placeholder the field shows, rather than the empty string
            // the reading surface used to render: an untitled document otherwise
            // has a title line while editing and none while reading, so the body
            // moves by a whole title's height on the swap.
            Text(title.isEmpty ? loc[.common_untitled] : title)
                .foregroundStyle(title.isEmpty ? DocsColor.textTertiary : DocsColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
