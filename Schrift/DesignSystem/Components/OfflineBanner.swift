import SwiftUI

/// A slim, subtle status strip shown below the nav bar when there's no
/// connection. Reassures that listed documents are cached on the device —
/// deliberately NOT an error style.
struct OfflineBanner: View {
    var note: String = "All documents saved on this device"

    var body: some View {
        HStack(spacing: DocsSpacing.space2xs) {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 15))
                .foregroundStyle(DocsColor.gray450)
            Text("Offline")
                .font(DocsFont.caption.weight(.bold))
                .tracking(DocsTypographySpec.caption.size * DocsTracking.wide)
                .foregroundStyle(DocsColor.textSecondary)
            Circle()
                .fill(DocsColor.gray300)
                .frame(width: 3, height: 3)
            Text(note)
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.vertical, DocsSpacing.spaceXS)
        .background(DocsColor.gray050)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline. \(note)")
    }
}

#Preview {
    VStack(spacing: 0) {
        OfflineBanner()
        OfflineBanner(note: "Editing the copy saved on this device")
        Spacer()
    }
}
