import Foundation

@MainActor
@Observable
final class ShareViewModel {
    var members: [ShareMember] = []
    var linkReach: LinkReach
    var linkRole: LinkRole?
    var searchQuery: String = ""
    var searchResults: [UserSearchResult] = []
    var isLoading = false
    var errorKey: L10nKey?

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID, linkReach: LinkReach, linkRole: LinkRole?) {
        self.client = client
        self.documentID = documentID
        self.linkReach = linkReach
        self.linkRole = linkRole
    }

    func load() async {
        isLoading = true
        errorKey = nil
        do {
            async let accessesList = client.listAccesses(documentID: documentID)
            async let invitationsPage = client.listInvitations(documentID: documentID)
            let accesses = try await accessesList
            let invitations = try await invitationsPage.results
            members = shareMembers(accesses: accesses, invitations: invitations)
        } catch {
            errorKey = .share_error_load
        }
        isLoading = false
    }

    func search() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        // Debounce: driven by `.task(id: searchQuery)`, a newer keystroke cancels
        // this task, so a stale response can't overwrite fresher results.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        do {
            let results = try await client.searchUsers(query: trimmed, excludingDocumentID: documentID)
            if Task.isCancelled || trimmed != searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) { return }
            searchResults = results
        } catch {
            if Task.isCancelled { return }
            errorKey = .share_error_search
        }
    }

    func invite(user: UserSearchResult, role: DocumentRole) async {
        do {
            _ = try await client.createAccess(documentID: documentID, userID: user.id, role: role)
            searchQuery = ""
            searchResults = []
            await load()
        } catch {
            errorKey = .share_error_invite
        }
    }

    func updateRole(accessID: UUID, role: DocumentRole) async {
        do {
            _ = try await client.updateAccess(documentID: documentID, accessID: accessID, role: role)
            await load()
        } catch {
            errorKey = .share_error_update_role
        }
    }

    func removeMember(_ member: ShareMember) async {
        do {
            switch member {
            case .access(let access):
                try await client.deleteAccess(documentID: documentID, accessID: access.id)
            case .invitation(let invitation):
                try await client.deleteInvitation(documentID: documentID, invitationID: invitation.id)
            }
            await load()
        } catch {
            errorKey = .share_error_remove_member
        }
    }

    func updateLinkConfiguration(reach: LinkReach, role: LinkRole?) async {
        do {
            let result = try await client.setLinkConfiguration(documentID: documentID, linkReach: reach, linkRole: role)
            linkReach = result.linkReach
            linkRole = result.linkRole
        } catch {
            errorKey = .share_error_update_link
        }
    }
}
