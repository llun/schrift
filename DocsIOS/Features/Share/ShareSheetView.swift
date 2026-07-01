import SwiftUI

func shareRoleDisplayTitle(_ role: DocumentRole, isPending: Bool) -> String {
    let base = role.rawValue.capitalized
    return isPending ? "\(base) (Pending)" : base
}

struct ShareSheetView: View {
    @Bindable var viewModel: ShareViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var memberPendingRoleChange: ShareMember?
    @State private var isChoosingLinkReach = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchField(text: $viewModel.searchQuery, placeholder: "Search by name or email")
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
                        linkSection
                        membersSection
                    }
                }
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
            .onChange(of: viewModel.searchQuery) {
                Task { await viewModel.search() }
            }
            .confirmationDialog(
                "Change Role",
                isPresented: Binding(
                    get: { memberPendingRoleChange != nil },
                    set: { if !$0 { memberPendingRoleChange = nil } }
                ),
                presenting: memberPendingRoleChange
            ) { member in
                ForEach([DocumentRole.reader, .commenter, .editor, .administrator], id: \.self) { role in
                    Button(role.rawValue.capitalized) {
                        if case .access(let access) = member {
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
                Button("Anyone in the organization") { Task { await viewModel.updateLinkConfiguration(reach: .authenticated, role: .reader) } }
                Button("Anyone with the link") { Task { await viewModel.updateLinkConfiguration(reach: .public, role: .reader) } }
            }
        }
    }

    private var searchResultsSection: some View {
        ListSection(header: "Add people") {
            VStack(spacing: 0) {
                ForEach(viewModel.searchResults) { user in
                    ListRow(title: user.fullName, subtitle: user.email, action: {
                        Task { await viewModel.invite(user: user, role: .reader) }
                    })
                }
            }
        }
    }

    private var linkSection: some View {
        ListSection(header: "Link Access") {
            HStack {
                LinkReachPill(reach: viewModel.linkReach, showsHint: true)
                Spacer()
            }
            .padding(.horizontal, DocsSpacing.gutterGrouped)
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .contentShape(Rectangle())
            .onTapGesture { isChoosingLinkReach = true }
        }
    }

    private var membersSection: some View {
        ListSection(header: "Members") {
            VStack(spacing: 0) {
                ForEach(viewModel.members) { member in
                    ShareMemberRow(
                        name: member.displayName,
                        email: member.email,
                        role: shareRoleDisplayTitle(member.role, isPending: member.isPending),
                        onTapRole: { memberPendingRoleChange = member }
                    )
                }
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
