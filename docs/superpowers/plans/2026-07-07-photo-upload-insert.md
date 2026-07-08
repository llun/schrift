# PR-2: Photo Upload + Insert — Implementation Plan

> **Amendment (2026-07-08, on completion).** Shipped as written, with these
> deviations — each forced by the real code rather than chosen:
> - The plan's test helpers (`makeLoadedViewModel`, `focusBlockForTesting`,
>   `tinyPNGData`) don't exist. `EditorPhotoInsertionTests` builds a loaded view
>   model the way `EditorViewModelTests` does (stub `formatted-content`,
>   `await load()`, `startEditing()`), focuses via `focusedBlockID`, and the
>   CoreGraphics PNG helper went straight into `SchriftTests/Support/TestImages.swift`.
> - `bodyData(from:)` had **two** private copies (`ShareEndpointsClientTests` *and*
>   `DocumentSaveTests`); both were consolidated into `Support/RequestBodyHelpers.swift`.
> - `applySlashSelection`'s `.insertPhoto` branch calls `requestPhotoInsertion()`
>   rather than setting `isPhotoPickerPresented` directly, so both entry points
>   share one `hasLoadedContent` / `!isUploadingPhoto` gate.
> - `mediaCheckMaxAttempts` and the error copy are `private static let` on the view
>   model (the plan implied instance properties).
> - **Task 5 Step 4's manual end-to-end verification against the real server was
>   NOT performed** — it needs a signed-in device and a live `docs.llun.dev`.
>   Everything else is covered by tests; that on-device pass is still owed.
>
> The plan said nothing about a photo landing *after* the editing session ends
> (Done, or a navigation pop — neither cancels the picker's `Task`). Six review
> rounds hardened that path into rules the plan never anticipated:
> - The insert **always persists immediately** (`flushPendingChanges()`), never via
>   `markDirty`'s debounce: that `autosaveTask` dies with the view model on a pop.
> - `currentMarkdown()` returns `serializeMarkdown(blocks)` **only in blocks mode**.
>   In reading mode `blocks` may be a lossy parse of `rawMarkdown`, so a
>   full-overwrite save must carry the source. It must *not* key off
>   `openInMarkdownMode`, which `install()` computes once and which goes stale.
> - **All three** insertion paths (markdown, reading, blocks) must verify against
>   the *saved* markdown before committing: none may report success without
>   producing an `.image` block. A fenced code block swallows the image line —
>   open at the tail, wrapping the caret, or (in blocks mode) formed on
>   serialization by a neighbouring paragraph holding a bare ` ``` `. Blocks mode
>   is the subtle one: the block array shows the image while
>   `serializeMarkdown(blocks)` — the exact string `MarkdownYjs.encode` re-parses —
>   contains none, so the photo silently never reaches the server. We never
>   rewrite the source to make room; we surface the friendly error.
> - `isDocumentDiscarded` gates the insert, or an upload landing after a delete
>   re-drafts the document and resurrects it on reopen.
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user pick a photo from their library and insert it into a document as a PR-1 `.image` block that renders in both the app and the La Suite Docs web client.

**Architecture:** A multipart `POST documents/{id}/attachment-upload/` endpoint on `DocsAPIClient` (single `file` field — the backend computes everything else), a bounded media-check readiness poll that yields the final absolute `https://{host}/media/{key}` URL (mirroring the web client), a pure ImageIO downscale/re-encode helper, and an `EditorViewModel` upload flow triggered from the slash menu and the formatting bar. The `.image` block is inserted only on success; autosave embeds the URL via the existing save coordinator.

**Tech Stack:** Swift 6, SwiftUI `PhotosPicker` (PhotosUI — out-of-process, **no** photo-library permission or `project.yml` change), ImageIO/CoreGraphics, XCTest with `MockURLProtocol`.

## Global Constraints

- **Depends on PR-1** (`.image` BlockKind + encoder support). Branch off the PR-1 branch; open this PR against `main` after PR-1 merges.
- Verified backend contract (suitenumerique/docs `main`, checked 2026-07-07):
  - `POST /api/v1.0/documents/{id}/attachment-upload/` — multipart with **exactly one field: `file`**. `file_name` / `content_type` / `expected_extension` / `is_unsafe` are computed **server-side** and are NOT client fields. Requires editor/admin/owner (`abilities.attachment_upload`); throttled; max size `DOCUMENT_IMAGE_MAX_SIZE` (default 10 MB) for all attachments.
  - Response `201 {"file": "/api/v1.0/documents/{id}/media-check/?key={urlencoded key}"}` — a **relative media-check API path, NOT a media URL**. The key is `{doc-uuid}/attachments/{file-uuid}.{ext}`.
  - `GET …/media-check/?key=…` returns `{"status": "processing"}` until the malware scan finishes, then `{"status": "ready", "file": "/media/{key}"}` (relative). The web client polls this and then embeds the **absolute** `https://{host}/media/{key}` in content; we do the same. On the default self-hosted deployment the scanner is the dummy backend, so readiness is near-immediate.
  - The magic-sniffed mime must match the filename extension, or the file is stored under a `-unsafe` key with forced-download disposition (and won't render). We always upload re-encoded JPEG named `photo.jpg` with `Content-Type: image/jpeg`, so this can't trigger.
  - `extract_attachments()` matches `/media/{uuid}/attachments/{uuid}.{ext}` as a substring — the absolute URL we embed matches. Attachment linkage already happened at upload time (`document.attachments.append`); embedding the URL matters for duplication/copy parity.
- New mutating endpoint MUST go through `send` (CSRF/Origin/Referer attach centrally). There is no multipart helper today — the body builder is new, pure, and never string-interpolates user data into headers.
- Never log upload data, cookies, or headers. XCTest only; `waitUntil` (no `XCTestExpectation`, no sleeps-for-state); isolate UserDefaults; `MockURLProtocol` for all HTTP.
- `swift format --recursive --in-place Schrift SchriftTests` before pushing; `xcodegen generate` before building; full suite green before the PR is review-ready.
- PR title: `feat: insert photos from the library into documents`.
- Error copy: `"Couldn't add the photo. Please try again."`
- Recorded YAGNI decisions (do NOT implement): no camera capture; no caption/alt editing (insert with empty alt); no upload progress percentage; no retry queue. The media-check poll IS in scope (v1) because the upload response contains no directly loadable URL — this supersedes the original design's "defer polling" note, which was based on a wrong response-shape assumption.

---

### Task 1: Multipart body builder + attachment endpoints

**Files:**
- Create: `Schrift/Core/Networking/AttachmentEndpoints.swift`
- Modify: `Schrift/Core/Networking/DocsAPIClient.swift` (add `absoluteServerURL(for:)`)
- Create: `SchriftTests/Core/Networking/AttachmentEndpointsClientTests.swift`
- Create: `SchriftTests/Support/RequestBodyHelpers.swift` (move the private `bodyData(from:)` stream-draining helper out of `ShareEndpointsClientTests.swift`; update that file to use it)

**Interfaces:**
- Produces (consumed by Task 4):
  - `func uploadAttachment(documentID: UUID, fileName: String, contentType: String, data: Data) async throws -> String` — returns the raw `file` string (the relative media-check path).
  - `func checkMedia(path: String) async throws -> MediaCheckResponse` where `struct MediaCheckResponse: Decodable, Equatable, Sendable { let status: String; let file: String? }`.
  - `func absoluteServerURL(for path: String) -> URL?` on the actor.
  - Free functions `multipartFormDataBody(boundary: String, fieldName: String, fileName: String, contentType: String, fileData: Data) -> Data` and `attachmentKey(fromMediaCheckPath path: String) -> String?`.

- [ ] **Step 1: Write the failing tests**

`AttachmentEndpointsClientTests.swift` (mirror `ShareEndpointsClientTests` mechanics: `makeClient()` with `MockURLProtocol.makeSession()` and baseURL `https://docs.example.org/api/v1.0/`, statics reset in `tearDown`):

```swift
func testUploadAttachmentPostsMultipartFileAndReturnsFilePath() async throws {
    let responseBody = #"{"file": "/api/v1.0/documents/11111111-1111-4111-8111-111111111111/media-check/?key=11111111-1111-4111-8111-111111111111%2Fattachments%2F22222222-2222-4222-8222-222222222222.jpg"}"#
        .data(using: .utf8)!
    MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: responseBody, error: nil) }
    let client = makeClient()
    let payload = Data([0xFF, 0xD8, 0xFF, 0xE0])

    let file = try await client.uploadAttachment(
        documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: payload)

    XCTAssertTrue(file.hasSuffix("2222.jpg"))
    let request = try XCTUnwrap(MockURLProtocol.lastRequest)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(
        request.url?.absoluteString,
        "https://docs.example.org/api/v1.0/documents/\(documentID.uuidString.lowercased())/attachment-upload/")
    let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
    XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
    let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
    let body = try XCTUnwrap(bodyData(from: request))
    let bodyString = String(decoding: body, as: UTF8.self)
    XCTAssertTrue(bodyString.contains("--\(boundary)\r\n"))
    XCTAssertTrue(bodyString.contains(#"Content-Disposition: form-data; name="file"; filename="photo.jpg""#))
    XCTAssertTrue(bodyString.contains("Content-Type: image/jpeg"))
    XCTAssertTrue(bodyString.contains("--\(boundary)--\r\n"))
    XCTAssertNotNil(body.range(of: payload))
}

func testUploadFailureMapsToDocsAPIError() async {
    MockURLProtocol.stubHandler = { _ in .init(statusCode: 400, headers: [:], body: Data(), error: nil) }
    do {
        _ = try await makeClient().uploadAttachment(
            documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: Data())
        XCTFail("Expected DocsAPIError")
    } catch let error as DocsAPIError {
        XCTAssertEqual(error, .server(statusCode: 400))
    } catch { XCTFail("Unexpected error: \(error)") }
}

func testCheckMediaDecodesReadyResponse() async throws {
    let responseBody = #"{"status": "ready", "file": "/media/1111/attachments/2222.jpg"}"#.data(using: .utf8)!
    MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
    let response = try await makeClient().checkMedia(
        path: "/api/v1.0/documents/1111/media-check/?key=1111%2Fattachments%2F2222.jpg")
    XCTAssertEqual(response, MediaCheckResponse(status: "ready", file: "/media/1111/attachments/2222.jpg"))
    XCTAssertEqual(
        MockURLProtocol.lastRequest?.url?.absoluteString,
        "https://docs.example.org/api/v1.0/documents/1111/media-check/?key=1111%2Fattachments%2F2222.jpg")
}

func testMultipartBodyIsDeterministicAndCRLFDelimited() {
    let body = multipartFormDataBody(
        boundary: "B", fieldName: "file", fileName: "photo.jpg", contentType: "image/jpeg",
        fileData: Data("abc".utf8))
    XCTAssertEqual(
        String(decoding: body, as: UTF8.self),
        "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\nabc\r\n--B--\r\n")
}

func testAttachmentKeyDecodesPercentEncodedKey() {
    XCTAssertEqual(
        attachmentKey(fromMediaCheckPath: "/api/v1.0/documents/1/media-check/?key=1%2Fattachments%2F2.jpg"),
        "1/attachments/2.jpg")
    XCTAssertNil(attachmentKey(fromMediaCheckPath: "/api/v1.0/documents/1/media-check/"))
}
```

Also add to `DocsAPIClientTests`:

```swift
func testAbsoluteServerURLResolvesAgainstServerRootNotAPIBase() async {
    let client = DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!)
    let url = await client.absoluteServerURL(for: "/media/1111/attachments/2222.jpg")
    XCTAssertEqual(url?.absoluteString, "https://docs.example.org/media/1111/attachments/2222.jpg")
}
```

Run `-only-testing:SchriftTests/AttachmentEndpointsClientTests -only-testing:SchriftTests/DocsAPIClientTests`. Expected: compile failure (types don't exist) — the failing state.

- [ ] **Step 2: Implement**

`AttachmentEndpoints.swift`:

```swift
import Foundation

/// Response of `POST documents/{id}/attachment-upload/`. `file` is a
/// server-relative media-check path (`/api/v1.0/documents/{id}/media-check/?key=…`),
/// NOT a media URL — poll it until the attachment is ready.
private struct AttachmentUploadResponse: Decodable {
    let file: String
}

/// Response of the media-check poll. `file` (present once `status == "ready"`)
/// is the server-relative media path (`/media/{key}`).
struct MediaCheckResponse: Decodable, Equatable, Sendable {
    let status: String
    let file: String?

    static let readyStatus = "ready"
}

/// Builds a single-file `multipart/form-data` body. Pure and deterministic for
/// a given boundary so tests can assert exact bytes. `fileName`/`contentType`
/// are app-supplied constants — never interpolate user-controlled data here.
func multipartFormDataBody(
    boundary: String, fieldName: String, fileName: String, contentType: String, fileData: Data
) -> Data {
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8))
    body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
    body.append(fileData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}

/// Extracts the storage key (`{doc-id}/attachments/{file-id}.{ext}`) from the
/// media-check path returned by the upload; `URLComponents` percent-decodes it.
func attachmentKey(fromMediaCheckPath path: String) -> String? {
    URLComponents(string: path)?.queryItems?.first(where: { $0.name == "key" })?.value
}

extension DocsAPIClient {
    /// Uploads a document attachment. The backend accepts exactly one multipart
    /// field, `file` — it sniffs the content type and derives the extension
    /// server-side, so the part's filename extension must match the real bytes
    /// (a mismatch flags the upload unsafe and it won't render inline).
    func uploadAttachment(documentID: UUID, fileName: String, contentType: String, data: Data) async throws
        -> String
    {
        let boundary = "schrift-" + UUID().uuidString
        let body = multipartFormDataBody(
            boundary: boundary, fieldName: "file", fileName: fileName, contentType: contentType, fileData: data)
        let response: AttachmentUploadResponse = try await send(
            path: "documents/\(documentID.uuidString.lowercased())/attachment-upload/",
            method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)")
        return response.file
    }

    /// Polls a media-check path exactly as the server returned it. The path is
    /// server-provided and already absolute (`/api/v1.0/…`), so — unlike every
    /// other endpoint — it intentionally starts with `/` and resolves against
    /// the host root without re-prefixing the API base.
    func checkMedia(path: String) async throws -> MediaCheckResponse {
        try await get(path)
    }
}
```

`DocsAPIClient.swift` — add alongside `siteOrigin` (keeps `baseURL` private):

```swift
/// Resolves a server-relative path (e.g. the `/media/…` value from
/// media-check) against the server origin, not the `/api/v1.0/` base.
func absoluteServerURL(for path: String) -> URL? {
    URL(string: path, relativeTo: baseURL)?.absoluteURL
}
```

Move `bodyData(from:)` from `ShareEndpointsClientTests.swift` into `SchriftTests/Support/RequestBodyHelpers.swift` (internal to the test target) and update both test files to use it — `URLSession` moves bodies into `httpBodyStream`, so multipart assertions need the drain helper.

- [ ] **Step 3: Run the two test classes; all pass.**

- [ ] **Step 4: Commit**

```sh
git add Schrift/Core/Networking/ SchriftTests/Core/Networking/ SchriftTests/Support/
git commit -m "feat: add attachment upload and media-check endpoints"
```

---

### Task 2: Image preparation helper

**Files:**
- Create: `Schrift/Features/Editor/ImagePreparation.swift`
- Create: `SchriftTests/Features/Editor/ImagePreparationTests.swift`

**Interfaces:**
- Produces: `func preparedJPEGData(from data: Data, maxPixelSize: Int = 2048, compressionQuality: Double = 0.8) -> Data?` (consumed by Task 4).

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Schrift

final class ImagePreparationTests: XCTestCase {
    /// Solid-color PNG generated with CoreGraphics — no bundle fixture needed.
    private func pngData(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func pixelSize(of data: Data) -> (width: Int, height: Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int)
    }

    func testDownscalesLargeImagesToMaxEdge() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: pngData(width: 3000, height: 1500)))
        let size = pixelSize(of: jpeg)
        XCTAssertEqual(size.width, 2048)
        XCTAssertEqual(size.height, 1024)
    }

    func testSmallImagesAreNotUpscaled() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: pngData(width: 100, height: 80)))
        let size = pixelSize(of: jpeg)
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 80)
    }

    func testOutputIsJPEG() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: pngData(width: 10, height: 10)))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
    }

    func testNonImageDataReturnsNil() {
        XCTAssertNil(preparedJPEGData(from: Data([0x00, 0x01, 0x02])))
    }
}
```

Run `-only-testing:SchriftTests/ImagePreparationTests`; expected: compile failure.

- [ ] **Step 2: Implement**

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales an image (HEIC/PNG/JPEG…) to at most `maxPixelSize` on its long
/// edge and re-encodes it as JPEG. Uses ImageIO's thumbnail path so the full-
/// resolution bitmap is never decoded into memory, and bakes in the EXIF
/// orientation so the upload displays upright everywhere. Returns nil for
/// undecodable data.
func preparedJPEGData(from data: Data, maxPixelSize: Int = 2048, compressionQuality: Double = 0.8) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        return nil
    }
    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
    CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
```

