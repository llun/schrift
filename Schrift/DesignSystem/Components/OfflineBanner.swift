import SwiftUI

/// A slim, subtle status strip shown below the nav bar when there's no
/// connection. Reassures that listed documents are cached on the device —
/// deliberately NOT an error style.
///
/// `note` has no default: callers pass an explicit, already-resolved string
/// (usually `loc[.offline_note]`) so this component doesn't need to guess a
/// caller-appropriate default from inside an environment-less initializer.
struct OfflineBanner: View {
    @Environment(\.docsTheme) private var theme
    var note: String

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        HStack(spacing: DocsSpacing.space2xs) {
            MaterialSymbol(.cloud_done, size: 17, fill: true)
                .foregroundStyle(theme.colors.gray450)
            Text(loc[.offline_status])
                .font(DocsFont.caption.weight(.semibold))
                .docsTracking(DocsTypographySpec.caption, DocsTracking.wide)
                .foregroundStyle(theme.colors.textSecondary)
            Circle()
                .fill(theme.colors.gray300)
                .frame(width: 3, height: 3)
            Text(note)
                .font(DocsFont.footnote)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.vertical, DocsSpacing.spaceXS)
        .background(theme.colors.gray050)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.colors.borderDefault)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(loc[.offline_status]). \(note)")
    }
}

#Preview {
    VStack(spacing: 0) {
        OfflineBanner(note: "All documents saved on this device")
        OfflineBanner(note: "Working on the copy saved on this device")
        Spacer()
    }
    .environment(LocalizationStore())
}
