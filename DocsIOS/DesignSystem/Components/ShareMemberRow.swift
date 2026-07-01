import SwiftUI

func shareMemberDisplaySuffix(isCurrentUser: Bool) -> String? {
    isCurrentUser ? "(you)" : nil
}

struct ShareMemberRow: View {
    let name: String
    let email: String
    var role: String = "Reader"
    var isCurrentUser: Bool = false
    var onTapRole: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Avatar(name: name, size: 40)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(name)
                        .font(DocsFont.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DocsColor.textPrimary)
                    if let suffix = shareMemberDisplaySuffix(isCurrentUser: isCurrentUser) {
                        Text(suffix)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                Text(email)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }

            Spacer()

            Button(action: { onTapRole?() }) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(role)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
            .accessibilityLabel("Role: \(role)")
            .accessibilityHint("Double tap to change role")
        }
        .padding(.horizontal, DocsSpacing.gutterGrouped)
        .frame(minHeight: DocsSpacing.rowMinHeight)
    }
}

#Preview {
    VStack(spacing: 0) {
        ShareMemberRow(name: "Camille Moreau", email: "camille.moreau@beta.gouv.fr", role: "Admin", isCurrentUser: true)
        ShareMemberRow(name: "Alfredo Levin", email: "alfredo.levin@test.gouv.fr", role: "Editor")
        ShareMemberRow(name: "Desirae Dokidis", email: "desirae.dokidis@gmail.com", role: "Reader")
    }
}
