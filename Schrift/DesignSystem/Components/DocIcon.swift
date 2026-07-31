import SwiftUI

func docIconDisplayText(emoji: String?) -> String? {
    guard let emoji, !emoji.isEmpty else { return nil }
    return emoji
}

struct DocIcon: View {
    var emoji: String? = nil
    var size: CGFloat = 24
    var tinted: Bool = false
    var pinned: Bool = false

    /// The icon and its box scale together, so a document row stays
    /// proportionate to the title beside it at every text size. Scaling only
    /// the glyph would crop it against the fixed box.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var glyphSize: CGFloat { size * scale }
    private var box: CGFloat { tinted ? glyphSize + 14 : glyphSize }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let displayEmoji = docIconDisplayText(emoji: emoji) {
                    Text(displayEmoji)
                        .font(.system(size: glyphSize * 0.9))
                } else {
                    MaterialSymbol(.description, size: size)
                        .foregroundStyle(DocsColor.brandFill)
                }
            }
            .frame(width: box, height: box)
            .background(tinted ? DocsColor.brandFillSubtle : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: tinted ? DocsRadius.md : 0))

            if pinned {
                MaterialSymbol(.push_pin, size: 14, fill: true)
                    .foregroundStyle(DocsColor.brandFill)
                    .padding(1)
                    .background(Circle().fill(DocsColor.surfacePage))
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
