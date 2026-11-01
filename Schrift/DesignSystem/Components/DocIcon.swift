import SwiftUI

func docIconDisplayText(emoji: String?) -> String? {
    guard let emoji, !emoji.isEmpty else { return nil }
    return emoji
}

struct DocIcon: View {
    @Environment(\.docsTheme) private var theme
    var emoji: String? = nil
    var size: CGFloat = 24
    var tinted: Bool = false
    var pinned: Bool = false
    /// When set (and `tinted`), the tile is a soft fill of the accent this document id hashes to
    /// (`docTileTint(for:)`) instead of the single brand tint, and the page glyph takes the accent.
    var tintSeed: UUID? = nil

    /// The icon and its box scale together, so a document row stays
    /// proportionate to the title beside it at every text size. Scaling only
    /// the glyph would crop it against the fixed box.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var glyphSize: CGFloat { size * scale }
    private var box: CGFloat { tinted ? glyphSize + 14 : glyphSize }
    private var seedAccent: (light: UInt32, dark: UInt32)? { tintSeed.map { docTileTint(for: $0) } }
    private var accentColor: Color? {
        seedAccent.map { Color(lightHex: $0.light, darkHex: $0.dark) }
    }
    private var tileFill: Color {
        guard tinted else { return Color.clear }
        if let accent = seedAccent {
            return Color(lightHex: accent.light, darkHex: accent.dark, opacity: docTileTintOpacity)
        }
        return theme.colors.brandFillSubtle
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let displayEmoji = docIconDisplayText(emoji: emoji) {
                    Text(displayEmoji)
                        .font(.system(size: glyphSize * 0.9))
                } else {
                    // Sized from this view's own scaled value with the symbol's
                    // scaling off: two independent `ScaledMetric`s need not agree
                    // at every category (scaling is not a flat multiple at
                    // accessibility sizes), and the box is sized from ours.
                    MaterialSymbol(.description, size: glyphSize, scales: false)
                        .foregroundStyle(accentColor ?? theme.colors.brandFill)
                }
            }
            .frame(width: box, height: box)
            .background(tileFill)
            .clipShape(RoundedRectangle(cornerRadius: tinted ? DocsRadius.md : 0))

            if pinned {
                MaterialSymbol(.push_pin, size: 14, fill: true)
                    .foregroundStyle(theme.colors.brandFill)
                    .padding(1)
                    .background(Circle().fill(theme.colors.surfacePage))
                    .offset(x: 4, y: 4)
            }
        }
        // Decorative in every usage — the adjacent title carries the identity.
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceSM) {
        DocIcon(emoji: "📄")
        DocIcon(emoji: nil, tinted: true)
        DocIcon(emoji: "📌", pinned: true)
    }
    .padding()
}

/// The per-document tint: tiles for a run of ids, alternating the page glyph and an emoji.
#Preview("Tinted tiles") {
    HStack(spacing: DocsSpacing.spaceSM) {
        ForEach(0..<8, id: \.self) { index in
            DocIcon(emoji: index % 2 == 0 ? nil : "📝", tinted: true, tintSeed: previewUUID(index))
        }
    }
    .padding()
}

private func previewUUID(_ index: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)") ?? UUID()
}
