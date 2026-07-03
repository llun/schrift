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
            NavBar(title: "Account", backTitle: "Profile", onBack: onBack, surfaceTint: .sunken)

            ScrollView {
                VStack(spacing: DocsSpacing.spaceMD - DocsSpacing.space3xs) {
                    identityHeader
                    profileSection
                    signInSection
                    manageSection
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .padding(.bottom, DocsSpacing.spaceMD + DocsSpacing.space3xs)
            }
        }
        .background(DocsColor.surfaceSunken)
        .task { await viewModel.load() }
    }

    // MARK: - Identity header

    private var identityHeader: some View {
        VStack(spacing: DocsSpacing.space3xs) {
            Avatar(name: viewModel.user?.displayName ?? "Account", size: 88)
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(DocsColor.brandFill)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(DocsColor.surfaceSunken, lineWidth: 3))
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 2, y: 2)
                    .accessibilityHidden(true)
                }
                .padding(.bottom, DocsSpacing.space2xs)

            VStack(spacing: DocsSpacing.space3xs) {
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
        .padding(.top, DocsSpacing.spaceXS)
        .padding(.bottom, DocsSpacing.space3xs)
    }

    // MARK: - Profile

    private var profileSection: some View {
        ListSection(header: "Profile") {
            ListRow(
                systemImage: "person.text.rectangle",
                title: "Full name",
                value: viewModel.user?.displayName ?? "—",
                showsChevron: true
            )
            ProfileRowDivider()
            ListRow(
                systemImage: "translate",
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
