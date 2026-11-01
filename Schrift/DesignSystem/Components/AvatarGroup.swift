import SwiftUI

struct AvatarGroupLayout: Equatable {
    let visibleNames: [String]
    let overflowCount: Int
}

func avatarGroupLayout(names: [String], max: Int) -> AvatarGroupLayout {
    // `max` is a caller-supplied parameter on `AvatarGroup`, and `prefix(_:)` traps on a
    // negative length — so a negative limit means "show no avatars", the same as
    // zero, rather than a crash.
    let limit = Swift.max(0, max)
    if names.count <= limit {
        return AvatarGroupLayout(visibleNames: names, overflowCount: 0)
    }
    // The prototype shows the first `limit` avatars, then a "+N" chip for the rest.
    let visible = Array(names.prefix(limit))
    let overflow = names.count - visible.count
    return AvatarGroupLayout(visibleNames: visible, overflowCount: overflow)
}

/// One visible avatar and the identity SwiftUI tracks it by.
struct AvatarGroupFace: Identifiable, Equatable {
    let id: UInt
    let name: String
}

/// The visible names paired with their identities: the caller's, where it gave one per name,
/// otherwise the position — which is what the row has always been identified by. A short
/// `identities` array falls back to the position for the names it does not cover rather than
/// trapping on an out-of-range index.
func avatarGroupFaces(names: [String], identities: [UInt]?) -> [AvatarGroupFace] {
    names.enumerated().map { index, name in
        AvatarGroupFace(
            id: identities.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? UInt(index), name: name)
    }
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
    @Environment(\.docsTheme) private var theme
    let names: [String]
    var size: CGFloat = 32
    var max: Int = 4
    /// A stable identity per name (a collaborator's client id), parallel to `names`. Without
    /// it a face is identified by its position, which is right for a static row; with it an
    /// avatar that joins is a *new* view, so `arrivalTransition` can play for it alone.
    var identities: [UInt]? = nil
    /// How a newly arriving avatar enters. `.identity` (the default) is no transition.
    var arrivalTransition: AnyTransition = .identity

    /// The row's single scale. It is handed down to each `Avatar` rather than
    /// letting them scale themselves, so the discs, the negative overlap and the
    /// "+N" disc are all measured from the same number — the stack comes apart
    /// at large text sizes if any one of them drifts.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let layout = avatarGroupLayout(names: names, max: max)
        let metrics = avatarGroupMetrics(size: size, scale: scale)
        HStack(spacing: metrics.overlap) {
            ForEach(avatarGroupFaces(names: layout.visibleNames, identities: identities)) { face in
                Avatar(name: face.name, size: size, scaleOverride: scale)
                    .overlay(Circle().stroke(theme.colors.surfacePage, lineWidth: 2))
                    .transition(arrivalTransition)
            }
            if layout.overflowCount > 0 {
                Circle()
                    .fill(theme.colors.surfaceMuted)
                    .frame(width: metrics.diameter, height: metrics.diameter)
                    .overlay(
                        Text("+\(layout.overflowCount)")
                            .font(.system(size: metrics.overflowFontSize, weight: .semibold))
                            .foregroundStyle(theme.colors.textSecondary)
                    )
                    .overlay(Circle().stroke(theme.colors.surfacePage, lineWidth: 2))
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
