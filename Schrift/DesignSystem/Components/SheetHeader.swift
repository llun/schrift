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
                Button(action: onClose) {
                    MaterialSymbol(.close, size: 20)
                        .foregroundStyle(DocsColor.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(DocsColor.surfaceMuted, in: Circle())
                        // Keep the handoff's 30pt disc, but float the tap target
                        // to the 44pt iOS minimum around it.
                        .frame(width: DocsSpacing.rowMinHeight, height: DocsSpacing.rowMinHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(closeLabel)
            }
        }
        // Matches the handoff `Sheet` title row padding (4 / 16 / 10); the app
        // uses its 16pt sheet gutter rather than the prototype's 18.
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.top, DocsSpacing.space3xs)
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
