import Foundation

/// App-scoped pin intent and replay. Raw list caches remain server snapshots while work is
/// pending. Every surface reads the same scoped overlay, including after a cold launch.
@MainActor
@Observable
final class DocumentPinCoordinator {
    private let client: DocsAPIClient
    private let store: PendingDocumentPinStore
    private let cache: DocumentCacheStore
    private let serverOrigin: String
    private let signedInUser: SignedInUserStore
    private let userDefaults: UserDefaults
    private var pending: [String: PendingDocumentPin]
    private var settled: [String: Settled] = [:]
    private var failures: Set<String> = []
    private(set) var isSyncing = false
    private var needsAnotherPass = false
    private(set) var revision = 0

    private struct Settled {
        let intent: PendingDocumentPin
        let revision: Int
        /// Fresh pages own membership; older pages still need the observed bit.
        var membershipReadBoundary: Int? = nil
    }

    init(
        client: DocsAPIClient, store: PendingDocumentPinStore, cache: DocumentCacheStore,
        serverOrigin: String, signedInUser: SignedInUserStore, userDefaults: UserDefaults
    ) {
        self.client = client
        self.store = store
        self.cache = cache
        self.serverOrigin = serverOrigin
        self.signedInUser = signedInUser
        self.userDefaults = userDefaults
        pending = Dictionary(store.allPins().map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        for intent in store.allSettled() {
            settled[intent.key] = Settled(
                intent: intent, revision: 0,
                membershipReadBoundary: intent.preservesCachedMembership == true ? -1 : nil)
            if intent.wasRejected == true { failures.insert(intent.key) }
        }
    }

    @discardableResult
    func queue(documentID: UUID, isPinned: Bool, row: Document?, ownerUserID: UUID) -> Bool {
        guard !serverOrigin.isEmpty else { return false }
        let key = key(documentID, ownerUserID)
        let intent = PendingDocumentPin(
            documentID: documentID, serverOrigin: serverOrigin, ownerUserID: ownerUserID,
            isPinned: isPinned,
            previousValue: pending[key]?.previousValue ?? settled[key]?.intent.isPinned ?? row?.isFavorite ?? !isPinned,
            row: row ?? pending[key]?.row ?? settled[key]?.intent.row,
            intentID: UUID(), requestedAt: Date(),
            allowsRecentFallback: pending[key]?.allowsRecentFallback ?? settled[key]?.intent.allowsRecentFallback)
        // Write ahead of both the observable state and the request.
        guard store.save(intent) else { return false }
        pending[key] = intent
        failures.remove(key)
        revision += 1
        if isSyncing { needsAnotherPass = true }
        return true
    }

    func value(for documentID: UUID, fallback: Bool, ownerUserID: UUID?, fetchedAt: Int) -> Bool {
        overrides(ownerUserID: ownerUserID, fetchedAt: fetchedAt).first { $0.documentID == documentID }?.isPinned
            ?? fallback
    }

    func desiredValue(for documentID: UUID, fallback: Bool, ownerUserID: UUID?) -> Bool {
        guard let ownerUserID else { return fallback }
        return pending[key(documentID, ownerUserID)]?.isPinned ?? fallback
    }

    func failure(for documentID: UUID, ownerUserID: UUID?) -> L10nKey? {
        _ = revision
        guard let ownerUserID, failures.contains(key(documentID, ownerUserID)) else { return nil }
        return .options_error_toggle_favorite
    }

    func clearFailures() { failures.removeAll() }

    /// The identity store is not observable; invalidate dependent surfaces after learning
    /// a new account, even when a transport failure leaves all pin records untouched.
    func sessionIdentityDidChange() { revision += 1 }

    var hasFailure: Bool {
        _ = revision
        guard let owner = signedInUser.userID else { return false }
        return failures.contains { $0.hasPrefix("\(serverOrigin)|\(owner.uuidString)|") }
    }

    /// Pending intent always wins, even if a fetch happens to agree. Settled intent wins
    /// only over reads issued before settlement; later reads may reflect edits on the web.
    func resolve(
        pinned: [Document], recent: [Document], ownerUserID: UUID?, fetchedAt: Int, includePending: Bool = true
    ) -> FavoriteOverlay {
        let intents = overrides(ownerUserID: ownerUserID, fetchedAt: fetchedAt, includePending: includePending)
        let membershipIntents = intents.filter {
            pending[$0.key] != nil || (settled[$0.key]?.membershipReadBoundary.map { fetchedAt < $0 } ?? true)
        }
        var result = applyFavoriteOverrides(
            pinned: pinned, recent: recent,
            overrides: Dictionary(
                membershipIntents.map { ($0.documentID, $0.isPinned) }, uniquingKeysWith: { _, b in b }))
        for intent in membershipIntents {
            // Metadata may come from Search or an editor's cached subpage rather than the
            // root feed. Keep that real row available through an offline pin and unpin.
            if intent.isPinned, !result.pinned.contains(where: { $0.id == intent.documentID }), var row = intent.row {
                row.isFavorite = true
                result.pinned.insert(row, at: 0)
            }
            if !intent.isPinned, intent.allowsRecentFallback != false,
                !result.recent.contains(where: { $0.id == intent.documentID }),
                var row = recent.first(where: { $0.id == intent.documentID })
                    ?? pinned.first(where: { $0.id == intent.documentID }) ?? intent.row
            {
                row.isFavorite = false
                result.recent.insert(row, at: 0)
            }
        }
        for intent in intents {
            result.pinned = applyingFavoriteFlag(
                result.pinned, documentID: intent.documentID, isFavorite: intent.isPinned)
            result.recent = applyingFavoriteFlag(
                result.recent, documentID: intent.documentID, isFavorite: intent.isPinned)
        }
        return result
    }

    func applyingFlags(_ rows: [Document], ownerUserID: UUID?, fetchedAt: Int, includePending: Bool = true)
        -> [Document]
    {
        overrides(ownerUserID: ownerUserID, fetchedAt: fetchedAt, includePending: includePending).reduce(rows) {
            applyingFavoriteFlag($0, documentID: $1.documentID, isFavorite: $1.isPinned)
        }
    }

    private func overrides(ownerUserID: UUID?, fetchedAt: Int, includePending: Bool = true) -> [PendingDocumentPin] {
        // Register even when identity is unknown and no dictionary has been read yet.
        _ = revision
        guard let ownerUserID else { return [] }
        let queued = pending.values.filter {
            includePending && $0.serverOrigin == serverOrigin && $0.ownerUserID == ownerUserID
        }
        let completed = settled.values.filter {
            $0.intent.serverOrigin == serverOrigin && $0.intent.ownerUserID == ownerUserID
                && $0.revision > fetchedAt && (!includePending || pending[$0.intent.key] == nil)
        }.map(\.intent)
        return (Array(queued) + completed).sorted { $0.key < $1.key }
    }

    private func key(_ documentID: UUID, _ ownerUserID: UUID) -> String {
        PendingDocumentPin.key(documentID: documentID, serverOrigin: serverOrigin, ownerUserID: ownerUserID)
    }

    /// Called from the existing launch/foreground/reconnect funnel and after an online
    /// toggle. Overlapping triggers coalesce; every await rechecks identity and intent.
    func sync(isBlocked: @MainActor (UUID) -> Bool) async {
        guard !userDefaults.bool(forKey: "schrift.workOffline") else { return }
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsAnotherPass = false
            guard let owner = signedInUser.userID else { return }
            let candidates = pending.values.filter {
                $0.serverOrigin == serverOrigin && $0.ownerUserID == owner && !isBlocked($0.documentID)
            }.sorted { $0.key < $1.key }
            guard !candidates.isEmpty else { return }
            guard let verifiedOwner = try? await client.currentUser().id,
                verifiedOwner == owner, signedInUser.userID == owner
            else { return }
            for candidate in candidates {
                guard signedInUser.userID == owner, !userDefaults.bool(forKey: "schrift.workOffline") else { return }
                guard let sent = pending[candidate.key], !isBlocked(sent.documentID) else { continue }
                let failure: DocsAPIError?
                do {
                    try await client.setFavorite(documentID: sent.documentID, isFavorite: sent.isPinned)
                    failure = nil
                } catch {
                    failure = (error as? DocsAPIError) ?? .network("Pin request failed")
                }
                guard signedInUser.userID == owner, let latest = pending[sent.key], !isBlocked(sent.documentID) else {
                    continue
                }
                if let failure, !terminalPinFailure(failure) {
                    // Authentication/transport/429/5xx are still owed. A reconnect trigger
                    // received during the request gets its own pass instead of being lost.
                    continue
                }
                if latest.intentID != sent.intentID {
                    if failure == nil {
                        var updated = latest
                        updated.previousValue = sent.isPinned
                        if store.save(updated) { pending[updated.key] = updated }
                    }
                    needsAnotherPass = true
                    continue
                }
                // Placement metadata may have changed during the request without a new toggle.
                var completed = latest
                if failure != nil {
                    completed.isPinned = sent.previousValue
                    completed.wasRejected = true
                    failures.insert(sent.key)
                }
                guard store.saveSettled(completed) else { continue }
                revision += 1
                settled[sent.key] = Settled(intent: completed, revision: revision)
                // Write-through before removing the durable intent: a torn completion
                // replays an idempotent POST/DELETE rather than forgetting the local result.
                cache.setFavorite(sent.documentID, isFavorite: completed.isPinned, document: completed.row)
                store.remove(sent)
                pending[sent.key] = nil
            }
        } while needsAnotherPass
    }

