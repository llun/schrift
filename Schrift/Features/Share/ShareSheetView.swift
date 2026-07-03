import SwiftUI

func shareRoleDisplayTitle(_ role: DocumentRole, isPending: Bool) -> String {
    let base = role.rawValue.capitalized
    return isPending ? "\(base) (Pending)" : base
}

struct ShareSheetView: View {
    @Bindable var viewModel: ShareViewModel
    var shareURL: URL? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var memberPendingRoleChange: ShareMember?
    @State private var isChoosingLinkReach = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DocsTextField(
                    text: $viewModel.searchQuery, placeholder: "Invite by name or email", icon: "person.badge.plus"
                )
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.vertical, DocsSpacing.spaceSM)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
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
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await viewModel.load()
            }
            .task(id: viewModel.searchQuery) {
                await viewModel.search()
            }
            .confirmationDialog(
                "Change Role",
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
                        Button(role.rawValue.capitalized) {
                            Task { await viewModel.updateRole(accessID: access.id, role: role) }
                        }
                    }
                }
                Button("Remove", role: .destructive) {
                    Task { await viewModel.removeMember(member) }
                }
            }
            .confirmationDialog("Link Access", isPresented: $isChoosingLinkReach) {
                Button("Restricted") { Task { await viewModel.updateLinkConfiguration(reach: .restricted, role: nil) } }
                Button("Anyone in the organization") {
                    Task { await viewModel.updateLinkConfiguration(reach: .authenticated, role: .reader) }
                }
                Button("Anyone with the link") {
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
            Text("No people found")
                .font(DocsFont.subhead)
                .foregroundStyle(DocsColor.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DocsSpacing.spaceLG)
        } else {
            ListSection(header: "Add people") {
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
            title: "Copy link", variant: .secondary, color: .brand, size: .large, icon: "link", fullWidth: true,
            pill: true, isDisabled: shareURL == nil
        ) {
            guard let shareURL else { return }
            UIPasteboard.general.string = shareURL.absoluteString
            dismiss()
        }
        .padding(.bottom, DocsSpacing.spaceBase)
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            sectionLabel("Link parameters")
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
            .accessibilityLabel("Change link access")
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
            sectionLabel("Shared with \(viewModel.members.count) \(viewModel.members.count == 1 ? "person" : "people")")
            ForEach(viewModel.members) { member in
                ShareMemberRow(
                    name: member.displayName,
                    // A pending invite has no name, so displayName == email; drop
                    // the subtitle to avoid printing the email twice.
                    email: member.displayName == member.email ? "" : member.email,
                    role: shareRoleDisplayTitle(member.role, isPending: member.isPending),
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
}
