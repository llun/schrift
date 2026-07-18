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
        /// The document's live Yjs replica (C1), built lazily on the first
        /// inbound sync update. Exactly one owner touches it — this manager, on
        /// the main actor (see `Core/Yjs`'s "one owner" rule) — and it must be
        /// `destroy()`ed wherever the entry is removed, or its item graph leaks
        /// (yjs relies on a tracing GC; `YDoc.destroy()` breaks the cycles ARC
        /// cannot).
        var replica: YDoc?
        /// True once at least one inbound update has integrated cleanly. Gates
        /// `projectedReplica` — a replica that has never seen a real update (or
        /// whose only updates all failed) has nothing meaningful to project.
        var initialSyncApplied = false
        /// True once an inbound update has failed to decode/apply. A corrupt or
        /// half-synced replica must never drive the editor, so once set this
        /// entry stops building/updating a replica for the rest of its lifetime
        /// (the change-signal fallback via `remoteChangeTokens` still fires).
        var replicaFailSafe = false
    }

    private var entries: [UUID: Entry] = [:]
    /// True between `suspend()` and `resume()` (app backgrounded). While set,
    /// `resume()` is the only path that rebuilds, and a reconnect edge is ignored
    /// (we don't reopen sockets in the background).
    private var isSuspended = false

    /// Whether the server advertises a collaboration WebSocket. Set by whoever
    /// owns the manager once `GET /config/` resolves (`ServerConfig
    /// .supportsLiveCollaboration`); a server fact, so a stored flag rather than
    /// a live closure. Defaults false, so nothing connects before it is known.
    var serverSupportsLiveCollaboration = false

    /// Our own awareness (`{name, color}`) broadcast to every session, learned once
    /// via `refreshLocalAwareness()`. nil until then (and if the current-user fetch
    /// fails), in which case sessions join as silent observers. The colour is
    /// derived by the App-layer provider — Core never reaches into the avatar
    /// palette — so this stays a plain value.
    private var localAwareness: LocalAwarenessState?

    /// Per-document change-signal counters (see `remoteChangeToken(for:)`).
    private var remoteChangeTokens: [UUID: Int] = [:]

    /// Per-document replica-version counters (see `replicaVersion(for:)`).
    private var replicaVersions: [UUID: Int] = [:]

    private let serverBaseURL: URL
    private let cookieProvider: @Sendable () -> [HTTPCookie]
    private let featureEnabled: @MainActor () -> Bool
    private let isOffline: @MainActor () -> Bool
    private let serverConfigProvider: @Sendable () async -> ServerConfig?
    private let localStateProvider: @Sendable () async -> LocalAwarenessState?
    private let socketFactory: WebSocketFactory
    private let lingerSeconds: Double
    /// Mints the client id for a document's replica (`YDoc.clientID`). Random by
    /// default, matching the roadmap's "fresh random id per session, never
    /// persisted" rule; tests inject a fixed value for determinism.
    private let replicaClientIDProvider: () -> UInt32

    init(
        serverBaseURL: URL,
        cookieProvider: @escaping @Sendable () -> [HTTPCookie],
        featureEnabled: @escaping @MainActor () -> Bool,
        isOffline: @escaping @MainActor () -> Bool,
        serverConfigProvider: @escaping @Sendable () async -> ServerConfig?,
        localStateProvider: @escaping @Sendable () async -> LocalAwarenessState? = { nil },
        socketFactory: @escaping WebSocketFactory,
        lingerSeconds: Double = 5,
        replicaClientIDProvider: @escaping () -> UInt32 = { UInt32.random(in: 1..<UInt32.max) }
    ) {
        self.serverBaseURL = serverBaseURL
        self.cookieProvider = cookieProvider
        self.featureEnabled = featureEnabled
        self.isOffline = isOffline
        self.serverConfigProvider = serverConfigProvider
        self.localStateProvider = localStateProvider
        self.socketFactory = socketFactory
        self.lingerSeconds = lingerSeconds
        self.replicaClientIDProvider = replicaClientIDProvider
    }

    /// Learns whether this deployment runs the collaboration server (from
    /// `GET /config/`), so the view doesn't reach past its view model to do
    /// networking. Best-effort — a failed fetch leaves live collaboration off.
    func refreshServerSupport() async {
        serverSupportsLiveCollaboration = await serverConfigProvider()?.supportsLiveCollaboration ?? false
    }

    /// Learns our own awareness (display name + colour) once, so new sessions
    /// announce our presence. Best-effort — a failed fetch leaves sessions as
    /// silent observers (they still track peers). Runs at launch, but a document
    /// can open *before* it resolves (the fetch races navigation), so a change
    /// rebuilds any live session: one that joined as a silent observer then
    /// re-announces us with the now-known awareness. Idempotent — no rebuild when
    /// the value is unchanged.
    func refreshLocalAwareness() async {
        let resolved = await localStateProvider()
        guard resolved != localAwareness else { return }
        localAwareness = resolved
        guard !isSuspended else { return }
        rebuildActiveSessions()
        // A lingering (released, refCount 0) entry keeps a session built before
        // our identity resolved; `rebuildActiveSessions` skips it. Drop that
        // session so a reopen *within the linger window* rebuilds a fresh one that
        // announces us, instead of reusing the silent session (its localState is
        // immutable). The entry keeps lingering for the quick-reopen path.
        for id in Array(entries.keys) where entries[id]?.refCount == 0 {
            entries[id]?.session?.stop()
            entries[id]?.session = nil
        }
    }

    /// The peers currently present in a document, or `[]` when no live session
    /// exists for it. Reading this in a view body tracks both the manager's
    /// session map and the session's `peers`, so the presence UI re-renders when a
    /// peer joins/leaves *and* when the manager swaps in a fresh session (resume /
    /// reconnect) — the editor never holds a stale session reference.
    func peers(for documentID: UUID) -> [CollaborationPeer] {
        entries[documentID]?.session?.peers ?? []
    }

    /// A monotonic token that increments each time a peer signals a change to the
    /// document (a Yjs sync update over the live socket). The editor observes it
    /// (`onChange`) and debounces a silent revalidation — the signal is only a
    /// *prompt* to re-fetch, never applied content (there is no CRDT yet). Survives
    /// session rebuilds; reset when the document's entry is torn down.
    func remoteChangeToken(for documentID: UUID) -> Int {
        remoteChangeTokens[documentID] ?? 0
    }

    /// A monotonic token that increments each time an inbound Yjs sync update
    /// integrates cleanly into the document's replica (C1). Unlike
    /// `remoteChangeToken`, this only advances on a *successful* apply — a
    /// malformed update bumps `remoteChangeToken` (the fallback-refresh signal
    /// still fires) but not this. `0` when no replica exists yet. Survives
    /// session rebuilds; reset when the document's entry is torn down.
    func replicaVersion(for documentID: UUID) -> Int {
        replicaVersions[documentID] ?? 0
    }

    /// True once an inbound update has failed to decode/apply for this
    /// document. While set, the replica is never rebuilt or projected — a
    /// corrupt/half-synced replica must not silently drive the editor.
    func replicaIsFailSafe(for documentID: UUID) -> Bool {
        entries[documentID]?.replicaFailSafe ?? false
    }

    /// The document's live replica projected into BlockNote-vocabulary blocks
    /// (B5's `YBlockProjection.project`), or `nil` when there is nothing safe to
    /// project: no replica yet, the entry is fail-safed, no update has
    /// integrated yet, or the replica still has unintegrated pending
    /// structs/deletes (`YStructStore.pendingStructs`/`pendingDs`) — projecting
    /// a partially-synced store would show content that is about to change
    /// shape the moment the missing dependency arrives.
    func projectedReplica(for documentID: UUID, interlinkingOrigin: String?) -> ProjectedDocument? {
        guard let entry = entries[documentID], !entry.replicaFailSafe, entry.initialSyncApplied,
            let replica = entry.replica,
            replica.store.pendingStructs == nil, replica.store.pendingDs == nil
        else { return nil }
        return YBlockProjection.project(replica, interlinkingOrigin: interlinkingOrigin)
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
        // Never open a socket while backgrounded — `resume()` is the only rebuild
        // path when suspended (upholds the same invariant as `reconnect()`).
        guard !isSuspended, availability == .available else { return nil }
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

    /// scenePhase background: close every socket (1001). Still-referenced entries
    /// keep their refcount (session nilled) so `resume()` can rebuild them; an
    /// idle entry mid-linger is dropped here (cancelling its linger would
    /// otherwise strand it, since `resume()` only rebuilds referenced entries).
    func suspend() {
        isSuspended = true
        for (id, entry) in entries {
            entry.lingerTask?.cancel()
            entry.session?.stop()
            if entry.refCount == 0 {
                entry.replica?.destroy()
                entries.removeValue(forKey: id)
                remoteChangeTokens.removeValue(forKey: id)
                replicaVersions.removeValue(forKey: id)
            } else {
                entries[id]?.session = nil
                entries[id]?.lingerTask = nil
            }
        }
    }

    /// scenePhase foreground: rebuild a fresh session for every still-referenced
    /// document. A no-op unless we were suspended (a brief `.inactive` blip never
    /// suspended, so there is nothing to rebuild).
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        rebuildActiveSessions()
    }

    /// Reconnect trigger, shared with draft sync: on the `ConnectivityMonitor`
    /// false→true edge, rebuild sessions that have dropped. Ignored while
    /// suspended — the app is backgrounded and must not reopen sockets.
    func reconnect() {
        guard !isSuspended else { return }
        rebuildActiveSessions()
    }

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
            documentName: documentID.uuidString.lowercased(), transport: transport, localState: localAwareness,
            onRemoteChange: { [weak self] in self?.remoteChangeTokens[documentID, default: 0] += 1 },
            onSyncUpdate: { [weak self] data in self?.applyReplicaUpdate(data, for: documentID) })
        session.start()
        return session
    }

    /// Applies one inbound Yjs update to the document's replica (C1), building
    /// the replica lazily on first call. A no-op once the entry has fail-safed.
    ///
    /// A decode/integrate failure destroys the replica and latches
    /// `replicaFailSafe` rather than retrying or leaving a partially-applied
    /// store around: an update is attacker-controlled wire data (it arrives from
    /// a peer), and this store must never trap or drive the editor off corrupt
    /// state. `onRemoteChange` has already bumped `remoteChangeTokens` for this
    /// same message (wired separately in `makeSession`), so the change-signal
    /// fallback (silent revalidation) still fires even after fail-safe.
    private func applyReplicaUpdate(_ data: Data, for documentID: UUID) {
        guard var entry = entries[documentID], !entry.replicaFailSafe else { return }
        let replica = entry.replica ?? YDoc(clientID: UInt(replicaClientIDProvider()), gc: true)
        entry.replica = replica
        do {
            try replica.applyUpdate(try YUpdateDecoder.decode(data))
            entry.initialSyncApplied = true
            entries[documentID] = entry
            replicaVersions[documentID, default: 0] += 1
        } catch {
            replica.destroy()
            entry.replica = nil
            entry.replicaFailSafe = true
            entry.initialSyncApplied = false
            entries[documentID] = entry
        }
    }

    private func rebuildActiveSessions() {
        // Availability can have changed since these sessions were created (the
        // toggle flipped, went offline): if live is no longer available, drop the
        // sockets and leave the entries session-less rather than reopening. A
        // later reconnect rebuilds them once available again.
        let available = availability == .available
        for (id, entry) in entries where entry.refCount > 0 {
            entry.session?.stop()
            entries[id]?.session = available ? makeSession(for: id) : nil
        }
    }

    private func teardownIfIdle(_ documentID: UUID) {
        guard let entry = entries[documentID], entry.refCount == 0 else { return }
        entry.session?.stop()
        entry.replica?.destroy()
        entries.removeValue(forKey: documentID)
        remoteChangeTokens.removeValue(forKey: documentID)
        replicaVersions.removeValue(forKey: documentID)
    }
}

extension DocumentCollaborationManager {
    /// A manager that never opens a socket — for `#Preview`s (and any view test)
    /// that only needs the environment value present. Gated off (`featureEnabled`
    /// false), so `session(for:)` always returns nil and the socket factory is
    /// never invoked.
    static func inert() -> DocumentCollaborationManager {
        DocumentCollaborationManager(
            serverBaseURL: URL(string: "https://example.com/api/v1.0/")!,
            cookieProvider: { [] },
            featureEnabled: { false },
            isOffline: { true },
            serverConfigProvider: { nil },
            socketFactory: URLSessionWebSocket.factory())
    }
}
