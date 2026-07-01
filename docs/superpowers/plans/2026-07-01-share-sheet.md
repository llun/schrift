# Share Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Share sheet (part of design spec Phase 8): invite members by email search, manage existing members' roles (including pending invitations), and change the document's link-sharing reach/role — wired to the real accesses/invitations/link-configuration/user-search APIs. Wires `EditorView`'s previously-no-op Share button to present this sheet. This is a large phase, split into two plans per the design spec's own "small PRs" build-sequence intent (matching how Home and Editor were each kept single-plan-sized) — the **Options sheet** (Pin/Unpin, Copy link, Copy as Markdown, Duplicate, Delete) is a separate, smaller follow-up plan.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including a Simulator screenshot of the sheet with sample members, one real member and one pending invitation together — and the exact request/response shapes were read directly from the real `suitenumerique/docs` backend source. This plan's research surfaced more distinct endpoint groups than any prior plan (`accesses`, `invitations`, `link-configuration`, user search), and validation caught one real, easy-to-miss encoding bug:

- **`PUT /documents/{id}/link-configuration/` is validated server-side with `partial=True`, which means `link_role` must be sent as an explicit JSON `null` when the reach is "restricted" — omitting the key entirely leaves a stale non-null role in the database.** Naively, `JSONEncoder`'s synthesized `Encodable` conformance for a struct with an `Optional` property does **not** emit `"key": null` for `nil` — it silently omits the key (`encodeIfPresent` semantics). Verified directly: a request built from a synthesized-`Encodable` request struct with `linkRole: nil` produced a JSON body with no `link_role` key at all. `LinkConfigurationRequest` in this plan has a **hand-written `encode(to:)`** that calls `container.encodeNil(forKey: .linkRole)` when the value is `nil`, confirmed via a test that inspects the actual serialized request body for the literal JSON `null`.
- **`DocumentAccessSerializer` dynamically returns different `user` shapes depending on the requester's privilege level** (`DocumentAccessViewSet.get_serializer_class` picks `DocumentAccessSerializer`, full user object, for admins/owners, or `DocumentAccessLightSerializer`, name-only, for everyone else). `ShareUser`'s fields (`id`, `email`, `fullName`, `shortName`) are all `Optional?` so both shapes decode without error — the app doesn't know in advance which shape a given account will receive.
- **Members and pending invitations are two different backend resources merged into one list client-side.** `GET /documents/{id}/accesses/` (real, accepted members) and `GET /documents/{id}/invitations/` (pending, not-yet-accepted invites) are fetched concurrently and combined into a single `[ShareMember]` via `shareMembers(accesses:invitations:)` — a pure, tested function. Expired invitations are filtered out (nothing productive for the user to do with a dead invite in this list). `ShareMember` is an enum (`.access`/`.invitation`) so `ShareMemberRow`'s existing `role`/`name`/`email` parameters can be driven uniformly, while role editing (`updateRole`) is intentionally typed to accept only a real `DocumentAccess` — a pending invitation's role is not editable in place in this plan (only removable), matching how the design spec's Share sheet only calls out a role *picker* for existing members, not invitation editing.
- **`GET /users/?q=&document_id=` returns a plain JSON array, not the `{count, next, previous, results}` wrapper every other list endpoint in this app uses** — confirmed directly: `UserViewSet.pagination_class = None`. `searchUsers` decodes `[UserSearchResult]` directly, not `PaginatedResponse<UserSearchResult>`.
- **`POST /documents/{id}/accesses/` expects the JSON key `user_id`, not `user`** — the backend docstring on `DocumentAccessViewSet` says `user: str`, but the actual `DocumentAccessSerializer.user_id` field (`source="user"`, `write_only=True`) is what DRF actually deserializes from; the docstring is stale relative to the code, so the real field definition (not the docstring) was trusted and verified with a test that inspects the sent request body.
- **`EditorViewModel.client` and `.documentID` both move from `private let` to `let`** (mirroring the identical `HomeViewModel.client` visibility change from the Home Screen plan) so `EditorView` can construct a `ShareViewModel` pointed at the same client and document when the user taps Share — a small, mechanical, low-risk modification to already-merged code, not a behavior change.
- **`EditorView` gains a `linkRole: LinkRole? = nil` parameter, and `HomeView`'s `.navigationDestination` passes `document.linkRole` through** — `EditorView` already received `reach: LinkReach` (from `document.linkReach`, the document's own explicit setting, not the ancestor-inherited `computedLinkReach`) since the read-only Editor Screen plan; this plan adds the matching `linkRole` so the Share sheet's link picker has both halves of the document's actual link configuration to seed itself with.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `LinkConfigurationRequest.encode(to:)` must explicitly call `encodeNil(forKey: .linkRole)` when `linkRole` is `nil` — do not replace this with a synthesized `Encodable` conformance or an `encodeIfPresent`-based approach; both silently omit the key instead of sending JSON `null`, which the backend's `partial=True` validation depends on to actually clear the field.
- `POST /documents/{id}/accesses/` must send the JSON key `user_id`, not `user` — trust `DocumentAccessSerializer`'s actual field definition over the (stale) docstring on `DocumentAccessViewSet`.
- `searchUsers` must decode a plain `[UserSearchResult]` array, never `PaginatedResponse<UserSearchResult>` — the backend's `UserViewSet` explicitly disables pagination.
- `ShareViewModel.updateRole` accepts a `DocumentAccess` (or its `accessID`), not a general `ShareMember` — pending invitations are removable but not role-editable in this plan.
- Reuse `MockURLProtocol` from `DocsIOSTests/Core/Networking/MockURLProtocol.swift` for all new networking-dependent tests — do not create a second mock URLProtocol.
- Do not build the Options sheet (Pin/Unpin, Copy link, Copy as Markdown, Duplicate, Delete) in this plan — it is a separate, smaller follow-up plan per this plan's own scope split.
- Task 3 and Task 4 have no new XCTest files by design — they are UI glue verified by build-check and a Simulator screenshot. If `RootView.swift` is temporarily swapped for screenshots, it MUST be reverted to the real auth-gated version before committing — never commit a temporary version.

