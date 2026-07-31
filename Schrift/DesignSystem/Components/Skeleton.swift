import SwiftUI

/// A placeholder shape with a gentle opacity pulse.
///
/// The handoff's loading rule: *skeletons for lists, not spinners* — a spinner
/// says "something is happening", a skeleton says "rows are coming, and roughly
/// this many". Reserved for a **first** load with nothing cached; a
/// revalidation behind existing rows stays silent (see
/// `shouldShowLoadingPlaceholder`), because replacing real content with
/// placeholders would be a downgrade.
struct Skeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var cornerRadius: CGFloat = DocsRadius.sm

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DocsColor.surfaceMuted)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .opacity(isPulsing ? 0.45 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: isPulsing
            )
            // Gate the state, not just the animation: suppressing only the
            // animation would snap it to the dimmed end value and leave it
            // there, which is dimmer than the static placeholder intended.
            .onAppear { if !reduceMotion { isPulsing = true } }
            .accessibilityHidden(true)
    }
}

/// One placeholder document row: leading icon block, a title line, and a
/// shorter second line — the shape of the rows it stands in for.
struct SkeletonRow: View {
    /// Varies the title width per row so a column of them doesn't read as a
    /// suspiciously uniform block.
    var titleWidthFraction: CGFloat = 0.6
    var showsSubtitle: Bool = true

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Skeleton(width: 36, height: 36, cornerRadius: DocsRadius.md)

            VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
                GeometryReader { proxy in
                    Skeleton(width: proxy.size.width * titleWidthFraction, height: 13)
                }
                .frame(height: 13)

                if showsSubtitle {
                    Skeleton(width: 96, height: 11)
                }
            }
        }
        .padding(.vertical, DocsSpacing.spaceXS)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .accessibilityHidden(true)
    }
}

/// A short column of `SkeletonRow`s standing in for a list that is loading for
/// the first time. Marked as one accessibility element that announces loading,
/// since the individual shapes carry nothing to speak.
struct SkeletonList: View {
    var rows: Int = 5

    @Environment(LocalizationStore.self) private var loc

    /// Deterministic per-row widths — a fixed rhythm rather than randomness, so
    /// the placeholder doesn't reshuffle on every redraw.
    private static let widthFractions: [CGFloat] = [0.62, 0.45, 0.7, 0.52, 0.58, 0.66]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { index in
                SkeletonRow(titleWidthFraction: Self.widthFractions[index % Self.widthFractions.count])
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc[.common_loading])
    }
}

#Preview {
    VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
        SkeletonList()
        Skeleton(width: 140, height: 20)
    }
    .padding()
    .environment(LocalizationStore())
}

#Preview("Dark") {
    SkeletonList()
        .padding()
        .environment(LocalizationStore())
        .preferredColorScheme(.dark)
}
