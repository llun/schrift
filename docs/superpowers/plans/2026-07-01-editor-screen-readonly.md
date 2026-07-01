# Editor Screen (Read-Only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Editor screen's read-only rendering path (design spec Phase 6 — editing + save is explicitly Phase 7, a later plan): a `GET /documents/{id}/formatted-content/?content_format=markdown` endpoint method, a pure Markdown-to-blocks parser, a `MarkdownBlockView` that renders each block type (paragraph, heading, bullet list, checklist, quote) using Apple's native `AttributedString(markdown:)` for inline styling, and an `EditorView` (NavBar with back, emoji + title + `LinkReachPill`, Share/Options placeholder buttons) wired into `HomeView` via a `NavigationStack` pushed from tapping a `DocRow`.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including three separate Simulator screenshots (the Editor screen's chrome and error state, and a standalone rendering of all five Markdown block types with real sample content) — and the exact `formatted-content` response shape was read directly from the real `suitenumerique/docs` backend source rather than assumed. Key decisions:

- **The `formatted-content` response is a distinct, smaller shape than `Document`, confirmed directly in `viewsets.py`'s `formatted_content` action**: `{"id": "...", "title": "...", "content": "<markdown or null>", "created_at": "...", "updated_at": "..."}`. `content` is `null` when the document has no Yjs content yet (e.g. a brand-new empty document) — modeled as `FormattedDocumentContent.content: String?`, and `EditorViewModel.load()` treats `nil` the same as an empty string (`parseMarkdownBlocks(formatted.content ?? "")`), rendering zero blocks rather than crashing or erroring.
- **`AttributedString(markdown:)` is used exactly where the design spec suggested evaluating it first — for *inline* styling (bold/italic/inline code) within a single block's text — not for block-level structure.** Verified directly: `AttributedString(markdown:)` does not distinguish headings, lists, or blockquotes from plain paragraphs; it flattens everything into one inline-styled string. Block-level structure (which line is a heading vs. a bullet vs. a checklist item vs. a quote vs. a plain paragraph) is handled by a small, pure, line-based parser (`parseMarkdownBlocks`) written for this plan — this keeps the "zero third-party dependencies" constraint intact while still using the native API for what it's actually good at.
- **`parseMarkdownBlocks(_:) -> [MarkdownBlock]` is a pure function operating line-by-line**, with `MarkdownBlock` as a plain `Equatable` enum (`.heading(level:text:)`, `.paragraph(text:)`, `.bulletItem(text:)`, `.checklistItem(checked:text:)`, `.quote(text:)`) holding raw `String`, not `AttributedString` — this keeps the parser fully unit-testable with plain string comparisons; `AttributedString(markdown:)` conversion happens only at render time in `MarkdownBlockView`, per block. Checklist detection (`- [ ] `/`- [x] `/`- [X] `) is checked before plain-bullet detection (`- `/`* `), since every checklist line would otherwise also match the bullet prefix.
- **`EditorViewModel` is `@MainActor`**, matching the established precedent from `ConnectViewModel`/`HomeViewModel` (an `@Observable` class calling `async` methods needs this to compile under this project's Swift 6 strict concurrency settings).
- **Navigation from Home to Editor uses a plain `[Document]`-typed `@State` path with `NavigationStack(path:)` and `.navigationDestination(for: Document.self)`, not the type-erased `NavigationPath`.** This only requires `Document: Hashable`, not `Codable` + `Hashable`, which is simpler given `Document` is already `Codable`. `Document` and its nested `DocumentAbilities` both gain `Hashable` conformance (a mechanical, low-risk addition — every stored property on both types was already a `Hashable`-conforming type). Both the app's custom `NavBar` (used by `HomeView` and `EditorView`) and the system navigation bar would otherwise double up, so both the Home root and the Editor destination apply `.toolbar(.hidden, for: .navigationBar)` — `NavigationStack` still provides push/pop mechanics and the swipe-back gesture with the system bar hidden; the custom `NavBar`'s `onBack` closure drives the actual pop (`path.removeLast()`).
- **`HomeViewModel.client` changes from `private let` to `let`** so `HomeView` can reuse the same `DocsAPIClient` instance to construct `EditorViewModel` when pushing to the Editor screen, instead of constructing a second client. This is a small, mechanical visibility change to already-merged code (from the Home Screen plan), not a behavior change.
- **Share and Options buttons in the Editor `NavBar` are non-functional placeholders** (`NavBarAction(..., action: {})`), matching the same interim pattern already established for `HomeView`'s non-"Docs" `TabBar` items and `DocRow.onOpen` before this plan. Building real Share/Options behavior is Phase 8 (a later plan).
- **Collaborator avatars (`AvatarGroup`) are deliberately not included in this plan.** The design spec describes them as "a static list from accesses," which needs a `GET /documents/{id}/accesses/` endpoint this codebase doesn't have yet — building a GET-only partial version now, only to decorate this screen, would duplicate work the Sharing plan (Phase 8) needs to do properly (GET/POST/PATCH/DELETE) anyway. Deferred, not forgotten.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies — Markdown rendering uses Foundation's `AttributedString(markdown:)` plus this plan's own pure block parser, not a Markdown package.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destination: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `parseMarkdownBlocks` must check for a checklist prefix (`- [ ] `, `- [x] `, `- [X] `, and the `*` equivalents) before checking for a plain bullet prefix (`- `, `* `) — reversing the order would misclassify every checklist item as a plain bullet.
- `EditorViewModel` must be `@MainActor`; any test file constructing one must also be `@MainActor`.
- `EditorView` must render both a loading state and an error state (same requirement as `HomeView` from the prior plan) — a failed load must never render as a silently blank screen.
- Do not build the Share sheet, Options sheet, editing/save flow, or `AvatarGroup`-backed collaborators in this plan — see Architecture for why each is explicitly out of scope.
- `HomeView` and `EditorView` both apply `.toolbar(.hidden, for: .navigationBar)` inside the `NavigationStack` — the app's custom `NavBar` component is the only navigation chrome that should ever be visible; do not let the system navigation bar show through.
- Reuse `MockURLProtocol` from `DocsIOSTests/Core/Networking/MockURLProtocol.swift` for all new networking-dependent tests — do not create a second mock URLProtocol.

## File Structure

```
DocsIOS/
├── Core/
│   └── Networking/
│       ├── FormattedDocumentContent.swift                   — FormattedDocumentContent, DocsAPIClient.formattedContent(documentID:format:) (Task 1)
│       └── Document.swift                                    — MODIFY: add Hashable to Document and DocumentAbilities (Task 1)
└── Features/
    ├── Editor/
    │   ├── MarkdownBlock.swift                                — MarkdownBlock, parseMarkdownBlocks (Task 2)
    │   ├── EditorViewModel.swift                               — EditorViewModel (Task 3)
    │   ├── MarkdownBlockView.swift                             — markdownInlineText, markdownHeadingFont, MarkdownBlockView (Task 4)
    │   └── EditorView.swift                                    — EditorView (Task 4)
    └── Home/
        ├── HomeViewModel.swift                                 — MODIFY: client visibility private let -> let (Task 4)
        └── HomeView.swift                                      — MODIFY: NavigationStack + navigationDestination to EditorView (Task 4)

DocsIOSTests/
├── Core/
│   └── Networking/
│       └── FormattedDocumentContentTests.swift                — Task 1
└── Features/
    └── Editor/
        ├── MarkdownBlockTests.swift                            — Task 2
        └── EditorViewModelTests.swift                          — Task 3
```

---

### Task 1: FormattedDocumentContent endpoint + Document Hashable

**Files:**
- Create: `DocsIOS/Core/Networking/FormattedDocumentContent.swift`
- Modify: `DocsIOS/Core/Networking/Document.swift`
- Test: `DocsIOSTests/Core/Networking/FormattedDocumentContentTests.swift`

**Interfaces:**
- Consumes: `DocsAPIClient` (Networking Foundation plan), `JSONDecoder.docsAPI`.
- Produces: `struct FormattedDocumentContent: Codable, Equatable, Sendable`, `DocsAPIClient.formattedContent(documentID:format:) async throws -> FormattedDocumentContent`, `Document: Hashable`, `DocumentAbilities: Hashable` (added conformances, no new members) — consumed by Task 3's `EditorViewModel` and Task 4's `HomeView` navigation.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Core/Networking/FormattedDocumentContentTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class FormattedDocumentContentDecodingTests: XCTestCase {
    func testDecodesFullFixture() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "title": "Q3 Planning",
            "content": "# Heading\\n\\nBody text",
            "created_at": "2026-01-15T10:30:00Z",
            "updated_at": "2026-01-16T11:00:00Z"
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder.docsAPI.decode(FormattedDocumentContent.self, from: json)
        XCTAssertEqual(result.title, "Q3 Planning")
        XCTAssertEqual(result.content, "# Heading\n\nBody text")
    }

    func testDecodesNullContentForEmptyDocument() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "title": null,
            "content": null,
            "created_at": "2026-01-15T10:30:00Z",
            "updated_at": "2026-01-15T10:30:00Z"
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder.docsAPI.decode(FormattedDocumentContent.self, from: json)
        XCTAssertNil(result.title)
        XCTAssertNil(result.content)
    }
}

