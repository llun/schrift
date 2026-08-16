import SwiftUI

enum PagesTreeLayout {
    /// Panel width from the handoff. Capped against the screen on a narrow
    /// device so the drawer can never cover everything behind it — the scrim
    /// has to stay tappable.
    static let panelWidth: CGFloat = 306
    static let maxWidthFraction: CGFloat = 0.85
    /// Indent per level, from the handoff.
    static let indentPerLevel: CGFloat = 18
    /// The disclosure column. A tap target, not a glyph size — the chevron stays
    /// small. Leaves reserve the same width so titles line up down the level.
    static let disclosureWidth: CGFloat = DocsSpacing.rowMinHeight

    static func width(availableWidth: CGFloat) -> CGFloat {
        min(panelWidth, availableWidth * maxWidthFraction)
    }
}

/// The editor's document tree — the handoff's `DocTreePanel`, as a leading
/// slide-in drawer over a scrim.
///
/// It shows the open document as the root, then its subpages, expandable to any
/// depth. Levels load lazily and cache-first, so a document you have already
/// opened has its level available offline.
struct PagesTreeDrawer: View {
    @Bindable var viewModel: PagesTreeViewModel
    let rootTitle: String
    var onOpen: (Document) -> Void
    var onClose: () -> Void
    /// A row's Delete swipe action was tapped. The *editor* owns the confirmation alert, not
    /// the drawer: an alert presented from inside a view that is itself a transitioning
    /// overlay is fragile, and the editor already hosts the sibling undo alert.
    var onRequestDelete: (Document) -> Void = { _ in }
    /// A row's Move swipe action was tapped. The editor owns the picker sheet for the same
    /// reason it owns the delete alert: presenting one from inside a transitioning overlay is
    /// fragile, and the drawer would take the sheet down with itself as it closes.
    var onRequestMove: (Document) -> Void = { _ in }
    /// A struck-through row's "Keep this document".
    var onUndoPendingDelete: (Document) -> Void = { _ in }

    @Environment(LocalizationStore.self) private var loc

    /// Which row's swipe strip is open. Drawer-local: it floats over the editor's own list,
    /// and one shared value would let either close the other's strip.
    @State private var swipe = SwipeRevealState<UUID>()

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                panel(width: PagesTreeLayout.width(availableWidth: proxy.size.width))

