import SwiftUI

struct AvatarGroupLayout: Equatable {
    let visibleNames: [String]
    let overflowCount: Int
}

func avatarGroupLayout(names: [String], max: Int) -> AvatarGroupLayout {
    if names.count <= max {
        return AvatarGroupLayout(visibleNames: names, overflowCount: 0)
    }
    let visibleCount = Swift.max(max - 1, 0)
    let visible = Array(names.prefix(visibleCount))
    let overflow = names.count - visibleCount
    return AvatarGroupLayout(visibleNames: visible, overflowCount: overflow)
}

struct AvatarGroup: View {
    let names: [String]
    var size: CGFloat = 32
    var max: Int = 4

    var body: some View {
        let layout = avatarGroupLayout(names: names, max: max)
        HStack(spacing: -size * 0.3) {
            ForEach(Array(layout.visibleNames.enumerated()), id: \.offset) { _, name in
                Avatar(name: name, size: size)
                    .overlay(Circle().stroke(DocsColor.surfacePage, lineWidth: 2))
            }
            if layout.overflowCount > 0 {
                Circle()
                    .fill(DocsColor.surfaceMuted)
                    .frame(width: size, height: size)
                    .overlay(
                        Text("+\(layout.overflowCount)")
                            .font(.system(size: size * 0.35, weight: .semibold))
                            .foregroundStyle(DocsColor.textSecondary)
                    )
                    .overlay(Circle().stroke(DocsColor.surfacePage, lineWidth: 2))
            }
        }
    }
}

#Preview {
    AvatarGroup(names: ["Camille Moreau", "Alfredo Levin", "Desirae Dokidis", "Amandine Salambo", "Charlie Saris"], max: 3)
        .padding()
}
