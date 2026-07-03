import SwiftUI

struct SegmentedControlLayout: Equatable {
    let segmentFraction: Double
    let thumbOffsetFraction: Double
}

func segmentedControlLayout(segmentCount: Int, selectedIndex: Int) -> SegmentedControlLayout {
    guard segmentCount > 0 else { return SegmentedControlLayout(segmentFraction: 0, thumbOffsetFraction: 0) }
    let fraction = 1.0 / Double(segmentCount)
    let clampedIndex = min(max(selectedIndex, 0), segmentCount - 1)
    return SegmentedControlLayout(segmentFraction: fraction, thumbOffsetFraction: fraction * Double(clampedIndex))
}

struct SegmentedControl: View {
    let segments: [String]
    @Binding var selectedIndex: Int

    private let trackPadding: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let layout = segmentedControlLayout(segmentCount: segments.count, selectedIndex: selectedIndex)
            ZStack(alignment: .leading) {
                // Sunken rounded-rect track (not a full pill).
                RoundedRectangle(cornerRadius: DocsRadius.md)
                    .fill(DocsColor.surfaceSunken)

                // White sliding thumb, one radius step tighter than the track.
                // A hairline border plus a soft shadow give it the crisp edge
                // the reference thumb reads with over the sunken track.
                RoundedRectangle(cornerRadius: DocsRadius.sm)
                    .fill(DocsColor.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: DocsRadius.sm)
                            .strokeBorder(DocsColor.borderDefault, lineWidth: 0.5)
                    )
                    .shadow(color: DocsColor.textPrimary.opacity(0.08), radius: 2, x: 0, y: 1)
                    // Per-segment cell model (reference): each cell is width/n and
                    // the thumb is inset 2pt on every edge within its cell, so the
                    // pill stays centered under every label.
                    .frame(
                        width: geometry.size.width * layout.segmentFraction - trackPadding * 2,
                        height: geometry.size.height - trackPadding * 2
                    )
                    .offset(x: geometry.size.width * layout.thumbOffsetFraction + trackPadding)
                    .animation(.easeOut(duration: 0.2), value: selectedIndex)

                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Text(segment)
                            .font(.system(size: 13, weight: index == selectedIndex ? .semibold : .medium))
                            .foregroundStyle(index == selectedIndex ? DocsColor.textPrimary : DocsColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedIndex = index }
                            .accessibilityAddTraits(index == selectedIndex ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
        .frame(height: 34)
    }
}

#Preview {
    @Previewable @State var selectedIndex = 0
    SegmentedControl(segments: ["All", "Shared", "Pinned"], selectedIndex: $selectedIndex)
        .padding()
}
