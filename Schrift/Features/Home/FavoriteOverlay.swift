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

/// The Recent section's rows: the recents feed minus whatever the Pinned section is already
/// rendering, so no document appears twice on Home.
///
/// **Why anything is needed.** Home fetches its two lists separately — `favorite_list/` for the
/// Pinned section and `listDocuments(isFavorite: nil, …)` for the feed — and the second is
/// deliberately *unfiltered*, so a pinned document is in both responses. Pinned wins, because it
/// is the section the user asked for; Recent is the residue.
///
/// **Keyed on membership, never on `isFavorite`.** The flag and the Pinned section can and do
/// disagree: `favorite_list/` is paginated and Home consumes only `.results`, so a favorite past
/// its first page is flagged `true` in the recents feed and simply absent from
/// `pinnedDocuments`. (A cold start can produce the same shape — `loadPinnedDocuments()` answers
/// `[]` for a key `DocumentCacheStore.setFavorite` declines to fabricate, while the recents cache
/// still carries flagged rows.) Filtering on the flag would hide such a document from *both*
/// sections; filtering on what Pinned actually renders can only ever move a row between them,
/// never take it off the screen — and that is the property worth having, because every id
/// removed here is drawn by the Pinned section in the same body pass.
///
/// **Why not fetch the feed with `isFavorite: false` instead.** Pinned documents would then be
/// absent from `fetchedRecentDocuments` and its cache, so an unpin — which only removes the row
/// from `pinnedDocuments` (see `applyFavoriteChange`) — would leave the document in no section
/// at all until the next successful fetch. Filtering at read time keeps the hand-back instant.
///
/// **Accepted residual: Recent is subtracted from, never topped up.** Home has no pagination —
/// both lists are page one — so a pinned document removed from Recent is not replaced by the
/// next unpinned one, and a user whose whole first page is pinned sees no Recent section while
/// their other documents sit on a page Home never requests. Fixing it properly means paging the
/// feed, which is a larger change than this one. Related and deliberate: Recent no longer holds
/// the pinned document edited two minutes ago, and `favorite_list/` states no ordering, so
/// Home's top row is no longer necessarily the most recently updated document.
func recentsExcludingPinned(recent: [Document], pinned: [Document]) -> [Document] {
    guard !pinned.isEmpty else { return recent }
    let pinnedIDs = Set(pinned.map(\.id))
    return recent.filter { !pinnedIDs.contains($0.id) }
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
