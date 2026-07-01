import XCTest
@testable import DocsIOS

final class ShareModelsDecodingTests: XCTestCase {
    func testDecodesFullDocumentAccess() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "document": {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "path": "0001", "depth": 1},
            "user": {"id": "9c2c2c2c-2c2c-4c2c-9c2c-2c2c2c2c2c2c", "email": "camille@example.com", "full_name": "Camille Moreau", "short_name": "Camille", "language": "en-us", "is_first_connection": false},
            "team": "",
            "role": "administrator",
            "abilities": {},
            "max_ancestors_role": null,
            "max_role": "administrator"
        }
        """.data(using: .utf8)!

        let access = try JSONDecoder.docsAPI.decode(DocumentAccess.self, from: json)
        XCTAssertEqual(access.user?.email, "camille@example.com")
        XCTAssertEqual(access.user?.fullName, "Camille Moreau")
        XCTAssertEqual(access.role, .administrator)
    }

    func testDecodesLightDocumentAccessWithoutUserIdOrEmail() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "document": {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "path": "0001", "depth": 1},
            "user": {"full_name": "Camille Moreau", "short_name": "Camille"},
            "team": "",
            "role": "reader",
            "abilities": {},
            "max_ancestors_role": null,
            "max_role": "reader"
        }
        """.data(using: .utf8)!

        let access = try JSONDecoder.docsAPI.decode(DocumentAccess.self, from: json)
        XCTAssertNil(access.user?.id)
        XCTAssertNil(access.user?.email)
        XCTAssertEqual(access.user?.fullName, "Camille Moreau")
    }

    func testDecodesInvitation() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "abilities": {},
            "created_at": "2026-01-15T10:30:00Z",
            "email": "new.member@example.com",
            "document": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "role": "editor",
            "issuer": "9c2c2c2c-2c2c-4c2c-9c2c-2c2c2c2c2c2c",
            "is_expired": false
        }
        """.data(using: .utf8)!

        let invitation = try JSONDecoder.docsAPI.decode(Invitation.self, from: json)
        XCTAssertEqual(invitation.email, "new.member@example.com")
        XCTAssertEqual(invitation.role, .editor)
        XCTAssertFalse(invitation.isExpired)
    }

    func testDecodesUserSearchResult() throws {
        let json = """
        {"id": "9c2c2c2c-2c2c-4c2c-9c2c-2c2c2c2c2c2c", "email": "camille@example.com", "full_name": "Camille Moreau", "short_name": "Camille", "language": "en-us", "is_first_connection": false}
        """.data(using: .utf8)!

        let user = try JSONDecoder.docsAPI.decode(UserSearchResult.self, from: json)
        XCTAssertEqual(user.email, "camille@example.com")
    }

    func testDecodesUserSearchResultsAsPlainArray() throws {
        let json = """
        [
            {"id": "9c2c2c2c-2c2c-4c2c-9c2c-2c2c2c2c2c2c", "email": "camille@example.com", "full_name": "Camille Moreau", "short_name": "Camille", "language": "en-us", "is_first_connection": false}
        ]
        """.data(using: .utf8)!

        let users = try JSONDecoder.docsAPI.decode([UserSearchResult].self, from: json)
        XCTAssertEqual(users.count, 1)
    }
}

final class ShareMembersTests: XCTestCase {
    private func makeAccess(email: String, role: DocumentRole) -> DocumentAccess {
        DocumentAccess(id: UUID(), user: ShareUser(id: UUID(), email: email, fullName: email, shortName: email), team: nil, role: role)
    }

    private func makeInvitation(email: String, role: DocumentRole, isExpired: Bool = false) -> Invitation {
        Invitation(id: UUID(), email: email, role: role, isExpired: isExpired)
    }

    func testCombinesAccessesAndInvitations() {
        let access = makeAccess(email: "member@example.com", role: .editor)
        let invitation = makeInvitation(email: "pending@example.com", role: .reader)

        let members = shareMembers(accesses: [access], invitations: [invitation])

        XCTAssertEqual(members.count, 2)
        XCTAssertFalse(members[0].isPending)
        XCTAssertTrue(members[1].isPending)
    }

    func testExpiredInvitationsAreExcluded() {
        let invitation = makeInvitation(email: "expired@example.com", role: .reader, isExpired: true)

        let members = shareMembers(accesses: [], invitations: [invitation])

        XCTAssertTrue(members.isEmpty)
    }

    func testDisplayNameFallsBackToEmailWhenFullNameMissing() {
        let access = DocumentAccess(id: UUID(), user: ShareUser(id: nil, email: "only-email@example.com", fullName: nil, shortName: nil), team: nil, role: .reader)
        XCTAssertEqual(ShareMember.access(access).displayName, "only-email@example.com")
    }
}

final class ShareEndpointsPathTests: XCTestCase {
    func testUserSearchPathEncodesQueryAndDocumentID() {
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
        let path = userSearchPath(query: "cam", excludingDocumentID: id)
        XCTAssertTrue(path.hasPrefix("users/?"))
        XCTAssertTrue(path.contains("q=cam"))
        XCTAssertTrue(path.contains("document_id=8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b"))
    }
}
