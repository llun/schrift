import Foundation

/// Row enrichment resolved from a document's accesses. Absent for a document
/// whose accesses call hasn't landed (or failed) — the row then shows a
/// date-only subtitle and no avatars.
struct SharedRowEnrichment: Equatable {
    var sharedByName: String?
    var memberNames: [String]
}

/// Display names for a document's members, feeding the row's `AvatarGroup`.
/// Prefers full name, then short name, then email; drops entries with no
/// usable name so the avatar group never renders a blank initial.
func sharedMemberNames(accesses: [DocumentAccess]) -> [String] {
    accesses.compactMap { access in
        let name = access.user?.fullName ?? access.user?.shortName ?? access.user?.email
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}

/// The name shown as "Shared by …": the member whose user id equals the
/// document's `creator`. nil when the creator is unknown, not among the
/// accesses, or has no usable name — the row then falls back to a date-only
/// subtitle.
func sharedCreatorName(accesses: [DocumentAccess], creator: UUID?) -> String? {
    guard let creator, let match = accesses.first(where: { $0.user?.id == creator }) else { return nil }
    let name = match.user?.fullName ?? match.user?.shortName ?? match.user?.email
    guard let name, !name.isEmpty else { return nil }
    return name
}

/// Which faces a Shared row draws: the sharer leads the row, the rest trail as the
/// member group.
struct SharedRowFaces: Equatable {
    /// The name whose `Avatar` leads the row. nil ⇒ the sharer is unknown (accesses not
    /// loaded, failed, or offline), so the row keeps its `DocIcon` in the same slot.
    let leading: String?
    /// The names for the trailing `AvatarGroup`: every member except the leading person.
    let trailing: [String]
}

/// Splits the row's people into the leading avatar and the trailing group. The sharer
/// would otherwise appear twice (they are one of the document's members), so the first
/// matching member is dropped from the group; later duplicates are different people who
/// happen to share a display name and stay. A blank sharer name is treated as unknown.
func sharedRowFaces(sharedByName: String?, memberNames: [String]) -> SharedRowFaces {
    guard let sharedByName, !sharedByName.isEmpty else {
        return SharedRowFaces(leading: nil, trailing: memberNames)
    }
    var trailing = memberNames
    if let index = trailing.firstIndex(of: sharedByName) { trailing.remove(at: index) }
    return SharedRowFaces(leading: sharedByName, trailing: trailing)
}
