import Foundation

/// A move made on this device, held until a fetch agrees with it.
struct MoveOverride: Equatable {
    /// Nil when the document was promoted to the top level.
    var newParentID: UUID?
    /// The row to re-insert when a promotion outran the fetch. Nil when the mover had none, in
    /// which case a stale fetch simply costs the row until the next one.
    var row: Document?
}

/// A recents fetch folded together with moves made on this device since it was issued.
struct MoveOverlay: Equatable {
    var recent: [Document]
    /// The overrides this fetch already agrees with, so the caller can retire them.
    var confirmed: Set<UUID>
}

/// Fold moves made on this device into a recents fetch that predates them, and report which of
/// those the fetch has now confirmed.
///
/// **Why an override at all.** `load()` assigns its arrays wholesale, so a fetch issued before
/// a move resolves after it and puts the row back where it was — the same race the pin and
/// delete paths already handle, with the same answer: **filter, never bump `loadGeneration`**
/// (bumping is self-cancelling, and wedges `isLoading` true).
///
/// **Why these retire, unlike `deletedSinceLoad`.** That set may be kept forever because server
/// ids are never reused, so a deleted id can never name a live document again. Placement has no
/// such property: a document filed under a parent today can be moved back to the top level
/// tomorrow, from here or from the web. An override kept past the point the server agrees with
/// it would veto that return for the life of the process — the same failure
/// `applyFavoriteOverrides` documents for pins.
///
/// **Only the recents feed.** A move does not change what is pinned (a favorite is a per-user
/// annotation the server keeps across one) nor what is shared with you (that is decided by
/// access), so neither list is touched here.
func applyMoveOverrides(recent: [Document], overrides: [UUID: MoveOverride]) -> MoveOverlay {
    guard !overrides.isEmpty else { return MoveOverlay(recent: recent, confirmed: []) }

    var resolved = recent
    var confirmed: Set<UUID> = []

    for (documentID, override) in overrides {
        let fetchLists = recent.contains { $0.id == documentID }
        if override.newParentID == nil {
            // Promoted. The feed listing it is the server agreeing.
            if fetchLists {
                confirmed.insert(documentID)
            } else if let row = override.row, !resolved.contains(where: { $0.id == documentID }) {
                // The fetch predates the move and would otherwise drop the row that was just
                // put on screen. Front, as every other insert on this screen does.
                resolved.insert(row, at: 0)
            }
        } else {
            // Filed under a parent. Whether Home's unfiltered feed still lists a sub-page is
            // the server's answer to give — so the override is retired when the feed stops
            // listing it, and until then the row is held back rather than flickering in and
            // out on every fetch.
            if fetchLists {
                resolved.removeAll { $0.id == documentID }
            } else {
                confirmed.insert(documentID)
            }
        }
    }

    return MoveOverlay(recent: resolved, confirmed: confirmed)
}