final class FormattedDocumentContentClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testFormattedContentRequestsCorrectURLWithMarkdownFormat() async throws {
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        let result = try await client.formattedContent(documentID: id)

        XCTAssertEqual(result.content, "text")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/formatted-content/?content_format=markdown"
        )
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/FormattedDocumentContentDecodingTests -only-testing:DocsIOSTests/FormattedDocumentContentClientTests`
Expected: FAIL — `cannot find 'FormattedDocumentContent' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Core/Networking/FormattedDocumentContent.swift`:
```swift
import Foundation

struct FormattedDocumentContent: Codable, Equatable, Sendable {
    let id: UUID
    let title: String?
    let content: String?
    let createdAt: Date
    let updatedAt: Date
}

extension DocsAPIClient {
    func formattedContent(documentID: UUID, format: String = "markdown") async throws -> FormattedDocumentContent {
        let path = "documents/\(documentID.uuidString.lowercased())/formatted-content/?content_format=\(format)"
        return try await get(path)
    }
}
```

In `DocsIOS/Core/Networking/Document.swift`, change:
```swift
struct DocumentAbilities: Codable, Equatable {
```
to:
```swift
struct DocumentAbilities: Codable, Equatable, Hashable {
```
and change:
```swift
struct Document: Codable, Equatable, Identifiable {
```
to:
```swift
struct Document: Codable, Equatable, Hashable, Identifiable {
```
No other changes to `Document.swift` — both conformances synthesize automatically since every existing stored property on both types is already `Hashable`.

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/FormattedDocumentContentDecodingTests -only-testing:DocsIOSTests/FormattedDocumentContentClientTests`
Expected: PASS — `Executed 3 tests, with 0 failures` (2 decoding + 1 client). Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 166 tests, with 0 failures` (163 from the prior ten plans + 3 new). This full-suite run also proves the new `Hashable` conformances didn't break any existing `Document`/`DocumentAbilities` usage.

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Core/Networking/FormattedDocumentContent.swift DocsIOS/Core/Networking/Document.swift DocsIOSTests/Core/Networking/FormattedDocumentContentTests.swift
git commit -m "Add formatted-content endpoint and Document Hashable conformance"
```

---

### Task 2: MarkdownBlock parser

**Files:**
- Create: `DocsIOS/Features/Editor/MarkdownBlock.swift`
- Test: `DocsIOSTests/Features/Editor/MarkdownBlockTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `enum MarkdownBlock: Equatable`, `func parseMarkdownBlocks(_ markdown: String) -> [MarkdownBlock]` — consumed by Task 3's `EditorViewModel` and Task 4's `MarkdownBlockView`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Editor/MarkdownBlockTests.swift`:
```swift
import XCTest
@testable import DocsIOS

final class MarkdownBlockTests: XCTestCase {
    func testParsesParagraph() {
        XCTAssertEqual(parseMarkdownBlocks("Hello world"), [.paragraph(text: "Hello world")])
    }

    func testParsesHeadingLevels() {
        XCTAssertEqual(parseMarkdownBlocks("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(parseMarkdownBlocks("## Subtitle"), [.heading(level: 2, text: "Subtitle")])
        XCTAssertEqual(parseMarkdownBlocks("###### Deep"), [.heading(level: 6, text: "Deep")])
    }

    func testHeadingRequiresSpaceAfterHashes() {
        XCTAssertEqual(parseMarkdownBlocks("#NoSpace"), [.paragraph(text: "#NoSpace")])
    }

    func testParsesBulletItemsWithDashOrAsterisk() {
        XCTAssertEqual(parseMarkdownBlocks("- Item one"), [.bulletItem(text: "Item one")])
        XCTAssertEqual(parseMarkdownBlocks("* Item two"), [.bulletItem(text: "Item two")])
    }

    func testParsesUncheckedChecklistItem() {
        XCTAssertEqual(parseMarkdownBlocks("- [ ] Task"), [.checklistItem(checked: false, text: "Task")])
    }

    func testParsesCheckedChecklistItemLowercaseAndUppercase() {
        XCTAssertEqual(parseMarkdownBlocks("- [x] Done"), [.checklistItem(checked: true, text: "Done")])
        XCTAssertEqual(parseMarkdownBlocks("- [X] Done"), [.checklistItem(checked: true, text: "Done")])
    }

    func testChecklistIsDistinguishedFromPlainBullet() {
        let blocks = parseMarkdownBlocks("- [ ] Task\n- Not a checklist item")
        XCTAssertEqual(blocks, [.checklistItem(checked: false, text: "Task"), .bulletItem(text: "Not a checklist item")])
    }

    func testParsesQuote() {
        XCTAssertEqual(parseMarkdownBlocks("> Quoted text"), [.quote(text: "Quoted text")])
    }

    func testParsesMultipleBlocksInOrder() {
        let markdown = """
        # Heading

        A paragraph.

        - Bullet one
        - [ ] Checklist item
        > A quote
        """
        XCTAssertEqual(parseMarkdownBlocks(markdown), [
            .heading(level: 1, text: "Heading"),
            .paragraph(text: "A paragraph."),
            .bulletItem(text: "Bullet one"),
            .checklistItem(checked: false, text: "Checklist item"),
            .quote(text: "A quote"),
        ])
    }

    func testEmptyLinesAreSkipped() {
        XCTAssertEqual(parseMarkdownBlocks("\n\nHello\n\n\nWorld\n"), [.paragraph(text: "Hello"), .paragraph(text: "World")])
    }

    func testEmptyStringProducesNoBlocks() {
        XCTAssertEqual(parseMarkdownBlocks(""), [])
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/MarkdownBlockTests`
Expected: FAIL — `cannot find 'parseMarkdownBlocks' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Editor/MarkdownBlock.swift`:
```swift
import Foundation

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletItem(text: String)
    case checklistItem(checked: Bool, text: String)
    case quote(text: String)
}

func parseMarkdownBlocks(_ markdown: String) -> [MarkdownBlock] {
    markdown
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map(parseMarkdownLine)
}

private func parseMarkdownLine(_ line: String) -> MarkdownBlock {
    if let heading = parseHeading(line) {
        return heading
    }
    if let checklistItem = parseChecklistItem(line) {
        return checklistItem
    }
    if let bullet = parseBulletItem(line) {
        return bullet
    }
    if let quote = parseQuote(line) {
        return quote
    }
    return .paragraph(text: line)
}

private func parseHeading(_ line: String) -> MarkdownBlock? {
    var level = 0
    var index = line.startIndex
    while index < line.endIndex, line[index] == "#", level < 6 {
        level += 1
        index = line.index(after: index)
    }
    guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
    let text = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
    return .heading(level: level, text: text)
}

private func parseChecklistItem(_ line: String) -> MarkdownBlock? {
    for prefix in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "] {
        if line.hasPrefix(prefix) {
            let checked = prefix.contains("x") || prefix.contains("X")
            let text = String(line.dropFirst(prefix.count))
            return .checklistItem(checked: checked, text: text)
        }
    }
    return nil
}

private func parseBulletItem(_ line: String) -> MarkdownBlock? {
    for prefix in ["- ", "* "] {
        if line.hasPrefix(prefix) {
            return .bulletItem(text: String(line.dropFirst(prefix.count)))
        }
    }
    return nil
}

private func parseQuote(_ line: String) -> MarkdownBlock? {
    guard line.hasPrefix(">") else { return nil }
    let rest = line.dropFirst()
    return .quote(text: rest.trimmingCharacters(in: .whitespaces))
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/MarkdownBlockTests`
Expected: PASS — `Executed 11 tests, with 0 failures`. Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 177 tests, with 0 failures` (166 from Task 1 + 11 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Editor/MarkdownBlock.swift DocsIOSTests/Features/Editor/MarkdownBlockTests.swift
git commit -m "Add MarkdownBlock parser"
```

---

### Task 3: EditorViewModel

**Files:**
- Create: `DocsIOS/Features/Editor/EditorViewModel.swift`
- Test: `DocsIOSTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Consumes: `DocsAPIClient.formattedContent` (Task 1), `parseMarkdownBlocks` (Task 2).
- Produces: `@MainActor @Observable final class EditorViewModel` (`init(client:documentID:title:)`, `title: String`, `blocks: [MarkdownBlock]`, `isLoading: Bool`, `errorMessage: String?`, `func load() async`) — consumed by Task 4's `EditorView`.

- [ ] **Step 1: Write the failing tests**

`DocsIOSTests/Features/Editor/EditorViewModelTests.swift`:
```swift
import XCTest
@testable import DocsIOS

@MainActor
final class EditorViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel(title: String = "Untitled document") -> EditorViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return EditorViewModel(client: client, documentID: documentID, title: title)
    }

