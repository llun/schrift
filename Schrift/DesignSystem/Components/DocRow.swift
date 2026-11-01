import SwiftUI

func docRowReachIndicatorIcon(reach: LinkReach) -> MaterialIcon? {
    switch reach {
    case .restricted: return nil
    case .authenticated: return .vpn_lock
    case .public: return .public
    }
}

/// Pure and testable: the *localized* label strings are resolved by the caller
/// (from `LocalizationStore`) and passed in, so this only owns the branching/
/// ordering logic, not the translation lookup.
func docRowAccessibilityLabel(
    title: String,
    excerpt: String = "",
    reach: LinkReach,
    date: String,
    pageCountLabel: String = "",
    pinned: Bool,
    pendingSync: Bool = false,
    pendingSyncLabel: String = "",
    pendingDelete: Bool = false,
    pendingDeleteLabel: String = "",
    pinnedLabel: String,
    sharedWithOrganizationLabel: String,
    publicLabel: String
) -> String {
    var parts = [title]
    if pinned {
        parts.append(pinnedLabel)
    }
    // The badge itself is `accessibilityHidden` — the row ignores its children and composes
    // one label — so a state whose *only* visual signal is that glyph has to be spoken here
    // or it is invisible to VoiceOver.
    // Ahead of `pendingSync` for the same reason its glyph is: a document waiting to be
    // deleted is the more actionable fact, and the two can never both be true anyway
    // (tombstones name server ids, `pendingSync` rows client-minted ones).
    if pendingDelete, !pendingDeleteLabel.isEmpty {
        parts.append(pendingDeleteLabel)
    } else if pendingSync, !pendingSyncLabel.isEmpty {
        parts.append(pendingSyncLabel)
    }
    switch reach {
    case .restricted:
        break
    case .authenticated:
        parts.append(sharedWithOrganizationLabel)
    case .public:
        parts.append(publicLabel)
    }
    if !date.isEmpty {
        parts.append(date)
    }
    if !pageCountLabel.isEmpty {
        parts.append(pageCountLabel)
    }
    // The excerpt is the document's own text and the least predictable part of the label, so it
    // is spoken last, after the state and metadata that tell a listener what the row is.
    if !excerpt.isEmpty {
        parts.append(docRowSpokenExcerpt(excerpt))
    }
    return parts.joined(separator: ", ")
}

/// "4 pages" for a document with sub-pages, `nil` when it has none. Plural-aware through
/// `LocalizationStore.plural` (Slovene dual/few included).
@MainActor
func docRowPageCountLabel(_ count: Int, loc: LocalizationStore) -> String? {
    guard count > 0 else { return nil }
    return loc.plural(
        count, one: .docrow_pages_one, other: .docrow_pages_other,
        two: .docrow_pages_two, few: .docrow_pages_few)
}

/// Whether a document row stacks its title above its metadata instead of sharing
/// one line with it.
///
/// The trailing date holds `layoutPriority(1)` so it is never the thing that
/// truncates — which is right until the text is large enough that the title has
/// no room left and collapses to "A…". At accessibility sizes the two get their
/// own lines instead, per the HIG's guidance to reflow rather than truncate.
func rowUsesStackedLayout(_ dynamicTypeSize: DynamicTypeSize) -> Bool {
    dynamicTypeSize.isAccessibilitySize
}

/// Roughly how many characters of a footnote excerpt fit on one line beside the row's tile, used
/// to decide whether a search match is out of sight (`searchExcerptWindow`).
let docRowExcerptVisibleCharacters = 40
let docRowExcerptLeadingCharacters = 12

struct DocRow: View {
    @Environment(\.docsTheme) private var theme
    var emoji: String? = nil
    var title: String = "Untitled document"
    var pinned: Bool = false
    var reach: LinkReach = .restricted
    var date: String = ""
    var offlineAvailable: Bool = false
    /// Created on this device and not yet on the server. Distinct from `offlineAvailable`,
    /// which means the opposite direction of travel: a *server* document whose body is cached
    /// here. Both can be true at once — the only call site passes a screen-wide `isOffline`
    /// for the latter — so the `if/else if` ordering below is load-bearing, not defensive:
    /// this is the more actionable of the two, because it is *why* the document is missing
    /// from the web.
    var pendingSync: Bool = false
    /// Deleted on this device, waiting for the server to be told. The row stays visible and
    /// struck through rather than vanishing, because the deletion is still undoable — tapping
    /// it offers exactly that instead of opening the document.
    ///
    /// Mutually exclusive with `pendingSync` in practice: a tombstone names a **server** id,
    /// a `pendingSync` row a client-minted one. The ordering below states the precedence
    /// anyway rather than relying on that.
    var pendingDelete: Bool = false
    /// A line of the document's text under the title. Blank or whitespace-only is treated as absent.
    var excerpt: String? = nil
    /// The document's sub-page count (`Document.numchild`); a badge shows when it is above zero.
    var pageCount: Int = 0
    /// Seeds the tile's soft tint (the document id); nil keeps the single brand tint.
    var tintSeed: UUID? = nil
    /// Search results pass the query so the matched words in the title and excerpt are drawn
    /// highlighted, and an excerpt whose match is out of sight starts near it. nil (every other
    /// list) draws plain text. The VoiceOver label never carries the highlight.
    var highlightQuery: String? = nil
    var onOpen: (() -> Void)? = nil