                // The scrim: tapping anywhere outside the panel closes it, which
                // is the gesture people reach for before the close button.
                // `.contentShape` is what makes a clear view tappable.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                    .accessibilityElement()
                    .accessibilityLabel(loc[.pages_close])
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onClose() }
            }
        }
        .background(DocsColor.surfaceScrim.ignoresSafeArea())
        .transition(.opacity)
    }

    private func panel(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DocsColor.borderDefault)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    rootRow
                    ForEach(viewModel.rows) { row in
                        treeRow(row)
                    }
                    if let errorKey = viewModel.errorKey {
                        Text(loc[errorKey])
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.danger)
                            .padding(.horizontal, DocsSpacing.spaceSM)
                            .padding(.top, DocsSpacing.spaceXS)
                    } else if viewModel.rows.isEmpty && !viewModel.loading.contains(viewModel.rootID) {
                        Text(loc[.pages_empty])
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DocsSpacing.spaceSM)
                            .padding(.top, DocsSpacing.spaceXS)
                    }
                }
                .padding(.horizontal, DocsSpacing.spaceXS)
                .padding(.vertical, DocsSpacing.spaceXS)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { swipe = swipeRevealAfterScrollInteraction(swipe) }
            }

            newPageButton
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(DocsColor.surfacePage)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DocsColor.borderDefault).frame(width: 0.5)
        }
        .transition(.move(edge: .leading))
    }

    private var header: some View {
        HStack {
            Text(loc[.pages_title])
                .font(DocsFont.headline)
                .foregroundStyle(DocsColor.textPrimary)
            Spacer()
            IconButton(icon: .left_panel_close, label: loc[.pages_close], action: onClose)
        }
        .padding(.leading, DocsSpacing.spaceBase)
        .padding(.trailing, DocsSpacing.space2xs)
        .padding(.vertical, DocsSpacing.space2xs)
    }

    /// The open document, pinned above its subpages and always selected — it is
    /// the document behind the drawer.
    private var rootRow: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            DocIcon(size: 18)
            Text(rootTitle)
                .font(DocsFont.subhead.weight(.semibold))
                .foregroundStyle(DocsColor.textBrand)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceXS)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .background(DocsColor.brandFillSubtle, in: RoundedRectangle(cornerRadius: DocsRadius.md))
        .padding(.bottom, DocsSpacing.space3xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSelected)
    }

    private func treeRow(_ row: PagesTreeRow) -> some View {
        let label =
            isDeletePending(row)
            ? "\(title(of: row.document)), \(loc[.docrow_pending_delete])"
            : title(of: row.document)

        return HStack(spacing: DocsSpacing.space3xs) {
            // **Outside the swipe wrapper**, deliberately: the chevron is its own control, and
            // wrapping it would let a swipe that began on it fight the disclosure tap.
            disclosure(row)

            // **A tap gesture, not a `Button`** — the same conversion `SubpageRow` took, and
            // for the same reason: this row is wrapped in `SwipeRevealRow`, and a `Button`'s
            // gesture starts on touch-down and can still fire on touch-up after a horizontal
            // swipe, so swiping a page would open it. Only the *title* converts — the
            // disclosure chevron beside it stays a `Button` and stays outside the swipe
            // wrapper, so expanding a branch is never swallowed by the gesture.
            SwipeRevealRow(
                id: row.document.id,
                state: $swipe,
                // Delete only: a drawer row renders no pinned state, so a Pin action would
                // succeed with nothing here to show for it.
                actions: documentRowSwipeActions(
                    isPendingDelete: isDeletePending(row),
                    isLocalDocument: false,
                    isFavorite: row.document.isFavorite,
                    offersPin: false,
                    keepLabel: loc[.pending_delete_undo],
                    pinLabel: loc[.options_pin],
                    unpinLabel: loc[.options_unpin],
                    moveLabel: loc[.options_move],
                    deleteLabel: loc[.options_delete],
                    onKeep: { onUndoPendingDelete(row.document) },
                    onTogglePin: {},
                    onMove: { onRequestMove(row.document) },
                    onDelete: { onRequestDelete(row.document) }),
                accessibilityLabel: label,
                onActivate: { onOpen(row.document) }
            ) {
                HStack(spacing: DocsSpacing.spaceXS) {
                    DocIcon(size: 16)
                    Text(title(of: row.document))
                        .font(DocsFont.subhead)
                        // Read **here**, in the body, not only in the tap handler: a predicate
                        // called from `onOpen` registers no `@Observable` dependency, so the
                        // row would keep drawing as an ordinary page while tapping it popped
                        // an undo alert about a deletion nothing on screen had announced.
                        .foregroundStyle(
                            isDeletePending(row) ? DocsColor.textTertiary : DocsColor.textPrimary
                        )
                        .strikethrough(isDeletePending(row))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isDeletePending(row) {
                        MaterialSymbol(.delete, size: 14)
                            .foregroundStyle(DocsColor.gray350)
                    }
                }
                // Fill the row's height before taking the tap shape: a label is
                // only as tall as its text, so without this the row *looks* 44pt
                // but only its middle strip opens the page.
                //
                // Safe here, unlike the editor's save-status row, which had to
                // swap the same modifier for a `minHeight:` floor: an unbounded
                // max fills whatever it is *proposed*, and these rows sit in a
                // `ScrollView`, which proposes an unspecified height along its
                // scroll axis — so the row resolves to its ideal 44pt instead of
                // claiming the drawer. Don't "fix" this to match that one; do
                // reach for the floor in any stack that hands down a concrete
                // height. See CLAUDE.md's tap-target rule.
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(row.document) }
            }
            // The label and the `.isButton` trait now live on `SwipeRevealRow`, which
            // collapses this subtree with `children: .ignore` — still on the **title**, not
            // the row, so the disclosure chevron beside it keeps its own element and its own
            // label rather than being renamed or swallowed.
        }
        .padding(.leading, CGFloat(row.depth) * PagesTreeLayout.indentPerLevel)
        .padding(.horizontal, DocsSpacing.space3xs)
        .frame(minHeight: DocsSpacing.rowMinHeight)
    }

    /// Whether this row's document is waiting to be deleted. Wraps the view model so the
    /// three places the row consults it cannot drift apart.
    private func isDeletePending(_ row: PagesTreeRow) -> Bool {
        viewModel.isDeletePending(row.document)
    }

    /// The arrow is its own control: tapping it expands, tapping the title opens
    /// the page. Collapsing a branch shouldn't navigate away from what you are
    /// reading.
    @ViewBuilder
    private func disclosure(_ row: PagesTreeRow) -> some View {
        if row.hasChildren {
            Button {
                Task { await viewModel.toggle(row.document) }
            } label: {
                Group {
                    if viewModel.loading.contains(row.document.id) && !row.isExpanded {
                        ProgressView().controlSize(.mini)
                    } else {
                        MaterialSymbol(.chevron_right, size: 18)
                            .foregroundStyle(DocsColor.textTertiary)
                            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    }
                }
                // The glyph keeps its small visual box; the tap target around it
                // is the full 44pt, per `IconButton` — a chevron this size is
                // otherwise a quarter of the area iOS asks for.
                .frame(width: 22, height: 22)
                .frame(width: PagesTreeLayout.disclosureWidth, height: DocsSpacing.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc[row.isExpanded ? .pages_collapse : .pages_expand])
        } else {
            // Keeps titles on one vertical line whether or not a node has
            // children.
            Color.clear.frame(width: PagesTreeLayout.disclosureWidth, height: 22)
        }
    }

    private var newPageButton: some View {
        // Ungated. Neither being offline nor the root being unsynced stops this: `addPage`
        // mints locally in both cases, and the replay POSTs a parent before the page that
        // names it.
        VStack(spacing: 0) {
            Divider().overlay(DocsColor.borderDefault)
            Button {
                Task {
                    if let created = await viewModel.addPage(under: viewModel.rootID) {
                        onOpen(created)
                    }
                }
            } label: {
                HStack(spacing: DocsSpacing.spaceXS) {
                    MaterialSymbol(.add, size: 20)
                    Text(loc[.pages_new])
                        .font(DocsFont.subhead.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DocsColor.textBrand)
                .padding(.horizontal, DocsSpacing.spaceSM)
                .padding(.vertical, DocsSpacing.spaceSM)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func title(of document: Document) -> String {
        let trimmed = document.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? loc[.common_untitled] : trimmed
    }
}

// MARK: - Preview

/// Seeds the children cache and turns "work offline" on, so the catalog renders
/// a real tree through the real code path without a network or a stub client.
@MainActor
private func previewViewModel(variant: String) -> PagesTreeViewModel {
    let suiteName = "PagesTreeDrawerPreview.\(variant)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "schrift.workOffline")

    func document(_ title: String, numchild: Int = 0) -> Document {
        Document(
            id: UUID(), title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: numchild, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    let rootID = UUID()
    let guide = document("Onboarding guide", numchild: 2)
    let cache = DocumentChildrenCacheStore(userDefaults: defaults)
    cache.save([guide, document("Release notes"), document("")], for: rootID)
    cache.save([document("Week one"), document("Week two", numchild: 1)], for: guide.id)

    let viewModel = PagesTreeViewModel(
        rootID: rootID,
        client: DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!),
        cache: cache,
        userDefaults: defaults)
    return viewModel
}

#Preview("Pages tree") {
    let viewModel = previewViewModel(variant: "expanded")
    PagesTreeDrawer(viewModel: viewModel, rootTitle: "Team handbook", onOpen: { _ in }, onClose: {})
        .task {
            await viewModel.loadRoot()
            if let first = viewModel.rows.first(where: \.hasChildren) {
                await viewModel.toggle(first.document)
            }
        }
        .environment(LocalizationStore())
}

#Preview("Pages tree — dark, offline") {
    let viewModel = previewViewModel(variant: "offline")
    PagesTreeDrawer(
        viewModel: viewModel, rootTitle: "Team handbook", onOpen: { _ in }, onClose: {}
    )
    .task { await viewModel.loadRoot() }
    .environment(LocalizationStore())
    .preferredColorScheme(.dark)
}
