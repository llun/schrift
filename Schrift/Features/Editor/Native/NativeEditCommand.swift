import Foundation

/// One prevalidated command in replica UTF-16 coordinates. Ordinary typing
/// replaces a block-relative range; Return and boundary Backspace are
/// structural and carry no replacement text.
struct NativeEditCommand: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case replace(range: Range<Int>, replacement: String)
        /// Return at `offset`: a split whose new block takes `newID`, or an
        /// empty list item's reset to a paragraph (no block, `newID` unused).
        case split(offset: Int, newID: String)
        /// Backspace at `blockID`'s start: a paragraph joins the block above;
        /// a heading or list item resets to a paragraph.
        case join
    }

    let id: UUID
    let baseRevision: UInt64
    let blockID: String
    let kind: Kind

    init(id: UUID, baseRevision: UInt64, blockID: String, kind: Kind) {
        self.id = id
        self.baseRevision = baseRevision
        self.blockID = blockID
        self.kind = kind
    }

    /// The ordinary-typing spelling.
    init(id: UUID, baseRevision: UInt64, blockID: String, range: Range<Int>, replacement: String) {
        self.init(
            id: id, baseRevision: baseRevision, blockID: blockID,
            kind: .replace(range: range, replacement: replacement))
    }

    /// The inserted text for an ordinary command; empty for a structural one.
    var replacement: String {
        if case .replace(_, let replacement) = kind { return replacement }
        return ""
    }
}

/// One authoritative patch emitted for a command. Cleanup may emit additional
/// patches; origin alone cannot identify an echo or a cleanup repair.
struct NativePatchStamp: Equatable, Sendable {
    let commandID: UUID
    let baseRevision: UInt64
    let emission: Int
}
