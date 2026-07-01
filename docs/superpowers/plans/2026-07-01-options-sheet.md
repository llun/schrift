# Options Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Options sheet (the remainder of design spec Phase 8, split out from the Share Sheet plan): Pin/Unpin, Copy link, Copy as Markdown, Duplicate, and Delete (with a confirmation dialog) — wired to `EditorView`'s previously-no-op Options (`ellipsis`) button.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including a full-suite test run and a Simulator screenshot of the sheet — and the duplicate endpoint's request/response shape was read directly from the real `suitenumerique/docs` backend source.

- **`POST /documents/{id}/duplicate/` takes `with_accesses`/`with_descendants` booleans and returns just `{"id": "..."}`.** This plan's `duplicateDocument` defaults both to `false` (a plain content duplicate — matching the design spec's simple "Duplicate" action, not a bulk copy-with-permissions operation) and returns only the new document's `UUID`, not a full `Document`.
- **Pin/Unpin and Delete reuse endpoints that already exist from earlier plans** — `DocsAPIClient.setFavorite(documentID:isFavorite:)` (Home Screen plan) and `.deleteDocument(documentID:)` (Editor Editing plan, originally built for the temp-document cleanup flow but generically usable here). No new favorite/delete endpoint code is needed in this plan.
- **Copy link and Copy as Markdown are pure client-side actions, no network call.** Copy link builds a share URL directly (`https://{serverHost}/docs/{documentID}/`, matching the pattern the real backend's own web frontend uses for a document's canonical URL) and writes it to `UIPasteboard`. Copy as Markdown writes `EditorViewModel.rawMarkdown` (the same raw Markdown source already loaded for editing) to `UIPasteboard`.
- **`OptionsViewModel` is constructed lazily and held in `EditorView`'s own `@State`, not recreated on every sheet presentation** — mirroring how `EditorView` already treats its Share sheet's `ShareViewModel` as disposable-per-presentation, but here the Pin/Unpin toggle state needs to persist across repeated Options-sheet opens within the same Editor session (so a Pin taken, then the sheet dismissed and reopened, shows the updated state instead of resetting to the stale `initialIsFavorite` every time).
- **Delete needs to pop the Editor screen and refresh the Home list**, not just dismiss the sheet — `EditorView` gains an `onDeleted: (() -> Void)? = nil` closure, threaded from `HomeView`'s `.navigationDestination` as `{ path.removeLast(); Task { await viewModel.load() } }`, matching the existing `onBack` closure pattern already used for manual navigation.
- **`EditorView` also gains `serverHost: String` (required, for building the share URL) and `initialIsFavorite: Bool = false`** (seeded from `document.isFavorite`, mirroring how `reach`/`linkRole` are already seeded from the `Document` passed into `HomeView`'s `.navigationDestination`).

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `duplicateDocument` must send `with_accesses`/`with_descendants` as `false` by default and decode only `{"id": ...}` from the response — do not attempt to decode a full `Document` from the duplicate endpoint's response body.
- Reuse the existing `DocsAPIClient.setFavorite` and `.deleteDocument` methods — do not add new favorite/delete endpoint methods.
- Reuse `MockURLProtocol` from `DocsIOSTests/Core/Networking/MockURLProtocol.swift` for all new networking-dependent tests — do not create a second mock URLProtocol.
- Task 3 has no new XCTest files by design — it is UI glue verified by build-check and a Simulator screenshot. If `RootView.swift` is temporarily swapped for screenshots, it MUST be reverted to the real auth-gated version before committing — never commit a temporary version.

## File Structure

```
DocsIOS/
├── Core/
│   └── Networking/
│       └── DocumentDuplicate.swift                             — DuplicatedDocument, duplicateDocument (Task 1)
└── Features/
    ├── Options/
    │   ├── OptionsViewModel.swift                               — documentShareURL, OptionsViewModel (Task 2)
    │   └── OptionsSheetView.swift                                — OptionsSheetView (Task 3)
    ├── Editor/
    │   └── EditorView.swift                                     — MODIFY: serverHost/initialIsFavorite/onDeleted params, Options button wiring (Task 3)
    └── Home/
        └── HomeView.swift                                       — MODIFY: pass serverHost/isFavorite/onDeleted to EditorView (Task 3)

DocsIOSTests/
├── Core/
│   └── Networking/
│       └── DocumentDuplicateTests.swift                          — Task 1
└── Features/
    └── Options/
        └── OptionsViewModelTests.swift                           — Task 2
```

---

### Task 1: DocumentDuplicate endpoint

**Files:**
- Create: `DocsIOS/Core/Networking/DocumentDuplicate.swift`
- Test: `DocsIOSTests/Core/Networking/DocumentDuplicateTests.swift`

**Interfaces:**
- Consumes: `DocsAPIClient` (earlier plans).
- Produces: `func duplicateDocument(documentID:withAccesses:withDescendants:) async throws -> UUID` on `DocsAPIClient` — consumed by Task 2's `OptionsViewModel`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/DocumentDuplicateTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocumentDuplicateTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testDuplicateDocumentSendsRequestAndReturnsNewID() async throws {
        let newID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let body = #"{"id": "22222222-2222-4222-8222-222222222222"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: body, error: nil) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })

        let result = try await client.duplicateDocument(documentID: documentID)

        XCTAssertEqual(result, newID)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/duplicate/")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentDuplicateTests`
Expected: FAIL — `cannot find 'duplicateDocument' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Networking/DocumentDuplicate.swift`:
```swift
import Foundation

struct DuplicatedDocument: Codable, Equatable, Sendable {
    let id: UUID
}

private struct DuplicateRequest: Encodable {
    let withAccesses: Bool
    let withDescendants: Bool

    enum CodingKeys: String, CodingKey {
        case withAccesses = "with_accesses"
        case withDescendants = "with_descendants"
    }
}

extension DocsAPIClient {
    func duplicateDocument(documentID: UUID, withAccesses: Bool = false, withDescendants: Bool = false) async throws -> UUID {
        let body = try JSONEncoder().encode(DuplicateRequest(withAccesses: withAccesses, withDescendants: withDescendants))
        let result: DuplicatedDocument = try await send(path: "documents/\(documentID.uuidString.lowercased())/duplicate/", method: "POST", body: body)
        return result.id
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentDuplicateTests`
Expected: PASS — `Executed 1 test, with 0 failures`. Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 214 tests, with 0 failures` (213 from Plan 13 + 1 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/DocumentDuplicate.swift DocsIOSTests/Core/Networking/DocumentDuplicateTests.swift
git commit -m "Add document duplicate endpoint"
```

---

### Task 2: OptionsViewModel

**Files:**
- Create: `DocsIOS/Features/Options/OptionsViewModel.swift`
- Test: `DocsIOSTests/Features/Options/OptionsViewModelTests.swift`

**Interfaces:**
- Consumes: `DocsAPIClient.setFavorite`, `.deleteDocument` (earlier plans), `.duplicateDocument` (Task 1).
- Produces: `func documentShareURL(serverHost:documentID:) -> URL?`, `@MainActor @Observable final class OptionsViewModel` (`init(client:documentID:isFavorite:)`, `isFavorite: Bool`, `isDuplicating: Bool`, `isDeleting: Bool`, `errorMessage: String?`, `didDelete: Bool` (read-only), `func toggleFavorite() async`, `func duplicate() async -> UUID?`, `func delete() async`) — consumed by Task 3's `OptionsSheetView`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Options/OptionsViewModelTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class DocumentShareURLTests: XCTestCase {
    func testBuildsExpectedURL() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        XCTAssertEqual(
            documentShareURL(serverHost: "docs.llun.dev", documentID: id)?.absoluteString,
            "https://docs.llun.dev/docs/11111111-1111-4111-8111-111111111111/"
        )
    }
}

