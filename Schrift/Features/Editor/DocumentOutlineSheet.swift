import SwiftUI

/// A request for the visible canvas to scroll somewhere, made by the outline sheet.
///
/// The reading surface and the editing canvas each own their own `ScrollViewReader`, so the sheet
/// cannot reach either proxy. It hands the editor one of these instead, and whichever canvas is on
/// screen scrolls when it changes. The `token` makes asking for the same target twice (stepping
/// from a match, scrolling away, stepping back) a new request rather than an equal value that
/// `onChange` would swallow.
struct DocumentScrollRequest: Equatable {
    let target: EditorScrollTarget
    let token: Int

    /// The request that follows `previous` and asks for `target`.
    static func following(_ previous: DocumentScrollRequest?, target: EditorScrollTarget) -> DocumentScrollRequest {
        DocumentScrollRequest(target: target, token: (previous?.token ?? 0) + 1)
    }
}

/// "In this document": the open document's headings as a tappable outline, with find.
///
/// Separate from the Pages drawer, which is about the *other* pages. Tapping a heading scrolls the
/// editor there and closes the sheet. Typing in the find field shows "2 of 5" with previous/next
/// buttons that scroll to each matching block while the sheet stays up, and badges every heading
/// whose section holds matches with how many. All the rules live in `DocumentOutline.swift`.
struct DocumentOutlineSheet: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationStore.self) private var loc

    /// The document's title, listed first as the way back to the top.
    let documentTitle: String
    /// The document's blocks as they are now, so the outline follows edits and live changes.
    let blocks: [EditorBlock]
    /// Takes keyboard focus in the find field as the sheet appears (the Command-F route).
    var focusesFind = false
    /// Scrolls the editor's visible canvas to a target.
    let onScroll: (EditorScrollTarget) -> Void
    /// Jumps to a tapped heading. Separate from `onScroll` so the editing canvas can move focus
    /// there: otherwise UIKit gives the caret back to the old block when the sheet closes and the
    /// canvas scrolls back to it. Falls back to a plain scroll.
    var onSelectHeading: ((UUID) -> Void)?

    @State private var query = ""
    /// The match the stepper is on. An id rather than an index so an edit that adds or removes
    /// matches elsewhere does not slide the position onto a different block.
    @State private var currentMatchID: UUID?

    private var isFinding: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let matches = findMatchingBlockIDs(in: blocks, query: query)
        let items = buildOutline(blocks: blocks, matchingBlockIDs: matches)
        let position: Int? = currentMatchID.flatMap { matches.firstIndex(of: $0) } ?? (matches.isEmpty ? nil : 0)
        VStack(spacing: 0) {
            SheetHeader(title: loc[.outline_title], closeLabel: loc[.common_close], onClose: { dismiss() })

            SearchField(text: $query, placeholder: loc[.outline_find_placeholder], autoFocus: focusesFind)
                .padding(.horizontal, DocsSpacing.gutter)

            if isFinding {
                matchStepper(matches: matches, position: position)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    ForEach(items) { item in
                        headingRow(item)
                    }
                    if items.isEmpty && !isFinding {
                        Text(loc[.outline_empty])
                            .font(DocsFont.footnote)
                            .foregroundStyle(theme.colors.textTertiary)
                            .padding(.horizontal, DocsSpacing.gutter)
                            .padding(.vertical, DocsSpacing.spaceSM)
                    }
                }
                .padding(.top, DocsSpacing.spaceXS)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.colors.surfacePage)
        .onChange(of: query) { _, _ in
            // A new query starts at its first match, and the canvas behind follows so "1 of 5" is
            // true of what is on screen.
            let found = findMatchingBlockIDs(in: blocks, query: query)
            currentMatchID = found.first
            if let first = found.first { onScroll(.block(first)) }
            announceMatch(position: found.isEmpty ? nil : 0, count: found.count)
        }
    }

    // MARK: - Find

    private func matchStepper(matches: [UUID], position: Int?) -> some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            Text(
                matches.isEmpty
                    ? loc[.outline_no_matches]
                    : loc.format(.outline_match_position, (position ?? 0) + 1, matches.count)
            )
            .font(DocsFont.footnote)
            .foregroundStyle(theme.colors.textSecondary)
            .monospacedDigit()

            Spacer(minLength: DocsSpacing.spaceXS)

            // No up-chevron glyph in the bundled icon font; the down chevron turned over is one.
            IconButton(
                icon: .expand_more, label: loc[.outline_previous], size: .small, isDisabled: matches.isEmpty,
                action: { step(-1, matches: matches, from: position) }
            )
            .rotationEffect(.degrees(180))
            IconButton(
                icon: .expand_more, label: loc[.outline_next], size: .small, isDisabled: matches.isEmpty,
                action: { step(1, matches: matches, from: position) }
            )
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.top, DocsSpacing.space3xs)
    }

    private func step(_ delta: Int, matches: [UUID], from position: Int?) {
        guard let index = steppedMatchIndex(from: position, by: delta, count: matches.count) else { return }
        currentMatchID = matches[index]
        onScroll(.block(matches[index]))
        announceMatch(position: index, count: matches.count)
    }

    /// Focus stays on the Previous/Next button (or the field), so say which match the canvas is on.
    private func announceMatch(position: Int?, count: Int) {
        guard isFinding else { return }
        let text = position.map { loc.format(.outline_match_position, $0 + 1, count) } ?? loc[.outline_no_matches]
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: - Rows

    private var titleRow: some View {
        let trimmed = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            onScroll(.header)
            dismiss()
        } label: {
            Text(trimmed.isEmpty ? loc[.common_untitled] : trimmed)
                .font(DocsFont.headline)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headingRow(_ item: OutlineItem) -> some View {
        let hasMatches = item.matchCount > 0
        return Button {
            if let onSelectHeading {
                onSelectHeading(item.blockID)
            } else {
                onScroll(.block(item.blockID))
            }
            dismiss()
        } label: {
            HStack(spacing: DocsSpacing.spaceXS) {
                Text(item.title)
                    .font(headingFont(level: item.level))
                    .foregroundStyle(headingColor(level: item.level, hasMatches: hasMatches))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: DocsSpacing.spaceXS)
                if hasMatches {
                    Badge(text: "\(item.matchCount)", tone: .accent)
                }
            }
            // Each level steps in by one gutter, on the leading side so right-to-left mirrors it.
            .padding(.leading, CGFloat(item.level - 1) * DocsSpacing.spaceBase)
            .padding(.horizontal, DocsSpacing.gutter)
            .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(hasMatches ? loc.format(.outline_section_matches_a11y, item.matchCount) : "")
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: DocsFont.headline
        case 2: DocsFont.body
        default: DocsFont.subhead
        }
    }

    private func headingColor(level: Int, hasMatches: Bool) -> Color {
        if hasMatches { return theme.colors.textBrand }
        return level >= 3 ? theme.colors.textSecondary : theme.colors.textPrimary
    }
}

