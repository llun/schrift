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

    // MARK: - Create responses omit `is_favorite`

    /// The exact body `POST /documents/` returns, captured from a live docs backend.
    /// `is_favorite` is a **queryset annotation** the list endpoints add; `perform_create`
    /// serializes a freshly built instance that has no such attribute, so the key is simply
    /// absent — as it is from `POST documents/{id}/children/`. Decoding it as a required
    /// `Bool` threw `keyNotFound`, which surfaced as "Couldn't create a document. Please try
    /// again." *after* the server had already created the document.
    private let createResponseFixture = """
        {
            "id": "b0429ca8-39ec-4e70-a383-810e511a3fcb",
            "abilities": {"destroy": true, "partial_update": true, "children_create": true},
            "ancestors_link_reach": null,
            "ancestors_link_role": null,
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "content": "",
            "created_at": "2026-07-09T08:07:54.123456Z",
            "creator": "dea263d7-5b7a-4bdc-8db2-8e2f835cd2a6",
            "deleted_at": null,
            "depth": 1,
            "excerpt": null,
            "link_reach": "restricted",
            "link_role": "reader",
            "nb_accesses_ancestors": 1,
            "nb_accesses_direct": 1,
            "numchild": 0,
            "path": "00000Fq",
            "title": "Untitled document",
            "updated_at": "2026-07-09T08:07:54.123456Z",
            "user_role": "owner"
        }
        """.data(using: .utf8)!

    func testDecodesACreateResponseThatOmitsIsFavorite() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: createResponseFixture)

        // A brand-new document is never a favorite, so absent must mean false — not a throw.
        XCTAssertFalse(document.isFavorite)
        XCTAssertEqual(document.title, "Untitled document")
        XCTAssertEqual(document.depth, 1)
        XCTAssertTrue(document.abilities.childrenCreate)
    }

    /// An explicit value must still win over the default.
    func testAnExplicitIsFavoriteStillDecodes() throws {
        let document = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        XCTAssertTrue(document.isFavorite)
    }

    /// The cache re-encodes `Document` with a bare `JSONEncoder` and reads it back with a
    /// bare `JSONDecoder` (no key strategy). A hand-written `init(from:)` breaks that
    /// round-trip if its `CodingKeys` stop matching the synthesized encoder's output.
    func testDocumentSurvivesTheBareEncoderRoundTripUsedByTheCaches() throws {
        let original = try JSONDecoder.docsAPI.decode(Document.self, from: fixture)

        let reencoded = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(Document.self, from: reencoded)

        XCTAssertEqual(roundTripped, original)
    }
}
