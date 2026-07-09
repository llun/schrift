import XCTest

@testable import Schrift

final class AttachmentEndpointsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    // MARK: - Upload

    func testUploadAttachmentPostsMultipartFileAndReturnsFilePath() async throws {
        let responseBody = Data(
            #"{"file": "/api/v1.0/documents/11111111-1111-4111-8111-111111111111/media-check/?key=11111111-1111-4111-8111-111111111111%2Fattachments%2F22222222-2222-4222-8222-222222222222.jpg"}"#
                .utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: responseBody, error: nil) }
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0])

        let file = try await makeClient().uploadAttachment(
            documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: payload)

        XCTAssertTrue(file.hasSuffix("2222.jpg"))
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/\(documentID.uuidString.lowercased())/attachment-upload/")

        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(contentType.hasPrefix(prefix))
        let boundary = String(contentType.dropFirst(prefix.count))

        let body = try XCTUnwrap(bodyData(from: request))
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("--\(boundary)\r\n"))
        XCTAssertTrue(bodyString.contains(#"Content-Disposition: form-data; name="file"; filename="photo.jpg""#))
        XCTAssertTrue(bodyString.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(bodyString.contains("--\(boundary)--\r\n"))
        XCTAssertNotNil(body.range(of: payload))
    }

    /// The upload is a non-GET request, so it must route through `send` and pick
    /// up the CSRF/Origin/Referer headers Django's middleware requires.
    func testUploadAttachmentSendsCSRFAndOriginHeaders() async throws {
        let responseBody = Data(#"{"file": "/api/v1.0/documents/1/media-check/?key=1%2Fattachments%2F2.jpg"}"#.utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: responseBody, error: nil) }
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org", .path: "/", .name: "csrftoken", .value: "tok123",
        ])!
        let client = DocsAPIClient(
            baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [cookie] })

        _ = try await client.uploadAttachment(
            documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: Data([0xFF]))

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRFToken"), "tok123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://docs.example.org")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://docs.example.org/")
    }

    func testUploadFailureMapsToDocsAPIError() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 400, headers: [:], body: Data(), error: nil) }
        do {
            _ = try await makeClient().uploadAttachment(
                documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: Data())
            XCTFail("Expected DocsAPIError")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .server(statusCode: 400))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUploadForbiddenMapsToForbidden() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        do {
            _ = try await makeClient().uploadAttachment(
                documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: Data())
            XCTFail("Expected DocsAPIError")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Media check

    func testCheckMediaDecodesReadyResponse() async throws {
        let responseBody = Data(#"{"status": "ready", "file": "/media/1111/attachments/2222.jpg"}"#.utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }

        let response = try await makeClient().checkMedia(
            path: "/api/v1.0/documents/1111/media-check/?key=1111%2Fattachments%2F2222.jpg")

        XCTAssertEqual(response, MediaCheckResponse(status: "ready", file: "/media/1111/attachments/2222.jpg"))
        // The server-provided path is rooted, so it must resolve against the host
        // root — NOT get the /api/v1.0/ base appended a second time.
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/1111/media-check/?key=1111%2Fattachments%2F2222.jpg")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
    }

    func testCheckMediaDecodesProcessingResponseWithNoFile() async throws {
        let responseBody = Data(#"{"status": "processing"}"#.utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }

        let response = try await makeClient().checkMedia(path: "/api/v1.0/documents/1/media-check/?key=k")

        XCTAssertEqual(response, MediaCheckResponse(status: "processing", file: nil))
        XCTAssertNotEqual(response.status, MediaCheckResponse.readyStatus)
    }

    // MARK: - Media-check path validation

    /// The media-check path is the one request URL the *server* chooses. It must
    /// not be able to steer our HTTP client off-origin.
    ///
    /// Asserts on a URL-filtered recorder rather than `MockURLProtocol.lastRequest`:
    /// that static is set by *any* request, and a lingering save from another test
    /// class's `DocumentSaveCoordinator` would clobber it.
    func testCheckMediaRejectsOffOriginPathsWithoutIssuingARequest() async {
        for hostile in [
            "//evil.com/x", "https://evil.com/x", "http://evil.com/x", "javascript:alert(1)",
            "file:///etc/passwd", "api/v1.0/relative",
        ] {
            let log = RequestRecorder()
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            }
            do {
                _ = try await makeClient().checkMedia(path: hostile)
                XCTFail("Expected checkMedia to reject \(hostile)")
            } catch let error as DocsAPIError {
                // Not `guard … else { continue }`: a `continue` here would skip the
                // request-count assertion on exactly the buggy path that issues a
                // request and then throws `.decoding`, leaving it only ever reached
                // after a correct rejection (where the log is trivially empty).
                if case .network = error {
                } else {
                    XCTFail("Expected .network for \(hostile), got \(error)")
                }
            } catch {
                XCTFail("Unexpected error for \(hostile): \(error)")
            }
            // The invariant is "no request at all", not "no request to a particular
            // host": a substring count is structurally zero for these inputs even if
            // checkMedia wrongly issued a GET to some other URL. Assert the recorder
            // saw nothing, which a rejected path guarantees and a leaked one violates.
            XCTAssertTrue(
                log.methods.isEmpty, "checkMedia must not issue any request for \(hostile)")
        }
    }

    func testIsSameOriginPathAcceptsOnlyPathAbsoluteReferences() {
        XCTAssertTrue(isSameOriginPath("/api/v1.0/documents/1/media-check/?key=k"))
        XCTAssertTrue(isSameOriginPath("/media/a.jpg"))
        XCTAssertFalse(isSameOriginPath("//evil.com/x"))
        XCTAssertFalse(isSameOriginPath("https://evil.com/x"))
        XCTAssertFalse(isSameOriginPath("relative/path"))
        XCTAssertFalse(isSameOriginPath(""))
    }

    // MARK: - Pure helpers

    func testMultipartBodyIsDeterministicAndCRLFDelimited() throws {
        let body = try XCTUnwrap(
            multipartFormDataBody(
                boundary: "B", fieldName: "file", fileName: "photo.jpg", contentType: "image/jpeg",
                fileData: Data("abc".utf8)))
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n"
                + "Content-Type: image/jpeg\r\n\r\nabc\r\n--B--\r\n")
    }

    func testMultipartBodyPreservesBinaryPayloadExactly() throws {
        // Raw JPEG bytes must survive untouched — no UTF-8 round trip. The
        // payload here contains a NUL and bytes that are invalid UTF-8.
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        let body = try XCTUnwrap(
            multipartFormDataBody(
                boundary: "B", fieldName: "file", fileName: "photo.jpg", contentType: "image/jpeg",
                fileData: payload))

        XCTAssertNotNil(body.range(of: payload))
        let trailer = Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(body.suffix(trailer.count), trailer)
    }

    /// The sole caller passes constants, but the signature invites a future caller
    /// to pass the picked asset's real filename — which is user-controlled. A
    /// quote or CRLF would break out of the multipart (or HTTP) header.
    ///
    /// Note `"\r\n"` is ONE Swift `Character` (an extended grapheme cluster), so a
    /// `Character`-based check silently misses it. Lone CR and lone LF are covered
    /// too, to pin that the guard compares unicode scalars.
    func testMultipartBodyRejectsHeaderInjectingTokens() {
        let payload = Data("abc".utf8)
        XCTAssertNil(
            multipartFormDataBody(
                boundary: "B", fieldName: "file", fileName: "a\rb", contentType: "image/jpeg", fileData: payload))
        XCTAssertNil(
            multipartFormDataBody(
                boundary: "B", fieldName: "file", fileName: "a\nb", contentType: "image/jpeg", fileData: payload))
        XCTAssertNil(
            multipartFormDataBody(
                boundary: "B", fieldName: "fi\"le", fileName: "photo.jpg", contentType: "image/jpeg",
                fileData: payload))
        XCTAssertNil(
            multipartFormDataBody(
                boundary: "B", fieldName: "file", fileName: "a\"; name=\"evil", contentType: "image/jpeg",
                fileData: payload))
        XCTAssertNil(
            multipartFormDataBody(
                boundary: "B", fieldName: "file", fileName: "a\r\nX-Evil: 1", contentType: "image/jpeg",
                fileData: payload))
        XCTAssertNil(
            multipartFormDataBody(
                boundary: "B", fieldName: "file", fileName: "photo.jpg", contentType: "image/jpeg\r\nX-Evil: 1",
                fileData: payload))
        XCTAssertNil(
            multipartFormDataBody(
                boundary: "B\r\n", fieldName: "file", fileName: "photo.jpg", contentType: "image/jpeg",
                fileData: payload))
    }

    func testUploadAttachmentRejectsHeaderInjectingFileName() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 201, headers: [:], body: Data(), error: nil)
        }
        do {
            _ = try await makeClient().uploadAttachment(
                documentID: documentID, fileName: "a\r\nX-Evil: 1", contentType: "image/jpeg", data: Data([0xFF]))
            XCTFail("Expected DocsAPIError")
        } catch let error as DocsAPIError {
            guard case .network = error else { return XCTFail("Expected .network, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 0)
    }

    func testAttachmentKeyDecodesPercentEncodedKey() {
        XCTAssertEqual(
            attachmentKey(fromMediaCheckPath: "/api/v1.0/documents/1/media-check/?key=1%2Fattachments%2F2.jpg"),
            "1/attachments/2.jpg")
        XCTAssertNil(attachmentKey(fromMediaCheckPath: "/api/v1.0/documents/1/media-check/"))
        XCTAssertNil(attachmentKey(fromMediaCheckPath: "not a url ?? key"))
    }
}