## File Structure

```
DocsIOS/
├── Core/
│   └── Networking/
│       ├── ShareModels.swift                                 — ShareUser, DocumentAccess, Invitation, UserSearchResult, LinkConfiguration, ShareMember, shareMembers (Task 1)
│       └── ShareEndpoints.swift                               — userSearchPath, DocsAPIClient accesses/invitations/link-configuration/user-search methods (Task 1)
└── Features/
    ├── Share/
    │   ├── ShareViewModel.swift                                — ShareViewModel (Task 2)
    │   └── ShareSheetView.swift                                — shareRoleDisplayTitle, ShareSheetView (Task 3)
    ├── Editor/
    │   ├── EditorViewModel.swift                               — MODIFY: client/documentID visibility (Task 4)
    │   └── EditorView.swift                                    — MODIFY: linkRole parameter, Share button wiring (Task 4)
    └── Home/
        └── HomeView.swift                                      — MODIFY: pass document.linkRole to EditorView (Task 4)

DocsIOSTests/
├── Core/
│   └── Networking/
│       ├── ShareModelsTests.swift                              — Task 1
│       └── ShareEndpointsClientTests.swift                     — Task 1
└── Features/
    └── Share/
        └── ShareViewModelTests.swift                           — Task 2
```

---

### Task 1: Share Codable models + endpoints

**Files:**
- Create: `DocsIOS/Core/Networking/ShareModels.swift`
- Create: `DocsIOS/Core/Networking/ShareEndpoints.swift`
- Test: `DocsIOSTests/Core/Networking/ShareModelsTests.swift`
- Test: `DocsIOSTests/Core/Networking/ShareEndpointsClientTests.swift`

**Interfaces:**
- Consumes: `DocsAPIClient`, `DocumentRole`, `LinkReach`, `LinkRole`, `PaginatedResponse`, `MockURLProtocol` (earlier plans).
- Produces: `struct ShareUser`, `struct DocumentAccess`, `struct Invitation`, `struct UserSearchResult`, `struct LinkConfiguration`, `enum ShareMember`, `func shareMembers(accesses:invitations:) -> [ShareMember]`, `func userSearchPath(query:excludingDocumentID:) -> String`, and on `DocsAPIClient`: `.listAccesses`, `.createAccess`, `.updateAccess`, `.deleteAccess`, `.listInvitations`, `.createInvitation`, `.deleteInvitation`, `.setLinkConfiguration`, `.searchUsers` — all consumed by Task 2's `ShareViewModel`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/ShareModelsTests.swift`:
```swift
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
```

