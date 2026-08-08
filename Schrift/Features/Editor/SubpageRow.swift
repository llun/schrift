import SwiftUI

struct SubpageRow: View {
    let document: Document
    /// Deleted on this device, waiting for the server to be told. The row stays — struck
    /// through, with a delete glyph — because the deletion is still undoable, and the tap
    /// offers that instead of opening the document.
    var pendingDelete: Bool = false
    var onOpen: (() -> Void)? = nil

    @Environment(LocalizationStore.self) private var loc

    private var displayTitle: String {
        let trimmed = document.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? loc[.common_untitled] : trimmed
    }

    /// The handoff's subpage rows carry a one-line summary under the title.
    /// Blank excerpts are dropped rather than rendered as an empty second line.
    private var summary: String? {
        let trimmed = document.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        // **A tap gesture, not a `Button`** — matching `DocRow`, and for a specific reason:
        // this row is wrapped in `SwipeRevealRow`, and a `Button`'s own gesture begins
        // tracking on touch-down and can still fire on touch-up *after* a horizontal swipe.
        // The two recognizers run simultaneously (there is no supported way to make the
        // enclosing `ScrollView` yield), so nothing else would cancel it and swiping a
        // sub-page would open the document. `.contentShape(Rectangle())` + `.onTapGesture`
        // has no such touch-down phase: a drag past the slop simply never becomes a tap.
        //
        // The `.isButton` trait below is what a `Button` used to supply, and the composed
        // label was already explicit, so VoiceOver is unchanged.
        HStack(spacing: DocsSpacing.spaceSM) {
            DocIcon(size: 22)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                Text(displayTitle)
                    .font(DocsFont.body)
                    .foregroundStyle(pendingDelete ? DocsColor.textTertiary : DocsColor.textPrimary)
                    .strikethrough(pendingDelete)
                    .lineLimit(1)

                if let summary {
                    Text(summary)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DocsSpacing.spaceXS)

            if document.numchild > 0 {
                HStack(spacing: DocsSpacing.space4xs) {
                    MaterialSymbol(.account_tree, size: 14)
                    Text("\(document.numchild)")
                }
                .font(DocsFont.caption)
                .foregroundStyle(DocsColor.textTertiary)
            }

            if pendingDelete {
                MaterialSymbol(.delete, size: 16)
                    .foregroundStyle(DocsColor.gray350)
            } else {
                MaterialSymbol(.chevron_right, size: 18)
                    .foregroundStyle(DocsColor.gray300)
            }
        }
        .padding(.horizontal, DocsSpacing.spaceXS)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        // One composed label, like `DocRow` and `SharedRow`. Applying a label to a `Button`
        // *replaces* the composition of its children, so this has to fold everything back in
        // — an earlier version set only the title and silently dropped the excerpt and the
        // sub-page count from every ordinary row. The `pendingDelete` phrase is here because
        // `MaterialSymbol` is `accessibilityHidden` (a Private-Use-Area glyph with no spoken
        // text), so a state carried only by that glyph and a strikethrough is otherwise
        // invisible.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            subpageRowAccessibilityLabel(
                title: displayTitle, summary: summary, childCount: document.numchild,
                pendingDelete: pendingDelete, pendingDeleteLabel: loc[.docrow_pending_delete])
        )
        .accessibilityAddTraits(.isButton)
    }
}

/// Pure and testable: the *localized* phrase is resolved by the caller and passed in, so this
/// owns only the ordering, matching `docRowAccessibilityLabel`.
///
/// The pending-deletion phrase comes straight after the title — it is the most actionable
/// fact about the row, and the one a reader needs before the excerpt.
func subpageRowAccessibilityLabel(
    title: String,
    summary: String?,
    childCount: Int,
    pendingDelete: Bool = false,
    pendingDeleteLabel: String = ""
) -> String {
    var parts = [title]
    if pendingDelete, !pendingDeleteLabel.isEmpty {
        parts.append(pendingDeleteLabel)
    }
    if let summary, !summary.isEmpty {
        parts.append(summary)
    }
    if childCount > 0 {
        parts.append("\(childCount)")
    }
    return parts.joined(separator: ", ")
}

#Preview {
    VStack(spacing: 0) {
        SubpageRow(
            document: Document(
                id: UUID(),
                title: "Meeting notes",
                excerpt: "Highlights from the sync",
                abilities: DocumentAbilities(),
                linkReach: .restricted,
                linkRole: .reader,
                isFavorite: false,
                depth: 2,
                numchild: 3,
                path: "0001",
                createdAt: Date(),
                updatedAt: Date(),
                userRole: nil,
                creator: nil
            )
        )
        SubpageRow(
            document: Document(
                id: UUID(),
                title: "Deleted while offline",
                excerpt: nil,
                abilities: DocumentAbilities(),
                linkReach: .restricted,
                linkRole: .reader,
                isFavorite: false,
                depth: 2,
                numchild: 0,
                path: "0002",
                createdAt: Date(),
                updatedAt: Date(),
                userRole: nil,
                creator: nil
            ),
            pendingDelete: true
        )
    }
    .padding()
    .environment(LocalizationStore())
}

#Preview("Dark") {
    VStack(spacing: 0) {
        SubpageRow(
            document: Document(
                id: UUID(), title: "Meeting notes", excerpt: "Highlights from the sync",
                abilities: DocumentAbilities(), linkReach: .restricted, linkRole: .reader,
                isFavorite: false, depth: 2, numchild: 3, path: "0001",
                createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
        )
        SubpageRow(
            document: Document(
                id: UUID(), title: "Deleted while offline", excerpt: nil,
                abilities: DocumentAbilities(), linkReach: .restricted, linkRole: .reader,
                isFavorite: false, depth: 2, numchild: 0, path: "0002",
                createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil),
            pendingDelete: true
        )
    }
    .padding()
    .background(DocsColor.surfacePage)
    .environment(LocalizationStore())
    .preferredColorScheme(.dark)
}
