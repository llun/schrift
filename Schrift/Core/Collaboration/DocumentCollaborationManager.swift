import Foundation

/// App-scoped owner of live-collaboration sessions, keyed by document id — built
/// once per authenticated server session and injected, alongside `DocsAPIClient`
/// and `DocumentSaveCoordinator`.
///
/// It hands a screen a `DocumentCollaborationSession` when live editing is
/// available (feature toggle on, online, server supports it), reference-counts
/// it so re-opening the same document reuses one socket, lingers briefly after
/// the last release, and rebuilds sessions on foreground / reconnect (a
/// `DocumentCollaborationSession` is signal-only and does not auto-reconnect —
/// reconnecting means a fresh session on a fresh socket).
///
/// Every app-dependent input is an injected closure, so the manager is testable
/// with a `FakeWebSocket` factory and holds no singletons. The per-session
/// "server route missing" memo the roadmap describes needs a handshake-failure
/// signal that lands with the write path, so availability here is
/// feature/offline/server-config only for now.
@MainActor
@Observable
final class DocumentCollaborationManager {
    private struct Entry {
        /// The live session, or nil while suspended (app backgrounded).
        var session: DocumentCollaborationSession?
        var refCount: Int
        var lingerTask: Task<Void, Never>?
    }

    private var entries: [UUID: Entry] = [:]

    /// Whether the server advertises a collaboration WebSocket. Set by whoever
    /// owns the manager once `GET /config/` resolves (`ServerConfig
    /// .supportsLiveCollaboration`); a server fact, so a stored flag rather than
    /// a live closure. Defaults false, so nothing connects before it is known.
    var serverSupportsLiveCollaboration = false

    private let serverBaseURL: URL
    private let cookieProvider: @Sendable () -> [HTTPCookie]
    private let featureEnabled: @MainActor () -> Bool
    private let isOffline: @MainActor () -> Bool
    private let socketFactory: WebSocketFactory
    private let lingerSeconds: Double

    init(
        serverBaseURL: URL,
        cookieProvider: @escaping @Sendable () -> [HTTPCookie],
        featureEnabled: @escaping @MainActor () -> Bool,
        isOffline: @escaping @MainActor () -> Bool,
        socketFactory: @escaping WebSocketFactory,
        lingerSeconds: Double = 5
    ) {
        self.serverBaseURL = serverBaseURL
        self.cookieProvider = cookieProvider
        self.featureEnabled = featureEnabled
        self.isOffline = isOffline
        self.socketFactory = socketFactory
        self.lingerSeconds = lingerSeconds
    }

    /// The current gate result, in the roadmap's fixed order.
    var availability: LiveCollaborationAvailability {
        liveCollaborationAvailability(
            featureEnabled: featureEnabled(), isOffline: isOffline(),
            serverSupports: serverSupportsLiveCollaboration, provenUnavailable: false)
    }

    /// A live session for the document, creating and connecting one on first
    /// request (reference-counted). Returns nil when live editing is unavailable
    /// or the socket URL can't be pinned to the server origin.
    func session(for documentID: UUID) -> DocumentCollaborationSession? {
        guard availability == .available else { return nil }
        if var entry = entries[documentID] {
            entry.lingerTask?.cancel()  // a re-open cancels the pending teardown
            entry.lingerTask = nil
            entry.refCount += 1
            if entry.session == nil { entry.session = makeSession(for: documentID) }
            entries[documentID] = entry
            return entry.session
        }
        guard let session = makeSession(for: documentID) else { return nil }
        entries[documentID] = Entry(session: session, refCount: 1, lingerTask: nil)
        return session
    }

    /// Releases one reference. When the last is gone the session lingers for
    /// `lingerSeconds` (a quick re-open reuses it) then is torn down.
    func release(_ documentID: UUID) {
        guard var entry = entries[documentID], entry.refCount > 0 else { return }
        entry.refCount -= 1
        guard entry.refCount == 0 else {
            entries[documentID] = entry
            return
        }
        entry.lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.lingerSeconds ?? 5))
            guard !Task.isCancelled else { return }
            self?.teardownIfIdle(documentID)
        }
        entries[documentID] = entry
    }

    /// scenePhase background: close every socket (1001) but keep the entries and
    /// their refcounts, so `resume()` can rebuild the ones still in use.
    func suspend() {
        for (id, entry) in entries {
            entry.lingerTask?.cancel()
            entry.session?.stop()
            entries[id]?.session = nil
            entries[id]?.lingerTask = nil
        }
    }

    /// scenePhase foreground: rebuild a fresh session for every still-referenced
    /// document (idle entries were already torn down by their linger).
    func resume() { rebuildActiveSessions() }

    /// Reconnect trigger, shared with draft sync: on the `ConnectivityMonitor`
    /// false→true edge, rebuild sessions that have dropped.
    func reconnect() { rebuildActiveSessions() }

    /// Test/inspection: how many documents currently hold a session.
    var activeDocumentCount: Int { entries.count }

    // MARK: - internals

    private func makeSession(for documentID: UUID) -> DocumentCollaborationSession? {
        guard
            let request = CollaborationEndpoint.webSocketRequest(
                serverBaseURL: serverBaseURL, documentID: documentID, cookies: cookieProvider())
        else { return nil }
        let transport = CollaborationTransport(socket: socketFactory(request))
        let session = DocumentCollaborationSession(
            documentName: documentID.uuidString.lowercased(), transport: transport)
        session.start()
        return session
    }

    private func rebuildActiveSessions() {
        for (id, entry) in entries where entry.refCount > 0 {
            entry.session?.stop()
            entries[id]?.session = makeSession(for: id)
        }
    }

    private func teardownIfIdle(_ documentID: UUID) {
        guard let entry = entries[documentID], entry.refCount == 0 else { return }
        entry.session?.stop()
        entries.removeValue(forKey: documentID)
    }
}
