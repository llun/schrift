import Foundation

/// Availability for server-backed reads and controls. HTTP errors say nothing about
/// the network path; Work Offline deliberately withholds reads even on a live path.
@MainActor
@Observable
final class OnlineAvailability {
    private let connectivity: ConnectivityMonitor?
    private let userDefaults: UserDefaults
    private var preferenceRevision = 0
    private var lastWorkOffline: Bool

    struct Token: Hashable {
        let pathRevision: Int
        let preferenceRevision: Int
        let workOffline: Bool
    }

    init(connectivity: ConnectivityMonitor? = nil, userDefaults: UserDefaults = .standard) {
        self.connectivity = connectivity
        self.userDefaults = userDefaults
        lastWorkOffline = userDefaults.bool(forKey: "schrift.workOffline")
    }

    var isOffline: Bool {
        // Register the preference dependency, but read the actual value at the request
        // boundary too: an AppStorage onChange may not have run yet.
        _ = preferenceRevision
        return userDefaults.bool(forKey: "schrift.workOffline") || connectivity?.isReachable == false
    }

    /// Whether status chrome should read as offline: `isOffline` plus transport evidence
    /// that the server cannot be reached despite a satisfied path (Wi-Fi without
    /// internet). For status display only (banner, save status, sync caption) — never
    /// for gating controls or `permitsResponse`, since a control disabled on failure
    /// evidence would make no request and could never recover.
    var showsOfflineStatus: Bool { isOffline || connectivity?.serverUnreachable == true }

    var token: Token {
        Token(
            pathRevision: connectivity?.revision ?? 0, preferenceRevision: preferenceRevision,
            workOffline: userDefaults.bool(forKey: "schrift.workOffline"))
    }

    func preferencesChanged() {
        let workOffline = userDefaults.bool(forKey: "schrift.workOffline")
        guard workOffline != lastWorkOffline else { return }
        lastWorkOffline = workOffline
        preferenceRevision += 1
    }

    func permitsResponse(for token: Token) -> Bool {
        !isOffline && self.token == token
    }
}
