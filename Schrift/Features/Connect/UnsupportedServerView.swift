import SwiftUI

/// Full-screen notice for a signed-in server that is not Docs 6+.
///
/// Schrift cannot talk to a pre-Docs 6 server — its content routes and save path are gone — so
/// the app refuses the session outright instead of failing request by request. Sign out is the
/// only action: it returns to Connect, where another server can be chosen. Styled like the
/// app's other full-screen states (`ContentUnavailableView` with a Material Symbol).
struct UnsupportedServerView: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc
    let onSignOut: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(loc[.server_unsupported])
            } icon: {
                MaterialSymbol(.dns, size: 52)
            }
        } actions: {
            DocsButton(
                title: loc[.profile_sign_out], variant: .secondary, icon: .logout, action: onSignOut)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.surfacePage)
    }
}

#Preview {
    UnsupportedServerView(onSignOut: {})
        .environment(LocalizationStore())
}
