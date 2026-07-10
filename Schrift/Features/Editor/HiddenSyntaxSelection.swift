import Foundation

/// Caret rules for a text view whose markdown syntax is drawn at zero width.
///
/// The syntax characters stay in the buffer — that is what keeps every offset in
/// the editor a *source* offset and spares the whole caret subsystem an
/// offset map — so the caret can address positions the user cannot see. These
/// two pure functions keep it on characters that exist visually.
///
/// All offsets are UTF-16, into the block's markdown source: the same
/// coordinates `UITextView.selectedRange` and `EditorViewModel.selection` use.
/// `hidden` is `InlineMarkdown.layout(of:).syntax`, which is maximal (adjacent
/// runs are already merged, being the complement of the visible spans) — but
/// neither function relies on that.

/// True when `offset` sits strictly between the ends of `range`. The ends
/// themselves are legitimate caret positions: they coincide visually with the
/// edge of the neighbouring content.
private func isInterior(_ offset: Int, of range: NSRange) -> Bool {
    offset > range.location && offset < range.location + range.length
}

/// Moves a selection off the invisible characters.
///
/// A collapsed caret snaps to the nearer edge of the hidden run it landed
/// inside (ties resolve upward). A non-empty selection expands outward, so a
/// hidden run is never bisected — the user cannot select half of a URL and cut
/// a link into two fragments that no longer parse as one.
func snappedSelection(_ selection: NSRange, hidden: [NSRange]) -> NSRange {
    guard !hidden.isEmpty else { return selection }

    if selection.length == 0 {
        return NSRange(location: snappedCaret(selection.location, hidden: hidden), length: 0)
    }

    var lower = selection.location
    var upper = selection.location + selection.length
    if let range = hidden.first(where: { isInterior(lower, of: $0) }) {
        lower = range.location
    }
    if let range = hidden.first(where: { isInterior(upper, of: $0) }) {
        upper = range.location + range.length
    }
    return NSRange(location: lower, length: upper - lower)
}

private func snappedCaret(_ offset: Int, hidden: [NSRange]) -> Int {
    guard let range = hidden.first(where: { isInterior(offset, of: $0) }) else { return offset }
    let upper = range.location + range.length
    return (offset - range.location) < (upper - offset) ? range.location : upper
}

/// Where the caret must sit before a backspace, so the keystroke deletes a
/// character the user can actually see.
///
/// When the character behind the caret is hidden, the caret first skips back
/// over the whole hidden run. Backspace at the end of `[Review](url)` therefore
/// deletes the `w` of the label, never the lone `)` — which would break the
/// link's syntax and make its URL spring into view.
///
/// There is deliberately no atomic "delete the whole link" rule. Reducing a
/// label to nothing yields `[](url)`, which stops parsing as a link and simply
/// reveals itself: the buffer is always exactly the markdown that will be
/// saved, so no edit can silently destroy content.
///
/// Loops rather than hopping once, so it is correct even for a `hidden` list
/// whose adjacent runs have not been merged.
func caretBeforeBackspace(from caret: Int, hidden: [NSRange]) -> Int {
    var caret = caret
    while caret > 0, let range = hidden.first(where: { NSLocationInRange(caret - 1, $0) }) {
        caret = range.location
    }
    return caret
}
