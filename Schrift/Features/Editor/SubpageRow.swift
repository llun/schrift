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
        Button(action: { onOpen?() }) {
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
        }
        .buttonStyle(.plain)
        // `MaterialSymbol` is `accessibilityHidden` (a Private-Use-Area glyph with no spoken
        // text), so a state carried only by that glyph and a strikethrough has to be said.
        .accessibilityLabel(
            pendingDelete ? "\(displayTitle), \(loc[.docrow_pending_delete])" : displayTitle)
    }
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
