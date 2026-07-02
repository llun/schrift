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

    private var box: CGFloat { tinted ? size + 14 : size }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let displayEmoji = docIconDisplayText(emoji: emoji) {
                    Text(displayEmoji)
                        .font(.system(size: size * 0.9))
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: size))
                        .foregroundStyle(DocsColor.brandFill)
                }
            }
            .frame(width: box, height: box)
            .background(tinted ? DocsColor.brandFillSubtle : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: tinted ? DocsRadius.md : 0))

            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DocsColor.brandFill)
                    .padding(1)
                    .background(Circle().fill(DocsColor.surfacePage))
                    .offset(x: 4, y: 4)
            }
        }
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
