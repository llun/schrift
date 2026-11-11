import Foundation
import Observation

/// Where a peer's cursor endpoint lands in the projection (PR10).
enum PeerCursorPlace: Equatable, Sendable {
    /// Inside a block's own text: a caret at that offset.
    case text(EditorPosition)
    /// Somewhere a caret cannot be drawn (inline nodes, a table cell, a
    /// column, a preview): the block that owns it shows a badge.
    case block(String)

    var blockID: String {
        switch self {
        case .text(let position): position.blockID
        case .block(let id): id
        }
    }
}

/// A peer's two endpoints, resolved on the replica session. Either is nil
/// when it cannot be shown; the peer stays in the presence list regardless.
struct PeerCursorPlaces: Equatable, Sendable {
    var anchor: PeerCursorPlace?
    var head: PeerCursorPlace?
}

/// The collaborators of one native replica scope and our own cursor, over the
/// scope's one live socket (`NativeCollaborationBinding`, PR10). Awareness is
/// view state: it is never journaled, persisted or undone, and resolving a
/// peer's cursor never writes the replica.
///
/// - **Inbound** awareness is untrusted. An entry over `maxStateBytes` is
///   ignored, an older or equal clock is stale (y-protocols: an equal clock
///   does not renew), `null` or an unparseable user removes the peer, and a
///   malformed cursor only hides the cursor. At most `maxPeers` are tracked; a
///   peer not renewed for `timeout` expires, and a socket that ends clears all.
/// - **Resolution** runs on the replica session in mailbox order
///   (`.resolveCursors`), at most one in flight: a change meanwhile asks
///   again once it is answered.
/// - **Outbound** is the engine's selection as directed relative positions,
///   reported by the replica after each message (`.watchCursor`) and
///   published at most every `publishInterval` (the latest wins). A reader's
///   replica reports none, and a reader's socket never publishes.
@MainActor @Observable
final class NativeAwarenessController {
    static let maxStateBytes = 8_192
    static let maxPeers = 64

    struct Peer: Equatable {
        var peer: CollaborationPeer
        var clock: UInt
        var cursor: AwarenessCursor?
        var lastSeen: ContinuousClock.Instant
    }

    /// Present collaborators, in client id order (`PresenceBar`).
    private(set) var peers: [CollaborationPeer] = []
    /// Each peer's resolved endpoints, by client id.
    private(set) var places: [UInt: PeerCursorPlaces] = [:]
    @ObservationIgnored private(set) var table: [UInt: Peer] = [:]
    /// The cursor the replica last reported; nil without a selection.
    @ObservationIgnored private(set) var localCursor: AwarenessCursor?
    /// The socket's session: where our cursor goes, and whose id is ours.
    @ObservationIgnored weak var session: DocumentCollaborationSession? {
        didSet { session?.updateLocalCursor(localCursor) }
    }
    /// Text views that paint these cursors.
    @ObservationIgnored private let views = NSHashTable<NativeTextView>.weakObjects()

    @ObservationIgnored private let replica: DocumentReplicaSession
    /// The socket's framing: y-websocket nests the user, Hocuspocus does not.
    @ObservationIgnored var wireProtocol: CollaborationWireProtocol
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let publishInterval: Duration
    /// Edits re-resolve peers at most this often (each resolve walks the
    /// positions' siblings on the replica).
    @ObservationIgnored private let resolveInterval: Duration
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    /// Resolutions posted to the replica (tests read the throttle).
    @ObservationIgnored private(set) var resolveCount = 0
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var resolving = false
    @ObservationIgnored private var needsResolve = false
    @ObservationIgnored private var lastPublish: ContinuousClock.Instant?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    init(
        replica: DocumentReplicaSession, wireProtocol: CollaborationWireProtocol = .yWebSocket,
        timeout: Duration = .seconds(30), publishInterval: Duration = .milliseconds(100),
        resolveInterval: Duration = .milliseconds(100),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.replica = replica
        self.wireProtocol = wireProtocol
        self.timeout = timeout
        self.publishInterval = publishInterval
        self.resolveInterval = resolveInterval
        self.now = now
        replica.mailbox.post(
            .watchCursor { [weak self] cursor in
                Task { @MainActor in self?.localCursorChanged(cursor) }
            })
    }

    // MARK: - Inbound

