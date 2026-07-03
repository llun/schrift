import SwiftUI

struct DocumentListView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    var onSelect: (Document) -> Void
    /// When set, the search field becomes a read-only shortcut into the Search tab
    /// (phone). Left nil on iPad, where the field performs inline search.
    var onSearchTap: (() -> Void)? = nil
    /// When set, shows a "New doc" nav-bar action that creates and opens a document.
    var onNewDocument: (() -> Void)? = nil

    @AppStorage("schrift.workOffline") private var workOffline = false
    @State private var documentPendingFavoriteChoice: Document?

    private var isOffline: Bool { viewModel.isOffline || workOffline }

    private var trailingActions: [NavBarAction] {
        var actions: [NavBarAction] = []
        // The nav bar no longer carries a search action — search is reached via
        // the in-page search field (which `onSearchTap` still drives on phone)
        // and the Search tab.
        if let onNewDocument {
            actions.append(NavBarAction(systemImage: "plus", label: "New doc", color: .brand, action: onNewDocument))
        }
        return actions
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: "Schrift",
                subtitle: serverHost,
                largeTitle: true,
                trailingActions: trailingActions
            )

            if isOffline {
                OfflineBanner()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
                        .padding(.bottom, DocsSpacing.spaceSM)

                    SegmentedControl(
                        segments: HomeFilter.allCases.map(\.title),
                        selectedIndex: Binding(
                            get: { viewModel.selectedFilter.rawValue },
                            set: { newValue in
                                let filter = HomeFilter(rawValue: newValue) ?? .all
                                Task { await viewModel.selectFilter(filter) }
                            }
                        )
                    )
                    .padding(.bottom, DocsSpacing.spaceBase + DocsSpacing.space4xs)

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.danger)
                            .padding(.bottom, DocsSpacing.spaceXS)
                    }

                    content
                }
                .padding(.top, DocsSpacing.space3xs)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceBase)
            }
            .refreshable {
                await viewModel.load()
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
        .onChange(of: viewModel.searchQuery) {
            Task { await viewModel.search() }
        }
        .confirmationDialog(
            "Document Options",
            isPresented: Binding(
                get: { documentPendingFavoriteChoice != nil },
                set: { if !$0 { documentPendingFavoriteChoice = nil } }
            ),
            presenting: documentPendingFavoriteChoice
        ) { document in
            Button(document.isFavorite ? "Unpin" : "Pin") {
                Task { await viewModel.toggleFavorite(document) }
            }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        if let onSearchTap {
            Button(action: onSearchTap) {
                SearchField(text: .constant(""), placeholder: "Search \(serverHost)")
                    .allowsHitTesting(false)
            }
            .buttonStyle(.plain)
            // Announce one actionable button, not the inert editable field inside.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Search \(serverHost)")
            .accessibilityAddTraits(.isButton)
        } else {
            SearchField(text: $viewModel.searchQuery, placeholder: "Search documents")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, DocsSpacing.spaceBase)
        } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if viewModel.searchResults.isEmpty {
                if viewModel.errorMessage == nil {
                    ContentUnavailableView.search(text: viewModel.searchQuery)
                }
            } else {
                documentSection(title: "Results", documents: viewModel.searchResults)
            }
        } else if viewModel.pinnedDocuments.isEmpty && viewModel.recentDocuments.isEmpty {
            if viewModel.errorMessage == nil {
                ContentUnavailableView(
                    "No documents yet",
                    systemImage: "doc.text",
                    description: Text("Documents you create or that are shared with you will appear here.")
                )
            }
        } else {
            if viewModel.showsPinnedSection {
                documentSection(title: "Pinned", icon: "pin.fill", documents: viewModel.pinnedDocuments)
            }
            documentSection(
                title: mainSectionTitle,
                icon: viewModel.selectedFilter == .pinned ? "pin.fill" : nil,
                documents: viewModel.recentDocuments
            )
        }
    }

    /// Header for the main (non-pinned) section, which reflects the active
    /// filter: the Pinned filter loads favorites here, so it must read "Pinned"
    /// rather than the default "Recent".
    private var mainSectionTitle: String {
        switch viewModel.selectedFilter {
        case .shared: return "Shared with me"
        case .pinned: return "Pinned"
        default: return "Recent"
        }
    }

    /// A flat document section — an icon+label header over hover-highlighted
    /// rows, with no grouped-card border (matches the reference doc list).
    @ViewBuilder
    private func documentSection(title: String, icon: String? = nil, documents: [Document]) -> some View {
        if !documents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space3xs + 1) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                    Text(title.uppercased())
                        .font(DocsFont.footnote.weight(.semibold))
                        .tracking(DocsTypographySpec.footnote.size * DocsTracking.eyebrow)
                        .foregroundStyle(DocsColor.textTertiary)
                }
                .padding(.horizontal, DocsSpacing.spaceXS)
                .padding(.bottom, DocsSpacing.space3xs)

                ForEach(documents) { document in
                    DocRow(
                        emoji: nil,
                        title: document.title ?? "Untitled document",
                        pinned: document.isFavorite,
                        reach: document.linkReach,
                        date: documentRowDate(document),
                        offlineAvailable: isOffline,
                        onOpen: { onSelect(document) },
                        onMore: { documentPendingFavoriteChoice = document }
                    )
                }
            }
            .padding(.bottom, DocsSpacing.spaceSM)
        }
    }
}

#Preview {
    DocumentListView(
        viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onSelect: { _ in }
    )
}