    func testLoadParsesMarkdownContentIntoBlocks() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Q3 Planning", "content": "# Heading\\n\\nA paragraph.", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.blocks, [.heading(level: 1, text: "Heading"), .paragraph(text: "A paragraph.")])
        XCTAssertEqual(viewModel.title, "Q3 Planning")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadWithNullContentProducesNoBlocks() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": null, "content": null, "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertTrue(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadKeepsOriginalTitleWhenServerTitleIsNull() async {
        let viewModel = makeViewModel(title: "Original Title")
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": null, "content": "Text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.title, "Original Title")
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.blocks.isEmpty)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/EditorViewModelTests`
Expected: FAIL — `cannot find 'EditorViewModel' in scope`

- [ ] **Step 3: Write the minimal implementation**

`DocsIOS/Features/Editor/EditorViewModel.swift`:
```swift
import Foundation

@MainActor
@Observable
final class EditorViewModel {
    var title: String
    var blocks: [MarkdownBlock] = []
    var isLoading = false
    var errorMessage: String?

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID, title: String) {
        self.client = client
        self.documentID = documentID
        self.title = title
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            if let fetchedTitle = formatted.title {
                title = fetchedTitle
            }
            blocks = parseMarkdownBlocks(formatted.content ?? "")
        } catch {
            errorMessage = "Couldn't load this document. Pull to refresh to try again."
        }
        isLoading = false
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DocsIOSTests/EditorViewModelTests`
Expected: PASS — `Executed 4 tests, with 0 failures`. Also run the full suite before committing: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'` — expect `Executed 181 tests, with 0 failures` (177 from Task 2 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add DocsIOS/Features/Editor/EditorViewModel.swift DocsIOSTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Add EditorViewModel"
```

---

### Task 4: MarkdownBlockView, EditorView, and Home navigation wiring

**Files:**
- Create: `DocsIOS/Features/Editor/MarkdownBlockView.swift`
- Create: `DocsIOS/Features/Editor/EditorView.swift`
- Modify: `DocsIOS/Features/Home/HomeViewModel.swift`
- Modify: `DocsIOS/Features/Home/HomeView.swift`

**Interfaces:**
- Consumes: `MarkdownBlock` (Task 2), `EditorViewModel` (Task 3), `NavBar`, `LinkReachPill` (DesignSystem), `HomeViewModel`, `Document` (Home Screen plan / Networking Foundation plan).
- Produces: `func markdownInlineText(_:) -> AttributedString`, `func markdownHeadingFont(level:) -> Font`, `struct MarkdownBlockView: View`, `struct EditorView: View` — `HomeView` is modified to wrap its content in a `NavigationStack` and push `EditorView` when a `DocRow` is tapped.

This task has no new XCTest files — see the Connect Screen and Home Screen plans' precedent and this plan's Global Constraints for why (UI glue verified by build-check and Simulator screenshots, not XCTest).

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Editor/MarkdownBlockView.swift`:
```swift
import SwiftUI

func markdownInlineText(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
}

func markdownHeadingFont(level: Int) -> Font {
    switch level {
    case 1: return DocsFont.title1
    case 2: return DocsFont.title2
    default: return DocsFont.headline
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(markdownInlineText(text))
                .font(markdownHeadingFont(level: level))
                .foregroundStyle(DocsColor.textPrimary)

        case .paragraph(let text):
            Text(markdownInlineText(text))
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)

        case .bulletItem(let text):
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Text("•")
                Text(markdownInlineText(text))
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textPrimary)

        case .checklistItem(let checked, let text):
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? DocsColor.brandFill : DocsColor.textTertiary)
                Text(markdownInlineText(text))
                    .strikethrough(checked)
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textPrimary)

        case .quote(let text):
            HStack(spacing: DocsSpacing.spaceXS) {
                Rectangle()
                    .fill(DocsColor.borderDefault)
                    .frame(width: 3)
                Text(markdownInlineText(text))
                    .italic()
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textSecondary)
        }
    }
}
```

`DocsIOS/Features/Editor/EditorView.swift`:
```swift
import SwiftUI

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    var onBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: viewModel.title,
                backTitle: "Docs",
                onBack: onBack,
                trailingActions: [
                    NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {}),
                    NavBarAction(systemImage: "ellipsis", label: "Options", action: {}),
                ]
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

            ScrollView {
                if viewModel.isLoading {
                    ProgressView()
                        .padding(DocsSpacing.spaceBase)
                } else {
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

In `DocsIOS/Features/Home/HomeViewModel.swift`, change:
```swift
    private let client: DocsAPIClient
```
to:
```swift
    let client: DocsAPIClient
```

`DocsIOS/Features/Home/HomeView.swift` — replace entirely with:
```swift
import SwiftUI

func documentRowDate(_ document: Document) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: document.updatedAt, relativeTo: Date())
}

struct HomeView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String

