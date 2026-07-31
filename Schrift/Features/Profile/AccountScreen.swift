import SwiftUI

/// Profile's push destinations. One case today; an enum rather than a bare
/// `Document`-style value so a second detail screen has an obvious home.
enum ProfileRoute: Hashable {
    case account
}

/// The name to show for an account, or `nil` when there is no user to describe.
///
/// Deliberately **not** falling back to `common_untitled`: that is the empty
/// *document* title, and using it here renders a person called "Untitled" —
/// indistinguishable, to the reader, from real data. `nil` means "we have
/// nothing", and the screen says so instead of inventing an identity.
func accountDisplayName(_ user: CurrentUser?) -> String? {
    guard let user else { return nil }
    for candidate in [user.fullName, user.shortName, user.email] {
        if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
    }
    return nil
}

/// The account detail, pushed from Profile's user row.
///
/// Scoped to what `GET /users/me/` actually returns — id, email, full name,
/// short name, language. The handoff's mock also shows a role badge, an
/// organization and a "member since" date, and offers to edit the name and
/// change the photo; none of those exist in the API, and inventing rows that
/// cannot be filled (or controls that cannot save) would be worse than a
/// shorter screen. Everything here is display-only, with one link out to the
/// web app where the account *can* be edited.
struct AccountScreen: View {
    let user: CurrentUser?
    let serverHost: String
    /// The server's own origin — where "manage on the web" goes.
    let serverURL: URL?

    @Environment(LocalizationStore.self) private var loc
    @Environment(\.openURL) private var openURL

    private var displayName: String? { accountDisplayName(user) }
    private var email: String? {
        guard let email = user?.email, !email.isEmpty else { return nil }
        return email
    }

    var body: some View {
        ScrollView {
            // Nothing loaded (offline, or a failed `/users/me/`) means there is
            // no account to show. Say that, rather than rendering a hero and a
            // "Full name" row filled with placeholder text that reads as real.
            if let displayName {
                VStack(spacing: DocsSpacing.spaceMD - DocsSpacing.space3xs) {
                    identityHeader(displayName)
                    profileSection(displayName)
                    signInSection
                    manageOnWebSection
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .padding(.bottom, DocsSpacing.spaceMD)
            } else {
                ContentUnavailableView {
                    Label {
                        Text(loc[.account_unavailable_title])
                    } icon: {
                        MaterialSymbol(.account_circle, size: 52)
                    }
                } description: {
                    Text(loc[.account_unavailable_body])
                }
                .padding(.top, DocsSpacing.spaceLG)
            }
        }
        .frame(maxWidth: .infinity)
        // The handoff puts this screen on the sunken surface, unlike the four
        // tab roots — it is a detail screen, and the grouped cards read against
        // it rather than floating on white.
        .background(DocsColor.surfaceSunken)
        .navigationTitle(loc[.account_title])
        .navigationBarTitleDisplayMode(.inline)
    }

    private func identityHeader(_ displayName: String) -> some View {
        VStack(spacing: DocsSpacing.space3xs) {
            Avatar(name: displayName, size: 88)
            Text(displayName)
                .font(DocsFont.title2)
                .foregroundStyle(DocsColor.textPrimary)
            if let email {
                Text(email)
                    .font(DocsFont.subhead)
                    .foregroundStyle(DocsColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DocsSpacing.spaceXS)
        .accessibilityElement(children: .combine)
    }

    private func profileSection(_ displayName: String) -> some View {
        ListSection(header: loc[.account_section_profile], footer: loc[.account_language_footer]) {
            ListRow(icon: .badge, title: loc[.account_full_name], value: displayName)
            // The *server* profile's language — distinct from the app's own UI
            // language in Preferences, which is a local preference and is never
            // written back to the server.
            if let language = user?.languageLabel {
                ListRow(icon: .translate, title: loc[.profile_language], value: language)
            }
        }
    }

    private var signInSection: some View {
        ListSection(header: loc[.account_section_signin], footer: loc[.account_signin_footer]) {
            if let email {
                ListRow(icon: .mail, title: loc[.account_email], subtitle: email)
            }
            ListRow(icon: .dns, title: loc[.profile_server], subtitle: serverHost)
        }
    }

    @ViewBuilder
    private var manageOnWebSection: some View {
        if let serverURL {
            ListSection {
                ListRow(
                    icon: .open_in_new,
                    title: loc[.account_manage_on_web],
                    subtitle: serverHost,
                    showsChevron: true,
                    action: { openURL(serverURL) }
                )
            }
        }
    }
}

#Preview {
    NavigationStack {
        AccountScreen(
            user: CurrentUser(
                id: UUID(), email: "camille.moreau@example.org", fullName: "Camille Moreau",
                shortName: "Camille", language: "en"),
            serverHost: "docs.llun.dev",
            serverURL: URL(string: "https://docs.llun.dev")
        )
    }
    .environment(LocalizationStore())
    .environment(AppearanceStore())
}
