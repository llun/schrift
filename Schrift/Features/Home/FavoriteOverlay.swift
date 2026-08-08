import Foundation

/// A list fetch folded together with pins made on this device since it was issued.
struct FavoriteOverlay: Equatable {
    var pinned: [Document]
    var recent: [Document]
    /// The overrides this fetch already agrees with, so the caller can retire them.
    var confirmed: Set<UUID>
}

/// Set `isFavorite` on a document wherever it appears in a list.
func applyingFavoriteFlag(_ documents: [Document], documentID: UUID, isFavorite: Bool) -> [Document] {
    documents.map { document in
        guard document.id == documentID else { return document }
        var updated = document
        updated.isFavorite = isFavorite
        return updated
    }
}

/// Fold pins and unpins made on this device into a list fetch that predates them, and report
/// which of those overrides the fetch has now confirmed.
///
/// **Why an override at all.** `load()` assigns both arrays wholesale from its fetch, so a
/// fetch issued *before* a pin resolves *after* it and silently reverts it — visibly, since
/// the whole Pinned section appears or disappears. This is the same race the deletion path
/// already handles, and it has the same answer: **filter, never bump `loadGeneration`.**
/// Bumping is self-cancelling — `load()` captures its generation, kicks `recoverDrafts()`,
/// then awaits, so a mutation landing in that window cancels the very load it fired from,
/// leaving the list stale, `isOffline` unset and `isLoading` stuck true because the guarded
/// early return skips the line that clears it.
///
/// **Why this differs from `deletedSinceLoad`, which is never cleared.** That set is safe to
/// keep forever because server ids are never reused, so a deleted id can never name a live
/// document again. A favorite has no such property: it is a bit that can be flipped back from
/// anywhere. An override kept past the point the server agrees with it would veto the *next*
/// change made from another client for the life of the process — unpin on the web, and the
/// app would keep re-pinning it on every fetch. So the overlay reports `confirmed`, and the
/// caller retires those inside the winning generation's guard.
///
/// **Applied to membership, not only to the flag.** A just-pinned document is simply *absent*
/// from a `favorite_list/` response issued before the POST, so flipping flags alone would
/// leave the Pinned section without it.
func applyFavoriteOverrides(
    pinned: [Document],
    recent: [Document],
    overrides: [UUID: Bool]
) -> FavoriteOverlay {
    guard !overrides.isEmpty else {
        return FavoriteOverlay(pinned: pinned, recent: recent, confirmed: [])
    }

    var resolvedPinned = pinned
    var resolvedRecent = recent
    var confirmed: Set<UUID> = []

    for (documentID, isFavorite) in overrides {
        let serverSaysPinned = pinned.contains { $0.id == documentID }
        if serverSaysPinned == isFavorite {
            // The fetch already reflects this pin; the override has done its job.
            confirmed.insert(documentID)
            continue
        }
        if isFavorite {
            // Pinned here, absent from a `favorite_list/` that predates the POST. Prefer a
            // copy from the recents feed so the row carries the server's own metadata;
            // failing that there is nothing to insert, and the next fetch will bring it.
            if let source = recent.first(where: { $0.id == documentID }) {
                var copy = source
                copy.isFavorite = true
                // At the front: "most recently pinned first" is the only ordering this screen
                // can know — `favorite_list/` states none — and it matches
                // `onDocumentMigrated`'s own `insert(at: 0)`.
                resolvedPinned.insert(copy, at: 0)
            }
        } else {
            resolvedPinned.removeAll { $0.id == documentID }
        }
        resolvedRecent = applyingFavoriteFlag(resolvedRecent, documentID: documentID, isFavorite: isFavorite)
    }

    return FavoriteOverlay(pinned: resolvedPinned, recent: resolvedRecent, confirmed: confirmed)
}
