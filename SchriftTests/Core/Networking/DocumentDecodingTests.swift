import XCTest
@testable import Schrift

final class DocumentDecodingTests: XCTestCase {
    private let fixture = """
    {
        "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
        "title": "Q3 Planning",
        "excerpt": "Some excerpt text",
        "abilities": {
            "update": true,
            "partial_update": true,
            "destroy": false,
            "link_configuration": true,
            "accesses_manage": true,
            "favorite": true,
            "duplicate": true,
            "children_create": true,
            "link_select_options": {"restricted": null, "public": ["reader", "editor"]},
            "versions_list": true
        },
        "ancestors_link_reach": "restricted",
        "ancestors_link_role": null,
        "computed_link_reach": "authenticated",
        "computed_link_role": "reader",
        "created_at": "2026-01-15T10:30:00.123456Z",
        "creator": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
        "deleted_at": null,
        "depth": 1,
        "link_role": "reader",
        "link_reach": "restricted",
        "nb_accesses_ancestors": 2,
        "nb_accesses_direct": 3,
        "numchild": 0,
        "path": "0001",
        "updated_at": "2026-01-16T11:00:00Z",
        "user_role": "owner",
        "is_favorite": true
    }
    """.data(using: .utf8)!

    func testDecodesFullFixtureIgnoringUnmodeledKeys() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        XCTAssertEqual(document.title, "Q3 Planning")
        XCTAssertEqual(document.excerpt, "Some excerpt text")
        XCTAssertEqual(document.linkReach, .restricted)
        XCTAssertEqual(document.linkRole, .reader)
        XCTAssertEqual(document.computedLinkReach, .authenticated)
        XCTAssertEqual(document.computedLinkRole, .reader)
        XCTAssertTrue(document.isFavorite)
        XCTAssertEqual(document.depth, 1)
        XCTAssertEqual(document.numchild, 0)
        XCTAssertEqual(document.path, "0001")
        XCTAssertEqual(document.userRole, .owner)
        XCTAssertNotNil(document.creator)
    }

    func testDecodesAbilitiesIgnoringNonBooleanKeys() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        XCTAssertTrue(document.abilities.update)
        XCTAssertTrue(document.abilities.partialUpdate)
        XCTAssertFalse(document.abilities.destroy)
        XCTAssertTrue(document.abilities.linkConfiguration)
        XCTAssertTrue(document.abilities.accessesManage)
        XCTAssertTrue(document.abilities.favorite)
        XCTAssertTrue(document.abilities.duplicate)
        XCTAssertTrue(document.abilities.childrenCreate)
    }

    func testDecodesDatesWithAndWithoutFractionalSeconds() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        XCTAssertEqual(utc.component(.year, from: document.createdAt), 2026)
        XCTAssertEqual(utc.component(.minute, from: document.createdAt), 30)
        XCTAssertEqual(utc.component(.hour, from: document.updatedAt), 11)
    }

    func testDecodesNullTitleAndExcerptAsNil() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "title": null,
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": null,
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 0,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "0001",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": null,
            "is_favorite": false
        }
        """.data(using: .utf8)!

        let document = try JSONDecoder.docsAPI.decode(Document.self, from: json)
        XCTAssertNil(document.title)
        XCTAssertNil(document.excerpt)
        XCTAssertNil(document.creator)
        XCTAssertNil(document.userRole)
        XCTAssertNil(document.computedLinkReach)
        XCTAssertFalse(document.abilities.update)
    }
}
