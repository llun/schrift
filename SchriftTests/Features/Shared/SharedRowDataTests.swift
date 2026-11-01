import XCTest

@testable import Schrift

final class SharedRowDataTests: XCTestCase {
    private func access(
        id: String?,
        full: String?,
        short: String? = nil,
        email: String? = nil,
        role: DocumentRole = .reader
    ) -> DocumentAccess {
        DocumentAccess(
            id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            user: ShareUser(
                id: id.flatMap(UUID.init(uuidString:)),
                email: email,
                fullName: full,
                shortName: short
            ),
            team: nil,
            role: role
        )
    }

    func testMemberNamesPrefersFullThenShortThenEmailAndDropsBlanks() {
        let accesses = [
            access(id: "11111111-1111-4111-8111-111111111111", full: "Amandine Salambo"),
            access(id: "22222222-2222-4222-8222-222222222222", full: nil, short: "Cam"),
            access(id: "33333333-3333-4333-8333-333333333333", full: nil, short: nil, email: "al@x.io"),
            access(id: "44444444-4444-4444-8444-444444444444", full: nil, short: nil, email: nil),
        ]
        XCTAssertEqual(sharedMemberNames(accesses: accesses), ["Amandine Salambo", "Cam", "al@x.io"])
    }

    func testCreatorNameMatchesCreatorUUID() {
        let creator = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let accesses = [
            access(id: "11111111-1111-4111-8111-111111111111", full: "Someone Else"),
            access(id: "22222222-2222-4222-8222-222222222222", full: "Amandine Salambo"),
        ]
        XCTAssertEqual(sharedCreatorName(accesses: accesses, creator: creator), "Amandine Salambo")
    }

    func testCreatorNameNilWhenCreatorNilOrAbsentOrNameless() {
        let accesses = [access(id: "11111111-1111-4111-8111-111111111111", full: "Someone")]
        XCTAssertNil(sharedCreatorName(accesses: accesses, creator: nil))
        XCTAssertNil(
            sharedCreatorName(
                accesses: accesses, creator: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!))
        let nameless = [access(id: "55555555-5555-4555-8555-555555555555", full: nil)]
        XCTAssertNil(
            sharedCreatorName(
                accesses: nameless, creator: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!))
    }

    func testFacesLeadWithSharerAndDropThemFromGroup() {
        let faces = sharedRowFaces(sharedByName: "Amandine", memberNames: ["Cam", "Amandine", "Al"])
        XCTAssertEqual(faces, SharedRowFaces(leading: "Amandine", trailing: ["Cam", "Al"]))
    }

    func testFacesDropOnlyFirstDuplicateName() {
        let faces = sharedRowFaces(sharedByName: "Sam", memberNames: ["Sam", "Sam"])
        XCTAssertEqual(faces, SharedRowFaces(leading: "Sam", trailing: ["Sam"]))
    }

    func testFacesKeepGroupWhenSharerNotAmongMembers() {
        let faces = sharedRowFaces(sharedByName: "Zed", memberNames: ["Cam", "Al"])
        XCTAssertEqual(faces, SharedRowFaces(leading: "Zed", trailing: ["Cam", "Al"]))
    }

    func testFacesFallBackToIconWhenSharerUnknownOrBlank() {
        XCTAssertEqual(
            sharedRowFaces(sharedByName: nil, memberNames: ["Cam"]),
            SharedRowFaces(leading: nil, trailing: ["Cam"]))
        XCTAssertEqual(
            sharedRowFaces(sharedByName: "", memberNames: ["Cam"]),
            SharedRowFaces(leading: nil, trailing: ["Cam"]))
        XCTAssertEqual(
            sharedRowFaces(sharedByName: nil, memberNames: []),
            SharedRowFaces(leading: nil, trailing: []))
    }

    /// The leading Avatar is sized from `docIconBoxSize` and told not to scale again, so it
    /// matches the tinted DocIcon box at every Dynamic Type scale.
    func testAvatarMatchesTintedDocIconBoxAtEveryScale() {
        for scale: CGFloat in [0.82, 1, 1.35, 2.1, 3.1] {
            let box = docIconBoxSize(scale: scale, tinted: true)
            XCTAssertEqual(box, 24 * scale + 14, accuracy: 0.001)
            let avatar = Avatar(name: "Amandine Salambo", size: box, scaleOverride: 1)
            XCTAssertEqual(avatar.scaledSize, box, accuracy: 0.001)
        }
        XCTAssertEqual(docIconBoxSize(scale: 1, tinted: true), 38)
        XCTAssertEqual(docIconBoxSize(scale: 2, tinted: false), 48)
    }
}