- [ ] **Step 3: Run the tests; all pass. Commit**

```sh
git add Schrift/Features/Editor/ImagePreparation.swift SchriftTests/Features/Editor/ImagePreparationTests.swift
git commit -m "feat: add ImageIO photo downscale and JPEG re-encode helper"
```

---

### Task 3: Slash-menu action model

The slash menu can currently only swap `BlockKind` (`SlashMenuItem.kind` is non-optional and `applySlashSelection` always assigns it). A photo item needs a side-effect action.

**Files:**
- Modify: `Schrift/Features/Editor/SlashMenu.swift` (item model + `allSlashMenuItems`)
- Modify: `Schrift/Features/Editor/EditorViewModel.swift` (`applySlashSelection`, ~line 713)
- Test: `SchriftTests/Features/Editor/` (the suite covering slash selection — search for existing `applySlashSelection` tests and extend in place)

**Interfaces:**
- Produces: `enum SlashMenuAction: Equatable, Sendable { case convert(BlockKind); case insertPhoto }`; `SlashMenuItem.action: SlashMenuAction` (replacing `kind`). Task 4 consumes `.insertPhoto` and the VM's `isPhotoPickerPresented` flag.

- [ ] **Step 1: Write the failing tests** (in the existing slash-menu test class):

```swift
func testSelectingPhotoItemPresentsThePickerAndConsumesTheQuery() {
    let viewModel = makeLoadedViewModel(blocks: [EditorBlock(kind: .paragraph, text: "/photo")])
    viewModel.focusBlockForTesting(viewModel.blocks[0].id)  // use the suite's focus helper
    let photoItem = allSlashMenuItems.first { $0.action == .insertPhoto }!
    viewModel.applySlashSelection(photoItem)
    XCTAssertTrue(viewModel.isPhotoPickerPresented)
    XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
    XCTAssertEqual(viewModel.blocks[0].text, "")
    XCTAssertNil(viewModel.slashQueryText)
}

func testPhotoItemMatchesImageKeywords() {
    XCTAssertTrue(filteredSlashItems(query: "ima", items: allSlashMenuItems).contains { $0.action == .insertPhoto })
}
```