`DocsIOSTests/Core/Networking/ShareEndpointsClientTests.swift`:
```swift
import XCTest
@testable import DocsIOS

private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let bytesRead = stream.read(&buffer, maxLength: bufferSize)
        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)
        } else {
            break
        }
    }
    return data
}

final class ShareEndpointsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func testSetLinkConfigurationWithRestrictedReachSendsExplicitNullLinkRole() async throws {
        let responseBody = #"{"link_reach": "restricted", "link_role": null}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()

        let result = try await client.setLinkConfiguration(documentID: documentID, linkReach: .restricted, linkRole: nil)

        XCTAssertEqual(result.linkReach, .restricted)
        XCTAssertNil(result.linkRole)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PUT")
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertTrue(json.keys.contains("link_role"))
        XCTAssertTrue(json["link_role"] is NSNull)
    }

    func testSetLinkConfigurationWithAuthenticatedReachSendsLinkRole() async throws {
        let responseBody = #"{"link_reach": "authenticated", "link_role": "reader"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()

        let result = try await client.setLinkConfiguration(documentID: documentID, linkReach: .authenticated, linkRole: .reader)

        XCTAssertEqual(result.linkReach, .authenticated)
        XCTAssertEqual(result.linkRole, .reader)
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["link_role"], "reader")
    }

    func testCreateAccessSendsUserIdAndRole() async throws {
        let responseBody = """
        {"id": "22222222-2222-4222-8222-222222222222", "document": {"id": "11111111-1111-4111-8111-111111111111", "path": "0001", "depth": 1}, "user": {"id": "33333333-3333-4333-8333-333333333333", "email": "new@example.com", "full_name": "New Member", "short_name": "New", "language": "en-us", "is_first_connection": false}, "team": "", "role": "reader", "abilities": {}, "max_ancestors_role": null, "max_role": "reader"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()
        let userID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

        let access = try await client.createAccess(documentID: documentID, userID: userID, role: .reader)

        XCTAssertEqual(access.role, .reader)
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["user_id"], "33333333-3333-4333-8333-333333333333")
        XCTAssertEqual(json["role"], "reader")
    }

    func testSearchUsersRequestsCorrectURL() async throws {
        let responseBody = "[]".data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()

        let results = try await client.searchUsers(query: "cam", excludingDocumentID: documentID)

        XCTAssertTrue(results.isEmpty)
        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("q=cam"))
        XCTAssertTrue(url.contains("document_id=11111111"))
    }

    func testDeleteAccessSendsDeleteRequest() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let accessID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

        try await client.deleteAccess(documentID: documentID, accessID: accessID)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ShareModelsDecodingTests -only-testing:DocsIOSTests/ShareMembersTests -only-testing:DocsIOSTests/ShareEndpointsPathTests -only-testing:DocsIOSTests/ShareEndpointsClientTests`
Expected: FAIL — `cannot find 'ShareUser' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Networking/ShareModels.swift`:
```swift
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
```