    @State private var selectedTab = "docs"
    @State private var documentPendingFavoriteChoice: Document?
    @State private var path: [Document] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavBar(title: "Docs", subtitle: serverHost, largeTitle: true)

                VStack(spacing: DocsSpacing.spaceSM) {
                    SearchField(text: $viewModel.searchQuery, placeholder: "Search documents")

                    SegmentedControl(
                        segments: HomeFilter.allCases.map(\.title),
                        selectedIndex: Binding(
                            get: { viewModel.selectedFilter.rawValue },
                            set: { newValue in
                                let filter = HomeFilter(rawValue: newValue) ?? .all
                                Task { await viewModel.selectFilter(filter) }
                            }
                        )
                    )
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.vertical, DocsSpacing.spaceSM)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .padding(.horizontal, DocsSpacing.gutter)
                }

                ScrollView {
                    if viewModel.isLoading {
                        ProgressView()
                            .padding(DocsSpacing.spaceBase)
                    } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        documentSection(title: "Search Results", documents: viewModel.searchResults)
                    } else {
                        if viewModel.showsPinnedSection {
                            documentSection(title: "Pinned", documents: viewModel.pinnedDocuments)
                        }
                        documentSection(title: "Recent", documents: viewModel.recentDocuments)
                    }
                }

                TabBar(items: [
                    TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                    TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                    TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                    TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
                ], selection: $selectedTab)
            }
            .background(DocsColor.surfacePage)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await viewModel.load()
            }
            .onChange(of: viewModel.searchQuery) {
                Task { await viewModel.search() }
            }
            .confirmationDialog(
                "Document Options",
                isPresented: Binding(
                    get: { documentPendingFavoriteChoice != nil },
                    set: { if !$0 { documentPendingFavoriteChoice = nil } }
                ),
                presenting: documentPendingFavoriteChoice
            ) { document in
                Button(document.isFavorite ? "Unpin" : "Pin") {
                    Task { await viewModel.toggleFavorite(document) }
                }
            }
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
        }
    }

    @ViewBuilder
    private func documentSection(title: String, documents: [Document]) -> some View {
        if !documents.isEmpty {
            ListSection(header: title) {
                VStack(spacing: 0) {
                    ForEach(documents) { document in
                        DocRow(
                            emoji: nil,
                            title: document.title ?? "Untitled document",
                            pinned: document.isFavorite,
                            reach: document.linkReach,
                            date: documentRowDate(document),
                            onOpen: { path.append(document) },
                            onMore: { documentPendingFavoriteChoice = document }
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)), serverHost: "docs.llun.dev")
}
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 181 tests, with 0 failures` (no new tests in this task; confirms Task 4's changes didn't regress anything).

- [ ] **Step 3: Visually verify in the Simulator**

Verify three things, each by temporarily pointing `RootView.body` at the relevant view directly (matching this plan's own validation — see Architecture), screenshotting, then reverting `RootView.swift` back to the real auth-gated version from the Home Screen plan **before committing**:

1. `HomeView` still renders correctly with the new `NavigationStack` wrapper (no visual regression from the Home Screen plan's screenshot).
2. `EditorView` on its own (e.g. `EditorView(viewModel: EditorViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!), documentID: UUID(), title: "Q3 Planning"), reach: .authenticated, onBack: {})`) — expect the NavBar back button/title/Share/Options icons, the large title + `LinkReachPill`, and (since there's no real backend to reach) the red "Couldn't load this document. Pull to refresh to try again." error text, not a blank screen.
3. `MarkdownBlockView` rendering real sample content directly (e.g. a `ScrollView` of `parseMarkdownBlocks(...)` over a string containing a heading, a paragraph with `**bold**`/`*italic*`/`` `code` ``, a bullet, an unchecked and a checked checklist item, and a quote) — expect each block type to render distinctly (heading larger/bold, checked checklist item shows a filled checkbox with strikethrough text, quote shows an indent bar and italic text).

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'
APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/DocsIOS-*/Build/Products/Debug-iphonesimulator/DocsIOS.app | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted dev.llun.DocsIOS
xcrun simctl io booted screenshot /tmp/editor-screen-verify.png
```

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Editor/MarkdownBlockView.swift DocsIOS/Features/Editor/EditorView.swift DocsIOS/Features/Home/HomeViewModel.swift DocsIOS/Features/Home/HomeView.swift
git commit -m "Add EditorView and MarkdownBlockView, wire HomeView navigation to Editor screen"
```

## Self-Review Notes

- **Spec coverage:** Implements the design spec's Phase 6 ("Editor screen — read-only rendering of formatted-content") and the Editor screen's chrome description (NavBar with back, emoji + title + LinkReachPill, Share + Options IconButtons — the last two as placeholders, per Global Constraints). Deliberately excludes editing/save (Phase 7), Share/Options sheet content (Phase 8), and AvatarGroup-backed collaborators (needs the not-yet-built accesses endpoint).
- **Real-backend cross-check:** The `formatted-content` response shape was read directly from `viewsets.py`'s `formatted_content` action, not assumed — this confirmed it is a distinct, smaller shape than the full `Document` model (no `abilities`, `link_reach`, etc.), which is why `FormattedDocumentContent` is its own type rather than reusing `Document`.
- **Placeholder scan:** No TBD/TODO. Share/Options buttons and `AvatarGroup` omission are documented, intentional deferrals, not forgotten work.
- **Type consistency:** `FormattedDocumentContent`, `MarkdownBlock`, `parseMarkdownBlocks`, `EditorViewModel`, `markdownInlineText`, `markdownHeadingFont`, `MarkdownBlockView`, `EditorView` are each defined once. `EditorViewModel` correctly reuses `DocsAPIClient`/`parseMarkdownBlocks` rather than reimplementing fetching or parsing.
- **Cross-file validation:** All code in this plan (all four tasks, including the `Document`/`DocumentAbilities` `Hashable` additions, the checklist-before-bullet parsing order, the `@MainActor` requirement on `EditorViewModel`, and the `NavigationStack` + hidden-system-nav-bar + custom-`NavBar` pattern) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 181 tests, with 0 failures` plus three passing Simulator screenshots (Home screen regression check, Editor screen chrome + error state, and all five Markdown block types rendered with real sample content).