Expected: compile failure (`action` doesn't exist).

- [ ] **Step 2: Implement**

`SlashMenu.swift`:

```swift
/// What selecting a slash-menu item does: convert the focused block, or run a
/// side-effect (the photo picker) that inserts its block later, on success.
enum SlashMenuAction: Equatable, Sendable {
    case convert(BlockKind)
    case insertPhoto
}

struct SlashMenuItem: Equatable, Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let action: SlashMenuAction
    let keywords: [String]
}
```

Mechanically rewrite `allSlashMenuItems` entries from `kind: X` to `action: .convert(X)`, and append:

```swift
SlashMenuItem(
    id: "photo", title: "Photo", systemImage: "photo",
    action: .insertPhoto, keywords: ["photo", "image", "picture", "img"]),
```

`EditorViewModel.applySlashSelection` becomes a switch over the action (divider branch unchanged in behavior):

```swift
func applySlashSelection(_ item: SlashMenuItem) {
    guard let focusedBlockID, let index = blockIndex(focusedBlockID) else { return }
    blocks[index].text = ""
    slashQueryText = nil
    switch item.action {
    case .convert(.divider):
        blocks[index].kind = .divider
        let newBlock = EditorBlock(kind: .paragraph)
        blocks.insert(newBlock, at: index + 1)
        focusBlock(newBlock.id, cursorAt: 0)
    case .convert(let kind):
        blocks[index].kind = kind
        focusBlock(focusedBlockID, cursorAt: 0)
    case .insertPhoto:
        isPhotoPickerPresented = true
        focusBlock(focusedBlockID, cursorAt: 0)
    }
    markDirty()
}
```

(`isPhotoPickerPresented` is declared in Task 4 — declare the `var isPhotoPickerPresented = false` stub now so this compiles.)

- [ ] **Step 3: Run the slash-menu tests plus the full editor suite slice; all pass. Commit**

```sh
git add Schrift/Features/Editor/SlashMenu.swift Schrift/Features/Editor/EditorViewModel.swift SchriftTests/Features/Editor/
git commit -m "feat: model slash-menu selections as actions and add a photo item"
```

---

### Task 4: View-model upload flow

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift`
- Test: Create `SchriftTests/Features/Editor/EditorPhotoInsertionTests.swift`

**Interfaces:**
- Consumes: Task 1 endpoints, Task 2 `preparedJPEGData`, Task 3 flag.
- Produces (consumed by Task 5's view wiring):
  - `var isPhotoPickerPresented: Bool`, `var isUploadingPhoto: Bool`
  - `func requestPhotoInsertion()`
  - `func insertPhoto(loadingData: @Sendable () async throws -> Data?) async`
  - init gains `mediaCheckRetryInterval: Duration = .seconds(1)` (tests pass `.zero`).

- [ ] **Step 1: Write the failing tests**

`EditorPhotoInsertionTests.swift` — `@MainActor final class`, mirroring the existing EditorViewModel test setup (MockURLProtocol session, stubbed `formatted-content` GET + `await viewModel.load()` to reach `hasLoadedContent`, `RequestRecorder` for multi-request flows, `waitUntil` for eventual state). Route stubs by URL substring:

```swift
private func stubUploadPipeline(mediaCheckStatus: String = "ready") {
    let docID = documentID.uuidString.lowercased()
    MockURLProtocol.stubHandler = { request in
        let url = request.url?.absoluteString ?? ""
        if url.contains("attachment-upload") {
            let body = #"{"file": "/api/v1.0/documents/\#(docID)/media-check/?key=\#(docID)%2Fattachments%2F22222222-2222-4222-8222-222222222222.jpg"}"#
            return .init(statusCode: 201, headers: [:], body: Data(body.utf8), error: nil)
        }
        if url.contains("media-check") {
            let body = mediaCheckStatus == "ready"
                ? #"{"status": "ready", "file": "/media/\#(docID)/attachments/22222222-2222-4222-8222-222222222222.jpg"}"#
                : #"{"status": "processing"}"#
            return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
        }
        return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)  // content GET etc.
    }
}
```

Tests (each builds the VM with `mediaCheckRetryInterval: .zero` and loads content first):

```swift
func testInsertPhotoUploadsAndInsertsImageBlockWithAbsoluteMediaURL() async throws {
    stubUploadPipeline()
    let viewModel = try await makeLoadedViewModel()
    viewModel.startEditing()

    await viewModel.insertPhoto(loadingData: { self.tinyPNGData() })

    let docID = self.documentID.uuidString.lowercased()
    let expected = "https://docs.example.org/media/\(docID)/attachments/22222222-2222-4222-8222-222222222222.jpg"
    XCTAssertTrue(viewModel.blocks.contains { $0.kind == .image(alt: "", url: expected) })
    XCTAssertTrue(viewModel.isDirty)
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertFalse(viewModel.isUploadingPhoto)
}

