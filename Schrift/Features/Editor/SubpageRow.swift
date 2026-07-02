import SwiftUI

struct SubpageRow: View {
    let document: Document
    var onOpen: (() -> Void)? = nil

    private var displayTitle: String {
        let trimmed = document.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled document" : trimmed
    }

    private var summary: String? {
        guard let excerpt = document.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !excerpt.isEmpty else { return nil }
        return excerpt
    }

    var body: some View {
        Button(action: { onOpen?() }) {
            HStack(spacing: DocsSpacing.spaceSM) {
                DocIcon(size: 22)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(displayTitle)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textPrimary)
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
                        Image(systemName: "list.bullet.indent")
                        Text("\(document.numchild)")
                    }
                    .font(DocsFont.caption)
                    .foregroundStyle(DocsColor.textTertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 16))
                    .foregroundStyle(DocsColor.gray300)
            }
            .padding(.horizontal, DocsSpacing.spaceXS)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    }
    .padding()
}