    /// A fresh flag from Search/Shared is authoritative for older surfaces and the
    /// next toggle's rollback baseline. It must not consume unsent intent or a newer
    /// observation, nor alter membership of favorites pages issued at the same revision.
    func didReadFlags(_ rows: [Document], ownerUserID: UUID?, fetchedAt: Int) {
        guard let ownerUserID, signedInUser.userID == ownerUserID else { return }
        let fresh = settled.values.filter {
            $0.intent.ownerUserID == ownerUserID && $0.intent.serverOrigin == serverOrigin
                && $0.revision <= fetchedAt && pending[$0.intent.key] == nil
        }
        for completed in fresh {
            guard let row = rows.first(where: { $0.id == completed.intent.documentID }),
                row.isFavorite != completed.intent.isPinned
            else { continue }
            var observed = completed.intent
            observed.isPinned = row.isFavorite
            observed.row = row
            observed.preservesCachedMembership = nil
            // Home's raw caches may still be old. This newer server bit protects membership
            // across relaunch until Home has cached a subsequent answer of its own.
            guard store.saveSettled(observed) else { continue }
            revision += 1
            settled[observed.key] = Settled(
                intent: observed, revision: revision,
                membershipReadBoundary: fetchedAt)
        }
    }

    /// Only after the raw caches have been written by a fetch issued after settlement.
    /// Release their membership protection, retaining scoped flags for older subpage metadata
    /// and pagination gaps. In-memory revisions still protect older reads on other screens.
    func didCacheFreshLists(pinned: [Document], recent: [Document], ownerUserID: UUID?, fetchedAt: Int) {
        guard let ownerUserID, signedInUser.userID == ownerUserID else { return }
        let fresh = settled.values.filter {
            $0.intent.ownerUserID == ownerUserID && $0.intent.serverOrigin == serverOrigin
                && $0.revision <= fetchedAt && pending[$0.intent.key] == nil
        }
        for completed in fresh {
            let pinnedRow = pinned.first { $0.id == completed.intent.documentID }
            let recentRow = recent.first { $0.id == completed.intent.documentID }
            var observed = completed.intent
            // Favorites membership proves true. Recent metadata can prove either bit;
            // absence from two paginated first pages proves neither.
            observed.isPinned = pinnedRow != nil ? true : (recentRow?.isFavorite ?? observed.isPinned)
            observed.row = pinnedRow ?? recentRow ?? observed.row
            observed.preservesCachedMembership = true
            guard store.saveSettled(observed) else { continue }
            revision += 1
            settled[observed.key] = Settled(
                intent: observed, revision: revision, membershipReadBoundary: fetchedAt)
        }
    }

