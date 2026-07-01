import Foundation

struct ShareUser: Codable, Equatable, Hashable {
    let id: UUID?
    let email: String?
    let fullName: String?
    let shortName: String?
}

struct DocumentAccess: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    let user: ShareUser?
    let team: String?
    var role: DocumentRole
}

struct Invitation: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    let email: String
    var role: DocumentRole
    let isExpired: Bool
}

struct UserSearchResult: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    let email: String
    let fullName: String
    let shortName: String
}

struct LinkConfiguration: Codable, Equatable {
    let linkReach: LinkReach
    let linkRole: LinkRole?
}

enum ShareMember: Identifiable, Hashable {
    case access(DocumentAccess)
    case invitation(Invitation)

    var id: String {
        switch self {
        case .access(let access): return "access-\(access.id.uuidString)"
        case .invitation(let invitation): return "invitation-\(invitation.id.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case .access(let access):
            return access.user?.fullName ?? access.user?.email ?? access.team ?? "Unknown"
        case .invitation(let invitation):
            return invitation.email
        }
    }

    var email: String {
        switch self {
        case .access(let access): return access.user?.email ?? ""
        case .invitation(let invitation): return invitation.email
        }
    }

    var role: DocumentRole {
        switch self {
        case .access(let access): return access.role
        case .invitation(let invitation): return invitation.role
        }
    }

    var isPending: Bool {
        switch self {
        case .access: return false
        case .invitation: return true
        }
    }
}

func shareMembers(accesses: [DocumentAccess], invitations: [Invitation]) -> [ShareMember] {
    accesses.map(ShareMember.access) + invitations.filter { !$0.isExpired }.map(ShareMember.invitation)
}
