import SwiftUI

/// Maps a role to the localized key that names it. Exhaustive over
/// `DocumentRole` because a document's owner can appear in the members list.
func roleTitleKey(_ role: DocumentRole) -> L10nKey {
    switch role {
    case .reader: return .share_role_reader
    case .commenter: return .share_role_commenter
    case .editor: return .share_role_editor
    case .administrator: return .share_role_administrator
    case .owner: return .share_role_owner
    }
}

@MainActor
func shareRoleDisplayTitle(_ role: DocumentRole, isPending: Bool, loc: LocalizationStore) -> String {
    let base = loc[roleTitleKey(role)]
    return isPending ? loc.format(.share_role_pending, base) : base
}

struct ShareSheetView: View {
    @Bindable var viewModel: ShareViewModel
    var shareURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationStore.self) private var loc

    @State private var memberPendingRoleChange: ShareMember?
    @State private var isChoosingLinkReach = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DocsTextField(
                    text: $viewModel.searchQuery, placeholder: loc[.share_invite_placeholder],
                    icon: "person.badge.plus"
                )
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.vertical, DocsSpacing.spaceSM)

                if let errorKey = viewModel.errorKey {
                    Text(loc[errorKey])
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .padding(.horizontal, DocsSpacing.gutter)
                }

                ScrollView {
                    if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResultsSection
                    } else {
                        VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
                            membersSection

                            Rectangle()
                                .fill(DocsColor.borderDefault)
                                .frame(height: 1)

                            linkSection
                            copyLinkButton
                        }
                        .padding(.horizontal, DocsSpacing.gutter)
                        .padding(.top, DocsSpacing.space3xs)
                    }
                }
                .refreshable { await viewModel.load() }
            }
            .background(DocsColor.surfacePage)
            .navigationTitle(loc[.share_title])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc[.common_done]) { dismiss() }
                }
            }
            .task {
                await viewModel.load()
            }
            .task(id: viewModel.searchQuery) {
                await viewModel.search()
            }
            .confirmationDialog(
                loc[.share_change_role],
                isPresented: Binding(
                    get: { memberPendingRoleChange != nil },
                    set: { if !$0 { memberPendingRoleChange = nil } }
                ),
                presenting: memberPendingRoleChange
            ) { member in
                // Role changes only apply to existing accesses; pending invitations
                // have no update-role endpoint, so offering role buttons there would
                // be dead UI. Show only "Remove" for invitations.
                if case .access(let access) = member {
                    ForEach([DocumentRole.reader, .commenter, .editor, .administrator], id: \.self) { role in
                        Button(loc[roleTitleKey(role)]) {
                            Task { await viewModel.updateRole(accessID: access.id, role: role) }
                        }
                    }
                }
                Button(loc[.share_remove], role: .destructive) {
                    Task { await viewModel.removeMember(member) }
                }
            }
            .confirmationDialog(loc[.share_link_access], isPresented: $isChoosingLinkReach) {
                Button(loc[.reach_restricted]) {
                    Task { await viewModel.updateLinkConfiguration(reach: .restricted, role: nil) }
                }
                Button(loc[.share_reach_authenticated]) {
                    Task { await viewModel.updateLinkConfiguration(reach: .authenticated, role: .reader) }
                }
                Button(loc[.share_reach_public]) {
                    Task { await viewModel.updateLinkConfiguration(reach: .public, role: .reader) }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DocsFont.footnote)
            .tracking(DocsTypographySpec.footnote.size * DocsTracking.eyebrow)
            .foregroundStyle(DocsColor.textTertiary)
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if viewModel.searchResults.isEmpty {
            // Avoid an empty bordered card while there are no matches.
            Text(loc[.share_no_people_found])
                .font(DocsFont.subhead)
                .foregroundStyle(DocsColor.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DocsSpacing.spaceLG)
        } else {
            ListSection(header: loc[.share_add_people]) {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { index, user in
                        if index > 0 { ProfileRowDivider() }
                        ListRow(
                            title: user.fullName, subtitle: user.email,
                            action: {
                                Task { await viewModel.invite(user: user, role: .reader) }
                            })
                    }
                }
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.top, DocsSpacing.space3xs)
        }
    }

    private var copyLinkButton: some View {
        DocsButton(
            title: loc[.share_copy_link], variant: .secondary, color: .brand, size: .large, icon: "link",
            fullWidth: true, pill: true, isDisabled: shareURL == nil
        ) {
            guard let shareURL else { return }
            UIPasteboard.general.string = shareURL.absoluteString
            dismiss()
        }
        .padding(.bottom, DocsSpacing.spaceBase)
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            sectionLabel(loc[.share_link_parameters])
            HStack {
                LinkReachPill(reach: viewModel.linkReach, showsHint: true)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 22))
                    .foregroundStyle(DocsColor.gray300)
            }
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .contentShape(Rectangle())
            .onTapGesture { isChoosingLinkReach = true }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(loc[.share_change_link_access])
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
            sectionLabel(
                loc.plural(viewModel.members.count, one: .share_members_one, other: .share_members_other)
            )
            ForEach(viewModel.members) { member in
                ShareMemberRow(
                    name: member.displayName,
                    // A pending invite has no name, so displayName == email; drop
                    // the subtitle to avoid printing the email twice.
                    email: member.displayName == member.email ? "" : member.email,
                    role: shareRoleDisplayTitle(member.role, isPending: member.isPending, loc: loc),
                    onTapRole: { memberPendingRoleChange = member }
                )
            }
        }
    }
}

#Preview {
    ShareSheetView(
        viewModel: ShareViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            linkReach: .restricted,
            linkRole: nil
        )
    )
    .environment(LocalizationStore())
}
