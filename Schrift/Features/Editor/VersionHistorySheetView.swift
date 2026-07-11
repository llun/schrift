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
        NavigationStack {
            VStack(spacing: 0) {
                if let errorKey = viewModel.errorKey {
                    Text(loc[errorKey])
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .padding(.horizontal, DocsSpacing.gutter)
                        .padding(.top, DocsSpacing.spaceSM)
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
                            ListSection {
                                ForEach(Array(viewModel.versions.enumerated()), id: \.element.id) {
                                    index, version in
                                    if index > 0 {
                                        ProfileRowDivider()
                                    }
                                    versionRow(version)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.top, DocsSpacing.space3xs)
                }
                .frame(maxHeight: 340)

                if let restoreURL {
                    ListSection {
                        ListRow(
                            icon: .open_in_new,
                            title: loc[.versions_restore_web],
                            action: { openURL(restoreURL) }
                        )
                    }
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.top, DocsSpacing.spaceSM)
                    .padding(.bottom, DocsSpacing.spaceSM)
                }
            }
            .background(DocsColor.surfacePage)
            .navigationTitle(loc[.versions_title])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc[.common_done]) { dismiss() }
                }
            }
            .task {
                await viewModel.load()
            }
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