`DocsIOS/Core/Networking/ShareEndpoints.swift`:
```swift
import Foundation

private struct AccessCreateRequest: Encodable {
    let userId: String
    let role: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
    }
}

private struct RoleUpdateRequest: Encodable {
    let role: String
}

private struct InvitationCreateRequest: Encodable {
    let email: String
    let role: String
}

private struct LinkConfigurationRequest: Encodable {
    let linkReach: String
    let linkRole: String?

    enum CodingKeys: String, CodingKey {
        case linkReach = "link_reach"
        case linkRole = "link_role"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(linkReach, forKey: .linkReach)
        if let linkRole {
            try container.encode(linkRole, forKey: .linkRole)
        } else {
            try container.encodeNil(forKey: .linkRole)
        }
    }
}

func userSearchPath(query: String, excludingDocumentID: UUID) -> String {
    var components = URLComponents()
    components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "document_id", value: excludingDocumentID.uuidString.lowercased()),
    ]
    return "users/?" + (components.percentEncodedQuery ?? "")
}

extension DocsAPIClient {
    func listAccesses(documentID: UUID) async throws -> PaginatedResponse<DocumentAccess> {
        try await get("documents/\(documentID.uuidString.lowercased())/accesses/")
    }

    func createAccess(documentID: UUID, userID: UUID, role: DocumentRole) async throws -> DocumentAccess {
        let body = try JSONEncoder().encode(AccessCreateRequest(userId: userID.uuidString.lowercased(), role: role.rawValue))
        return try await send(path: "documents/\(documentID.uuidString.lowercased())/accesses/", method: "POST", body: body)
    }

    func updateAccess(documentID: UUID, accessID: UUID, role: DocumentRole) async throws -> DocumentAccess {
        let body = try JSONEncoder().encode(RoleUpdateRequest(role: role.rawValue))
        return try await send(path: "documents/\(documentID.uuidString.lowercased())/accesses/\(accessID.uuidString.lowercased())/", method: "PATCH", body: body)
    }

    func deleteAccess(documentID: UUID, accessID: UUID) async throws {
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/accesses/\(accessID.uuidString.lowercased())/", method: "DELETE", body: nil)
    }

    func listInvitations(documentID: UUID) async throws -> PaginatedResponse<Invitation> {
        try await get("documents/\(documentID.uuidString.lowercased())/invitations/")
    }

    func createInvitation(documentID: UUID, email: String, role: DocumentRole) async throws -> Invitation {
        let body = try JSONEncoder().encode(InvitationCreateRequest(email: email, role: role.rawValue))
        return try await send(path: "documents/\(documentID.uuidString.lowercased())/invitations/", method: "POST", body: body)
    }

    func deleteInvitation(documentID: UUID, invitationID: UUID) async throws {
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/invitations/\(invitationID.uuidString.lowercased())/", method: "DELETE", body: nil)
    }

    func setLinkConfiguration(documentID: UUID, linkReach: LinkReach, linkRole: LinkRole?) async throws -> LinkConfiguration {
        let body = try JSONEncoder().encode(LinkConfigurationRequest(linkReach: linkReach.rawValue, linkRole: linkRole?.rawValue))
        return try await send(path: "documents/\(documentID.uuidString.lowercased())/link-configuration/", method: "PUT", body: body)
    }

    func searchUsers(query: String, excludingDocumentID: UUID) async throws -> [UserSearchResult] {
        try await get(userSearchPath(query: query, excludingDocumentID: excludingDocumentID))
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ShareModelsDecodingTests -only-testing:DocsIOSTests/ShareMembersTests -only-testing:DocsIOSTests/ShareEndpointsPathTests -only-testing:DocsIOSTests/ShareEndpointsClientTests`
Expected: PASS — `Executed 14 tests, with 0 failures` (5 decoding + 3 members + 1 path + 5 client). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 207 tests, with 0 failures` (193 from the prior twelve plans + 14 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/ShareModels.swift DocsIOS/Core/Networking/ShareEndpoints.swift DocsIOSTests/Core/Networking/ShareModelsTests.swift DocsIOSTests/Core/Networking/ShareEndpointsClientTests.swift
git commit -m "Add Share Codable models and endpoints"
```

---

### Task 2: ShareViewModel

