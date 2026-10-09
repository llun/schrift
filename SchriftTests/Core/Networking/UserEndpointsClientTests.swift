import XCTest

@testable import Schrift

final class UserEndpointsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func testCurrentUserGetsTheMePathAndDecodesSnakeCaseFields() async throws {
        let body = """
            {"id": "33333333-3333-4333-8333-333333333333", "email": "me@example.com", "full_name": "Me Myself", "short_name": "Me", "language": "fr", "is_first_connection": false}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        let user = try await makeClient().currentUser()

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/users/me/")
        XCTAssertEqual(user.id, UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        XCTAssertEqual(user.email, "me@example.com")
        XCTAssertEqual(user.fullName, "Me Myself")
        XCTAssertEqual(user.shortName, "Me")
        XCTAssertEqual(user.language, "fr")
    }

    func testCurrentUserToleratesAbsentKeys() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Data(#"{"email": "me@example.com"}"#.utf8), error: nil)
        }

        let user = try await makeClient().currentUser()

        XCTAssertEqual(user.email, "me@example.com")
        XCTAssertNil(user.id)
        XCTAssertNil(user.fullName)
        XCTAssertNil(user.shortName)
        XCTAssertNil(user.language)
    }

    func testCurrentUserDecodesAnEmptyObjectToAnAllNilUser() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil) }

        let user = try await makeClient().currentUser()

        XCTAssertEqual(user, CurrentUser())
    }

    func testCurrentUserMapsAnExpiredSession() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }

        do {
            _ = try await makeClient().currentUser()
            XCTFail("expected a thrown error")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
