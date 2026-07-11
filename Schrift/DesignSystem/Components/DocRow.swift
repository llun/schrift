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
    reach: LinkReach,
    date: String,
    pinned: Bool,
    pinnedLabel: String,
    sharedWithOrganizationLabel: String,
    publicLabel: String
) -> String {
    var parts = [title]
    if pinned {
        parts.append(pinnedLabel)
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
    return parts.joined(separator: ", ")
}

struct DocRow: View {
    var emoji: String? = nil
    var title: String = "Untitled document"
    var pinned: Bool = false
    var reach: LinkReach = .restricted
    var date: String = ""
    var offlineAvailable: Bool = false
    var onOpen: (() -> Void)? = nil

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            DocIcon(emoji: emoji, tinted: true, pinned: pinned)

            // Title and its inline reach glyph sit 6pt apart (reference), while
            // the DocIcon keeps the outer 12pt gap.
            HStack(spacing: DocsSpacing.space2xs) {
                Text(title)
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
                    .lineLimit(1)

                if let indicatorIcon = docRowReachIndicatorIcon(reach: reach) {
                    MaterialSymbol(indicatorIcon, size: 16)
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }

            Spacer(minLength: DocsSpacing.spaceXS)

            if offlineAvailable {
                MaterialSymbol(.cloud_done, size: 16)
                    .foregroundStyle(DocsColor.gray350)
                    .accessibilityLabel(loc[.docrow_available_offline])
            }

            if !date.isEmpty {
                Text(date)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
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
                title: title, reach: reach, date: date, pinned: pinned,
                pinnedLabel: loc[.docrow_pinned],
                sharedWithOrganizationLabel: loc[.docrow_shared_with_organization],
                publicLabel: loc[.docrow_public]
            )
        )
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    VStack(spacing: 0) {
        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
        DocRow(emoji: "📊", title: "Roadmap", reach: .authenticated, date: "Yesterday")
        DocRow(title: "Public notes", reach: .public, date: "Last week")
    }
    .environment(LocalizationStore())
}