@MainActor
final class OptionsViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel(isFavorite: Bool = false) -> OptionsViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return OptionsViewModel(client: client, documentID: documentID, isFavorite: isFavorite)
    }

    func testToggleFavoriteFlipsStateOnSuccess() async {
        let viewModel = makeViewModel(isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite()

        XCTAssertTrue(viewModel.isFavorite)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testToggleFavoriteFailureKeepsStateAndSetsError() async {
        let viewModel = makeViewModel(isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite()

        XCTAssertFalse(viewModel.isFavorite)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testDuplicateReturnsNewDocumentIDOnSuccess() async {
        let viewModel = makeViewModel()
        let body = #"{"id": "22222222-2222-4222-8222-222222222222"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: body, error: nil) }

        let result = await viewModel.duplicate()

        XCTAssertEqual(result, UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        XCTAssertFalse(viewModel.isDuplicating)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testDuplicateFailureSetsErrorAndReturnsNil() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        let result = await viewModel.duplicate()

        XCTAssertNil(result)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testDeleteSetsDidDeleteOnSuccess() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }

        await viewModel.delete()

        XCTAssertTrue(viewModel.didDelete)
        XCTAssertFalse(viewModel.isDeleting)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testDeleteFailureSetsErrorAndDoesNotSetDidDelete() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.delete()

        XCTAssertFalse(viewModel.didDelete)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentShareURLTests -only-testing:DocsIOSTests/OptionsViewModelTests`
Expected: FAIL — `cannot find 'OptionsViewModel' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Options/OptionsViewModel.swift`:
```swift
import Foundation

func documentShareURL(serverHost: String, documentID: UUID) -> URL? {
    URL(string: "https://\(serverHost)/docs/\(documentID.uuidString.lowercased())/")
}

@MainActor
@Observable
final class OptionsViewModel {
    var isFavorite: Bool
    var isDuplicating = false
    var isDeleting = false
    var errorMessage: String?
    private(set) var didDelete = false

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID, isFavorite: Bool) {
        self.client = client
        self.documentID = documentID
        self.isFavorite = isFavorite
    }

    func toggleFavorite() async {
        errorMessage = nil
        do {
            try await client.setFavorite(documentID: documentID, isFavorite: !isFavorite)
            isFavorite.toggle()
        } catch {
            errorMessage = "Couldn't update favorite. Please try again."
        }
    }

    @discardableResult
    func duplicate() async -> UUID? {
        isDuplicating = true
        errorMessage = nil
        defer { isDuplicating = false }
        do {
            return try await client.duplicateDocument(documentID: documentID)
        } catch {
            errorMessage = "Couldn't duplicate document. Please try again."
            return nil
        }
    }

    func delete() async {
        isDeleting = true
        errorMessage = nil
        do {
            try await client.deleteDocument(documentID: documentID)
            didDelete = true
        } catch {
            errorMessage = "Couldn't delete document. Please try again."
        }
        isDeleting = false
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/DocumentShareURLTests -only-testing:DocsIOSTests/OptionsViewModelTests`
Expected: PASS — `Executed 7 tests, with 0 failures` (1 share-URL + 6 view-model). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 221 tests, with 0 failures` (214 from Task 1 + 7 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Options/OptionsViewModel.swift DocsIOSTests/Features/Options/OptionsViewModelTests.swift
git commit -m "Add OptionsViewModel"
```

---

### Task 3: OptionsSheetView UI + wire EditorView Options button

**Files:**
- Create: `DocsIOS/Features/Options/OptionsSheetView.swift`
- Modify: `DocsIOS/Features/Editor/EditorView.swift`
- Modify: `DocsIOS/Features/Home/HomeView.swift`

**Interfaces:**
- Consumes: `OptionsViewModel` (Task 2), `ListSection`, `ListRow` (DesignSystem).
- Produces: `struct OptionsSheetView: View` — presented as a sheet from `EditorView`'s Options (`ellipsis`) button; `EditorView` gains `serverHost: String`, `initialIsFavorite: Bool = false`, `onDeleted: (() -> Void)? = nil` parameters; `HomeView`'s `.navigationDestination(for: Document.self)` passes `serverHost`, `document.isFavorite`, and an `onDeleted` closure through.

This task has no new XCTest files — see the Share Sheet plan's Task 3/4 precedent and this plan's Global Constraints for why (UI glue verified by build-check and a Simulator screenshot, not XCTest).

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Options/OptionsSheetView.swift`:
```swift
import SwiftUI

struct OptionsSheetView: View {
    @Bindable var viewModel: OptionsViewModel
    let shareURL: URL?
    let markdown: String
    var onDeleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .padding(.horizontal, DocsSpacing.gutter)
                        .padding(.top, DocsSpacing.spaceSM)
                }

                ListSection {
                    VStack(spacing: 0) {
                        ListRow(
                            systemImage: viewModel.isFavorite ? "pin.slash" : "pin",
                            title: viewModel.isFavorite ? "Unpin" : "Pin",
                            action: { Task { await viewModel.toggleFavorite() } }
                        )
                        ListRow(systemImage: "link", title: "Copy link", action: { copyLink() })
                        ListRow(systemImage: "doc.on.doc", title: "Copy as Markdown", action: { copyMarkdown() })
                        ListRow(systemImage: "plus.square.on.square", title: "Duplicate", action: {
                            Task {
                                await viewModel.duplicate()
                                dismiss()
                            }
                        })
                        ListRow(title: "Delete document", isDestructive: true, action: { isConfirmingDelete = true })
                    }
                }

                Spacer()
            }
            .background(DocsColor.surfacePage)
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this document?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.delete()
                        if viewModel.didDelete {
                            dismiss()
                            onDeleted?()
                        }
                    }
                }
            }
        }
    }

    private func copyLink() {
        if let shareURL {
            UIPasteboard.general.string = shareURL.absoluteString
        }
        dismiss()
    }

    private func copyMarkdown() {
        UIPasteboard.general.string = markdown
        dismiss()
    }
}

#Preview {
    OptionsSheetView(
        viewModel: OptionsViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            isFavorite: false
        ),
        shareURL: URL(string: "https://docs.llun.dev/docs/abc/"),
        markdown: "# Sample"
    )
}
```

In `DocsIOS/Features/Editor/EditorView.swift`, add `serverHost`, `initialIsFavorite`, `onDeleted` parameters and Options-sheet presentation state:
```swift
struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    let serverHost: String
    var linkRole: LinkRole? = nil
    var initialIsFavorite: Bool = false
    var onBack: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil

    @State private var isPresentingShareSheet = false
    @State private var isPresentingOptionsSheet = false
    @State private var optionsViewModel: OptionsViewModel?
```

Add a second `.sheet` modifier alongside the existing Share sheet's:
```swift
        .sheet(isPresented: $isPresentingOptionsSheet) {
            if let optionsViewModel {
                OptionsSheetView(
                    viewModel: optionsViewModel,
                    shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID),
                    markdown: viewModel.rawMarkdown,
                    onDeleted: onDeleted
                )
            }
        }
```

Replace the Options `NavBarAction`'s empty `action: {}` with:
```swift
            NavBarAction(systemImage: "ellipsis", label: "Options", action: {
                if optionsViewModel == nil {
                    optionsViewModel = OptionsViewModel(client: viewModel.client, documentID: viewModel.documentID, isFavorite: initialIsFavorite)
                }
                isPresentingOptionsSheet = true
            }),
```

In `DocsIOS/Features/Home/HomeView.swift`, find the `.navigationDestination(for: Document.self)` block and add `serverHost`, `initialIsFavorite`, and `onDeleted`:
```swift
            .navigationDestination(for: Document.self) { document in
                EditorView(
                    viewModel: EditorViewModel(
                        client: viewModel.client,
                        documentID: document.id,
                        title: document.title ?? "Untitled document"
                    ),
                    reach: document.linkReach,
                    serverHost: serverHost,
                    linkRole: document.linkRole,
                    initialIsFavorite: document.isFavorite,
                    onBack: { path.removeLast() },
                    onDeleted: {
                        path.removeLast()
                        Task { await viewModel.load() }
                    }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 221 tests, with 0 failures` (no new tests in this task).

- [ ] **Step 3: Visually verify in the Simulator**

Temporarily point `RootView.body` at an `OptionsSheetView` with sample data (matching this plan's own validation — see Architecture), screenshot, then revert `RootView.swift` back to the real auth-gated version **before committing**:

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'
APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/DocsIOS-*/Build/Products/Debug-iphonesimulator/DocsIOS.app | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted dev.llun.DocsIOS
xcrun simctl io booted screenshot /tmp/options-sheet-verify.png
```
Expected: the screenshot shows "Options" title with a Done button, a list with Unpin/Pin (varying by sample `isFavorite`), Copy link, Copy as Markdown, Duplicate, and a red "Delete document" row.

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Options/OptionsSheetView.swift DocsIOS/Features/Editor/EditorView.swift DocsIOS/Features/Home/HomeView.swift
git commit -m "Wire EditorView Options button to present OptionsSheetView"
```

## Self-Review Notes

- **Spec coverage:** Implements the remainder of design spec Phase 8 ("Pin/Unpin, Copy link, Copy as Markdown, Duplicate, Delete") — completing the Options half that the Share Sheet plan explicitly deferred.
- **Real-backend cross-check:** The duplicate endpoint's request/response shape (`with_accesses`/`with_descendants` booleans in, `{"id": ...}` out) was read directly from the real `suitenumerique/docs` backend source, not guessed from the design spec alone.
- **Reuse over duplication:** Pin/Unpin and Delete reuse `DocsAPIClient.setFavorite`/`.deleteDocument` from earlier plans rather than adding parallel endpoint methods — only the genuinely new `duplicateDocument` endpoint is added.
- **Placeholder scan:** No TBD/TODO. All five Options actions (Pin/Unpin, Copy link, Copy as Markdown, Duplicate, Delete) are fully wired, not stubbed.
- **Type consistency:** `DuplicatedDocument`, `documentShareURL`, `OptionsViewModel`, `OptionsSheetView` are each defined once. `OptionsSheetView` reuses `ListSection`/`ListRow` from the DesignSystem layer rather than building new presentational components.
- **Cross-file validation:** All code in this plan (all three tasks, including the `duplicateDocument` request/response shape, the `OptionsViewModel`'s lazy-construction-and-reuse lifecycle in `EditorView`, and a Simulator screenshot of the populated Options sheet showing all five actions and the destructive Delete row) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 221 tests, with 0 failures` plus a passing Simulator screenshot of the Options sheet.
