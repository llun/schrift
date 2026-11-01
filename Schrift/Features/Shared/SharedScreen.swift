import SwiftUI

struct SharedScreen: View {
    @Environment(\.docsTheme) private var theme
    @Bindable var viewModel: SharedViewModel
    let serverHost: String
    /// `SessionStore.signInGeneration`: a re-login reloads even inside the freshness window.
    let signInGeneration: Int
    var onOpenDocument: (Document) -> Void

    @Environment(LocalizationStore.self) private var loc
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The struck-through row the user tapped, if any — see `pendingDeleteUndoAlert`.
    @State private var documentPendingUndo: Document?
    @AppStorage("schrift.workOffline") private var workOffline = false
    /// Display-only debounce of the path/transport offline evidence, so a slow load cannot flash
    /// the banner and push the list down and back. Work Offline is a choice, so it is immediate.
    @State private var offlineStatus = DebouncedStatus()
    private var showsOfflineBanner: Bool { workOffline || offlineStatus.value }

    private func subtitle(for document: Document) -> String {
        let date = documentRowDate(document, locale: loc.locale)
        if let name = viewModel.enrichment[document.id]?.sharedByName {
            return loc.format(.shared_subtitle_shared_by, name, date)
        }
        return loc.format(.shared_subtitle_with, date)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
                Group {
                    if let errorKey = viewModel.errorKey {
                        Text(loc[errorKey])
                            .font(DocsFont.footnote)
                            .foregroundStyle(theme.colors.danger)
                            .padding(.horizontal, DocsSpacing.gutter)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(reduceMotion ? nil : .snappy, value: viewModel.errorKey)

                // Per-list gate: spinner only while fetching a list with no
                // local copy; never claim "0 documents" for a list that is
                // simply not yet known (the banner/error above conveys that).
                if viewModel.showsLoadingPlaceholder {
                    // Skeleton rows rather than a spinner: the handoff's
                    // loading rule for lists, and it says "rows are coming"
                    // where a spinner only says "wait".
                    SkeletonList(shape: .shared)
                        .padding(.horizontal, DocsSpacing.gutter)
                } else if viewModel.showsDocumentList {
                    // Flat, per the handoff: an uppercase count eyebrow over
                    // rows drawn straight on the page, with no grouped card
                    // around them — matching Home's sections rather than the
                    // boxed list this used to be.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(
                            loc.plural(
                                viewModel.documents.count, one: .shared_count_one,
                                other: .shared_count_other,
                                two: .shared_count_two, few: .shared_count_few
                            )
                            .uppercased()
                        )
                        .font(DocsFont.footnote.weight(.semibold))
                        .foregroundStyle(theme.colors.textTertiary)
                        .docsTracking(DocsTypographySpec.footnote, DocsTracking.eyebrow)
                        .padding(.horizontal, DocsSpacing.spaceXS)
                        .padding(.bottom, DocsSpacing.space3xs)

                        ForEach(viewModel.documents) { document in
                            SharedRow(
                                title: document.title ?? loc[.common_untitled],
                                subtitle: subtitle(for: document),
                                sharedByName: viewModel.enrichment[document.id]?.sharedByName,
                                memberNames: viewModel.enrichment[document.id]?.memberNames ?? [],
                                // Reading the predicate in this body registers the
                                // `@Observable` dependency, so the row strikes through
                                // (and un-strikes on undo) with no list fetch.
                                pendingDelete: viewModel.isDeletePending(document),
                                pendingDeleteLabel: loc[.docrow_pending_delete],
                                onTap: {
                                    if viewModel.isDeletePending(document) {
                                        documentPendingUndo = document
                                    } else {
                                        onOpenDocument(document)
                                    }
                                }
                            )
                            .documentZoomSource(document: document.id, surface: .shared)
                        }
                    }
                    // Rows glide when a revalidation changes the list rather than snapping.
                    .animation(reduceMotion ? nil : .snappy, value: viewModel.documents.map(\.id))
                    // Matches Home's section rhythm before the footer.
                    .padding(.bottom, DocsSpacing.spaceSM)
                    .padding(.horizontal, DocsSpacing.gutter)
                }

                Text(loc[.shared_footer_with])
                    .font(DocsFont.footnote)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.horizontal, DocsSpacing.gutterGrouped)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DocsSpacing.spaceBase)
            .padding(.bottom, DocsSpacing.spaceBase)
        }
        .refreshable {
            await viewModel.refresh()
        }
        // A bar on the scroll view, as on Home: the ScrollView stays the root the navigation bar
        // tracks, and the banner sits under the large title and subtitle in either bar state.
        .safeAreaBar(edge: .top, spacing: 0) {
            if showsOfflineBanner {
                OfflineBanner(note: loc[.offline_note])
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: showsOfflineBanner)
        .onChange(of: viewModel.offlineStatusEvidence, initial: true) { _, raw in offlineStatus.update(raw) }
        // Claim the full width the removed NavBar used to define, or the
        // screen sizes to its widest child and starves the title.
        .frame(maxWidth: .infinity)
        .background(theme.colors.surfacePage)
        .pendingDeleteUndoAlert(for: $documentPendingUndo) { document in
            viewModel.undoPendingDelete(document)
        }
        .navigationTitle(loc[.shared_title])
        .navigationSubtitle(serverHost)
        .task(
            id: SharedViewModel.LoadKey(token: viewModel.availability.token, sessionGeneration: signInGeneration)
        ) {
            await viewModel.loadIfStale(sessionGeneration: signInGeneration)
        }
    }
}

#Preview {
    SharedScreen(
        viewModel: SharedViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        signInGeneration: 0,
        onOpenDocument: { _ in }
    )
    .environment(LocalizationStore())
}
