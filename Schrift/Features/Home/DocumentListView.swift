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

    private var isOffline: Bool { viewModel.isOffline || workOffline }

    var body: some View {
        VStack(spacing: 0) {
            if isOffline {
                OfflineBanner(note: loc[.offline_note])
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
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
                            // Through `IconButton` rather than a bare 13pt glyph:
                            // it keeps the small visual box but floors the tap
                            // target at 44pt, which a footnote-sized close cross
                            // came nowhere near on its own.
                            IconButton(
                                icon: .close,
                                label: loc[.home_dismiss_error],
                                size: .small,
                                action: viewModel.dismissError)
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
        // Claim the full width the removed NavBar used to define, or the
        // screen sizes to its widest child and starves the title.
        .frame(maxWidth: .infinity)
        .background(DocsColor.surfacePage)
        // System chrome, not a drawn bar: the large title collapses on scroll,
        // the server host rides along as the subtitle, and on iOS 26 the bar
        // picks up Liquid Glass and its scroll-edge effect for free.
        .navigationTitle(loc[.home_title])
        .navigationSubtitle(serverHost)
        .toolbar {
            if let onNewDocument {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onNewDocument) {
                        MaterialSymbol(.add, size: 24)
                    }
                    .accessibilityLabel(loc[.home_newdoc])
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: viewModel.searchQuery) {
            Task { await viewModel.search() }
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
        // run of the list) — cached rows are never replaced by a spinner while
        // a background revalidation is in flight. The view trusts the VM's
        // single, unit-tested gate rather than re-deriving it here.
        if viewModel.isLoading {
            // Skeleton rows rather than a spinner, the same register the Shared
            // tab uses off the same gate — the handoff's rule is no spinners on
            // lists. No gutter here: the enclosing stack already applies it.
            SkeletonList()
        } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if viewModel.searchResults.isEmpty {
                if viewModel.errorKey == nil {
                    ContentUnavailableView.search(text: viewModel.searchQuery)
                }
            } else {
                documentSection(title: loc[.home_results], documents: viewModel.searchResults)
            }
        } else if !viewModel.showsPinnedSection && viewModel.recentDocuments.isEmpty {
            // Keyed to what will actually render (both sections empty), so an
            // empty list never leaves a silent blank area below the controls.
            // The empty state may only claim "No documents yet" for a *known*
            // list — a never-fetched list (e.g. a fresh install under Work
            // Offline) shows nothing; the offline banner or error text above
            // conveys the state.
            if viewModel.errorKey == nil && viewModel.isCurrentListKnown {
                ContentUnavailableView {
                    Label {
                        Text(loc[.home_empty_title])
                    } icon: {
                        MaterialSymbol(.description, size: 52)
                    }
                } description: {
                    Text(loc[.home_empty_body])
                }
            }
        } else {
            if viewModel.showsPinnedSection {
                documentSection(
                    title: loc[.home_section_pinned], icon: .push_pin, filled: true,
                    documents: viewModel.pinnedDocuments)
            }
            documentSection(
                title: loc[.home_section_recent],
                documents: viewModel.recentDocuments
            )
        }
    }

    /// A flat document section — an icon+label header over hover-highlighted
    /// rows, with no grouped-card border (matches the reference doc list).
    @ViewBuilder
    private func documentSection(title: String, icon: MaterialIcon? = nil, filled: Bool = false, documents: [Document])
        -> some View
    {
        if !documents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space3xs + 1) {
                    if let icon {
                        MaterialSymbol(icon, size: 15, fill: filled)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                    Text(title.uppercased())
                        .font(DocsFont.footnote.weight(.semibold))
                        .docsTracking(DocsTypographySpec.footnote, DocsTracking.eyebrow)
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
                        // Created here and not yet on the server — the one row state the
                        // user can act on (it is why the document is missing from the web).
                        pendingSync: viewModel.isLocalDocument(document),
                        onOpen: { onSelect(document) }
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
