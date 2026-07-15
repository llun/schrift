import Foundation

/// Whether live collaboration may run, and if not, why — most-specific reason
/// first. A pure decision so the gating chain is unit-testable in isolation; the
/// manager supplies the live inputs.
enum LiveCollaborationAvailability: Equatable, Sendable {
    /// The app-level "Live collaboration" toggle is off (the default). This is
    /// the outermost gate — nothing else is even consulted.
    case featureDisabled
    /// The app is offline or working offline; a live socket needs the network.
    case offline
    /// This deployment advertises no collaboration WebSocket, or repeated
    /// handshakes this app session proved the route missing.
    case serverUnavailable
    /// Every gate passes — a live session may be established.
    case available
}

/// Resolves live-collaboration availability from the gating chain, in the order
/// the roadmap fixes: the app toggle, then offline state, then the server's
/// advertised support (a boolean — the socket URL is always origin-derived),
/// then a per-session "proven unavailable" memo (set after the handshake reports
/// the feature missing, mirroring `prefersLegacyContentRoute`).
func liveCollaborationAvailability(
    featureEnabled: Bool,
    isOffline: Bool,
    serverSupports: Bool,
    provenUnavailable: Bool
) -> LiveCollaborationAvailability {
    if !featureEnabled { return .featureDisabled }
    if isOffline { return .offline }
    if !serverSupports || provenUnavailable { return .serverUnavailable }
    return .available
}
