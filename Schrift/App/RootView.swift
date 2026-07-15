import SwiftUI

/// Whether a reachability change should trigger a draft sync: only the false→true
/// (reconnect) edge, never a disconnect or a redundant true→true. Pure so the edge
/// is unit-testable without SwiftUI.
func shouldSyncOnReachabilityChange(wasReachable: Bool, isReachable: Bool) -> Bool {
    !wasReachable && isReachable
}

/// Whether a scene-phase change should trigger a draft sync: only when the app
/// becomes active (foreground), never on `.background`/`.inactive`.
func shouldSyncOnScenePhase(_ phase: ScenePhase) -> Bool {
    phase == .active
}

/// What a scene-phase change should do to live collaboration sockets. Only a
/// real `.background` closes them; `.inactive` is a transient blip (control
/// centre, an incoming-call banner) and must not tear down and immediately
/// rebuild every socket. Pure so it is unit-testable without SwiftUI.
enum CollaborationScenePhaseAction: Equatable { case resume, suspend, ignore }

func collaborationScenePhaseAction(_ phase: ScenePhase) -> CollaborationScenePhaseAction {
    switch phase {
    case .active: return .resume
    case .background: return .suspend
    case .inactive: return .ignore
    @unknown default: return .ignore
    }
}

private struct AuthenticatedHomeContainer: View {
    @State private var viewModel: HomeViewModel
    @State private var collaboration: DocumentCollaborationManager
    let serverURL: URL
    let serverHost: String
    let sessionStore: SessionStore
    let onSignOut: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.scenePhase) private var scenePhase

    init(serverURL: URL, sessionStore: SessionStore, onSignOut: @escaping () -> Void) {
        // The one client every feature shares: its onSessionExpired hook is
        // what turns any real 401 into the re-login sheet below (idempotent —
        // concurrent 401s just re-set the same flag). Its onRequestFailure hook
        // records what the server said about every non-2xx, which the view model
        // below quotes — the same log object, or the detail never arrives.
        let diagnostics = APIDiagnosticsLog()
        let client = DocsAPIClient(
            baseURL: serverURL.appendingPathComponent("api/v1.0/"),
            onSessionExpired: { Task { @MainActor in sessionStore.noteSessionExpired() } },
            onRequestFailure: { failure in diagnostics.record(failure) }
        )
        _viewModel = State(initialValue: HomeViewModel(client: client, diagnostics: diagnostics))
        // The app-scoped live-collaboration manager. Built once per authenticated
        // server session (it needs the server origin + cookies); dormant until the
        // `schrift.liveCollaboration` toggle is on AND the server advertises the
        // collaboration WebSocket (learned from `/config/` in `.task` below). The
        // dialed socket URL and cookies are always origin-derived.
        _collaboration = State(
            initialValue: DocumentCollaborationManager(
                serverBaseURL: serverURL,
                cookieProvider: { HTTPCookieStorage.shared.cookies(for: serverURL) ?? [] },
                featureEnabled: { LiveCollaborationPreference.isEnabled() },
                isOffline: { UserDefaults.standard.bool(forKey: "schrift.workOffline") },
                serverConfigProvider: { try? await client.serverConfig() },
                socketFactory: URLSessionWebSocket.factory()))
        self.serverURL = serverURL
        serverHost = serverURL.host ?? ""
        self.sessionStore = sessionStore
        self.onSignOut = onSignOut
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HomeSplitView(viewModel: viewModel, serverHost: serverHost)
            } else {
                HomeView(viewModel: viewModel, serverHost: serverHost, onSignOut: onSignOut)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { sessionStore.needsReauthentication },
                // Swipe-dismiss = cancel: keep showing cached data; the next
                // failing request re-presents the sheet.
                set: { if !$0 { sessionStore.cancelReauthentication() } }
            )
        ) {
            ReauthenticationSheetView(
                serverURL: serverURL,
                sessionStore: sessionStore,
                onAuthenticated: {
                    let homeViewModel = viewModel
                    Task { await homeViewModel.load() }
                },
                onCancel: { sessionStore.cancelReauthentication() }
            )
        }
        // Auto-sync queued drafts when connectivity returns (false→true edge) and
        // when the app comes to the foreground. Launch is covered by the existing
        // `recoverDrafts()` from HomeViewModel.load(). The coordinator self-guards
        // against overlapping runs, so a foreground that coincides with a reconnect
        // is harmless.
        .onChange(of: connectivity.isReachable) { wasReachable, isReachable in
            guard shouldSyncOnReachabilityChange(wasReachable: wasReachable, isReachable: isReachable) else { return }
            collaboration.reconnect()
            let homeViewModel = viewModel
            Task { await homeViewModel.syncPendingDrafts() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Live sockets follow the scene: closed on real background, rebuilt on
            // return; a transient `.inactive` blip is ignored. (No-op while the
            // manager holds no sessions.)
            switch collaborationScenePhaseAction(phase) {
            case .resume: collaboration.resume()
            case .suspend: collaboration.suspend()
            case .ignore: break
            }
            guard shouldSyncOnScenePhase(phase) else { return }
            let homeViewModel = viewModel
            Task { await homeViewModel.syncPendingDrafts() }
        }
        .environment(collaboration)
        .task {
            // Learn whether this deployment runs the collaboration server, so the
            // availability gate can open once the toggle is on. The fetch lives on
            // the manager (its injected provider), not here — the view never does
            // networking directly.
            await collaboration.refreshServerSupport()
        }
    }
}

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated, let serverURL = sessionStore.serverURL {
            AuthenticatedHomeContainer(
                serverURL: serverURL,
                sessionStore: sessionStore,
                onSignOut: {
                    // Full document bodies must not survive sign-out on disk. The
                    // metadata caches (DocumentCacheStore's document lists and
                    // DocumentChildrenCacheStore's sub-page lists) and unsaved
                    // drafts (PendingDraftStore) keep their existing behavior — a
                    // recorded decision, see the 2026-07-03 spec and the
                    // instant-local-doc-lists plan.
                    DocumentContentCacheStore().removeAll()
                    try? sessionStore.signOut()
                })
        } else {
            ConnectView(viewModel: ConnectViewModel(sessionStore: sessionStore, recentServers: recentServers))
        }
    }
}

#Preview {
    RootView()
        .environment(LocalizationStore())
        .environment(ConnectivityMonitor())
}
