import SwiftUI

/// Where a foldable's crease sits in a view, and how layout keeps clear of it.
///
/// The iPhone Duo reports its crease as a `.division` reserved region (iOS 27.1). Folded,
/// there is none; unfolded, a vertical strip runs down the middle of the inner screen.
/// Pure geometry so it is unit-testable on any SDK — only `foldAware` touches 27.1 API.
enum FoldLayout {
    /// The narrowest sidebar worth aligning to the fold; nearer the edge, the system width stays.
    static let minimumSidebarWidth: CGFloat = 280

    /// A crease as seen by one view: its horizontal span, and the view's width it was measured in.
    struct Fold: Equatable {
        var span: ClosedRange<CGFloat>
        var width: CGFloat
    }

    /// The horizontal span of the first vertical fold that crosses a view `width` wide, or
    /// nil. A horizontal crease (a tabletop posture) is ignored: text reads across it fine.
    static func verticalFold(in regions: [CGRect], width: CGFloat) -> ClosedRange<CGFloat>? {
        regions
            .first { $0.height > $0.width && $0.maxX > 0 && $0.minX < width }
            .map { max($0.minX, 0)...min($0.maxX, width) }
    }

    /// A sidebar that ends exactly at the fold, so list and document each get one panel.
    /// Nil when the fold is too near either edge to make two usable columns.
    static func sidebarWidth(fold: ClosedRange<CGFloat>, width: CGFloat) -> CGFloat? {
        let leading = fold.lowerBound
        guard leading >= minimumSidebarWidth, width - fold.upperBound >= minimumSidebarWidth else { return nil }
        return leading
    }

    /// Padding that moves content entirely onto the wider side of the fold, so no line of
    /// text or control straddles the crease.
    static func clearance(fold: ClosedRange<CGFloat>, width: CGFloat) -> EdgeInsets {
        let leadingSpace = fold.lowerBound
        let trailingSpace = width - fold.upperBound
        return leadingSpace >= trailingSpace
            ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: width - fold.lowerBound)
            : EdgeInsets(top: 0, leading: fold.upperBound, bottom: 0, trailing: 0)
    }
}

extension View {
    /// Reports the vertical fold crossing this view, in its own coordinates. Always nil on
    /// SDKs before iOS 27.1 (CI's Xcode) and on devices that do not fold.
    func foldAware(_ action: @escaping (FoldLayout.Fold?) -> Void) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
            // shortcut: reads the first active division only; a device with two creases would need more.
            return onGeometryChange(for: FoldLayout.Fold?.self) { proxy in
                guard #available(iOS 27.1, *) else { return nil }
                let width = proxy.size.width
                let regions = proxy.reservedRegions(kind: .division).map(\.frame)
                return FoldLayout.verticalFold(in: regions, width: width).map { .init(span: $0, width: width) }
            } action: {
                action($0)
            }
        #else
            return self
        #endif
    }

    /// Keeps this view's content on one side of a fold that crosses it.
    func foldClearance() -> some View {
        modifier(FoldClearance())
    }
}

private struct FoldClearance: ViewModifier {
    @State private var fold: FoldLayout.Fold?

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(fold.map { FoldLayout.clearance(fold: $0.span, width: $0.width) } ?? EdgeInsets())
            .foldAware { fold = $0 }
    }
}