func testInsertPhotoFallsBackToKeyDerivedURLWhenMediaCheckNeverReady() async throws {
    stubUploadPipeline(mediaCheckStatus: "processing")
    let viewModel = try await makeLoadedViewModel()
    viewModel.startEditing()

    await viewModel.insertPhoto(loadingData: { self.tinyPNGData() })

    let docID = self.documentID.uuidString.lowercased()
    let expected = "https://docs.example.org/media/\(docID)/attachments/22222222-2222-4222-8222-222222222222.jpg"
    XCTAssertTrue(viewModel.blocks.contains { $0.kind == .image(alt: "", url: expected) })
    XCTAssertNil(viewModel.errorMessage)  // upload succeeded — never lose it
}

func testInsertPhotoUploadFailureSetsFriendlyErrorAndInsertsNothing() async throws {
    MockURLProtocol.stubHandler = { request in
        (request.url?.absoluteString ?? "").contains("attachment-upload")
            ? .init(statusCode: 400, headers: [:], body: Data(), error: nil)
            : .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
    }
    let viewModel = try await makeLoadedViewModel()
    viewModel.startEditing()
    let blockCountBefore = viewModel.blocks.count

    await viewModel.insertPhoto(loadingData: { self.tinyPNGData() })

    XCTAssertEqual(viewModel.errorMessage, "Couldn't add the photo. Please try again.")
    XCTAssertEqual(viewModel.blocks.count, blockCountBefore)
    XCTAssertFalse(viewModel.isUploadingPhoto)
}

