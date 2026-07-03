import SwiftUI

struct AvatarGroupLayout: Equatable {
    let visibleNames: [String]
    let overflowCount: Int
}

func avatarGroupLayout(names: [String], max: Int) -> AvatarGroupLayout {
    if names.count <= max {
        return AvatarGroupLayout(visibleNames: names, overflowCount: 0)
    }
    // The prototype shows the first `max` avatars, then a "+N" chip for the rest.
    let visible = Array(names.prefix(max))
    let overflow = names.count - visible.count
    return AvatarGroupLayout(visibleNames: visible, overflowCount: overflow)
}

struct AvatarGroup: View {
    let names: [String]
    var size: CGFloat = 32
    var max: Int = 4

    var body: some View {
        let layout = avatarGroupLayout(names: names, max: max)
        HStack(spacing: -size * 0.32) {
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
                            .font(.system(size: size * 0.36, weight: .semibold))
                            .foregroundStyle(DocsColor.textSecondary)
                    )
                    .overlay(Circle().stroke(DocsColor.surfacePage, lineWidth: 2))
            }
        }
    }
}

#Preview {
    AvatarGroup(
        names: ["Camille Moreau", "Alfredo Levin", "Desirae Dokidis", "Amandine Salambo", "Charlie Saris"], max: 3
    )
    .padding()
}