    /// One decoded awareness frame from the socket.
    func receive(_ entries: [AwarenessEntry]) {
        let ownID = session?.awarenessClientID
        let instant = now()
        var changed = false
        for entry in entries where entry.clientID != ownID {
            guard entry.stateJSON.utf8.count <= Self.maxStateBytes else { continue }
            // Cheap refusals before any JSON is parsed: an unknown id at the
            // cap, or the removal of one never seen.
            if table[entry.clientID] == nil, table.count >= Self.maxPeers || entry.stateJSON == "null" { continue }
            if let known = table[entry.clientID] {
                // y-protocols: only a higher clock, or a removal at the same clock.
                guard entry.clock > known.clock || (entry.clock == known.clock && entry.stateJSON == "null") else {
                    continue
                }
            }
            guard
                let peer = CollaborationPeer(
                    clientID: entry.clientID, stateJSON: entry.stateJSON, wireProtocol: wireProtocol)
            else {
                changed = table.removeValue(forKey: entry.clientID) != nil || changed
                continue
            }
            table[entry.clientID] = Peer(
                peer: peer, clock: entry.clock, cursor: AwarenessCursor.parse(stateJSON: entry.stateJSON),
                lastSeen: instant)
            changed = true
        }
        guard changed else { return }
        publishPeers()
        startSweeping()
    }

    /// Drops every peer not renewed within `timeout`.
    func sweep() {
        let instant = now()
        let expired = table.filter { instant - $0.value.lastSeen > timeout }.keys
        guard !expired.isEmpty else { return }
        for id in expired { table[id] = nil }
        publishPeers()
    }

    /// The socket ended: what peers said is stale.
    func clear() {
        session = nil
        guard !table.isEmpty || !places.isEmpty else { return }
        table = [:]
        publishPeers()
    }

    private func publishPeers() {
        let next = table.values.map(\.peer).sorted { $0.clientID < $1.clientID }
        if next != peers { peers = next }
        let kept = places.filter { table[$0.key] != nil }
        if kept != places { places = kept }
        if table.isEmpty {
            sweepTask?.cancel()
            sweepTask = nil
        }
        resolve()
        redraw()
    }

    private func startSweeping() {
        guard sweepTask == nil else { return }
        let interval = timeout / 6
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.sweep()
            }
        }
    }

    // MARK: - Resolution

    /// The displayed document changed: the peers' positions move with it,
    /// re-resolved at most every `resolveInterval` however fast edits arrive.
    func documentChanged() {
        guard !table.isEmpty, resolveTask == nil else { return }
        let interval = resolveInterval
        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.resolveTask = nil
            self.resolve()
        }
    }

    private func resolve() {
        guard !resolving else {
            needsResolve = true
            return
        }
        let cursors = table.compactMapValues(\.cursor)
        guard !cursors.isEmpty else {
            if !places.isEmpty { places = [:] }
            return
        }
        resolving = true
        needsResolve = false
        resolveCount += 1
        let posted = replica.mailbox.post(
            .resolveCursors(
                cursors,
                reply: { [weak self] resolved in
                    Task { @MainActor in self?.resolved(resolved) }
                }))
        // A full mailbox: keystrokes come first; the next change asks again.
        if !posted { resolving = false }
    }

    private func resolved(_ resolved: [UInt: PeerCursorPlaces]) {
        resolving = false
        // A peer that left meanwhile stays gone.
        let next = resolved.filter { table[$0.key]?.cursor != nil }
        if next != places {
            places = next
            redraw()
        }
        if needsResolve { resolve() }
    }

    // MARK: - Painting

    func addView(_ view: NativeTextView) {
        views.add(view)
        view.cursorOverlay.awareness = self
    }

    private func redraw() {
        for view in views.allObjects { view.setNeedsLayout() }
    }

    // MARK: - Outbound

    private func localCursorChanged(_ cursor: AwarenessCursor?) {
        localCursor = cursor
        let instant = now()
        if let lastPublish, instant - lastPublish < publishInterval {
            guard publishTask == nil else { return }
            let wait = publishInterval - (instant - lastPublish)
            publishTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                self.publishTask = nil
                self.publishNow()
            }
            return
        }
        publishNow()
    }

    private func publishNow() {
        lastPublish = now()
        session?.updateLocalCursor(localCursor)
    }

    isolated deinit {
        publishTask?.cancel()
        sweepTask?.cancel()
        resolveTask?.cancel()
    }
}
