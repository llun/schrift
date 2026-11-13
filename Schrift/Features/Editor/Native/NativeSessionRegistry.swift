import Foundation
import Observation

/// One `DocumentReplicaSession` per `ReplicaScope` (PR08c), shared by every
/// surface open on it. `RootView` owns one per signed-in server session.
///
/// - **Refcounted.** `open` leases a new surface (`NativeEditorSession`) on
///   the scope's replica, restoring it first when none is open; closing the
///   surface detaches it, and the replica closes after its last surface.
/// - **Serial per scope.** A scope's next replica is restored only after the
///   previous one closed, so two replica sessions never journal into one
///   scope. Opens that arrive during a restore share it.
/// - **One save scheduler and one journal per scope**, shared by its surfaces.
/// - `drainAll` (background), `closeAll(where:)` (a sign-in change) and
///   `setWritable` act on every replica at once.
@MainActor @Observable
final class NativeSessionRegistry {
    @MainActor
    private final class Entry {
        let replica: Task<DocumentReplicaSession?, any Error>
        var surfaces: [NativeEditorSession] = []
        /// Opens awaiting the restore or their attach: the replica stays.
        var opening = 0
        var scheduler: NativeReplicaSaveScheduler?
        /// The scope's live socket binding (PR09a), stopped with the replica.
        var live: NativeCollaborationBinding?
        var isWritable = false
        /// Set once the replica's close was posted.
        var closed: Task<Void, Never>?

        init(replica: Task<DocumentReplicaSession?, any Error>) { self.replica = replica }
    }

    @ObservationIgnored private var entries: [ReplicaScope: Entry] = [:]
    /// The live bindings' reconnect timing (tests shorten it).
    @ObservationIgnored var liveBackoff = NativeCollaborationBinding.Backoff()
    /// Each scope's last replica close, awaited by its next restore.
    @ObservationIgnored private var closing: [ReplicaScope: Task<Void, Never>] = [:]

    /// The scopes with a replica open or opening.
    var openScopes: Set<ReplicaScope> { Set(entries.keys) }

