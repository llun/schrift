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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let displayEmoji = docIconDisplayText(emoji: emoji) {
                    Text(displayEmoji)
                        .font(.system(size: size * 0.7))
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: size * 0.55))
                        .foregroundStyle(DocsColor.brandFill)
                }
            }
            .frame(width: size, height: size)
            .background(tinted ? DocsColor.brandFillSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))

            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(DocsColor.brandFill)
                    .background(Circle().fill(DocsColor.surfacePage).frame(width: size * 0.4, height: size * 0.4))
                    .offset(x: size * 0.15, y: size * 0.15)
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