**Files:**
- Create: `DocsIOS/Features/Share/ShareViewModel.swift`
- Test: `DocsIOSTests/Features/Share/ShareViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1's models and endpoints.
- Produces: `@MainActor @Observable final class ShareViewModel` (`init(client:documentID:linkReach:linkRole:)`, `members: [ShareMember]`, `linkReach: LinkReach`, `linkRole: LinkRole?`, `searchQuery: String`, `searchResults: [UserSearchResult]`, `isLoading: Bool`, `errorMessage: String?`, `func load() async`, `func search() async`, `func invite(user:role:) async`, `func updateRole(accessID:role:) async`, `func removeMember(_:) async`, `func updateLinkConfiguration(reach:role:) async`) — consumed by Task 3's `ShareSheetView`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Share/ShareViewModelTests.swift`:
```swift
import XCTest
@testable import DocsIOS

private final class RequestLog: @unchecked Sendable {
    var requests: [URLRequest] = []
}

@MainActor
final class ShareViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel(linkReach: LinkReach = .restricted, linkRole: LinkRole? = nil) -> ShareViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return ShareViewModel(client: client, documentID: documentID, linkReach: linkReach, linkRole: linkRole)
    }

    private static let accessesFixture = """
    {"count": 1, "next": null, "previous": null, "results": [
        {"id": "22222222-2222-4222-8222-222222222222", "document": {"id": "11111111-1111-4111-8111-111111111111", "path": "0001", "depth": 1}, "user": {"id": "33333333-3333-4333-8333-333333333333", "email": "member@example.com", "full_name": "Member One", "short_name": "Member", "language": "en-us", "is_first_connection": false}, "team": "", "role": "editor", "abilities": {}, "max_ancestors_role": null, "max_role": "editor"}
    ]}
    """.data(using: .utf8)!

    private static let invitationsFixture = """
    {"count": 1, "next": null, "previous": null, "results": [
        {"id": "44444444-4444-4444-8444-444444444444", "abilities": {}, "created_at": "2026-01-15T10:30:00Z", "email": "pending@example.com", "document": "11111111-1111-4111-8111-111111111111", "role": "reader", "issuer": "33333333-3333-4333-8333-333333333333", "is_expired": false}
    ]}
    """.data(using: .utf8)!

    func testLoadMergesAccessesAndInvitations() async {
        let viewModel = makeViewModel()
        let accesses = Self.accessesFixture
        let invitations = Self.invitationsFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("invitations") {
                return .init(statusCode: 200, headers: [:], body: invitations, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: accesses, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.members.count, 2)
        XCTAssertFalse(viewModel.members[0].isPending)
        XCTAssertTrue(viewModel.members[1].isPending)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSearchWithEmptyQueryClearsResults() async {
        let viewModel = makeViewModel()
        viewModel.searchQuery = "   "

        await viewModel.search()

        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testInviteCallsCreateAccessThenReloads() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let accesses = Self.accessesFixture
        let invitations = Self.invitationsFixture
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                let body = """
                {"id": "55555555-5555-4555-8555-555555555555", "document": {"id": "11111111-1111-4111-8111-111111111111", "path": "0001", "depth": 1}, "user": {"id": "66666666-6666-4666-8666-666666666666", "email": "new@example.com", "full_name": "New", "short_name": "New", "language": "en-us", "is_first_connection": false}, "team": "", "role": "reader", "abilities": {}, "max_ancestors_role": null, "max_role": "reader"}
                """.data(using: .utf8)!
                return .init(statusCode: 201, headers: [:], body: body, error: nil)
            }
            if request.url?.path.contains("invitations") == true {
                return .init(statusCode: 200, headers: [:], body: invitations, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: accesses, error: nil)
        }
        let user = UserSearchResult(id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!, email: "new@example.com", fullName: "New", shortName: "New")

        await viewModel.invite(user: user, role: .reader)

        XCTAssertTrue(log.requests.contains { $0.httpMethod == "POST" })
        XCTAssertTrue(log.requests.contains { $0.httpMethod == "GET" })
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRemoveMemberDeletesAccessThenReloads() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let accesses = Self.accessesFixture
        let invitations = Self.invitationsFixture
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "DELETE" {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if request.url?.path.contains("invitations") == true {
                return .init(statusCode: 200, headers: [:], body: invitations, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: accesses, error: nil)
        }
        let access = DocumentAccess(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, user: nil, team: nil, role: .editor)

        await viewModel.removeMember(.access(access))

        XCTAssertTrue(log.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testUpdateLinkConfigurationUpdatesLocalState() async {
        let viewModel = makeViewModel(linkReach: .restricted, linkRole: nil)
        let responseBody = #"{"link_reach": "authenticated", "link_role": "reader"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }

        await viewModel.updateLinkConfiguration(reach: .authenticated, role: .reader)

        XCTAssertEqual(viewModel.linkReach, .authenticated)
        XCTAssertEqual(viewModel.linkRole, .reader)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ShareViewModelTests`
Expected: FAIL — `cannot find 'ShareViewModel' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Share/ShareViewModel.swift`:
```swift
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
        do {
            searchResults = try await client.searchUsers(query: trimmed, excludingDocumentID: documentID)
        } catch {
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
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/ShareViewModelTests`
Expected: PASS — `Executed 6 tests, with 0 failures`. Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 213 tests, with 0 failures` (207 from Task 1 + 6 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Share/ShareViewModel.swift DocsIOSTests/Features/Share/ShareViewModelTests.swift
git commit -m "Add ShareViewModel"
```

