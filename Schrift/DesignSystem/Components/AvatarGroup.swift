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

/// Every length in a stacked avatar row, derived from one diameter.
struct AvatarGroupMetrics: Equatable {
    let diameter: CGFloat
    /// The `HStack` spacing — negative, because the discs overlap.
    let overlap: CGFloat
    let overflowFontSize: CGFloat
}

/// Pure so the one thing that can go wrong here is testable: these three must
/// move *together* with Dynamic Type. Scaling the discs while the overlap stays
/// a fixed number of points is what pulls the stack apart at large text sizes.
func avatarGroupMetrics(size: CGFloat, scale: CGFloat) -> AvatarGroupMetrics {
    let diameter = size * scale
    return AvatarGroupMetrics(
        diameter: diameter,
        overlap: -diameter * 0.32,
        overflowFontSize: diameter * 0.36
    )
}

struct AvatarGroup: View {
    let names: [String]
    var size: CGFloat = 32
    var max: Int = 4

    /// The row's single scale. It is handed down to each `Avatar` rather than
    /// letting them scale themselves, so the discs, the negative overlap and the
    /// "+N" disc are all measured from the same number — the stack comes apart
    /// at large text sizes if any one of them drifts.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let layout = avatarGroupLayout(names: names, max: max)
        let metrics = avatarGroupMetrics(size: size, scale: scale)
        HStack(spacing: metrics.overlap) {
            ForEach(Array(layout.visibleNames.enumerated()), id: \.offset) { _, name in
                Avatar(name: name, size: size, scaleOverride: scale)
                    .overlay(Circle().stroke(DocsColor.surfacePage, lineWidth: 2))
            }
            if layout.overflowCount > 0 {
                Circle()
                    .fill(DocsColor.surfaceMuted)
                    .frame(width: metrics.diameter, height: metrics.diameter)
                    .overlay(
                        Text("+\(layout.overflowCount)")
                            .font(.system(size: metrics.overflowFontSize, weight: .semibold))
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
