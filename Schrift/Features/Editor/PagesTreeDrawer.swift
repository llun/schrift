import SwiftUI

enum PagesTreeLayout {
    /// Panel width from the handoff. Capped against the screen on a narrow
    /// device so the drawer can never cover everything behind it — the scrim
    /// has to stay tappable.
    static let panelWidth: CGFloat = 306
    static let maxWidthFraction: CGFloat = 0.85
    /// Indent per level, from the handoff.
    static let indentPerLevel: CGFloat = 18

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
    var isOffline: Bool = false
    var onOpen: (Document) -> Void
    var onClose: () -> Void

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                panel(width: PagesTreeLayout.width(availableWidth: proxy.size.width))

                // The scrim: tapping anywhere outside the panel closes it, which
                // is the gesture people reach for before the close button.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
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
        HStack(spacing: DocsSpacing.space3xs) {
            disclosure(row)

            Button {
                onOpen(row.document)
            } label: {
                HStack(spacing: DocsSpacing.spaceXS) {
                    DocIcon(size: 16)
                    Text(title(of: row.document))
                        .font(DocsFont.subhead)
                        .foregroundStyle(DocsColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(row.depth) * PagesTreeLayout.indentPerLevel)
        .padding(.horizontal, DocsSpacing.space3xs)
        .frame(minHeight: DocsSpacing.rowMinHeight)
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
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc[row.isExpanded ? .pages_collapse : .pages_expand])
        } else {
            // Keeps titles on one vertical line whether or not a node has
            // children.
            Color.clear.frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private var newPageButton: some View {
        if !isOffline {
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
