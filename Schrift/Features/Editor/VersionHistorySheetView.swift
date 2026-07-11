import SwiftUI

/// Localized "last modified" caption for a version row, mirroring
/// `documentRowDate` (`Home/HomeView.swift`).
func versionRowDate(_ version: DocumentVersion, locale: Locale) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.locale = locale
    return formatter.localizedString(for: version.lastModified, relativeTo: Date())
}

/// Read-only version history (Phase F, tasks F1-F3). There is no in-app
/// restore: the versions retrieve/restore API can't be verified end-to-end in
/// this headless environment, and restoring would touch the safety-critical
/// full-overwrite save path (see CLAUDE.md's Yjs section), so it is deferred
/// to F4. Older rows are display-only; "Restore on the web" is the one
/// restore affordance, and it hands off to the web app instead.
struct VersionHistorySheetView: View {
    @Bindable var viewModel: VersionHistoryViewModel
    var restoreURL: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        // A flat, boxless sheet (handoff `Sheet`): a pinned `SheetHeader` over the
        // version list drawn directly on the page surface — no `ListSection` card
        // and no `ProfileRowDivider`, matching the Options sheet. The version list
        // is the only scrolling region; the "Restore on the web" row is pinned
        // below it so it stays reachable.
        VStack(spacing: 0) {
            SheetHeader(title: loc[.versions_title], closeLabel: loc[.common_close], onClose: { dismiss() })

            if let errorKey = viewModel.errorKey {
                Text(loc[errorKey])
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.bottom, DocsSpacing.spaceXS)
            }

            ScrollView {
                Group {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, DocsSpacing.spaceLG)
                    } else if viewModel.versions.isEmpty {
                        if viewModel.errorKey == nil {
                            Text(loc[.versions_empty])
                                .font(DocsFont.footnote)
                                .foregroundStyle(DocsColor.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, DocsSpacing.spaceLG)
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.versions) { version in
                                versionRow(version)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 340)

            if let restoreURL {
                // Sits directly below the scrolling list, not pinned to the sheet
                // bottom (the filled VStack leaves page surface below it at the
                // `.large` detent). The bottom padding keeps it off the home
                // indicator when content fills the detent.
                ListRow(
                    icon: .open_in_new,
                    title: loc[.versions_restore_web],
                    action: { openURL(restoreURL) }
                )
                .padding(.bottom, DocsSpacing.spaceSM)
            }
        }
        // Fill the sheet so the flat page surface reaches the edges at the
        // `.large` detent, rather than the content-sized VStack leaving the
        // system sheet background showing below the capped list.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
    }

    private func versionRow(_ version: DocumentVersion) -> some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            MaterialSymbol(.schedule, size: 20)
                .foregroundStyle(DocsColor.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(versionRowDate(version, locale: loc.locale))
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)

            Spacer()

            if version.isCurrent {
                Text(loc[.versions_current])
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.success)
            }
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.vertical, DocsSpacing.spaceSM - DocsSpacing.space4xs)
        .frame(minHeight: DocsSpacing.rowMinHeight)
    }
}

#Preview {
    VersionHistorySheetView(
        viewModel: VersionHistoryViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID()
        ),
        restoreURL: URL(string: "https://docs.llun.dev/docs/abc/")
    )
    .environment(LocalizationStore())
}
