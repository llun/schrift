import SwiftUI

struct SearchScreen: View {
    @Bindable var viewModel: SearchViewModel
    let serverHost: String
    var onOpenDocument: (Document) -> Void

    private var trimmedQuery: String {
        viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Search", subtitle: serverHost, largeTitle: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SearchField(text: $viewModel.query, placeholder: "Search all documents")
                        .onSubmit {
                            viewModel.recordSearch()
                        }

                    if trimmedQuery.isEmpty {
                        emptyQueryContent
                    } else {
                        resultsContent
                    }
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.space3xs)
                .padding(.bottom, DocsSpacing.spaceBase)
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.loadQuickAccess()
        }
        .task(id: viewModel.query) {
            await viewModel.search()
        }
    }

    // MARK: - Empty query (recent + quick access)

    @ViewBuilder
    private var emptyQueryContent: some View {
        if !viewModel.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                sectionLabel("Recent searches", icon: "clock.arrow.circlepath")
                RecentSearchesFlow(terms: viewModel.recentSearches) { term in
                    viewModel.selectRecent(term)
                }
                .padding(.horizontal, DocsSpacing.spaceXS)
            }
        }

        VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
            sectionLabel("Quick access", icon: "pin.fill")
            if viewModel.quickAccess.isEmpty {
                Text("Pinned documents will appear here.")
                    .font(DocsFont.subhead)
                    .foregroundStyle(DocsColor.textTertiary)
            } else {
                documentList(viewModel.quickAccess)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.isSearching {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, DocsSpacing.spaceLG)
        } else if viewModel.results.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                sectionLabel(resultsCountLabel, icon: nil)
                documentList(viewModel.results)
            }
        }
    }

    private var resultsCountLabel: String {
        let count = viewModel.results.count
        return count == 1 ? "1 result" : "\(count) results"
    }

    private var emptyState: some View {
        VStack(spacing: DocsSpacing.space2xs) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(DocsColor.gray300)
            Text("No documents found")
                .font(DocsFont.headline)
                .foregroundStyle(DocsColor.textPrimary)
            Text("Nothing matches \u{201C}\(trimmedQuery)\u{201D}. Try another title or keyword.")
                .font(DocsFont.subhead)
                .foregroundStyle(DocsColor.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DocsSpacing.space2XL)
        .padding(.horizontal, DocsSpacing.spaceMD)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func documentList(_ documents: [Document]) -> some View {
        VStack(spacing: 0) {
            ForEach(documents) { document in
                DocRow(
                    title: document.title ?? "Untitled document",
                    pinned: document.isFavorite,
                    reach: document.linkReach,
                    date: documentRowDate(document),
                    onOpen: { onOpenDocument(document) }
                )
            }
        }
    }

    private func sectionLabel(_ text: String, icon: String?) -> some View {
        HStack(spacing: DocsSpacing.space3xs + 1) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15))
            }
            Text(text.uppercased())
                .font(DocsFont.footnote.weight(.semibold))
                .tracking(DocsTypographySpec.footnote.size * DocsTracking.eyebrow)
        }
        .foregroundStyle(DocsColor.textTertiary)
        .padding(.horizontal, DocsSpacing.spaceXS)
    }
}

// MARK: - Recent searches wrap-flow

private struct RecentSearchesFlow: View {
    let terms: [String]
    var onSelect: (String) -> Void

    var body: some View {
        FlowLayout(spacing: DocsSpacing.spaceXS) {
            ForEach(terms, id: \.self) { term in
                Button {
                    onSelect(term)
                } label: {
                    HStack(spacing: DocsSpacing.space2xs) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 16))
                            .foregroundStyle(DocsColor.textTertiary)
                        Text(term)
                            .font(DocsFont.subhead)
                            .foregroundStyle(DocsColor.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .padding(.vertical, 7)
                    .background(DocsColor.surfaceSunken)
                    .overlay(
                        RoundedRectangle(cornerRadius: DocsRadius.pill)
                            .stroke(DocsColor.borderDefault, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DocsRadius.pill))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Simple wrap-flow layout

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    SearchScreen(
        viewModel: SearchViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onOpenDocument: { _ in }
    )
}
