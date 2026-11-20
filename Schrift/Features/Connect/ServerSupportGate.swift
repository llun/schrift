import Foundation

/// The signed-in server's Docs capability as the app shows it at launch.
///
/// Seeded **synchronously** from `ServerCapabilityStore`, so a server already known to be
/// pre-Docs 6 is refused before any network call — including on an offline launch, where the
/// refresh below can never answer. The refresh then re-checks in the background: a server
/// upgraded to Docs 6 clears the notice, and one downgraded raises it.
///
/// Only a *definitive* answer moves the gate (`serverCapability(from:)`). A failed or offline
/// refresh leaves the cached value — or unknown — alone, so an offline launch of a Docs 6
/// server keeps working.
@MainActor
@Observable
final class ServerSupportGate {
    private let store: ServerCapabilityStore
    private let serverOrigin: String
    private(set) var capability: ServerCapability?

    init(serverOrigin: String, store: ServerCapabilityStore = ServerCapabilityStore()) {
        self.serverOrigin = serverOrigin
        self.store = store
        self.capability = store.capability(forServerOrigin: serverOrigin)
    }

    /// Schrift supports only Docs 6+; a confirmed legacy server is refused.
    var isBlocked: Bool { capability == .legacy }

    /// Re-ask the server and record what it proves. `fetch` returns the config or the error the
    /// request threw; a failure that proves nothing leaves the current answer untouched.
    func refresh(using fetch: () async -> Result<ServerConfig, any Error>) async {
        guard let proven = serverCapability(from: await fetch()) else { return }
        store.record(proven, forServerOrigin: serverOrigin)
        capability = proven
    }
}
