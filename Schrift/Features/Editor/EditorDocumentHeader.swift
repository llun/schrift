import SwiftUI

/// A canvas target for caret visibility and filtered/full reading/editing handoff.
///
/// An enum rather than a bare `UUID?` so the header and the trailing tap target
/// are expressible without minting sentinel ids that could be mistaken for a
/// block's.
enum EditorScrollTarget: Hashable {
    case header
    /// Reading uses model block IDs; editing resolves them to native input row IDs.
    case block(UUID)
    /// The tap-to-append space below the last block.
    case trailer
}

/// Carries the document body's scroll offset across the reading ↔ editing swap.
///
/// The two surfaces are different `ScrollView`s, so the swap used to throw the
/// offset away: tapping a paragraph three screens down opened the editor at the
/// very top, with the block the user touched nowhere on screen.
///
/// **A raw content offset, not a `.scrollPosition(id:)` anchor** — that was the
/// first attempt and it does not work here. `scrollPosition(id:)` reports the id
/// of the item the scroll view is *aligned* to, and free-scrolling content
/// (no `.scrollTargetBehavior(.viewAligned)`, which would make the document
/// snap) is almost never aligned to one, so the binding stayed nil and the
/// handoff silently did nothing. Verified on a device: the editor still opened
/// at the top. An offset is the honest unit for a surface that scrolls freely,
/// and it is only meaningful *because* this change made the two layouts the same
/// — a shared offset in two differently-laid-out canvases would land somewhere
/// arbitrary.
/// Checklist chrome and filtering are that unequal-layout case: snapshot actual
/// visible row frames and restore a block ID, without relying on aligned scrolling.
///
/// **Deliberately not `@Observable`, and this is the point.** The offset changes
/// on every scroll frame; routing that through `@State` would invalidate
/// `EditorView` each time, and the reading surface rebuilds every
/// `MarkdownBlockView` — each running `AttributedString(markdown:)` and an
/// `NSDataDetector` pass — so scrolling would re-parse the whole document
/// continuously. A plain reference type stores it without invalidating anything;
/// the value is only ever *read* when a surface appears, which is when it is
/// needed.
@MainActor final class EditorScrollAnchorStore {
    /// Where the surface currently on screen is scrolled to, updated as it
    /// scrolls.
    private var liveOffsetY: CGFloat = 0

    /// The offset the *next* surface should open at, or `nil` for "wherever you
    /// naturally start".
    private var pendingOffsetY: CGFloat?
    private var blockFrames: [UUID: CGRect] = [:]
    private var pendingBlockID: UUID?

    func noteBlockFrames(_ frames: [UUID: CGRect]) {
        blockFrames = frames
    }

    func noteScrolled(to offsetY: CGFloat) {
        liveOffsetY = offsetY
    }

    /// Snapshots the live offset for the surface about to replace this one.
    ///
    /// Called at the moment of the swap rather than tracked continuously,
    /// because a `ScrollView` being torn down reports a **final geometry of
    /// zero** — which would overwrite the anchor with "the top" at exactly the
    /// moment it is needed, and did: the editor kept opening at the top of the
    /// document with the offset handoff apparently wired up correctly.
    func snapshotForSwap() {
        pendingBlockID = nil
        pendingOffsetY = liveOffsetY
    }

    /// Filtered and full canvases have different heights. Snapshot a measured
    /// visible block rather than applying an offset to unrelated content. If Done
    /// hides that block, prefer the next visible survivor, then the previous one.
    func snapshotForSwap(blockOrder: [UUID], restoringAmong visibleIDs: [UUID]) {
        pendingBlockID = nil
        pendingOffsetY = 0
        guard liveOffsetY > 0,
            let index = blockOrder.firstIndex(where: { blockFrames[$0].map { $0.maxY > 0 } == true })
        else { return }
        let visible = Set(visibleIDs)
        pendingBlockID =
            blockOrder[index...].first(where: { visible.contains($0) })
            ?? blockOrder[..<index].last(where: { visible.contains($0) })
        if pendingBlockID != nil { pendingOffsetY = nil }
    }

    func consumePendingBlock() -> UUID? {
        defer { pendingBlockID = nil }
        return pendingBlockID
    }

    /// Read once, by the surface appearing. Clearing it is what stops a later,
    /// unrelated appearance (popping back to a document, a tab switch) from
    /// re-applying a stale offset.
    func consumePendingOffset() -> CGFloat? {
        defer { pendingOffsetY = nil }
        return pendingOffsetY
    }
}

/// Actual row frames in the scroll viewport, independent of free-scroll alignment.
struct EditorBlockFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func recordingEditorBlockFrame(_ id: UUID) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: EditorBlockFramesKey.self,
                    value: [id: geometry.frame(in: .scrollView(axis: .vertical))])
            }
        }
    }
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
    @Environment(\.docsTheme) private var theme
    let title: String
    /// Non-nil draws the title as an editable field. Same font, tracking and
    /// colour either way — only the caret differs.
    let onEditTitle: ((String) -> Void)?
    let reach: LinkReach
    let peers: [CollaborationPeer]
    var onConsumeInitialTitleFocus: (() -> Bool)? = nil
    @ViewBuilder var status: () -> Status

    @Environment(LocalizationStore.self) private var loc
    @FocusState private var isTitleFocused: Bool
    @State private var titleSelection: TextSelection?

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
            TextField(
                loc[.common_untitled], text: Binding(get: { title }, set: onEditTitle),
                selection: $titleSelection, axis: .vertical
            )
            .foregroundStyle(theme.colors.textPrimary)
            .focused($isTitleFocused)
            .task {
                guard onConsumeInitialTitleFocus?() == true else { return }
                // Select the creation title without clearing it or marking a draft dirty.
                // The next keystroke replaces it; ordinary/manual edits retain their caret.
                titleSelection = TextSelection(range: title.startIndex..<title.endIndex)
                isTitleFocused = true
            }
        } else {
            // The same placeholder the field shows, rather than the empty string
            // the reading surface used to render: an untitled document otherwise
            // has a title line while editing and none while reading, so the body
            // moves by a whole title's height on the swap.
            Text(title.isEmpty ? loc[.common_untitled] : title)
                .foregroundStyle(title.isEmpty ? theme.colors.textTertiary : theme.colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
