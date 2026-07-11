import SwiftUI

/// Pure and testable: the *localized* "(you)" label is resolved by the caller
/// (from `LocalizationStore`) and passed in, so this only owns the
/// current-user branching, not the translation lookup — mirrors
/// `docRowAccessibilityLabel`.
func shareMemberDisplaySuffix(isCurrentUser: Bool, youLabel: String) -> String? {
    isCurrentUser ? youLabel : nil
}

struct ShareMemberRow: View {
    let name: String
    let email: String
    var role: String = "Reader"
    var isCurrentUser: Bool = false
    var onTapRole: (() -> Void)? = nil

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Avatar(name: name, size: 40)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space2xs) {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DocsColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let suffix = shareMemberDisplaySuffix(isCurrentUser: isCurrentUser, youLabel: loc[.common_you]) {
                        Text(suffix)
                            .font(DocsFont.caption)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                if !email.isEmpty {
                    Text(email)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { onTapRole?() }) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(role)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DocsColor.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DocsColor.textSecondary)
                }
                .frame(minHeight: DocsSpacing.rowMinHeight)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(loc.format(.sharemember_role_a11y, role))
            .accessibilityHint(loc[.sharemember_role_hint])
        }
        .padding(.horizontal, DocsSpacing.space3xs)
        .padding(.vertical, DocsSpacing.spaceXS)
    }
}

#Preview {
    VStack(spacing: 0) {
        ShareMemberRow(name: "Camille Moreau", email: "camille.moreau@beta.gouv.fr", role: "Admin", isCurrentUser: true)
        ShareMemberRow(name: "Alfredo Levin", email: "alfredo.levin@test.gouv.fr", role: "Editor")
        ShareMemberRow(name: "Desirae Dokidis", email: "desirae.dokidis@gmail.com", role: "Reader")
    }
    .environment(LocalizationStore())
}
