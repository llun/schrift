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
    /// The struck-through row the user tapped, if any — see `pendingDeleteUndoAlert`.
    @State private var documentPendingUndo: Document?
    /// The row whose Delete swipe action was tapped, awaiting confirmation.
    @State private var documentPendingDeleteConfirmation: Document?
    /// Which row's swipe strip is open. List-wide, so opening one closes the rest.
    @State private var swipe = SwipeRevealState<UUID>()

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
            // Scrolling dismisses an open strip, as it does in a system list. Guarded inside
            // `swipeRevealAfterScrollInteraction` so a swipe that nudges the scroll view —
            // which it will, the two gestures being simultaneous — does not close its own.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { swipe = swipeRevealAfterScrollInteraction(swipe) }
            }
        }
        // Claim the full width the removed NavBar used to define, or the
        // screen sizes to its widest child and starves the title.
        .frame(maxWidth: .infinity)
        .background(DocsColor.surfacePage)
        .pendingDeleteUndoAlert(for: $documentPendingUndo) { document in
            viewModel.undoPendingDelete(document)
        }
        .deleteConfirmationAlert(
            for: $documentPendingDeleteConfirmation,
            hasLocalSubpages: { viewModel.hasLocalSubpages($0) }
        ) { document in
            Task { await viewModel.deleteDocument(document) }
        }
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
                    // Every predicate is read *here*, in the body, which is what registers the
                    // `@Observable` dependency — so a row strikes through, un-strikes, or
                    // swaps Pin for Unpin without waiting for a list fetch.
                    let isPendingDelete = viewModel.isDeletePending(document)
                    let isLocal = viewModel.isLocalDocument(document)
                    let title = document.title ?? loc[.common_untitled]
                    let date = documentRowDate(document, locale: loc.locale)
                    // Hoisted and handed to both the row and its swipe wrapper: the wrapper
                    // collapses with `children: .ignore`, which discards whatever `DocRow`
                    // composed, so it has to be given the identical string.
                    let label = docRowAccessibilityLabel(
                        title: title, reach: document.linkReach, date: date,
                        pinned: document.isFavorite,
                        pendingSync: isLocal, pendingSyncLabel: loc[.docrow_on_this_device],
                        pendingDelete: isPendingDelete, pendingDeleteLabel: loc[.docrow_pending_delete],
                        pinnedLabel: loc[.docrow_pinned],
                        sharedWithOrganizationLabel: loc[.docrow_shared_with_organization],
                        publicLabel: loc[.docrow_public])
                    // A document on its way out is not opened — the tap offers to keep it
                    // instead, which is the only place that choice is still available.
                    let open = {
                        if isPendingDelete {
                            documentPendingUndo = document
                        } else {
                            onSelect(document)
                        }
                    }

                    SwipeRevealRow(
                        id: document.id,
                        state: $swipe,
                        actions: documentRowSwipeActions(
                            isPendingDelete: isPendingDelete,
                            isLocalDocument: isLocal,
                            isFavorite: document.isFavorite,
                            offersPin: true,
                            keepLabel: loc[.pending_delete_undo],
                            pinLabel: loc[.options_pin],
                            unpinLabel: loc[.options_unpin],
                            deleteLabel: loc[.options_delete],
                            onKeep: { viewModel.undoPendingDelete(document) },
                            onTogglePin: { Task { await viewModel.toggleFavorite(document) } },
                            onDelete: { documentPendingDeleteConfirmation = document }),
                        accessibilityLabel: label,
                        onActivate: open
                    ) {
                        DocRow(
                            emoji: nil,
                            title: title,
                            pinned: document.isFavorite,
                            reach: document.linkReach,
                            date: date,
                            offlineAvailable: isOffline,
                            // Created here and not yet on the server — the one row state the
                            // user can act on (it is why the document is missing from the web).
                            pendingSync: isLocal,
                            // Deleted here, not yet sent.
                            pendingDelete: isPendingDelete,
                            onOpen: open
                        )
                    }
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
