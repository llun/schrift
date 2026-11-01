import Foundation

/// A document title split into the emoji it leads with (if any) and the text that follows.
struct DocTitleParts: Equatable {
    let emoji: String?
    let title: String
}

/// Whether one grapheme cluster is an emoji a user typed to decorate a title.
///
/// `Unicode.Scalar.Properties.isEmoji` alone is too wide: digits, `#` and `*` are emoji
/// scalars (they start keycaps), so "2024 plan" would lose its year. A cluster counts when
/// its first scalar is drawn as an emoji by default, or when it asks for emoji presentation
/// with a variation selector (U+FE0F), which covers "❤️" and the keycap "1️⃣" but not a bare "1".
func docTitleCharacterIsEmoji(_ character: Character) -> Bool {
    guard let first = character.unicodeScalars.first else { return false }
    if first.properties.isEmojiPresentation { return true }
    return first.properties.isEmoji && character.unicodeScalars.contains { $0.value == 0xFE0F }
}

/// Splits a leading emoji off a title: "🚀 Release checklist" → ("🚀", "Release checklist").
///
/// A title that is *only* an emoji is left whole (there would be nothing left to display), as
/// is one with no leading emoji. Pure, so the Home and Search rows share one rule.
func docTitleParts(_ rawTitle: String?) -> DocTitleParts {
    let raw = rawTitle ?? ""
    guard let first = raw.first, docTitleCharacterIsEmoji(first) else {
        return DocTitleParts(emoji: nil, title: raw)
    }
    let rest = String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rest.isEmpty else { return DocTitleParts(emoji: nil, title: raw) }
    return DocTitleParts(emoji: String(first), title: rest)
}

/// The accent a document's tile is tinted with, chosen from the avatar palette by hashing the
/// document id. Stable across launches, devices and renames (the id never changes), so a
/// document keeps its colour; the lower-cased canonical string keeps it independent of how
/// the UUID happens to be formatted.
func docTileTint(for id: UUID) -> (light: UInt32, dark: UInt32) {
    avatarColorPalette[docTileTintIndex(for: id)]
}

func docTileTintIndex(for id: UUID) -> Int {
    avatarColorIndex(for: id.uuidString.lowercased())
}

/// How strongly the accent is laid over the page to make the tile's soft fill.
let docTileTintOpacity: Double = 0.16

/// A document's one-line excerpt for a row: runs of whitespace (including the newlines of a
/// multi-paragraph excerpt) collapse to single spaces, and a blank excerpt is `nil`.
func docRowExcerptText(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
}

/// How many lines a row's title may use. Stacked (accessibility) rows keep their three; a row
/// with a second line of detail lets the title wrap to two so similar names stay distinguishable.
func docRowTitleLineLimit(hasDetailLine: Bool, isStacked: Bool) -> Int {
    if isStacked { return 3 }
    return hasDetailLine ? 2 : 1
}
