import SwiftUI

struct SharedScreen: View {
    @Bindable var viewModel: SharedViewModel
    let serverHost: String
    var onOpenDocument: (Document) -> Void

    @Environment(LocalizationStore.self) private var loc
    @AppStorage("schrift.workOffline") private var workOffline = false

    private func subtitle(for document: Document) -> String {
        let date = documentRowDate(document, locale: loc.locale)
        if let name = viewModel.enrichment[document.id]?.sharedByName {
            return loc.format(.shared_subtitle_shared_by, name, date)
        }
        return loc.format(.shared_subtitle_with, date)
    }

    var body: some View {
        VStack(spacing: 0) {
            if workOffline || viewModel.isOffline { OfflineBanner(note: loc[.offline_note]) }

            ScrollView {
                VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
                    if let errorKey = viewModel.errorKey {
                        Text(loc[errorKey])
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.danger)
                            .padding(.horizontal, DocsSpacing.gutter)
                    }

                    // Per-list gate: spinner only while fetching a list with no
                    // local copy; never claim "0 documents" for a list that is
                    // simply not yet known (the banner/error above conveys that).
                    if viewModel.showsLoadingPlaceholder {
                        // Skeleton rows rather than a spinner: the handoff's
                        // loading rule for lists, and it says "rows are coming"
                        // where a spinner only says "wait".
                        SkeletonList()
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
                            .foregroundStyle(DocsColor.textTertiary)
                            .docsTracking(DocsTypographySpec.footnote, DocsTracking.eyebrow)
                            .padding(.horizontal, DocsSpacing.spaceXS)
                            .padding(.bottom, DocsSpacing.space3xs)

                            ForEach(viewModel.documents) { document in
                                SharedRow(
                                    title: document.title ?? loc[.common_untitled],
                                    subtitle: subtitle(for: document),
                                    memberNames: viewModel.enrichment[document.id]?.memberNames ?? [],
                                    onTap: { onOpenDocument(document) }
                                )
                            }
                        }
                        .padding(.horizontal, DocsSpacing.gutter)
                    }

                    Text(loc[.shared_footer_with])
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                        .padding(.horizontal, DocsSpacing.gutterGrouped)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DocsSpacing.spaceBase)
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
        .navigationTitle(loc[.shared_title])
        .navigationSubtitle(serverHost)
        .task {
            await viewModel.load()
        }
    }
}

#Preview {
    SharedScreen(
        viewModel: SharedViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onOpenDocument: { _ in }
    )
    .environment(LocalizationStore())
}
