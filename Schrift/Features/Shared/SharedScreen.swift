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
            NavBar(title: loc[.shared_title], subtitle: serverHost, largeTitle: true, showsBorder: false)

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
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, DocsSpacing.spaceBase)
                    } else if viewModel.showsDocumentList {
                        ListSection(
                            header: loc.plural(
                                viewModel.documents.count, one: .shared_count_one, other: .shared_count_other,
                                two: .shared_count_two, few: .shared_count_few)
                        ) {
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
                .padding(.top, DocsSpacing.spaceBase)
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
