import SwiftUI

/// Fixed width of a pinned card at the default text size, before Dynamic Type scaling.
let pinnedCardBaseWidth: CGFloat = 168

/// Whether Home's Pinned section is drawn as a horizontal shelf of cards.
///
/// Only on the page canvas (compact width, where the list owns the screen) and below the
/// accessibility text sizes. The iPad sidebar (`DocsCanvasRole.sidebar`) is a narrow column
/// whose rows already carry the swipe actions, so it keeps rows; accessibility sizes fall back
/// to the vertical rows for the same reason `rowUsesStackedLayout` exists — cards of fixed
/// width would force the title to truncate.
func pinnedShelfIsEnabled(canvasRole: DocsCanvasRole, dynamicTypeSize: DynamicTypeSize) -> Bool {
    canvasRole == .page && !dynamicTypeSize.isAccessibilitySize
}

/// One pinned document on Home's shelf: the document tile, a title of up to two lines and up
/// to two lines of its text, on a soft brand surface. Tapping opens the document; the row
/// actions (unpin, move, delete) are attached by the caller as a context menu.
struct PinnedCard: View {
    @Environment(\.docsTheme) private var theme
    var emoji: String? = nil
    var title: String = "Untitled document"
    var excerpt: String? = nil
    var tintSeed: UUID? = nil
    /// Deleted on this device, not yet sent: struck through, and the tap offers to undo.
    var pendingDelete: Bool = false
    /// The composed VoiceOver label, supplied by the caller (it is the same string the vertical
    /// row speaks, from `docRowAccessibilityLabel`).
    var accessibilityLabel: String = ""
    var onOpen: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.space3xs) {
            DocIcon(emoji: emoji, size: 24, tinted: false, tintSeed: tintSeed)
                .padding(.bottom, DocsSpacing.space4xs)

            Text(title)
                .font(DocsFont.subhead.weight(.semibold))
                .foregroundStyle(pendingDelete ? theme.colors.textTertiary : theme.colors.textPrimary)
                .strikethrough(pendingDelete)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)

            Text(docRowExcerptText(excerpt) ?? " ")
                .font(DocsFont.footnote)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .padding(DocsSpacing.spaceSM)
        .frame(width: pinnedCardBaseWidth * scale, alignment: .leading)
        .background(theme.colors.brandFillSubtle, in: RoundedRectangle(cornerRadius: DocsRadius.lg))
        .contentShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: DocsRadius.lg))
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel.isEmpty ? title : accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Pinned cards") {
    ScrollView(.horizontal) {
        HStack(spacing: DocsSpacing.spaceXS) {
            PinnedCard(
                emoji: "🚀", title: "Schrift release checklist",
                excerpt: "TestFlight build 214, check fastlane lanes and the release notes",
                tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            PinnedCard(
                title: "Q4 roadmap", excerpt: "Offline search, outline, iPad shortcuts",
                tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            PinnedCard(title: "A long title that wraps onto a second line and then truncates after that")
            PinnedCard(emoji: "🗑️", title: "Deleted offline", excerpt: "Struck through", pendingDelete: true)
        }
        .padding()
    }
    .environment(LocalizationStore())
}

#Preview("Pinned cards (dark)") {
    HStack(spacing: DocsSpacing.spaceXS) {
        PinnedCard(
            emoji: "🚀", title: "Schrift release checklist", excerpt: "TestFlight build 214, check fastlane",
            tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        PinnedCard(
            title: "Q4 roadmap", excerpt: "Offline search, outline, iPad shortcuts",
            tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    }
    .padding()
    .background(DocsColor.surfacePage)
    .environment(LocalizationStore())
    .preferredColorScheme(.dark)
}