    /// Placement is independent of pin state. A landed filing must not be undone by
    /// the metadata fallback of an outstanding unpin; real future feed rows still win.
    func documentMoved(documentID: UUID, newParentID: UUID?) {
        for key in Array(pending.keys) {
            guard var intent = pending[key], intent.documentID == documentID,
                intent.serverOrigin == serverOrigin
            else { continue }
            intent.allowsRecentFallback = newParentID == nil
            if store.save(intent) { pending[key] = intent }
        }
        for key in Array(settled.keys) {
            guard var completed = settled[key], completed.intent.documentID == documentID,
                completed.intent.serverOrigin == serverOrigin
            else { continue }
            var updated = completed.intent
            updated.allowsRecentFallback = newParentID == nil
            guard store.saveSettled(updated) else { continue }
            completed = Settled(
                intent: updated, revision: completed.revision,
                membershipReadBoundary: completed.membershipReadBoundary)
            settled[key] = completed
        }
        revision += 1
    }

    /// A completed deletion supersedes this session's pin. A queued deletion merely holds
    /// it, so undo can still replay the user's original pin intent.
    func remove(documentID: UUID) {
        let keys = pending.values.filter { $0.documentID == documentID && $0.serverOrigin == serverOrigin }.map(\.key)
        for key in keys {
            if let intent = pending[key] { store.remove(intent) }
            pending[key] = nil
        }
        for completed in settled.values
        where completed.intent.documentID == documentID && completed.intent.serverOrigin == serverOrigin {
            store.removeSettled(completed.intent)
        }
        settled = settled.filter {
            $0.value.intent.documentID != documentID || $0.value.intent.serverOrigin != serverOrigin
        }
        revision += 1
    }
}

private func terminalPinFailure(_ error: DocsAPIError) -> Bool {
    switch error {
    case .forbidden, .notFound, .routeNotFound: true
    case .server(let code): (400..<500).contains(code)
    case .sessionExpired, .rateLimited, .network, .decoding: false
    }
}
