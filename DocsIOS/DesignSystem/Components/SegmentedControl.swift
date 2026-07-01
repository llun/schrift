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

    var body: some View {
        GeometryReader { geometry in
            let layout = segmentedControlLayout(segmentCount: segments.count, selectedIndex: selectedIndex)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DocsColor.surfaceMuted)

                Capsule()
                    .fill(DocsColor.surfacePage)
                    .frame(width: geometry.size.width * layout.segmentFraction)
                    .offset(x: geometry.size.width * layout.thumbOffsetFraction)
                    .animation(.easeOut(duration: 0.2), value: selectedIndex)

                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Text(segment)
                            .font(DocsFont.subhead)
                            .foregroundStyle(index == selectedIndex ? DocsColor.textPrimary : DocsColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedIndex = index }
                    }
                }
            }
        }
        .frame(height: DocsSpacing.rowMinHeight)
    }
}

#Preview {
    @Previewable @State var selectedIndex = 0
    SegmentedControl(segments: ["All", "Shared", "Pinned"], selectedIndex: $selectedIndex)
        .padding()
}
