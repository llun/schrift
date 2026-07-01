import SwiftUI

struct AccountScreen: View {
    @Bindable var viewModel: ProfileViewModel
    let serverHost: String
    var onBack: () -> Void

    private var manageURL: URL? {
        URL(string: "https://\(serverHost)")
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Account", backTitle: "Profile", onBack: onBack)

            ScrollView {
                VStack(spacing: DocsSpacing.spaceMD) {
                    identityHeader
                    profileSection
                    signInSection
                    manageSection
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.vertical, DocsSpacing.spaceMD)
            }
        }
        .background(DocsColor.surfaceSunken)
        .task { await viewModel.load() }
    }

    // MARK: - Identity header

    private var identityHeader: some View {
        VStack(spacing: DocsSpacing.spaceSM) {
            Avatar(name: viewModel.user?.displayName ?? "Account", size: 88)

            VStack(spacing: DocsSpacing.space4xs) {
                Text(viewModel.user?.displayName ?? "Account")
                    .font(DocsFont.title2)
                    .foregroundStyle(DocsColor.textPrimary)
                if let email = viewModel.user?.email {
                    Text(email)
                        .font(DocsFont.subhead)
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DocsSpacing.spaceSM)
    }

    // MARK: - Profile

    private var profileSection: some View {
        ListSection(header: "Profile") {
            ListRow(
                title: "Full name",
                value: viewModel.user?.displayName ?? "—",
                showsChevron: true
            )
            ProfileRowDivider()
            ListRow(
                title: "Language",
                value: viewModel.user?.languageLabel ?? "—",
                showsChevron: true
            )
        }
    }

    // MARK: - Sign-in

    private var signInSection: some View {
        ListSection(
            header: "Sign-in",
            footer: "You're signed in with your web session. Schrift connects using your browser cookie and never stores your password."
        ) {
            ListRow(
                systemImage: "envelope",
                title: "Email",
                subtitle: viewModel.user?.email ?? "—"
            )
            ProfileRowDivider()
            ListRow(
                systemImage: "server.rack",
                title: "Server",
                subtitle: serverHost
            )
        }
    }

    // MARK: - Manage

    private var manageSection: some View {
        ListSection {
            ListRow(
                systemImage: "arrow.up.right.square",
                title: "Manage account on the web",
                subtitle: serverHost,
                showsChevron: true,
                action: {
                    if let manageURL {
                        UIApplication.shared.open(manageURL)
                    }
                }
            )
        }
    }
}

#Preview {
    AccountScreen(
        viewModel: ProfileViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onBack: {}
    )
}
