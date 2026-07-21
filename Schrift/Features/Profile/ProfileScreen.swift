import SwiftUI

struct ProfileScreen: View {
    @Bindable var viewModel: ProfileViewModel
    let serverHost: String
    var isOffline: Bool = false
    var onSignOut: () -> Void

    @AppStorage("schrift.notifications") private var notificationsEnabled: Bool = true
    @AppStorage("schrift.workOffline") private var workOffline: Bool = false
    // Live collaboration is opt-in (default off): the write path is verified in CI but the
    // on-device end-to-end WebSocket check against a real server is still owed. The manager
    // reads this key live (RootView's `featureEnabled` closure), so writing it here is the
    // entire wiring — see `LiveCollaborationPreference`.
    @AppStorage(LiveCollaborationPreference.key) private var liveCollaboration: Bool = false

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
        // The handoff puts Profile on the plain page surface (white in light mode),
        // like the other three tabs — with the grouped cards defined by their
        // hairline border, not by a sunken grey backdrop. (The old iOS-grouped
        // grey came from the pre-redesign Profile/Account screens.)
        .background(DocsColor.surfacePage)
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
            ListRow(icon: .account_circle, title: viewModel.user?.email ?? "—")
        }
    }

    // MARK: - 2) Preferences

    private var preferencesSection: some View {
        ListSection(
            header: loc[.profile_prefs],
            // The section footer is a single `Text`, which renders the newline — one
            // sentence per toggle (Work offline, then Live collaboration).
            footer: loc[.profile_prefs_footer] + "\n" + loc[.profile_live_collaboration_footer]
        ) {
            ListRow(
                icon: .dark_mode,
                title: loc[.profile_appearance],
                value: loc[appearanceValueKey(appearance.selected)],
                showsChevron: true,
                action: { showAppearanceSheet = true }
            )
            ListRow(
                icon: .translate,
                title: loc[.profile_language],
                value: loc.language.autonym,
                showsChevron: true,
                action: { showLanguageSheet = true }
            )
            ProfileTrailingRow(icon: .notifications, title: loc[.profile_notifications]) {
                Switch(isOn: $notificationsEnabled)
            }
            ProfileTrailingRow(icon: .cloud_off, title: loc[.profile_work_offline]) {
                Switch(isOn: $workOffline)
            }
            ProfileTrailingRow(icon: .group, title: loc[.profile_live_collaboration]) {
                Switch(isOn: $liveCollaboration)
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
                ProfileTrailingRow(icon: .dns, title: serverHost) {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Badge(
                            text: isOfflineOrForced ? loc[.profile_offline] : loc[.profile_connected],
                            tone: isOfflineOrForced ? .neutral : .success,
                            dot: true
                        )
                        MaterialSymbol(.chevron_right, size: 18)
                            .foregroundStyle(DocsColor.gray300)
                    }
                }
            }
            .buttonStyle(.plain)
            if let serverVersion = viewModel.serverVersion {
                ListRow(icon: .deployed_code, title: loc[.profile_server_version], value: serverVersion)
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
                icon: .logout, title: loc[.profile_sign_out], isDestructive: true,
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
