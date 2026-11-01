import SwiftUI

/// The shimmer's pure pieces: when it runs and where its band sits.
enum SkeletonShimmer {
    /// One full sweep, in seconds.
    static let period: TimeInterval = 1.6
    /// The highlight band's width as a share of the bar it crosses.
    static let bandFraction: CGFloat = 0.6
}

/// Whether skeletons shimmer. Under Reduce Motion they are plain static bars.
func skeletonShimmerIsEnabled(reduceMotion: Bool) -> Bool {
    !reduceMotion
}

/// The band's leading x-offset for `phase`: it starts fully off the leading edge and ends fully
/// off the trailing edge, so the bar rests plain between sweeps.
func skeletonShimmerBandOffset(
    phase: CGFloat, width: CGFloat, bandFraction: CGFloat = SkeletonShimmer.bandFraction
) -> CGFloat {
    let band = width * bandFraction
    return -band + phase * (width + band)
}

/// A placeholder shape with a soft highlight sweeping across it.
///
/// The handoff's loading rule: *skeletons for lists, not spinners* — a spinner
/// says "something is happening", a skeleton says "rows are coming, and roughly
/// this many". Reserved for a **first** load with nothing cached; a
/// revalidation behind existing rows stays silent (see
/// `shouldShowLoadingPlaceholder`), because replacing real content with
/// placeholders would be a downgrade.
///
/// The shimmer replaces the old opacity blink. It is one `.linear` repeating animation of the band's
/// offset, started once on appear, so the render server interpolates it and the view's body is not
/// re-evaluated per frame (no per-bar `TimelineView`). Bars in a `SkeletonList` appear together,
/// so they start in step. It is off under Reduce Motion (`skeletonShimmerIsEnabled`), leaving the
/// static bar.
struct Skeleton: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var cornerRadius: CGFloat = DocsRadius.sm

    /// 0 at rest, animated to 1 once on appear; the band's offset is derived from it.
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(theme.colors.surfaceMuted)
            .frame(width: width, height: height)
            .overlay {
                // Gate the view, not just an animation: with Reduce Motion on there is no
                // shimmer view at all, so the bar is exactly the static placeholder.
                if skeletonShimmerIsEnabled(reduceMotion: reduceMotion) { shimmer }
            }
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
    }

    /// Brighter than the bar in light, lighter than it in dark; both from the theme's tokens.
    private var highlight: Color {
        colorScheme == .dark ? theme.colors.textPrimary.opacity(0.1) : theme.colors.surfacePage.opacity(0.7)
    }

    private var shimmer: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [Color.clear, highlight, Color.clear], startPoint: .leading, endPoint: .trailing
            )
            .frame(width: proxy.size.width * SkeletonShimmer.bandFraction)
            .offset(x: skeletonShimmerBandOffset(phase: phase, width: proxy.size.width))
        }
        .onAppear {
            withAnimation(.linear(duration: SkeletonShimmer.period).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .allowsHitTesting(false)
    }
}

/// One placeholder document row. `Shape.ledger` matches the Ledger `DocRow` (Home, Search): the
/// tinted tile, a title line with the trailing date, and an excerpt line, with heights and padding
/// following the real row (tile 38pt, title and excerpt lines at body/footnote leading) so
/// loading → content does not shift the list. `Shape.shared` keeps the compact two-line shape of
/// Shared's `SharedRow` (same tile box, no trailing date, no inner horizontal inset because the
/// screen supplies the gutter). Bar and line heights scale with Dynamic Type like the tile.
struct SkeletonRow: View {
    enum Shape {
        case ledger
        case shared
    }

    @Environment(\.docsTheme) private var theme
    var shape: Shape = .ledger
    /// Varies the title width per row so a column of them doesn't read as a
    /// suspiciously uniform block.
    var titleWidthFraction: CGFloat = 0.6
    var showsSubtitle: Bool = true

    /// The tile scales with Dynamic Type exactly as `DocIcon`'s does (24pt glyph + 14pt tint box).
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var titleBarHeight: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var detailBarHeight: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var titleLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var detailLineHeight: CGFloat = 16

    var body: some View {
        switch shape {
        case .ledger: ledgerBody
        case .shared: sharedBody
        }
    }

    private var tileSize: CGFloat { docIconBoxSize(scale: scale, tinted: true) }

    private var ledgerBody: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Skeleton(width: tileSize, height: tileSize, cornerRadius: DocsRadius.md)

            VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                HStack(spacing: DocsSpacing.spaceXS) {
                    GeometryReader { proxy in
                        Skeleton(width: proxy.size.width * titleWidthFraction, height: titleBarHeight)
                            .frame(maxHeight: .infinity)
                    }
                    Skeleton(width: 40, height: detailBarHeight)
                }
                .frame(height: titleLineHeight)

                if showsSubtitle {
                    GeometryReader { proxy in
                        Skeleton(
                            width: proxy.size.width * min(titleWidthFraction + 0.25, 0.95), height: detailBarHeight
                        )
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: detailLineHeight)
                }
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceSM - DocsSpacing.space4xs)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .accessibilityHidden(true)
    }

    private var sharedBody: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Skeleton(width: tileSize, height: tileSize, cornerRadius: DocsRadius.md)

            VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
                GeometryReader { proxy in
                    Skeleton(width: proxy.size.width * titleWidthFraction, height: titleBarHeight)
                }
                .frame(height: titleBarHeight)

                if showsSubtitle {
                    Skeleton(width: 96, height: detailBarHeight)
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
    @Environment(\.docsTheme) private var theme
    var rows: Int = 5
    var shape: SkeletonRow.Shape = .ledger

    @Environment(LocalizationStore.self) private var loc

    /// Deterministic per-row widths — a fixed rhythm rather than randomness, so
    /// the placeholder doesn't reshuffle on every redraw.
    private static let widthFractions: [CGFloat] = [0.62, 0.45, 0.7, 0.52, 0.58, 0.66]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { index in
                SkeletonRow(
                    shape: shape, titleWidthFraction: Self.widthFractions[index % Self.widthFractions.count])
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
