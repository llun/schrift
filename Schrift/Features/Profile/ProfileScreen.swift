import SwiftUI

struct ProfileScreen: View {
    @Bindable var viewModel: ProfileViewModel
    let serverHost: String
    var isOffline: Bool = false
    var onOpenAccount: () -> Void
    var onSignOut: () -> Void

    @AppStorage("schrift.appearance") private var appearance: String = "system"
    @AppStorage("schrift.notifications") private var notificationsEnabled: Bool = true
    @AppStorage("schrift.workOffline") private var workOffline: Bool = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Profile", largeTitle: true)

            ScrollView {
                VStack(spacing: DocsSpacing.spaceMD) {
                    accountBanner
                    preferencesSection
                    serverSection
                    supportSection
                    signOutSection
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.vertical, DocsSpacing.spaceMD)
            }
        }
        .background(DocsColor.surfaceSunken)
        .task { await viewModel.load() }
    }

    // MARK: - 1) Account banner

    private var accountBanner: some View {
        Button(action: onOpenAccount) {
            HStack(spacing: DocsSpacing.spaceSM) {
                Avatar(name: viewModel.user?.displayName ?? "Account", size: 56)

                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(viewModel.user?.displayName ?? "Account")
                        .font(DocsFont.headline)
                        .foregroundStyle(DocsColor.textPrimary)
                    if let email = viewModel.user?.email {
                        Text(email)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DocsColor.textTertiary)
            }
            .padding(.horizontal, DocsSpacing.gutterGrouped)
            .frame(minHeight: 72)
            .background(DocsColor.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2) Preferences

    private var appearanceLabel: String {
        appearance.prefix(1).uppercased() + appearance.dropFirst()
    }

    private func cycleAppearance() {
        switch appearance {
        case "system": appearance = "light"
        case "light": appearance = "dark"
        default: appearance = "system"
        }
    }

    private var preferencesSection: some View {
        ListSection(
            header: "Preferences",
            footer: "When on, documents you've opened stay readable on this device without a connection."
        ) {
            ListRow(
                systemImage: "circle.lefthalf.filled",
                title: "Appearance",
                value: appearanceLabel,
                action: cycleAppearance
            )
            ProfileRowDivider()
            ListRow(
                systemImage: "globe",
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

    private var serverSection: some View {
        ListSection(
            header: "Server",
            footer: "The app connects to any Schrift server using your existing web session."
        ) {
            ProfileTrailingRow(systemImage: "server.rack", title: serverHost) {
                Badge(
                    text: isOffline ? "Offline" : "Connected",
                    tone: isOffline ? .neutral : .success
                )
            }
        }
    }

    // MARK: - 4) Support

    private var supportSection: some View {
        ListSection(header: "Support") {
            ListRow(systemImage: "questionmark.circle", title: "Help & feedback", showsChevron: true)
            ProfileRowDivider()
            ListRow(systemImage: "lock.shield", title: "Privacy policy", showsChevron: true)
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
            ListRow(title: "Sign out", isDestructive: true, action: onSignOut)
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