    @Environment(LocalizationStore.self) private var loc
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isStacked: Bool { rowUsesStackedLayout(dynamicTypeSize) }
    private var excerptText: String? { docRowExcerptText(excerpt) }
    private var activeHighlightQuery: String? {
        guard let query = highlightQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return nil
        }
        return query
    }
    private var pageCountText: String? { docRowPageCountLabel(pageCount, loc: loc) }
    /// A second line exists (excerpt and/or page count), so the title may wrap to two lines.
    private var hasDetailLine: Bool { excerptText != nil || pageCountText != nil }

    var body: some View {
        HStack(alignment: isStacked ? .top : .center, spacing: DocsSpacing.spaceSM) {
            DocIcon(emoji: emoji, tinted: true, pinned: pinned, tintSeed: tintSeed)

            if isStacked {
                VStack(alignment: .leading, spacing: DocsSpacing.space3xs) {
                    titleLine
                    if let excerptText {
                        excerptLabel(excerptText, lines: 2)
                    }
                    HStack(spacing: DocsSpacing.space2xs) {
                        offlineIndicator
                        dateLabel
                        pageCountBadge
                    }
                }
                Spacer(minLength: 0)
            } else if hasDetailLine {
                // Ledger shape: the date stays trailing on the title's first line; the
                // excerpt fills the second line with the page badge trailing it.
                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    HStack(alignment: .firstTextBaseline, spacing: DocsSpacing.spaceXS) {
                        titleLine
                        Spacer(minLength: DocsSpacing.spaceXS)
                        offlineIndicator
                        dateLabel
                    }
                    HStack(spacing: DocsSpacing.spaceXS) {
                        if let excerptText {
                            excerptLabel(excerptText, lines: 1)
                        }
                        Spacer(minLength: 0)
                        pageCountBadge
                    }
                }
            } else {
                titleLine
                Spacer(minLength: DocsSpacing.spaceXS)
                offlineIndicator
                dateLabel
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceSM - DocsSpacing.space4xs)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        // Collapse the row into a single button carrying the composed label,
        // otherwise the child Texts/glyphs stay separately focusable and the
        // label is never applied.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            docRowAccessibilityLabel(
                title: title, excerpt: excerptText ?? "", reach: reach, date: date,
                pageCountLabel: pageCountText ?? "", pinned: pinned,
                pendingSync: pendingSync, pendingSyncLabel: loc[.docrow_on_this_device],
                pendingDelete: pendingDelete, pendingDeleteLabel: loc[.docrow_pending_delete],
                pinnedLabel: loc[.docrow_pinned],
                sharedWithOrganizationLabel: loc[.docrow_shared_with_organization],
                publicLabel: loc[.docrow_public]
            )
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Title and its inline reach glyph sit 6pt apart (reference), while the
    /// DocIcon keeps the outer 12pt gap.
    private var titleLine: some View {
        HStack(spacing: DocsSpacing.space2xs) {
            highlightedText(title, font: DocsFont.body)
                .font(DocsFont.body)
                .foregroundStyle(pendingDelete ? theme.colors.textTertiary : theme.colors.textPrimary)
                .strikethrough(pendingDelete)
                .lineLimit(docRowTitleLineLimit(hasDetailLine: hasDetailLine, isStacked: isStacked))
                .fixedSize(horizontal: false, vertical: true)

            if let indicatorIcon = docRowReachIndicatorIcon(reach: reach) {
                MaterialSymbol(indicatorIcon, size: 16)
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
    }

    /// Plain `Text` unless a search query is set, in which case the matched words are highlighted
    /// with the brand-subtle fill and a semibold weight (existing tokens, no new colours).
    private func highlightedText(_ string: String, font: Font) -> Text {
        guard let query = activeHighlightQuery else { return Text(string) }
        return Text(
            searchHighlightedString(
                string, query: query, locale: loc.locale, font: font,
                background: theme.colors.brandFillSubtle, foreground: theme.colors.textPrimary))
    }

    private func excerptLabel(_ text: String, lines: Int) -> some View {
        let shown =
            activeHighlightQuery.map {
                searchExcerptWindow(
                    text, query: $0, locale: loc.locale, visibleLimit: docRowExcerptVisibleCharacters * lines,
                    leadingContext: docRowExcerptLeadingCharacters * lines)
            } ?? text
        return highlightedText(shown, font: DocsFont.footnote)
            .font(DocsFont.footnote)
            .foregroundStyle(theme.colors.textSecondary)
            .lineLimit(lines)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var pageCountBadge: some View {
        if let pageCountText {
            Text(pageCountText)
                .font(DocsFont.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, DocsSpacing.spaceXS)
                .padding(.vertical, DocsSpacing.space4xs)
                .background(theme.colors.surfaceMuted, in: Capsule())
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var offlineIndicator: some View {
        if pendingDelete {
            MaterialSymbol(.delete, size: 16)
                .foregroundStyle(theme.colors.gray350)
                .accessibilityLabel(loc[.docrow_pending_delete])
        } else if pendingSync {
            MaterialSymbol(.cloud_off, size: 16)
                .foregroundStyle(theme.colors.gray350)
                .accessibilityLabel(loc[.docrow_on_this_device])
        } else if offlineAvailable {
            MaterialSymbol(.cloud_done, size: 16)
                .foregroundStyle(theme.colors.gray350)
                .accessibilityLabel(loc[.docrow_available_offline])
        }
    }

    @ViewBuilder
    private var dateLabel: some View {
        if !date.isEmpty {
            Text(date)
                .font(DocsFont.footnote)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)
                .layoutPriority(isStacked ? 0 : 1)
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
        DocRow(emoji: "📊", title: "Roadmap", reach: .authenticated, date: "Yesterday")
        DocRow(title: "Public notes", reach: .public, date: "Last week")
        // The two sync states, and the overlap: a locally-created row while the whole screen
        // is offline is both, and must read as pending.
        DocRow(
            emoji: "📥", title: "Cached copy", reach: .restricted, date: "1 hour ago",
            offlineAvailable: true)
        DocRow(emoji: "✏️", title: "Written on the plane", reach: .restricted, date: "Just now", pendingSync: true)
        DocRow(
            emoji: "✏️", title: "Offline and unsynced", reach: .restricted, date: "Just now",
            offlineAvailable: true, pendingSync: true)
        DocRow(
            emoji: "🗑️", title: "Deleted while offline", reach: .restricted, date: "Just now",
            pendingDelete: true)
    }
    .environment(LocalizationStore())
}

/// The stacked layout, which only appears at accessibility text sizes — the
/// branch a title would otherwise truncate to "Q…" in.
#Preview("Accessibility size") {
    VStack(spacing: 0) {
        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
        DocRow(emoji: "📊", title: "Roadmap", reach: .authenticated, date: "Yesterday")
        DocRow(title: "Public notes", reach: .public, date: "Last week")
        DocRow(
            emoji: "🗑️", title: "Deleted while offline", reach: .restricted, date: "Just now",
            pendingDelete: true)
    }
    .environment(LocalizationStore())
    .dynamicTypeSize(.accessibility3)
}

/// The new pending-deletion state in dark. A `textTertiary` title with a strikethrough and a
/// `gray350` glyph has a different contrast story from the light half, and a token's dark
/// counterpart existing is not proof it reads correctly beside one.
#Preview("Pending deletion (dark)") {
    VStack(spacing: 0) {
        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
        DocRow(
            emoji: "🗑️", title: "Deleted while offline", reach: .restricted, date: "Just now",
            pendingDelete: true)
    }
    .background(DocsColor.surfacePage)
    .environment(LocalizationStore())
    .preferredColorScheme(.dark)
}

/// The Ledger rows: tinted tile, a title that may use two lines, one line of the document's
/// text, and the sub-page count badge.
#Preview("Ledger rows") {
    VStack(spacing: 0) {
        DocRow(
            emoji: "📝", title: "Meeting notes 31 Oct", reach: .restricted, date: "Yesterday",
            excerpt: "Decided to ship page chips on Friday, then revisit the theme picker.",
            tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        DocRow(
            title: "Trip to Chiang Mai: flights, hotels, the long list of things to book before December",
            reach: .authenticated, date: "Thu", excerpt: "Flights booked, need hotel near Nimman", pageCount: 4,
            tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        DocRow(
            title: "Reading notes", pinned: true, reach: .public, date: "Wed", pageCount: 1,
            tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        DocRow(
            emoji: "🗑️", title: "Deleted while offline", date: "Just now", pendingDelete: true,
            excerpt: "Struck through", pageCount: 2)
    }
    .environment(LocalizationStore())
}

#Preview("Ledger rows (dark)") {
    VStack(spacing: 0) {
        DocRow(
            title: "Trip to Chiang Mai", date: "Thu", excerpt: "Flights booked, need hotel near Nimman",
            pageCount: 4, tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        DocRow(
            emoji: "📝", title: "Meeting notes 31 Oct", date: "Yesterday",
            excerpt: "Decided to ship page chips on Friday",
            tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }
    .background(DocsColor.surfacePage)
    .environment(LocalizationStore())
    .preferredColorScheme(.dark)
}

#Preview("Ledger rows (accessibility size)") {
    DocRow(
        title: "Trip to Chiang Mai", date: "Thu", excerpt: "Flights booked, need hotel near Nimman",
        pageCount: 4, tintSeed: UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    .environment(LocalizationStore())
    .dynamicTypeSize(.accessibility3)
}
