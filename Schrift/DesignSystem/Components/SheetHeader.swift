import SwiftUI

/// The header row for a bottom sheet: an inline `title2` title on the left and
/// an optional circular close button on the right — the app's standard sheet
/// chrome (handoff `Sheet`). Pin it above a sheet's scrollable body and pair the
/// sheet with `.presentationDetents` + `.presentationDragIndicator(.visible)` so
/// the system grabber sits above the title.
///
/// The body below a `SheetHeader` is a **flat, boxless** list: `ListRow`s
/// rendered directly on `DocsColor.surfacePage` with no `ListSection` card and
/// no `ProfileRowDivider` between them — matching the handoff's `OptionsSheet`.
struct SheetHeader: View {
    let title: String
    /// Accessibility label for the close button; only used when `onClose` is set.
    var closeLabel: String = "Close"
    /// When non-nil, a trailing circular close button that dismisses the sheet.
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Text(title)
                .font(DocsFont.title2)
                .foregroundStyle(DocsColor.textPrimary)

            Spacer(minLength: DocsSpacing.spaceSM)

            if let onClose {
                IconButton(icon: .close, label: closeLabel, variant: .soft, size: .small, action: onClose)
            }
        }
        // The handoff `Sheet` seats the title well clear of the drag indicator:
        // a full 16pt sheet gutter above (the prior 4pt read as cramped against
        // the grabber), the app's 16pt gutter on the sides, and 10pt below.
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.top, DocsSpacing.spaceBase)
        .padding(.bottom, DocsSpacing.spaceSM - DocsSpacing.space4xs)
    }
}

#Preview("Light") {
    VStack(spacing: 0) {
        SheetHeader(title: "Options", closeLabel: "Close", onClose: {})
        SheetHeader(title: "Version history", closeLabel: "Close", onClose: {})
        SheetHeader(title: "No close button")
        Spacer()
    }
    .background(DocsColor.surfacePage)
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    VStack(spacing: 0) {
        SheetHeader(title: "Options", closeLabel: "Close", onClose: {})
        SheetHeader(title: "Version history", closeLabel: "Close", onClose: {})
        Spacer()
    }
    .background(DocsColor.surfacePage)
    .preferredColorScheme(.dark)
}
