import Foundation

/// The checklist items that were just ticked while "Hide completed" is on and have not left
/// the reading list yet.
///
/// A tick hides its row, but removing the row in the same transaction as the tick animates it
/// out with its *last* inputs — an empty checkbox sliding away, so the person never sees the
/// tick land. The tick therefore happens in two phases: the row is ticked and kept on screen
/// here (it renders checked and the checkbox pulses), and after
/// `DocsMotion.checklistSettleDelay(reduceMotion:)` the view finishes it inside the collapse
/// animation, so the row leaves already ticked.
///
/// Pure value logic, so the edge cases are unit-tested rather than left to timing:
/// - each tick gets a fresh token, and `finish` only acts on the token it was handed, so a
///   pending finish from an earlier tick can never cut a re-tick's settle short;
/// - unticking during the settle (`cancel`) drops the id at once, so the row simply stays;
/// - the document changing under it (`prune`) drops ids whose block went away or is no
///   longer ticked.
///
/// `ChecklistReadingPresentation` keeps a settling item on screen together with everything it
/// would hide along with it, so the whole group collapses as one when the settle finishes.
struct ChecklistSettling: Equatable {
    private var tokens: [UUID: Int] = [:]
    private var lastToken = 0

    /// The items still on screen although ticked.
    var ids: Set<UUID> { Set(tokens.keys) }

    var isEmpty: Bool { tokens.isEmpty }

    /// Starts (or restarts) the settle for an item just ticked. Returns the token to `finish`
    /// it with.
    mutating func begin(_ id: UUID) -> Int {
        lastToken += 1
        tokens[id] = lastToken
        return lastToken
    }

    /// The item was unticked (or its settle is otherwise abandoned): it stops settling now.
    mutating func cancel(_ id: UUID) {
        tokens[id] = nil
    }

    /// Ends the settle that `token` started, letting the hidden row leave. Returns whether it
    /// did — `false` when the item was unticked, re-ticked (a newer token) or pruned since.
    @discardableResult
    mutating func finish(_ id: UUID, token: Int) -> Bool {
        guard tokens[id] == token else { return false }
        tokens[id] = nil
        return true
    }

    /// Keeps only the items that are still in `blocks` and still ticked. Callers on a hot path
    /// check `isEmpty` first, so an observed owner is not written to for nothing.
    mutating func prune(keeping blocks: [EditorBlock]) {
        guard !tokens.isEmpty else { return }
        let ticked = Set(
            blocks.lazy.filter { if case .checklistItem(checked: true) = $0.kind { true } else { false } }.map(\.id))
        tokens = tokens.filter { ticked.contains($0.key) }
    }

    mutating func removeAll() {
        tokens.removeAll()
    }
}