func testInsertPhotoCancelledPickerInsertsNothingAndShowsNoError() async throws {
    stubUploadPipeline()
    let viewModel = try await makeLoadedViewModel()
    viewModel.startEditing()
    let blockCountBefore = viewModel.blocks.count

    await viewModel.insertPhoto(loadingData: { nil })

    XCTAssertNil(viewModel.errorMessage)
    XCTAssertEqual(viewModel.blocks.count, blockCountBefore)
}

func testSlashPhotoInsertionReplacesTheEmptyParagraphAndAppendsATrailingParagraph() async throws {
    // Focused empty paragraph (the consumed "/photo" block) is replaced in
    // place by the image, with a fresh focused paragraph after it — mirroring
    // the divider slash behavior.
    ...
}
```

`tinyPNGData()` reuses the CoreGraphics PNG helper from ImagePreparationTests (extract it to `SchriftTests/Support/TestImages.swift` and update ImagePreparationTests to use it). Expected: compile failure.

- [ ] **Step 2: Implement** in `EditorViewModel.swift`:

New state + init parameter (stored `let mediaCheckRetryInterval: Duration`, defaulted `.seconds(1)`; private `let mediaCheckMaxAttempts = 5`):

```swift
var isPhotoPickerPresented = false
var isUploadingPhoto = false
```

Intent methods:

```swift
/// Entry point for both the formatting-bar button and the slash-menu item.
func requestPhotoInsertion() {
    guard hasLoadedContent, !isUploadingPhoto else { return }
    isPhotoPickerPresented = true
}

