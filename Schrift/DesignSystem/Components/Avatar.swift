import SwiftUI

/// The exact `ACCENTS` order the design system's `Avatar` hashes into, so a
/// given name maps to the same accent color as the reference prototype. Each
/// entry pairs its light hex with its dark counterpart: the accent hues are
/// identical in dark, but `brandFill` differs, so the background must render
/// through `Color(lightHex:darkHex:)` to stay adaptive.
let avatarColorPalette: [(light: UInt32, dark: UInt32)] = [
    (DocsColorHex.accentBlue1, DocsColorHexDark.accentBlue1),
    (DocsColorHex.accentGreen, DocsColorHexDark.accentGreen),
    (DocsColorHex.accentOrange, DocsColorHexDark.accentOrange),
    (DocsColorHex.accentPurple, DocsColorHexDark.accentPurple),
    (DocsColorHex.accentPink, DocsColorHexDark.accentPink),
    (DocsColorHex.accentBlue2, DocsColorHexDark.accentBlue2),
    (DocsColorHex.brandFill, DocsColorHexDark.brandFill),
    (DocsColorHex.accentBrown, DocsColorHexDark.accentBrown),
]

func avatarInitials(for name: String) -> String {
    let parts = name.split(separator: " ").filter { !$0.isEmpty }
    guard let first = parts.first?.first else { return "?" }
    if parts.count > 1, let last = parts[parts.count - 1].first {
        return (String(first) + String(last)).uppercased()
    }
    return String(first).uppercased()
}

func avatarColorHexPair(for name: String) -> (light: UInt32, dark: UInt32) {
    // Mirror the prototype: h = (h * 31 + charCode) >>> 0, index = h % count.
    var hash: UInt32 = 0
    for scalar in name.unicodeScalars {
        hash = hash &* 31 &+ scalar.value
    }
    return avatarColorPalette[Int(hash % UInt32(avatarColorPalette.count))]
}

/// The light hex for a name — the value the light-mode appearance keys off, kept
/// as a distinct accessor so the palette-index mapping stays testable.
func avatarColorHex(for name: String) -> UInt32 {
    avatarColorHexPair(for: name).light
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
        let colors = avatarColorHexPair(for: name)
        return Circle()
            .fill(Color(lightHex: colors.light, darkHex: colors.dark))
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
