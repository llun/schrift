import XCTest
@testable import Schrift

@MainActor
final class EditorViewModelChildrenTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel(title: String = "Untitled document") -> EditorViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelChildrenTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        return EditorViewModel(client: client, documentID: documentID, title: title, saveCoordinator: coordinator)
    }

    private static func childrenFixture(id: String, title: String) -> Data {
        """
        {
            "count": 1,
            "next": null,
            "previous": null,
            "results": [
                {
                    "id": "\(id)",
                    "title": "\(title)",
                    "excerpt": null,
                    "abilities": {},
                    "computed_link_reach": "restricted",
                    "computed_link_role": null,
                    "created_at": "2026-01-15T10:30:00Z",
                    "creator": null,
                    "depth": 2,
                    "link_role": "reader",
                    "link_reach": "restricted",
                    "numchild": 0,
                    "path": "00010001",
                    "updated_at": "2026-01-15T10:30:00Z",
                    "user_role": "owner",
                    "is_favorite": false
                }
            ]
        }
        """.data(using: .utf8)!
    }

    func testLoadChildrenPopulatesSubpages() async {
        let viewModel = makeViewModel()
        let body = Self.childrenFixture(id: "11111111-1111-4111-8111-111111111111", title: "Meeting notes")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.loadChildren()

        XCTAssertEqual(viewModel.subpages.map(\.title), ["Meeting notes"])
    }

    func testLoadChildrenFailureLeavesSubpagesEmpty() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.loadChildren()

        XCTAssertTrue(viewModel.subpages.isEmpty)
    }

    func testLoadPopulatesSubpagesAndCapturesUpdatedAt() async {
        let viewModel = makeViewModel()
        let contentBody = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Body", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        let childrenBody = Self.childrenFixture(id: "22222222-2222-4222-8222-222222222222", title: "Child page")
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("children") {
                return .init(statusCode: 200, headers: [:], body: childrenBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: contentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.subpages.map(\.title), ["Child page"])
        XCTAssertNotNil(viewModel.updatedAt)
    }
}