---

### Task 3: ShareSheetView UI

**Files:**
- Create: `DocsIOS/Features/Share/ShareSheetView.swift`

**Interfaces:**
- Consumes: `ShareViewModel` (Task 2), `SearchField`, `ListSection`, `ListRow`, `ShareMemberRow`, `LinkReachPill` (DesignSystem).
- Produces: `func shareRoleDisplayTitle(_:isPending:) -> String`, `struct ShareSheetView: View` — presented as a sheet, consumed by Task 4's `EditorView`.

This task has no XCTest steps — see the Home Screen and Editor Screen plans' precedent and this plan's Global Constraints for why (UI glue verified by build-check and a Simulator screenshot, not XCTest).

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Share/ShareSheetView.swift`:
```swift
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
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 213 tests, with 0 failures` (no new tests in this task).

- [ ] **Step 3: Visually verify in the Simulator**

Temporarily point `RootView.body` at a `ShareSheetView` presented via `.sheet(isPresented: .constant(true))`, with the view model's `members` pre-populated with at least one real `.access` member and one `.invitation` member (matching this plan's own validation — see Architecture), screenshot, then revert `RootView.swift` back to the real auth-gated version **before committing**:

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'
APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/DocsIOS-*/Build/Products/Debug-iphonesimulator/DocsIOS.app | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted dev.llun.DocsIOS
xcrun simctl io booted screenshot /tmp/share-sheet-verify.png
```
Expected: the screenshot shows "Share" title with a Done button, a search field, the Link Access section with a `LinkReachPill`, and a Members section listing both the real member (with a plain role) and the pending invitation (role suffixed "(Pending)").

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Share/ShareSheetView.swift
git commit -m "Add ShareSheetView"
```

---

### Task 4: Wire EditorView Share button

**Files:**
- Modify: `DocsIOS/Features/Editor/EditorViewModel.swift`
- Modify: `DocsIOS/Features/Editor/EditorView.swift`
- Modify: `DocsIOS/Features/Home/HomeView.swift`

**Interfaces:**
- Consumes: `ShareSheetView`, `ShareViewModel` (Task 3).
- Produces: `EditorViewModel.client`/`.documentID` change from `private let` to `let`; `EditorView` gains a `linkRole: LinkRole? = nil` parameter and presents `ShareSheetView` when the Share `NavBarAction` is tapped; `HomeView`'s `.navigationDestination(for: Document.self)` passes `document.linkRole` through.

This task has no new XCTest files — same rationale as Task 3.

- [ ] **Step 1: Write the implementation**

In `DocsIOS/Features/Editor/EditorViewModel.swift`, change:
```swift
    private let client: DocsAPIClient
    private let documentID: UUID
    private var savedMarkdown: String = ""
```
to:
```swift
    let client: DocsAPIClient
    let documentID: UUID
    private var savedMarkdown: String = ""
```

`DocsIOS/Features/Editor/EditorView.swift` — replace entirely with:
```swift
import SwiftUI

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    var linkRole: LinkRole? = nil
    var onBack: (() -> Void)? = nil

    @State private var isPresentingShareSheet = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: viewModel.title,
                backTitle: "Docs",
                onBack: onBack,
                trailingActions: trailingActions
            )

            HStack(spacing: DocsSpacing.spaceXS) {
                Text(viewModel.title)
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
                LinkReachPill(reach: reach)
                Spacer()
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.top, DocsSpacing.spaceSM)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .padding(.horizontal, DocsSpacing.gutter)
            }

            if viewModel.isLoading {
                ProgressView()
                    .padding(DocsSpacing.spaceBase)
                Spacer()
            } else if viewModel.isEditing {
                TextEditor(text: $viewModel.rawMarkdown)
                    .font(DocsFont.body)
                    .padding(.horizontal, DocsSpacing.spaceXS)
                    .disabled(viewModel.isSaving)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                        ForEach(Array(viewModel.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                        }
                    }
                    .padding(DocsSpacing.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            ShareSheetView(
                viewModel: ShareViewModel(
                    client: viewModel.client,
                    documentID: viewModel.documentID,
                    linkReach: reach,
                    linkRole: linkRole
                )
            )
        }
    }

    private var trailingActions: [NavBarAction] {
        if viewModel.isEditing {
            return [
                NavBarAction(systemImage: "xmark", label: "Cancel", action: { viewModel.cancelEditing() }),
                NavBarAction(systemImage: "checkmark", label: "Save", action: { Task { await viewModel.save() } }),
            ]
        }
        return [
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: { isPresentingShareSheet = true }),
            NavBarAction(systemImage: "pencil", label: "Edit", action: { viewModel.startEditing() }),
            NavBarAction(systemImage: "ellipsis", label: "Options", action: {}),
        ]
    }
}

