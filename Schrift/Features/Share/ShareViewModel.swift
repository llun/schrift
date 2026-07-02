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
    var errorMessage: String?

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
        errorMessage = nil
        do {
            async let accessesPage = client.listAccesses(documentID: documentID)
            async let invitationsPage = client.listInvitations(documentID: documentID)
            let accesses = try await accessesPage.results
            let invitations = try await invitationsPage.results
            members = shareMembers(accesses: accesses, invitations: invitations)
        } catch {
            errorMessage = "Couldn't load members. Pull to refresh to try again."
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
            errorMessage = "Search failed. Please try again."
        }
    }

    func invite(user: UserSearchResult, role: DocumentRole) async {
        do {
            _ = try await client.createAccess(documentID: documentID, userID: user.id, role: role)
            searchQuery = ""
            searchResults = []
            await load()
        } catch {
            errorMessage = "Couldn't add member. Please try again."
        }
    }

    func updateRole(accessID: UUID, role: DocumentRole) async {
        do {
            _ = try await client.updateAccess(documentID: documentID, accessID: accessID, role: role)
            await load()
        } catch {
            errorMessage = "Couldn't update role. Please try again."
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
            errorMessage = "Couldn't remove member. Please try again."
        }
    }

    func updateLinkConfiguration(reach: LinkReach, role: LinkRole?) async {
        do {
            let result = try await client.setLinkConfiguration(documentID: documentID, linkReach: reach, linkRole: role)
            linkReach = result.linkReach
            linkRole = result.linkRole
        } catch {
            errorMessage = "Couldn't update link settings. Please try again."
        }
    }
}
