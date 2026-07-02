import SwiftUI

let avatarColorPalette: [UInt32] = [
    0xDA3B49, 0xB95D33, 0x8F7158, 0x9D6E00, 0x008948,
    0x4279B9, 0x00848F, 0x9961AF, 0xAA5F80, 0x75758A,
]

func avatarInitials(for name: String) -> String {
    let words = name.split(separator: " ").prefix(2)
    return words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
}

func avatarColorHex(for name: String) -> UInt32 {
    guard !name.isEmpty else { return avatarColorPalette[0] }
    let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return avatarColorPalette[sum % avatarColorPalette.count]
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