#Preview {
    EditorView(
        viewModel: EditorViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            title: "Q3 Planning"
        ),
        reach: .restricted
    )
}
```

In `DocsIOS/Features/Home/HomeView.swift`, find this exact block:
```swift
            .navigationDestination(for: Document.self) { document in
                EditorView(
                    viewModel: EditorViewModel(
                        client: viewModel.client,
                        documentID: document.id,
                        title: document.title ?? "Untitled document"
                    ),
                    reach: document.linkReach,
                    onBack: { path.removeLast() }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
```
Replace it with:
```swift
            .navigationDestination(for: Document.self) { document in
                EditorView(
                    viewModel: EditorViewModel(
                        client: viewModel.client,
                        documentID: document.id,
                        title: document.title ?? "Untitled document"
                    ),
                    reach: document.linkReach,
                    linkRole: document.linkRole,
                    onBack: { path.removeLast() }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 213 tests, with 0 failures` (no new tests in this task; confirms Task 4's changes didn't regress anything).

- [ ] **Step 3: Visually verify in the Simulator**

Temporarily point `RootView.body` at an `EditorView` (matching the read-only/editing Editor Screen plans' own validation technique), tap Share (or force `isPresentingShareSheet = true` in a modified preview), screenshot, then revert `RootView.swift` back to the real auth-gated version **before committing**. Expected: the Share sheet presents correctly from the Editor screen's Share button.

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Editor/EditorViewModel.swift DocsIOS/Features/Editor/EditorView.swift DocsIOS/Features/Home/HomeView.swift
git commit -m "Wire EditorView Share button to present ShareSheetView"
```

## Self-Review Notes

- **Spec coverage:** Implements the Share sheet half of design spec Phase 8 ("invite by name/email, member list with role picker... link reach picker... Copy link"). Copy link is not yet wired (no clipboard action exists in this plan — it's trivial `UIPasteboard` glue better suited to sit alongside the Options sheet's own Copy-link/Copy-as-Markdown actions in the follow-up plan, avoiding a one-off pattern here). The Options sheet itself (Pin/Unpin, Copy link, Copy as Markdown, Duplicate, Delete) is explicitly out of scope, per this plan's own documented scope split.
- **Real-backend cross-check:** All four endpoint groups (`accesses`, `invitations`, `link-configuration`, user search) were read directly from the real `suitenumerique/docs` backend source, not the design spec's endpoint table alone. This caught the `link_role` explicit-null encoding requirement (a real, easy-to-miss `partial=True` semantics issue), the `user_id` vs. `user` field-name discrepancy between a stale docstring and the actual serializer, and the unpaginated user-search response shape — none of which the design spec's endpoint table alone would have revealed.
- **Placeholder scan:** No TBD/TODO. Copy link's absence is a documented, intentional deferral to the next plan, not a forgotten placeholder.
- **Type consistency:** `ShareUser`, `DocumentAccess`, `Invitation`, `UserSearchResult`, `LinkConfiguration`, `ShareMember`, `shareMembers`, `userSearchPath`, `ShareViewModel`, `shareRoleDisplayTitle`, `ShareSheetView` are each defined once. `ShareSheetView` correctly reuses `ShareMemberRow`/`LinkReachPill`/`ListSection`/`ListRow`/`SearchField` from the DesignSystem layer rather than building new presentational components.
- **Cross-file validation:** All code in this plan (all four tasks, including the explicit-null `link_role` encoding fix verified against a real serialized-request-body inspection, the light-vs-full `DocumentAccess` user-shape decoding leniency, the accesses/invitations merge-and-filter logic, and a Simulator screenshot of the sheet with one real member and one pending invitation together) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 213 tests, with 0 failures` plus a passing Simulator screenshot of the populated Share sheet.
