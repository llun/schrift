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

    @Environment(LocalizationStore.self) private var loc
    @AppStorage("schrift.workOffline") private var workOffline = false
    @State private var documentPendingFavoriteChoice: Document?

    private var isOffline: Bool { viewModel.isOffline || workOffline }

    private var trailingActions: [NavBarAction] {
        var actions: [NavBarAction] = []
        // The nav bar no longer carries a search action — search is reached via
        // the in-page search field (which `onSearchTap` still drives on phone)
        // and the Search tab.
        if let onNewDocument {
            actions.append(
                NavBarAction(systemImage: "plus", label: loc[.home_newdoc], color: .brand, action: onNewDocument))
        }
        return actions
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: loc[.home_title],
                subtitle: serverHost,
                largeTitle: true,
                trailingActions: trailingActions,
                showsBorder: false
            )

            if isOffline {
                OfflineBanner(note: loc[.offline_note])
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
                        .padding(.bottom, DocsSpacing.spaceSM)

                    SegmentedControl(
                        segments: HomeFilter.allCases.map { loc[$0.titleKey] },
                        selectedIndex: Binding(
                            get: { viewModel.selectedFilter.rawValue },
                            set: { newValue in
                                let filter = HomeFilter(rawValue: newValue) ?? .all
                                Task { await viewModel.selectFilter(filter) }
                            }
                        )
                    )
                    .padding(.bottom, DocsSpacing.spaceBase + DocsSpacing.space4xs)

                    if let errorKey = viewModel.errorKey {
                        HStack(alignment: .firstTextBaseline, spacing: DocsSpacing.spaceXS) {
                            VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                                Text(loc[errorKey])
                                    .font(DocsFont.footnote)
                                    .foregroundStyle(DocsColor.danger)
                                if let errorDetail = viewModel.errorDetail {
                                    Text(errorDetail)
                                        .font(DocsFont.footnote)
                                        .foregroundStyle(DocsColor.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Button {
                                viewModel.dismissError()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(DocsFont.footnote)
                                    .foregroundStyle(DocsColor.textSecondary)
                            }
                            .accessibilityLabel(loc[.home_dismiss_error])
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, DocsSpacing.spaceXS)
                    }

                    content
                }
                .padding(.top, DocsSpacing.space3xs)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceBase)
            }
            .refreshable {
                await viewModel.refresh()
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
            loc[.home_document_options],
            isPresented: Binding(
                get: { documentPendingFavoriteChoice != nil },
                set: { if !$0 { documentPendingFavoriteChoice = nil } }
            ),
            presenting: documentPendingFavoriteChoice
        ) { document in
            Button(document.isFavorite ? loc[.home_unpin] : loc[.home_pin]) {
                Task { await viewModel.toggleFavorite(document) }
            }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        if let onSearchTap {
            Button(action: onSearchTap) {
                SearchField(text: .constant(""), placeholder: loc.format(.home_search_placeholder, serverHost))
                    .allowsHitTesting(false)
            }
            .buttonStyle(.plain)
            // Announce one actionable button, not the inert editable field inside.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(loc.format(.home_search_placeholder, serverHost))
            .accessibilityAddTraits(.isButton)
        } else {
            SearchField(text: $viewModel.searchQuery, placeholder: loc[.home_search_documents])
        }
    }

    @ViewBuilder
    private var content: some View {
        // isLoading is set only via shouldShowLoadingPlaceholder (true first
        // run of a filter) — cached rows are never replaced by a spinner while
        // a background revalidation is in flight. The view trusts the VM's
        // single, unit-tested gate rather than re-deriving it here.
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, DocsSpacing.spaceBase)
        } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if viewModel.searchResults.isEmpty {
                if viewModel.errorKey == nil {
                    ContentUnavailableView.search(text: viewModel.searchQuery)
                }
            } else {
                documentSection(title: loc[.home_results], documents: viewModel.searchResults)
            }
        } else if !viewModel.showsPinnedSection && viewModel.recentDocuments.isEmpty {
            // Keyed to what will actually render (the pinned section is hidden
            // under the .pinned filter), so an empty filter never leaves a
            // silent blank area below the controls. The empty state may only
            // claim "No documents yet" for a *known* list — a never-fetched
            // filter (e.g. first visited under Work Offline) shows nothing;
            // the offline banner or error text above conveys the state.
            if viewModel.errorKey == nil && viewModel.isCurrentListKnown {
                ContentUnavailableView(
                    loc[.home_empty_title],
                    systemImage: "doc.text",
                    description: Text(loc[.home_empty_body])
                )
            }
        } else {
            if viewModel.showsPinnedSection {
                documentSection(
                    title: loc[.home_section_pinned], icon: "pin.fill", documents: viewModel.pinnedDocuments)
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
        case .shared: return loc[.home_section_shared]
        case .pinned: return loc[.home_section_pinned]
        default: return loc[.home_section_recent]
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
                        title: document.title ?? loc[.common_untitled],
                        pinned: document.isFavorite,
                        reach: document.linkReach,
                        date: documentRowDate(document, locale: loc.locale),
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
    .environment(LocalizationStore())
}
