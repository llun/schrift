import Foundation

/// A move made on this device, held only for as long as a fetch might not know about it.
struct MoveOverride: Equatable {
    /// Nil when the document was promoted to the top level.
    var newParentID: UUID?
    /// The row to re-insert when a promotion outran the fetch. Nil when the mover had none, in
    /// which case a stale fetch simply costs the row until the next one.
    var row: Document?
    /// The list generation current when the move landed. Every fetch issued **after** this one
    /// already carries the move's outcome, so it retires the override — see
    /// `applyMoveOverrides`.
    var generation: Int
}

/// A recents fetch folded together with moves made on this device since it was issued.
struct MoveOverlay: Equatable {
    var recent: [Document]
    /// The overrides this fetch supersedes, so the caller can retire them.
    var confirmed: Set<UUID>
}

/// Fold moves made on this device into a recents fetch that predates them, and report which of
/// those the fetch has superseded.
///
/// **Why an override at all.** `load()` assigns its arrays wholesale, so a fetch issued before
/// a move resolves after it and puts the row back where it was — the same race the pin and
/// delete paths already handle, with the same answer: **filter, never bump `loadGeneration`**
/// (bumping is self-cancelling, and wedges `isLoading` true).
///
/// **Retirement is keyed to fetch ordering, not to what the fetch says.** This is the one place
/// the pin overlay's shape cannot be copied. A pin is *directly observable* — it either is or
/// is not in `favorite_list/` — so `applyFavoriteOverrides` can retire on agreement. Placement
/// is **not** observable here: `Document` carries no parent id, and Home's feed is fetched
/// without a parent filter, so whether it lists sub-pages is the server's answer to give and
/// not something this screen may assume. Retiring on content therefore reads an ambiguous
/// signal as proof, and wedges in both directions:
///
///  - a document filed under a parent, on a server whose feed *does* list sub-pages, would be
///    stripped from the array **and the persisted cache** on every load, for ever, and a later
///    move back to the top level made from the web would be vetoed for the life of the process
///    — precisely the failure retirement exists to prevent;
///  - a document promoted here and then **deleted** looks exactly like "the fetch does not list
///    it yet", so the promotion branch would go on re-inserting its stored row into Home and
///    into the recents cache on every load, resurrecting a document that no longer exists. That
///    one is not even caught by `deletedSinceLoad`, because the row comes from the override
///    rather than from the fetch it filters.
///
/// The generation answers it exactly, and with no ambiguity: an override exists to protect
/// fetches that were **already in flight** when the move landed. A fetch issued afterwards has
/// asked the server since, so whatever it returns *is* the truth — apply nothing, and retire.
func applyMoveOverrides(
    recent: [Document], overrides: [UUID: MoveOverride], generation: Int
) -> MoveOverlay {
    guard !overrides.isEmpty else { return MoveOverlay(recent: recent, confirmed: []) }

    var resolved = recent
    var confirmed: Set<UUID> = []

    for (documentID, override) in overrides {
        guard generation <= override.generation else {
            // Issued after the move: this fetch knows better than the override does.
            confirmed.insert(documentID)
            continue
        }
        if override.newParentID == nil {
            if let row = override.row, !resolved.contains(where: { $0.id == documentID }) {
                // The fetch predates the promotion and would otherwise drop the row that was
                // just put on screen. Front, as every other insert on this screen does.
                resolved.insert(row, at: 0)
            }
        } else {
            resolved.removeAll { $0.id == documentID }
        }
    }

    return MoveOverlay(recent: resolved, confirmed: confirmed)
}
