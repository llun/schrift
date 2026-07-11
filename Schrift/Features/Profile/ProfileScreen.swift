import SwiftUI

struct ProfileScreen: View {
    @Bindable var viewModel: ProfileViewModel
    let serverHost: String
    var isOffline: Bool = false
    var onSignOut: () -> Void

    @AppStorage("schrift.notifications") private var notificationsEnabled: Bool = true
    @AppStorage("schrift.workOffline") private var workOffline: Bool = false

    @State private var isConfirmingDisconnect = false
    @State private var showAppearanceSheet = false
    @State private var showLanguageSheet = false

    @Environment(LocalizationStore.self) private var loc
    @Environment(AppearanceStore.self) private var appearance

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: loc[.profile_title], largeTitle: true, showsBorder: false)

            ScrollView {
                VStack(spacing: DocsSpacing.spaceMD - DocsSpacing.space3xs) {
                    userSection
                    preferencesSection
                    serverSection
                    aboutSection
                    signOutSection
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.space3xs)
                .padding(.bottom, DocsSpacing.spaceMD)
            }
        }
        .background(DocsColor.surfaceSunken)
        .task { await viewModel.load() }
        .sheet(isPresented: $showAppearanceSheet) {
            AppearancePickerSheet()
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLanguageSheet) {
            LanguagePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            loc.format(.profile_disconnect_title, serverHost),
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button(loc[.profile_disconnect], role: .destructive) { onSignOut() }
        } message: {
            Text(loc[.profile_disconnect_body])
        }
    }

    // MARK: - 1) User

    private var userSection: some View {
        ListSection(header: loc[.profile_user]) {
            ListRow(systemImage: "person.circle", title: viewModel.user?.email ?? "—")
        }
    }

    // MARK: - 2) Preferences

    private var preferencesSection: some View {
        ListSection(
            header: loc[.profile_prefs],
            footer: loc[.profile_prefs_footer]
        ) {
            ListRow(
                systemImage: "moon",
                title: loc[.profile_appearance],
                value: loc[appearanceValueKey(appearance.selected)],
                showsChevron: true,
                action: { showAppearanceSheet = true }
            )
            ProfileRowDivider()
            ListRow(
                systemImage: "translate",
                title: loc[.profile_language],
                value: loc.language.autonym,
                showsChevron: true,
                action: { showLanguageSheet = true }
            )
            ProfileRowDivider()
            ProfileTrailingRow(systemImage: "bell", title: loc[.profile_notifications]) {
                Switch(isOn: $notificationsEnabled)
            }
            ProfileRowDivider()
            ProfileTrailingRow(systemImage: "icloud.slash", title: loc[.profile_work_offline]) {
                Switch(isOn: $workOffline)
            }
        }
    }

    // MARK: - 3) Server

    private var isOfflineOrForced: Bool { isOffline || workOffline }

    private var serverSection: some View {
        ListSection(
            header: loc[.profile_server],
            footer: loc[.profile_server_footer]
        ) {
            Button(action: { isConfirmingDisconnect = true }) {
                ProfileTrailingRow(systemImage: "server.rack", title: serverHost) {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Badge(
                            text: isOfflineOrForced ? loc[.profile_offline] : loc[.profile_connected],
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
            if let serverVersion = viewModel.serverVersion {
                ProfileRowDivider()
                ListRow(systemImage: "shippingbox", title: loc[.profile_server_version], value: serverVersion)
            }
        }
    }

    // MARK: - 4) About

    private var aboutSection: some View {
        ListSection(header: loc[.profile_about]) {
            ListRow(title: loc[.profile_version], value: appVersion)
        }
    }

    // MARK: - 5) Sign out

    private var signOutSection: some View {
        ListSection {
            ListRow(
                systemImage: "rectangle.portrait.and.arrow.right", title: loc[.profile_sign_out], isDestructive: true,
                action: onSignOut)
        }
    }
}

#Preview {
    ProfileScreen(
        viewModel: ProfileViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onSignOut: {}
    )
    .environment(LocalizationStore())
    .environment(AppearanceStore())
}