    /// A new surface on `scope`'s replica, restored off the main actor when
    /// none is open. Nil when there is no replica, or when the scope was
    /// closed (`closeAll`) while this open waited.
    func open(
        store: ReplicaStore, scope: ReplicaScope, hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> NativeEditorSession? {
        while entries[scope] == nil, let previous = closing[scope] {
            await previous.value
            if closing[scope] == previous { closing[scope] = nil }
        }
        let entry =
            entries[scope]
            ?? {
                let entry = Entry(
                    replica: Task { try await DocumentReplicaSession.restore(store: store, scope: scope, hooks: hooks) }
                )
                entries[scope] = entry
                return entry
            }()
        entry.opening += 1
        defer {
            entry.opening -= 1
            closeIfUnused(entry, scope: scope)
        }
        guard let replica = try await entry.replica.value else { return nil }
        guard entries[scope] === entry else { return nil }
        let session = await NativeEditorSession.attach(replica, scope: scope)
        guard entries[scope] === entry else {
            session.close()
            return nil
        }
        entry.surfaces.append(session)
        // Strong: the replica must close even if the registry is dropped first.
        // The cycle lasts only while the surface is leased.
        session.release = { [unowned session] in self.release(session, from: entry, scope: scope) }
        return session
    }

    /// The scope's one save scheduler, made by `make` for its first surface.
    func scheduler(
        for scope: ReplicaScope, make: () -> NativeReplicaSaveScheduler
    ) -> NativeReplicaSaveScheduler {
        if let scheduler = entries[scope]?.scheduler { return scheduler }
        let scheduler = make()
        entries[scope]?.scheduler = scheduler
        return scheduler
    }

    /// The scope's one live binding (PR09a), made over its replica on first
    /// use; its outbox is what the scope's journal publishes into. Nil when the
    /// scope has no open surface.
    func liveBinding(for scope: ReplicaScope, create: Bool = true) -> NativeCollaborationBinding? {
        guard let entry = entries[scope] else { return nil }
        if let live = entry.live { return live }
        guard create else { return nil }
        guard let replica = entry.surfaces.first?.replica else { return nil }
        let live = NativeCollaborationBinding(replica: replica, backoff: liveBackoff)
        entry.live = live
        return live
    }

    /// Installs (or, nil, removes) the scope's journal: the replica is
    /// writable for every surface at once. Returns false when it already had
    /// the journal asked for, or the scope is not open.
    @discardableResult
    func setWritable(_ journal: DocumentReplicaSession.Journal?, for scope: ReplicaScope) -> Bool {
        guard let entry = entries[scope], let replica = entry.surfaces.first?.replica,
            entry.isWritable != (journal != nil)
        else { return false }
        entry.isWritable = journal != nil
        replica.mailbox.post(.setWritable(journal))
        return true
    }

    /// The surfaces open on `scope`.
    func surfaces(of scope: ReplicaScope) -> [NativeEditorSession] { entries[scope]?.surfaces ?? [] }

    /// The scope's journal (`NativeEditorOpen.installTyping` and the headless
    /// lease, PR13b): every append recorded by `adapter`, then published to the
    /// scope's live outbox (journal before publication).
    @discardableResult
    func installJournal(_ adapter: ReplicaSaveAdapter, for scope: ReplicaScope) -> Bool {
        let outbox = liveBinding(for: scope)?.outbox
        return setWritable(
            { command, update in
                try adapter.record(command, update: update)
                outbox?.publish(update)
            }, for: scope)
    }

    /// What a headless media commit did (PR13b).
    enum MediaCommit: Equatable {
        /// `.mediaProps` was journaled and its save handed over.
        case committed
        /// Check only (no props): the block still holds the slot.
        case matches
        /// The block is gone, retyped or filled, or the replica no longer exists: drop the upload.
        case gone
        /// Nothing decided (closed, read-only, busy, a disk failure): try again later.
        case unavailable
    }

    /// The headless lease (PR13b): a surface on `scope`'s replica (an open
    /// editor's, else restored for this), the block found in mailbox order
    /// wherever it sits (a block of a column group that is not open is reached
    /// by opening that column first, review X6), then, with `props`, one
    /// `.mediaProps(props, expecting: slot)` barrier and its save.
    /// - The scope's journal is installed only when no other surface is open
    ///   and `mayWrite` (the editor open's typing gate) holds; an open editor
    ///   that does not write stays so (review X2). A document the session
    ///   cannot type is never written.
    /// - The save goes through the scope's scheduler when an editor installed
    ///   one, else through a private `make()` that never becomes the editor's
    ///   (review X7).
    /// Visible editors get the change by fan-out. Retried while stale or busy,
    /// `attempts` times `interval` apart.
    func commitMedia(
        _ props: [ProjectedProp]?, into blockID: String, expecting slot: MediaBlock.Slot, scope: ReplicaScope,
        store: ReplicaStore, attempts: Int = 50, interval: Duration = .milliseconds(100),
        mayWrite: () -> Bool = { false }, scheduler make: () -> NativeReplicaSaveScheduler
    ) async -> MediaCommit {
        switch Result(catching: { try store.manifest(for: scope) }) {
        case .success(nil): return .gone
        case .failure: return .unavailable
        case .success: break
        }
        guard let root = try? await open(store: store, scope: scope) else { return .unavailable }
        defer { root.close() }
        guard let found = await root.mediaLocation(blockID) else { return .unavailable }
        guard var location = found else { return .gone }
        var columnSurface: NativeEditorSession?
        defer { columnSurface?.close() }
        if let column = location.column {
            columnSurface = await root.openColumn(group: column.group, column: column.id)
            guard let columnSurface, let reread = await columnSurface.mediaLocation(blockID) else {
                return .unavailable
            }
            guard let reread else { return .gone }
            location = reread
        }
        guard location.slot == slot else { return .gone }
        guard let props else { return .matches }
        let session = columnSurface ?? root
        guard root.canType, !root.hasUnsupportedRoot else { return .unavailable }
        let entry = entries[scope]
        if entry?.isWritable != true {
            // Another surface (an editor) decides whether the scope writes.
            guard entry?.surfaces.count == 1, mayWrite() else { return .unavailable }
            installJournal(ReplicaSaveAdapter(store: store, scope: scope), for: scope)
        }
        let scheduler = entry?.scheduler ?? make()
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: interval) }
            await session.settle()
            guard !session.isClosed else { return .unavailable }
            switch await session.post(.mediaProps(props, expecting: slot), blockID: blockID) {
            case .applied:
                scheduler.schedule()
                scheduler.flush()
                return .committed
            case .refused:
                // The engine refuses a changed slot; the same slot is busy (a composition) or read-only.
                guard let current = await session.mediaLocation(blockID) else { return .unavailable }
                if current?.slot != slot { return .gone }
            case .stale: continue
            case nil, .failed, .invalidated, .composition: return .unavailable
            }
        }
        return .unavailable
    }

    /// Background: every debounced save is handed over now, then again once
    /// every message already posted was journaled.
    @discardableResult
    func drainAll() -> Task<Void, Never> {
        let entries = Array(entries.values)
        for entry in entries { entry.scheduler?.flush() }
        return Task {
            for entry in entries {
                // A command's result (which schedules the save) goes to its own surface.
                for surface in entry.surfaces { await surface.settle(maxRounds: 1) }
                entry.scheduler?.flush()
            }
        }
    }

    /// Closes every surface and replica whose scope matches (a sign-out or an
    /// account switch); opens still waiting return nil. The task ends once
    /// those replicas closed.
    @discardableResult
    func closeAll(where matches: (ReplicaScope) -> Bool = { _ in true }) -> Task<Void, Never> {
        var closed: [Task<Void, Never>] = []
        for (scope, entry) in entries where matches(scope) {
            entries[scope] = nil
            for surface in entry.surfaces { closed.append(surface.close()) }
            // An open still restoring or attaching finds its entry gone and returns nil.
            closed.append(retire(entry, scope: scope))
        }
        return Task {
            for task in closed { await task.value }
        }
    }

    private func release(_ session: NativeEditorSession, from entry: Entry, scope: ReplicaScope) -> Task<Void, Never> {
        entry.surfaces.removeAll { $0 === session }
        return closeIfUnused(entry, scope: scope) ?? Task {}
    }

    /// Closes the replica once nothing uses it.
    @discardableResult
    private func closeIfUnused(_ entry: Entry, scope: ReplicaScope) -> Task<Void, Never>? {
        guard entry.surfaces.isEmpty, entry.opening == 0 else { return nil }
        return retire(entry, scope: scope)
    }

    /// Posts the replica's close (once); the scope's next restore waits for it.
    private func retire(_ entry: Entry, scope: ReplicaScope) -> Task<Void, Never> {
        if let closed = entry.closed { return closed }
        if entries[scope] === entry { entries[scope] = nil }
        entry.live?.stop()
        let task = Task {
            guard let replica = try? await entry.replica.value else { return }
            replica.mailbox.post(.close)
            await replica.waitUntilClosed()
        }
        entry.closed = task
        closing[scope] = task
        return task
    }
}
