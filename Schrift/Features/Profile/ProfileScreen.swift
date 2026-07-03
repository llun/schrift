import SwiftUI

struct ProfileScreen: View {
    @Bindable var viewModel: ProfileViewModel
    let serverHost: String
    var isOffline: Bool = false
    var onOpenAccount: () -> Void
    var onSignOut: () -> Void

    @AppStorage("schrift.notifications") private var notificationsEnabled: Bool = true
    @AppStorage("schrift.workOffline") private var workOffline: Bool = false

    @State private var isConfirmingDisconnect = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Profile", largeTitle: true, surfaceTint: .sunken)

            ScrollView {
                VStack(spacing: DocsSpacing.spaceMD - DocsSpacing.space3xs) {
                    accountBanner
                    preferencesSection
                    serverSection
                    supportSection
                    signOutSection
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.space3xs)
                .padding(.bottom, DocsSpacing.spaceMD)
            }
        }
        .background(DocsColor.surfaceSunken)
        .task { await viewModel.load() }
        .confirmationDialog(
            "Disconnect from \(serverHost)?",
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { onSignOut() }
        } message: {
            Text("You'll need to sign in again to reconnect.")
        }
    }

    // MARK: - 1) Account banner

    private var accountBanner: some View {
        Button(action: onOpenAccount) {
            HStack(spacing: DocsSpacing.spaceSM + DocsSpacing.space4xs) {
                Avatar(name: viewModel.user?.displayName ?? "Account", size: 56)

                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(viewModel.user?.displayName ?? "Account")
                        .font(DocsFont.headline)
                        .foregroundStyle(DocsColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let email = viewModel.user?.email {
                        Text(email)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 18))
                    .foregroundStyle(DocsColor.gray300)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, DocsSpacing.spaceBase)
            .background(DocsColor.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DocsRadius.lg)
                    .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2) Preferences

    private var preferencesSection: some View {
        ListSection(
            header: "Preferences",
            footer: "When on, documents you've opened stay readable on this device without a connection."
        ) {
            // The palette has no dark variant yet, so appearance follows the
            // system. Show it as a static value rather than a cycler that changes
            // nothing (matching the reference's static "System").
            ListRow(
                systemImage: "moon",
                title: "Appearance",
                value: "System",
                showsChevron: true
            )
            ProfileRowDivider()
            ListRow(
                systemImage: "translate",
                title: "Language",
                value: viewModel.user?.languageLabel ?? "—",
                showsChevron: true
            )
            ProfileRowDivider()
            ProfileTrailingRow(systemImage: "bell", title: "Notifications") {
                Switch(isOn: $notificationsEnabled)
            }
            ProfileRowDivider()
            ProfileTrailingRow(systemImage: "icloud.slash", title: "Work offline") {
                Switch(isOn: $workOffline)
            }
        }
    }

    // MARK: - 3) Server

    private var isOfflineOrForced: Bool { isOffline || workOffline }

    private var serverSection: some View {
        ListSection(
            header: "Server",
            footer: "The app connects to any Schrift server using your existing web session."
        ) {
            Button(action: { isConfirmingDisconnect = true }) {
                ProfileTrailingRow(systemImage: "server.rack", title: serverHost) {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Badge(
                            text: isOfflineOrForced ? "Offline" : "Connected",
                            tone: isOfflineOrForced ? .neutral : .success,
                            dot: true
                        )
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18))
                            .foregroundStyle(DocsColor.gray300)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 4) Support

    private var supportSection: some View {
        ListSection(header: "Support") {
            ListRow(systemImage: "questionmark.circle", title: "Help & feedback", showsChevron: true)
            ProfileRowDivider()
            ListRow(systemImage: "shield", title: "Privacy policy", showsChevron: true)
            ProfileRowDivider()
            ListRow(
                systemImage: "info.circle",
                title: "About Schrift",
                value: appVersion,
                showsChevron: true
            )
        }
    }

    // MARK: - 5) Sign out

    private var signOutSection: some View {
        ListSection {
            ListRow(
                systemImage: "rectangle.portrait.and.arrow.right", title: "Sign out", isDestructive: true,
                action: onSignOut)
        }
    }
}

#Preview {
    ProfileScreen(
        viewModel: ProfileViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onOpenAccount: {},
        onSignOut: {}
    )
}