/// The Command-F entry point: a zero-size button whose only job is to own the key equivalent.
///
/// The editor has no menu bar command to hang a shortcut on, so a hidden control carries it. The
/// label is real text because iPadOS lists the shortcut by it in the Command-key overlay.
struct DocumentFindShortcut: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!isEnabled)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Presents the outline sheet and owns the Command-F shortcut that opens it, as one modifier so the
/// editor's already long modifier chain gains a single line rather than two.
struct DocumentOutlinePresentation: ViewModifier {
    @Binding var isPresented: Bool
    let focusesFind: Bool
    let documentTitle: String
    let blocks: [EditorBlock]
    let findShortcutTitle: String
    let findShortcutEnabled: Bool
    let onFindShortcut: () -> Void
    let onScroll: (EditorScrollTarget) -> Void
    let onSelectHeading: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .background {
                DocumentFindShortcut(title: findShortcutTitle, isEnabled: findShortcutEnabled, action: onFindShortcut)
            }
            .sheet(isPresented: $isPresented) {
                DocumentOutlineSheet(
                    documentTitle: documentTitle, blocks: blocks, focusesFind: focusesFind, onScroll: onScroll,
                    onSelectHeading: onSelectHeading
                )
                .presentationDetents([.medium, .large])
                // Let the canvas behind the half-height sheet be seen and scrolled while stepping
                // through matches. Regular-width iPad ignores detents (centered form sheet), so
                // stepping there may be covered; tapping a heading closes the sheet either way.
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
            }
    }
}
