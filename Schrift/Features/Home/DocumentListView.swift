import SwiftUI

struct DocumentListView: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.docsCanvasRole) private var canvasRole
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    var onSelect: (Document) -> Void
    /// When set, the search field becomes a read-only shortcut into Home’s Search screen
    /// (compact width). Left nil at regular width, where the field performs inline search.
    var onSearchTap: (() -> Void)? = nil
    /// When set, shows a "New doc" nav-bar action that creates and opens a document.
    var onNewDocument: (() -> Void)? = nil

    @Environment(LocalizationStore.self) private var loc
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("schrift.workOffline") private var workOffline = false
    /// The struck-through row the user tapped, if any — see `pendingDeleteUndoAlert`.
    @State private var documentPendingUndo: Document?
    /// The row whose Delete swipe action was tapped, awaiting confirmation.
    @State private var documentPendingDeleteConfirmation: Document?
    /// The row whose Move swipe action was tapped, presenting the destination picker. No
    /// confirmation alert accompanies it: picking a destination is itself the deliberate step,
    /// and a move is reversible in a way a deletion is not.
    @State private var documentPendingMove: Document?
    /// Which row's swipe strip is open. List-wide, so opening one closes the rest.
    @State private var swipe = SwipeRevealState<UUID>()

    private var isOffline: Bool { viewModel.isOffline || workOffline }
    /// Display-only: the path/transport evidence is debounced so a slow or flaky load cannot
    /// flash the banner and shove the list down and back; Work Offline is a choice, so immediate.
    @State private var offlineStatus = DebouncedStatus()
    private var showsOfflineBanner: Bool { workOffline || offlineStatus.value }

    /// Identity of what the Pinned and Recent sections show; the animation trigger.
    private var listIDs: [UUID] {
        viewModel.pinnedDocuments.map(\.id) + viewModel.recentDocuments.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsOfflineBanner {
                OfflineBanner(note: loc[.offline_note])
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
                        .padding(.bottom, DocsSpacing.spaceBase + DocsSpacing.space4xs)

                    Group {
                        if let errorKey = viewModel.errorKey {
                            HStack(alignment: .firstTextBaseline, spacing: DocsSpacing.spaceXS) {
                                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                                    Text(loc[errorKey])
                                        .font(DocsFont.footnote)
                                        .foregroundStyle(theme.colors.danger)
                                    if let errorDetail = viewModel.errorDetail {
                                        Text(errorDetail)
                                            .font(DocsFont.footnote)
                                            .foregroundStyle(theme.colors.textSecondary)
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
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(reduceMotion ? nil : .snappy, value: viewModel.errorKey)

                    content
                }
                // Rows glide when a revalidation adds, removes or reorders them (and when the
                // Pinned header appears) instead of snapping. Keyed on the fetched lists only —
                // never on search results, which change per keystroke and would feel laggy.
                .animation(reduceMotion ? nil : .snappy, value: listIDs)
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
        .animation(reduceMotion ? nil : .snappy, value: showsOfflineBanner)
        .onChange(of: viewModel.offlineStatusEvidence, initial: true) { _, raw in offlineStatus.update(raw) }
        // Claim the full width the removed NavBar used to define, or the
        // screen sizes to its widest child and starves the title.
        .frame(maxWidth: .infinity)
        .background(canvasRole == .sidebar ? theme.colors.surfaceSunken : theme.colors.surfacePage)
        .pendingDeleteUndoAlert(for: $documentPendingUndo) { document in
            viewModel.undoPendingDelete(document)
        }
        .deleteConfirmationAlert(
            for: $documentPendingDeleteConfirmation,
            hasLocalSubpages: { viewModel.hasLocalSubpages($0) }
        ) { document in
            Task { await viewModel.deleteDocument(document) }
        }
        // `.sheet(item:)` keys the picker to the row it was opened from; `MoveDocumentSheet`
        // owns the view model in `@State` so a re-render of this list cannot swap it out from
        // under an open sheet.
        .sheet(item: $documentPendingMove) { document in
            MoveDocumentSheet(
                client: viewModel.client, document: document,
                saveCoordinator: viewModel.saveCoordinator, signedInUser: viewModel.signedInUser
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // System chrome, not a drawn bar: the large title collapses on scroll,
        // the server host rides along as the subtitle, and on iOS 26 the bar
        // picks up Liquid Glass and its scroll-edge effect for free.
        .navigationTitle(loc[.home_title])
        .navigationSubtitle(serverHost)
        .toolbar {
            if let onNewDocument {
                ToolbarItem(placement: .topBarTrailing) {
                    NewDocumentToolbarButton(action: onNewDocument)
                        .disabled(viewModel.isCreatingDocument)
                }
            }
        }
        .task(id: viewModel.availability.token) {
            await viewModel.loadIfStale()
            await viewModel.search()
        }
        .onChange(of: viewModel.searchQuery) {
            Task { await viewModel.search() }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            if let onSearchTap {
                Button(action: onSearchTap) {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        MaterialSymbol(.search, size: 20)
                            .foregroundStyle(theme.colors.textTertiary)
                        Text(loc.format(.home_search_placeholder, serverHost))
                            .font(DocsFont.callout)
                            .foregroundStyle(theme.colors.textTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .frame(minHeight: DocsSpacing.rowMinHeight)
                    .background(theme.colors.surfaceSunken)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // The native button combines its text label; an accessibility wrapper
                // here would expose a second nested button on iPhone.
                // Offline it still opens Search, which then looks through this device's documents.
                .accessibilityHint(viewModel.availability.isOffline ? loc[.search_offline_local_only] : "")
            } else {
                SearchField(text: $viewModel.searchQuery, placeholder: loc[.home_search_documents])
                    .disabled(viewModel.availability.isOffline)
                    .accessibilityHint(viewModel.availability.isOffline ? loc[.search_offline_explanation] : "")
            }
            // The inline field is the server's search and stays unavailable offline; the compact
            // shortcut opens the Search screen, which searches this device instead.
            if viewModel.availability.isOffline, onSearchTap == nil {
                Text(loc[.search_offline_explanation])
                    .font(DocsFont.footnote)
                    .foregroundStyle(theme.colors.textSecondary)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: viewModel.availability.isOffline)
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
        } else if !viewModel.availability.isOffline,
            !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
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
                    shelf: pinnedShelfIsEnabled(canvasRole: canvasRole, dynamicTypeSize: dynamicTypeSize),
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
    private func documentSection(
        title: String, icon: MaterialIcon? = nil, filled: Bool = false, shelf: Bool = false,
        documents: [Document]
    ) -> some View {
        if !documents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space3xs + 1) {
                    if let icon {
                        MaterialSymbol(icon, size: 15, fill: filled)
                            .foregroundStyle(theme.colors.textTertiary)
                    }
                    Text(title.uppercased())
                        .font(DocsFont.footnote.weight(.semibold))
                        .docsTracking(DocsTypographySpec.footnote, DocsTracking.eyebrow)
                        .foregroundStyle(theme.colors.textTertiary)
                }
                .padding(.horizontal, DocsSpacing.spaceXS)
                .padding(.bottom, DocsSpacing.space3xs)

                // The shelf only ever replaces the Pinned section's rows; the swipe strip and the
                // card's context menu offer the same actions.
                if shelf {
                    pinnedShelf(documents)
                } else {
                    ForEach(documents) { document in
                        documentRow(document)
                    }
                }
            }
            .padding(.bottom, DocsSpacing.spaceSM)
        }
    }

    /// The identity every presentation of a document shares: title without its leading
    /// emoji, that emoji (nil → tinted page glyph), one-line excerpt and the composed
    /// VoiceOver label. Hoisted so the row, its swipe wrapper and the pinned card speak the
    /// identical string.
    private struct RowPresentation {
        let emoji: String?
        let title: String
        let excerpt: String?
        let date: String
        let pageCountLabel: String?
        let label: String
    }

    private func presentation(
        _ document: Document, isLocal: Bool, isPendingDelete: Bool
    ) -> RowPresentation {
        let parts = docTitleParts(document.title)
        let title = parts.title.isEmpty ? loc[.common_untitled] : parts.title
        let excerpt = docRowExcerptText(document.excerpt)
        let date = documentRowDate(document, locale: loc.locale)
        let pageCountLabel = docRowPageCountLabel(document.numchild, loc: loc)
        let label = docRowAccessibilityLabel(
            title: title, excerpt: excerpt ?? "", reach: document.linkReach, date: date,
            pageCountLabel: pageCountLabel ?? "", pinned: document.isFavorite,
            pendingSync: isLocal, pendingSyncLabel: loc[.docrow_on_this_device],
            pendingDelete: isPendingDelete, pendingDeleteLabel: loc[.docrow_pending_delete],
            pinnedLabel: loc[.docrow_pinned],
            sharedWithOrganizationLabel: loc[.docrow_shared_with_organization],
            publicLabel: loc[.docrow_public])
        return RowPresentation(
            emoji: parts.emoji, title: title, excerpt: excerpt, date: date,
            pageCountLabel: pageCountLabel, label: label)
    }

    /// A horizontal shelf of pinned cards. Keeps the tap/open behaviour of the rows it replaces
    /// and exposes their swipe actions as a context menu and as VoiceOver actions.
    @ViewBuilder
    private func pinnedShelf(_ documents: [Document]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                ForEach(documents) { document in
                    pinnedCard(document)
                }
            }
            .padding(.horizontal, DocsSpacing.spaceXS)
            .padding(.vertical, DocsSpacing.space3xs)
        }
        // Cards sit inside the screen gutter, but a card scrolled past it should run to the
        // screen edge instead of being clipped a gutter short of it.
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func pinnedCard(_ document: Document) -> some View {
        let isPendingDelete = viewModel.isDeletePending(document)
        let isLocal = viewModel.isLocalDocument(document)
        let row = presentation(document, isLocal: isLocal, isPendingDelete: isPendingDelete)
        let open = {
            if isPendingDelete {
                documentPendingUndo = document
            } else {
                onSelect(document)
            }
        }
        let actions = documentRowSwipeActions(
            isPendingDelete: isPendingDelete,
            isLocalDocument: isLocal,
            isFavorite: document.isFavorite,
            offersPin: true,
            keepLabel: loc[.pending_delete_undo],
            pinLabel: loc[.options_pin],
            unpinLabel: loc[.options_unpin],
            moveLabel: loc[.options_move],
            deleteLabel: loc[.options_delete],
            onKeep: { viewModel.undoPendingDelete(document) },
            onTogglePin: { Task { await viewModel.toggleFavorite(document) } },
            onMove: { documentPendingMove = document },
            onDelete: { documentPendingDeleteConfirmation = document })

        PinnedCard(
            emoji: row.emoji,
            title: row.title,
            excerpt: row.excerpt,
            tintSeed: document.id,
            pendingDelete: isPendingDelete,
            accessibilityLabel: row.label,
            onOpen: open
        )
        .documentZoomSource(document: document.id, surface: .home, style: .card)
        .contextMenu {
            ForEach(actions) { action in
                Button(role: action.role == .destructive ? .destructive : nil, action: action.handler) {
                    Text(action.label)
                }
            }
        }
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.label, action: action.handler)
            }
        }
    }

    @ViewBuilder
    private func documentRow(_ document: Document) -> some View {
        // Every predicate is read *here*, in the body, which is what registers the
        // `@Observable` dependency — so a row strikes through, un-strikes, or
        // swaps Pin for Unpin without waiting for a list fetch.
        let isPendingDelete = viewModel.isDeletePending(document)
        let isLocal = viewModel.isLocalDocument(document)
        // Hoisted and handed to both the row and its swipe wrapper: the wrapper
        // collapses with `children: .ignore`, which discards whatever `DocRow`
        // composed, so it has to be given the identical string.
        let row = presentation(document, isLocal: isLocal, isPendingDelete: isPendingDelete)
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
                moveLabel: loc[.options_move],
                deleteLabel: loc[.options_delete],
                onKeep: { viewModel.undoPendingDelete(document) },
                onTogglePin: { Task { await viewModel.toggleFavorite(document) } },
                onMove: { documentPendingMove = document },
                onDelete: { documentPendingDeleteConfirmation = document }),
            accessibilityLabel: row.label,
            onActivate: open
        ) {
            DocRow(
                emoji: row.emoji,
                title: row.title,
                pinned: document.isFavorite,
                reach: document.linkReach,
                date: row.date,
                offlineAvailable: isOffline,
                // Created here and not yet on the server — the one row state the
                // user can act on (it is why the document is missing from the web).
                pendingSync: isLocal,
                // Deleted here, not yet sent.
                pendingDelete: isPendingDelete,
                excerpt: row.excerpt,
                pageCount: document.numchild,
                tintSeed: document.id,
                onOpen: open
            )
        }
        .documentZoomSource(document: document.id, surface: .home)
    }
}

/// A template image lets the system toolbar recognize an icon-only action,
/// rather than sizing the Material Symbols text glyph as a wider text button.
struct NewDocumentToolbarButton: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.docsCanvasRole) private var canvasRole
    var action: () -> Void

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        Button(action: action) {
            ToolbarIcon(.add)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(loc[.home_newdoc])
    }
}

#Preview {
    NavigationStack {
        DocumentListView(
            viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
            serverHost: "docs.llun.dev",
            onSelect: { _ in },
            onNewDocument: {}
        )
    }
    .environment(LocalizationStore())
}
