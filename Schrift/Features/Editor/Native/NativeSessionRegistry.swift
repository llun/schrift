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
