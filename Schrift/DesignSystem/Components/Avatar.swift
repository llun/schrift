import SwiftUI

/// The exact `ACCENTS` order the design system's `Avatar` hashes into, so a
/// given name maps to the same accent color as the reference prototype.
let avatarColorPalette: [UInt32] = [
    DocsColorHex.accentBlue1, DocsColorHex.accentGreen, DocsColorHex.accentOrange,
    DocsColorHex.accentPurple, DocsColorHex.accentPink, DocsColorHex.accentBlue2,
    DocsColorHex.brandFill, DocsColorHex.accentBrown,
]

func avatarInitials(for name: String) -> String {
    let parts = name.split(separator: " ").filter { !$0.isEmpty }
    guard let first = parts.first?.first else { return "?" }
    if parts.count > 1, let last = parts[parts.count - 1].first {
        return (String(first) + String(last)).uppercased()
    }
    return String(first).uppercased()
}

func avatarColorHex(for name: String) -> UInt32 {
    // Mirror the prototype: h = (h * 31 + charCode) >>> 0, index = h % count.
    var hash: UInt32 = 0
    for scalar in name.unicodeScalars {
        hash = hash &* 31 &+ scalar.value
    }
    return avatarColorPalette[Int(hash % UInt32(avatarColorPalette.count))]
}

struct Avatar: View {
    let name: String
    var imageURL: URL? = nil
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsView
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Decorative: an adjacent name label carries the identity in every use.
        .accessibilityHidden(true)
    }

    private var initialsView: some View {
        Circle()
            .fill(Color(hex: avatarColorHex(for: name)))
            .overlay(
                Text(avatarInitials(for: name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceSM) {
        Avatar(name: "Camille Moreau")
        Avatar(name: "Alfredo Levin", size: 48)
        Avatar(name: "")
    }
    .padding()
}