/// Runs the picked photo through prepare → upload → readiness poll and inserts
/// the resulting `.image` block. A cancelled pick (`nil` data) is a silent
/// no-op; a failure sets friendly copy and inserts nothing, so a broken upload
/// can never leave a placeholder in the document.
func insertPhoto(loadingData: @Sendable () async throws -> Data?) async {
    guard hasLoadedContent, !isUploadingPhoto else { return }
    isUploadingPhoto = true
    defer { isUploadingPhoto = false }
    do {
        guard let originalData = try await loadingData() else { return }
        guard let jpegData = preparedJPEGData(from: originalData) else {
            errorMessage = "Couldn't add the photo. Please try again."
            return
        }
        let mediaCheckPath = try await client.uploadAttachment(
            documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: jpegData)
        guard let urlString = await readyMediaURLString(fromMediaCheckPath: mediaCheckPath) else {
            errorMessage = "Couldn't add the photo. Please try again."
            return
        }
        insertImageBlock(url: urlString)
    } catch {
        errorMessage = "Couldn't add the photo. Please try again."
    }
}
```

Readiness poll + fallback (private):

```swift
/// Polls media-check until the attachment is ready and returns the absolute
/// media URL to embed (matching what the web client persists). Falls back to
/// the URL derived from the upload key if readiness can't be confirmed in
/// time — the upload already succeeded, so the URL must never be lost.
private func readyMediaURLString(fromMediaCheckPath path: String) async -> String? {
    for attempt in 0..<mediaCheckMaxAttempts {
        if attempt > 0 { try? await Task.sleep(for: mediaCheckRetryInterval) }
        if let response = try? await client.checkMedia(path: path),
            response.status == MediaCheckResponse.readyStatus, let file = response.file,
            let absolute = await client.absoluteServerURL(for: file)
        {
            return absolute.absoluteString
        }
    }
    guard let key = attachmentKey(fromMediaCheckPath: path),
        let absolute = await client.absoluteServerURL(for: "/media/" + key)
    else { return nil }
    return absolute.absoluteString
}
```

Insertion (private) — mirrors the divider slash behavior; in markdown-source mode inserts the markdown at the caret instead:

```swift
private func insertImageBlock(url: String) {
    if mode == .markdown {
        insertAtCursor("![](\(url))")
        return
    }
    let image = EditorBlock(kind: .image(alt: "", url: url))
    let trailing = EditorBlock(kind: .paragraph)
    if let focusedBlockID, let index = blockIndex(focusedBlockID),
        blocks[index].kind == .paragraph, blocks[index].text.isEmpty
    {
        blocks[index] = image
        blocks.insert(trailing, at: index + 1)
    } else if let focusedBlockID, let index = blockIndex(focusedBlockID) {
        blocks.insert(image, at: index + 1)
        blocks.insert(trailing, at: index + 2)
    } else {
        blocks.append(image)
        blocks.append(trailing)
    }
    focusBlock(trailing.id, cursorAt: 0)
    markDirty()
}
```

- [ ] **Step 3: Run `-only-testing:SchriftTests/EditorPhotoInsertionTests`; all pass. Commit**

```sh
git add Schrift/Features/Editor/EditorViewModel.swift SchriftTests/
git commit -m "feat: upload picked photos and insert them as image blocks"
```

---

### Task 5: View wiring — picker, formatting-bar button, uploading indicator

**Files:**
- Modify: `Schrift/Features/Editor/EditorView.swift`
- Modify: `Schrift/Features/Editor/EditorFormattingBar.swift`

**Interfaces:**
- Consumes: `isPhotoPickerPresented` / `isUploadingPhoto` / `requestPhotoInsertion()` / `insertPhoto(loadingData:)`.

- [ ] **Step 1: Wire the picker** in `EditorView.swift` (`import PhotosUI`; `@State private var selectedPhotoItem: PhotosPickerItem?`):

```swift
.photosPicker(isPresented: $viewModel.isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
.onChange(of: selectedPhotoItem) { _, newItem in
    guard let newItem else { return }
    selectedPhotoItem = nil
    Task { await viewModel.insertPhoto(loadingData: { try await newItem.loadTransferable(type: Data.self) }) }
}
```

(`PhotosPicker` is the out-of-process system picker — no usage-description key, no `project.yml` change.)

- [ ] **Step 2: Add the formatting-bar button** in `EditorFormattingBar.swift`, next to the existing insert ("plus") button, following the `barButton` pattern:

```swift
barButton(
    icon: "photo", label: "Insert photo",
    disabled: !hasTarget || viewModel.isUploadingPhoto
) {
    viewModel.requestPhotoInsertion()
}
```

The `label` feeds the accessibility label like every other bar button.

- [ ] **Step 3: Uploading indicator** — in the `.safeAreaInset(edge: .bottom)` block of EditorView, above the formatting bar, styled to match the existing inline banners (offline banner / error text):

```swift
if viewModel.isUploadingPhoto {
    HStack(spacing: DocsSpacing.spaceXS) {
        ProgressView()
        Text("Uploading photo…")
    }
    // match the offline-banner font/color tokens and padding
}
```

- [ ] **Step 4: Manual end-to-end verification** (simulator against the real server — the one step tests can't cover):
  1. Sign in to `docs.llun.dev`, open a doc, enter edit mode.
  2. Insert a photo via the formatting-bar button; verify the uploading indicator, then the rendered image.
  3. Insert one via `/photo` in the slash menu; verify the empty paragraph is replaced and focus lands on the trailing paragraph.
  4. Wait for autosave; open the doc in the web client and confirm the image renders there as a real image block.
  5. Edit and re-save the doc in the app; confirm the image survives on the web (the PR-1 bug-fix, end to end).
  6. Cancel the picker; confirm nothing was inserted and no error shows.

- [ ] **Step 5: Commit**

```sh
git add Schrift/Features/Editor/EditorView.swift Schrift/Features/Editor/EditorFormattingBar.swift
git commit -m "feat: add photo picker entry points to the editor"
```

---

### Task 6: Docs, formatting, full suite, PR + review loop

- [ ] **Step 1: Update CLAUDE.md**:
  - Networking section: note the attachment endpoints (`AttachmentEndpoints.swift`), the single-`file` multipart contract, the media-check poll, and the deliberate leading-slash exception for server-provided paths.
  - Editor section: the photo-insert flow (prepare → upload → poll → insert on success only; error copy; picker needs no plist key).
  - Repository layout: `AttachmentEndpoints.swift`, `ImagePreparation.swift`.
- [ ] **Step 2: Commit this plan** as `docs/superpowers/plans/2026-07-07-photo-upload-insert.md`; add a dated amendment note to the design spec if its editor/save description needs it.
- [ ] **Step 3: Format, regenerate, full suite** (same commands as PR-1 Task 5). Expected: PASS.
- [ ] **Step 4: Push, open the PR** (`feat: insert photos from the library into documents`, base `main` after PR-1 merges), then run the mandatory PR review loop until a clean round and **`Build & Test` green on the latest pushed state**.

## Self-review notes

- Spec coverage: endpoint ✓ (Task 1, corrected to single-`file`), image prep ✓ (Task 2), entry points ✓ (Tasks 3+5), transient upload state ✓ (Task 4, no placeholder block ever persisted), dirty/autosave via coordinator ✓ (insertImageBlock → markDirty), friendly errors ✓, processing window ✓ (bounded poll + key-derived fallback — in scope because the upload response is a media-check path, not a media URL).
- Type consistency: `MediaCheckResponse`, `multipartFormDataBody(boundary:fieldName:fileName:contentType:fileData:)`, `attachmentKey(fromMediaCheckPath:)`, `preparedJPEGData(from:maxPixelSize:compressionQuality:)`, `insertPhoto(loadingData:)` used identically across Tasks 1–5.
- Out of scope (recorded): camera, captions/alt editing, upload progress, retry queue, abilities-gated button visibility (a 403 maps to the friendly error, same as every save-path failure today).
