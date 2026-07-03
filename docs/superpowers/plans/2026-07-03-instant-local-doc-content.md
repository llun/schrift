# Instant Local Document Content + Background Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A previously-opened document renders instantly from an on-disk cache with zero loading UI, revalidates against the server in the background, shows a live "Synced X ago" caption, surfaces newer server copies via a tappable "Updated" banner, and becomes readable offline.

**Architecture:** A new file-based `DocumentContentCacheStore` (one JSON per doc under Application Support, mtime-driven LRU eviction) is read synchronously by `EditorViewModel.load()` before any network call; the fetch becomes an awaited revalidation tail that classifies its outcome at completion time. `DocumentSaveCoordinator` write-throughs the cache on save success. `EditorView` gains the sync caption, banner pill, and corrected offline chrome.

**Tech Stack:** Swift 6, SwiftUI, iOS 18, XCTest, XcodeGen. Zero third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-07-03-instant-local-doc-content-design.md` (rev 2). Read it before starting; it is the authority on behavior.

## Global Constraints

- Swift 6, minimum deployment iOS 18.0. No new SPM/CocoaPods/Carthage packages.
- XCTest only — never `import Testing` / `@Test` / `#expect`. No `XCTestExpectation`, no arbitrary sleeps; poll with the shared `waitUntil {}` helper (`SchriftTests/Support/AsyncTestHelpers.swift:36`).
- The Xcode project is generated: after **adding any new file**, run `xcodegen generate` before building. Never edit or commit `Schrift.xcodeproj`.
- Full test command (used in every task; `-only-testing` narrows it):
  ```sh
  xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift \
    -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/<TestClass>
  ```
- Never log, print, or interpolate cached document content/titles into errors or debug output.
- User-facing copy is exact: `"Reading the copy saved on this device"`, `"This document is no longer available."`, `"Couldn't refresh. Please try again."`, `"Document updated · tap to refresh"`, `"Synced just now"`, `"Not synced yet"`, and the existing `"Couldn't load this document. Pull to refresh to try again."` stays.
- UserDefaults keys use `dev.llun.Schrift.*`; the cache directory is `dev.llun.Schrift/ContentCache` under Application Support.
- Views use design tokens only (`DocsColor`/`DocsFont`/`DocsSpacing`); no raw hex/color literals.
- Commit after every task. The final task also updates docs (CLAUDE.md doc-sync rule).

---

### Task 1: Pure eviction-selection function

**Files:**
- Create: `Schrift/Features/Editor/DocumentContentCacheStore.swift`
- Create: `SchriftTests/Features/Editor/DocumentContentCacheStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct ContentCacheIndexEntry: Equatable { let id: UUID; let syncedAt: Date }` and top-level `func contentCacheEvictions(index: [ContentCacheIndexEntry], limit: Int) -> [UUID]`. Task 2 adds the store to this same file and calls this function.

- [ ] **Step 1: Write the failing tests**

Create `SchriftTests/Features/Editor/DocumentContentCacheStoreTests.swift`:

```swift
import XCTest
@testable import Schrift

final class DocumentContentCacheStoreTests: XCTestCase {
    // MARK: - contentCacheEvictions (pure, filesystem-free)

    private func entry(_ n: Int, minutesAgo: Int) -> ContentCacheIndexEntry {
        ContentCacheIndexEntry(
            id: UUID(uuidString: String(format: "%08d-0000-0000-0000-000000000000", n))!,
            syncedAt: Date(timeIntervalSince1970: 1_000_000 - TimeInterval(minutesAgo * 60))
        )
    }

    func testEvictionsAtOrUnderLimitReturnsEmpty() {
        XCTAssertEqual(contentCacheEvictions(index: [], limit: 2), [])
        XCTAssertEqual(contentCacheEvictions(index: [entry(1, minutesAgo: 0)], limit: 2), [])
        XCTAssertEqual(
            contentCacheEvictions(index: [entry(1, minutesAgo: 0), entry(2, minutesAgo: 5)], limit: 2),
            []
        )
    }

    func testEvictionsReturnsOldestBeyondLimit() {
        let index = [entry(1, minutesAgo: 10), entry(2, minutesAgo: 0), entry(3, minutesAgo: 20), entry(4, minutesAgo: 5)]
        // Keep the 2 newest (2, 4); evict 1 and 3.
        XCTAssertEqual(Set(contentCacheEvictions(index: index, limit: 2)), Set([entry(1, minutesAgo: 0).id, entry(3, minutesAgo: 0).id]))
    }

    func testEvictionsKeepsNewestNBySyncedAt() {
        let index = [entry(1, minutesAgo: 3), entry(2, minutesAgo: 2), entry(3, minutesAgo: 1)]
        XCTAssertEqual(contentCacheEvictions(index: index, limit: 1), [entry(2, minutesAgo: 0).id, entry(1, minutesAgo: 0).id])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/DocumentContentCacheStoreTests`
Expected: BUILD FAILS — `cannot find 'ContentCacheIndexEntry' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Schrift/Features/Editor/DocumentContentCacheStore.swift`:

```swift
import Foundation

/// One row of the content-cache eviction index. Kept `Equatable` so the
/// selection logic below is a top-level pure function testable without the
/// filesystem (mirroring `addingRecentServer`/`addingRecentSearch`).
struct ContentCacheIndexEntry: Equatable {
    let id: UUID
    let syncedAt: Date
}

/// IDs to evict so that only the `limit` most-recently-synced entries remain,
/// ordered most-recently-evictable first (i.e. newest of the evicted first).
func contentCacheEvictions(index: [ContentCacheIndexEntry], limit: Int) -> [UUID] {
    guard index.count > limit else { return [] }
    return index
        .sorted { $0.syncedAt > $1.syncedAt }
        .dropFirst(limit)
        .map(\.id)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command. Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/DocumentContentCacheStore.swift SchriftTests/Features/Editor/DocumentContentCacheStoreTests.swift
git commit -m "Add pure eviction selection for the content cache"
```

---

### Task 2: `DocumentContentCacheStore` (file-based CRUD + eviction)

**Files:**
- Modify: `Schrift/Features/Editor/DocumentContentCacheStore.swift`
- Modify: `SchriftTests/Features/Editor/DocumentContentCacheStoreTests.swift`

**Interfaces:**
- Consumes: `contentCacheEvictions` / `ContentCacheIndexEntry` (Task 1).
- Produces (used by Tasks 4, 6–10, 13):
  ```swift
  struct CachedDocumentContent: Codable, Equatable, Sendable {
      let documentID: UUID
      let title: String?
      let markdown: String
      let syncedAt: Date
  }
  final class DocumentContentCacheStore {
      init(directory: URL? = nil, fileManager: FileManager = .default, limit: Int = 50)
      func content(for documentID: UUID) -> CachedDocumentContent?
      func save(_ entry: CachedDocumentContent)
      func remove(documentID: UUID)
      func removeAll()
  }
  ```
  There is deliberately **no server-timestamp field** (see spec §1). The store is stateless (index derived from disk per call), non-`Sendable`, `@MainActor`-caller-only.

- [ ] **Step 1: Write the failing tests**

Append to `DocumentContentCacheStoreTests` (and add the setUp/tearDown + helpers):

```swift
    private var directory: URL!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentContentCacheStoreTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeStore(limit: Int = 50) -> DocumentContentCacheStore {
        DocumentContentCacheStore(directory: directory, limit: limit)
    }

    private func makeEntry(id: UUID? = nil, markdown: String = "# Hello") -> CachedDocumentContent {
        CachedDocumentContent(
            documentID: id ?? documentID,
            title: "Doc",
            markdown: markdown,
            syncedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    // MARK: - CRUD

    func testSaveThenContentRoundTrips() {
        let store = makeStore()
        let entry = makeEntry()
        store.save(entry)
        XCTAssertEqual(store.content(for: documentID), entry)
    }

    func testContentForUnknownDocumentReturnsNil() {
        XCTAssertNil(makeStore().content(for: documentID))
    }

    func testCorruptFileReturnsNil() {
        let store = makeStore()
        store.save(makeEntry())
        let file = directory.appendingPathComponent("\(documentID.uuidString.lowercased()).json")
        try? Data("not json".utf8).write(to: file)
        XCTAssertNil(store.content(for: documentID))
    }

    func testRemoveDeletesEntry() {
        let store = makeStore()
        store.save(makeEntry())
        store.remove(documentID: documentID)
        XCTAssertNil(store.content(for: documentID))
    }

    func testRemoveAllDeletesEveryEntry() {
        let store = makeStore()
        let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        store.save(makeEntry())
        store.save(makeEntry(id: other))
        store.removeAll()
        XCTAssertNil(store.content(for: documentID))
        XCTAssertNil(store.content(for: other))
    }

    func testIndependentInstancesShareTheDirectory() {
        // The store is stateless: a second instance over the same directory
        // sees the first instance's writes (spec §1 "Stateless").
        makeStore().save(makeEntry())
        XCTAssertEqual(makeStore().content(for: documentID), makeEntry())
    }

    // MARK: - Eviction

    func testSaveEvictsOldestBeyondLimit() throws {
        let store = makeStore(limit: 2)
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let c = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        store.save(makeEntry(id: a))
        store.save(makeEntry(id: b))
        // Force distinct, deterministic mtimes (mtime IS the eviction index).
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                             ofItemAtPath: directory.appendingPathComponent("\(a.uuidString.lowercased()).json").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                             ofItemAtPath: directory.appendingPathComponent("\(b.uuidString.lowercased()).json").path)
        store.save(makeEntry(id: c))   // triggers eviction; c has mtime "now"
        XCTAssertNil(store.content(for: a), "oldest entry is evicted")
        XCTAssertNotNil(store.content(for: b))
        XCTAssertNotNil(store.content(for: c))
    }

    // MARK: - Backup exclusion

    func testCacheDirectoryIsExcludedFromBackup() throws {
        makeStore().save(makeEntry())
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/DocumentContentCacheStoreTests`
Expected: BUILD FAILS — `cannot find 'CachedDocumentContent' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Schrift/Features/Editor/DocumentContentCacheStore.swift`:

```swift
/// A previously-synced copy of a document's content. `syncedAt` is the
/// wall-clock of the successful fetch/save that produced it. There is
/// deliberately no server-timestamp field: nothing in the design reads one,
/// and the save endpoints return none — a stored server-clock value would go
/// stale or get backfilled from the client clock, the exact clock-mixing
/// hazard `pendingDraftClockTolerance` exists to avoid.
struct CachedDocumentContent: Codable, Equatable, Sendable {
    let documentID: UUID
    let title: String?
    let markdown: String
    let syncedAt: Date
}

/// On-disk cache of document content: one JSON file per document under
/// Application Support (durable — "keep local" means it survives; Caches
/// would be OS-reclaimable). Stateless: the eviction index is derived from
/// disk on every call, so independently constructed instances over the same
/// directory stay consistent. Like the other stores it never throws and is
/// confined to `@MainActor` callers. Entries hold full user document text —
/// never log or print their contents.
final class DocumentContentCacheStore {
    private let directory: URL
    private let fileManager: FileManager
    private let limit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil, fileManager: FileManager = .default, limit: Int = 50) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.llun.Schrift/ContentCache", isDirectory: true)
        self.limit = limit
        // Millisecond precision, matching PendingDraftStore: plain .iso8601
        // truncates to whole seconds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func content(for documentID: UUID) -> CachedDocumentContent? {
        guard let data = try? Data(contentsOf: fileURL(for: documentID)) else { return nil }
        return try? decoder.decode(CachedDocumentContent.self, from: data)
    }

    func save(_ entry: CachedDocumentContent) {
        guard let data = try? encoder.encode(entry) else { return }
        ensureDirectory()
        try? data.write(to: fileURL(for: entry.documentID), options: .atomic)
        evictBeyondLimit()
    }

    func remove(documentID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: documentID))
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Private

    private func fileURL(for documentID: UUID) -> URL {
        directory.appendingPathComponent("\(documentID.uuidString.lowercased()).json")
    }

    private func ensureDirectory() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Cached content is re-downloadable from the user's own server; full
        // document bodies must not flow into iCloud/device backups. Unsaved
        // work still backs up via PendingDraftStore.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The eviction index comes from file modification dates: every path that
    /// bumps an entry's `syncedAt` rewrites its file at that same moment, so
    /// mtime tracks `syncedAt` and building the index never reads or decodes
    /// file contents.
    private func evictBeyondLimit() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let index = urls.compactMap { url -> ContentCacheIndexEntry? in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ContentCacheIndexEntry(id: id, syncedAt: date)
        }
        for id in contentCacheEvictions(index: index, limit: limit) {
            remove(documentID: id)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command. Expected: all `DocumentContentCacheStoreTests` PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/DocumentContentCacheStore.swift SchriftTests/Features/Editor/DocumentContentCacheStoreTests.swift
git commit -m "Add file-based DocumentContentCacheStore with mtime LRU eviction"
```

---

### Task 3: Pure `syncStatusCaption` formatter

**Files:**
- Modify: `Schrift/Features/Editor/EditorView.swift` (top-level function above the view, like `documentRowDate` in `HomeView.swift:3`)
- Create: `SchriftTests/Features/Editor/EditorViewTests.swift`

**Interfaces:**
- Produces: `func syncStatusCaption(lastSyncedAt: Date, now: Date) -> String` (used by Task 12's header caption).

- [ ] **Step 1: Write the failing tests**

Create `SchriftTests/Features/Editor/EditorViewTests.swift`:

```swift
import XCTest
@testable import Schrift

final class EditorViewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testUnderAMinuteIsSyncedJustNow() {
        XCTAssertEqual(syncStatusCaption(lastSyncedAt: base, now: base), "Synced just now")
        XCTAssertEqual(syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(59)), "Synced just now")
    }

    func testOlderThanAMinuteUsesRelativeWording() {
        let caption = syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(5 * 60))
        // RelativeDateTimeFormatter output is locale-dependent; pin the shape,
        // not the exact words.
        XCTAssertTrue(caption.hasPrefix("Synced "))
        XCTAssertNotEqual(caption, "Synced just now")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/EditorViewTests`
Expected: BUILD FAILS — `cannot find 'syncStatusCaption' in scope`.

- [ ] **Step 3: Write the implementation**

At the top of `Schrift/Features/Editor/EditorView.swift`, after `import SwiftUI`, add:

```swift
/// "Synced X ago" caption for the editor header. Pure — `now` is a parameter
/// (note `documentRowDate` reads `Date()` internally and is untestable; this
/// one is driven by a `TimelineView` tick so it must not).
func syncStatusCaption(lastSyncedAt: Date, now: Date) -> String {
    if now.timeIntervalSince(lastSyncedAt) < 60 {
        return "Synced just now"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return "Synced \(formatter.localizedString(for: lastSyncedAt, relativeTo: now))"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command. Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/EditorView.swift SchriftTests/Features/Editor/EditorViewTests.swift
git commit -m "Add pure syncStatusCaption formatter"
```

---

### Task 4: Coordinator write-through + draft-discard APIs

**Files:**
- Modify: `Schrift/Features/Editor/DocumentSaveCoordinator.swift`
- Modify: `SchriftTests/Features/Editor/DocumentSaveCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DocumentContentCacheStore`, `CachedDocumentContent` (Task 2).
- Produces (used by Tasks 8, 10):
  ```swift
  // DocumentSaveCoordinator additions
  init(client:, draftStore: PendingDraftStore = PendingDraftStore(),
       contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
       backgroundTasks: BackgroundTaskProvider = .uiApplication)
  func discardStoredDraft(_ draft: PendingDraft)      // removes only if still identical
  func discardPendingWork(documentID: UUID)           // drops queued slot + stored draft
  ```
  On save **success**, the coordinator writes `CachedDocumentContent(documentID:, title: save.title, markdown: save.markdown, syncedAt: Date())` to the cache. Never on failure. (Void PATCHes return no server timestamp — the entry has no such field.)

- [ ] **Step 1: Write the failing tests**

`DocumentSaveCoordinatorTests` already has `makeCoordinator(...)`, `stubSavePipeline(log:)`, `isSaved(_:)`, and `documentID` helpers. Add a per-test cache directory:

```swift
    private var cacheDirectory: URL!

    // in setUp():
    cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DocumentSaveCoordinatorTests.\(UUID().uuidString)", isDirectory: true)

    // in tearDown():
    try? FileManager.default.removeItem(at: cacheDirectory)
    cacheDirectory = nil
```

Then change `makeCoordinator` to build the cache store and return it (keep the helper's existing parameters — e.g. `backgroundTasks:` — exactly as they are; only the store construction and the tuple change). The body becomes:

```swift
    let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
    let coordinator = DocumentSaveCoordinator(
        client: client,
        draftStore: draftStore,
        contentCache: contentCache,
        backgroundTasks: backgroundTasks
    )
    return (coordinator, draftStore, contentCache)
```

Update every existing call site in the file from the 2-tuple to the 3-tuple (add `, _` or the new name). Then add:

```swift
    func testSaveSuccessWritesContentCacheEntry() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        let entry = contentCache.content(for: documentID)
        XCTAssertEqual(entry?.title, "Doc")
        XCTAssertEqual(entry?.markdown, "# Content")
        XCTAssertNotNil(entry?.syncedAt)
    }

    func testSaveFailureWritesNoContentCacheEntry() async {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertNil(contentCache.content(for: documentID))
    }

    func testDiscardStoredDraftRemovesOnlyIfUnchanged() {
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: .noop)
        let original = PendingDraft(documentID: documentID, title: "A", markdown: "a", updatedAt: Date(timeIntervalSince1970: 100))
        draftStore.save(original)

        // Draft changed since the caller captured it: keep the newer one.
        let newer = PendingDraft(documentID: documentID, title: "B", markdown: "b", updatedAt: Date(timeIntervalSince1970: 200))
        draftStore.save(newer)
        coordinator.discardStoredDraft(original)
        XCTAssertEqual(draftStore.draft(for: documentID), newer)

        // Unchanged: removed.
        coordinator.discardStoredDraft(newer)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testDiscardPendingWorkDropsDraft() {
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: .noop)
        draftStore.save(PendingDraft(documentID: documentID, title: "A", markdown: "a", updatedAt: Date()))
        coordinator.discardPendingWork(documentID: documentID)
        XCTAssertNil(draftStore.draft(for: documentID))
    }
```

(Adjust `makeCoordinator`'s tuple to `(coordinator, draftStore, contentCache)` and update existing call sites in the file — they destructure a 2-tuple today.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/DocumentSaveCoordinatorTests`
Expected: BUILD FAILS — no `contentCache:` init parameter / `discardStoredDraft` undefined.

- [ ] **Step 3: Write the implementation**

In `DocumentSaveCoordinator.swift`:

1. Add the stored property and init parameter (after `draftStore`):

```swift
    private let draftStore: PendingDraftStore
    private let contentCache: DocumentContentCacheStore
    private let backgroundTasks: BackgroundTaskProvider

    init(
        client: DocsAPIClient,
        draftStore: PendingDraftStore = PendingDraftStore(),
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        backgroundTasks: BackgroundTaskProvider = .uiApplication
    ) {
        self.client = client
        self.draftStore = draftStore
        self.contentCache = contentCache
        self.backgroundTasks = backgroundTasks
    }
```

2. In `finish(documentID:save:error:)`, extend the success branch (`error == nil`) — after the draft-removal `if`:

```swift
        if error == nil {
            states[documentID] = .saved(Date())
            if let draft = draftStore.draft(for: documentID),
               draft.title == save.title, draft.markdown == save.markdown {
                draftStore.remove(documentID: documentID)
            }
            // Keep the local copy consistent with what the server now holds.
            // The save PATCHes are void (no server timestamp exists here);
            // syncedAt is the client wall-clock of the confirmed save.
            contentCache.save(CachedDocumentContent(
                documentID: documentID,
                title: save.title,
                markdown: save.markdown,
                syncedAt: Date()
            ))
        } else {
```

3. Add the two public methods (after `recoverDrafts()`):

```swift
    /// Removes a stored draft only if it is still exactly the given draft —
    /// the user may have produced a newer one while the caller awaited
    /// (mirrors recoverDrafts' re-check).
    func discardStoredDraft(_ draft: PendingDraft) {
        guard draftStore.draft(for: draft.documentID) == draft else { return }
        draftStore.remove(documentID: draft.documentID)
    }

    /// Drops all queued/stored work for a document (delete flow). An already
    /// in-flight PATCH cannot be meaningfully cancelled; it fails harmlessly
    /// against the deleted document.
    func discardPendingWork(documentID: UUID) {
        queued[documentID] = nil
        draftStore.remove(documentID: documentID)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command. Expected: all `DocumentSaveCoordinatorTests` PASS (existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/DocumentSaveCoordinator.swift SchriftTests/Features/Editor/DocumentSaveCoordinatorTests.swift
git commit -m "Write content cache on save success; add draft-discard APIs"
```

---

### Task 5: Extract `install()` in `EditorViewModel` (behavior-preserving)

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift:99-136`

**Interfaces:**
- Produces: `private func install(markdown: String, title contentTitle: String?)` — the single content-installation routine. Tasks 6–9 extend it. No public API change; **no behavior change** (existing `EditorViewModelTests` must pass unmodified).

- [ ] **Step 1: Refactor `load()`**

Replace lines 99–136 of `EditorViewModel.swift` with:

```swift
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            if let fetchedTitle = formatted.title {
                title = fetchedTitle
            }
            var content = formatted.content ?? ""
            var contentTitle: String? = nil
            // Content still on its way to the server (or stranded from an
            // earlier session) is newer than what the server returned.
            if let pending = saveCoordinator.pendingSave(documentID: documentID) {
                content = pending.markdown
                contentTitle = pending.title
            } else if let draft = saveCoordinator.storedDraft(documentID: documentID),
                      formatted.updatedAt <= draft.updatedAt.addingTimeInterval(pendingDraftClockTolerance) {
                content = draft.markdown
                contentTitle = draft.title
            }
            install(markdown: content, title: contentTitle)
            updatedAt = formatted.updatedAt
            await loadChildren()
        } catch {
            errorMessage = "Couldn't load this document. Pull to refresh to try again."
        }
        isLoading = false
    }

    /// Installs content as the on-screen document. Every path that puts
    /// content on screen routes through here so the round-trip safety check
    /// and the dirty baseline are never bypassed — skipping them risks a
    /// destructive full-overwrite save of non-round-trippable content.
    private func install(markdown: String, title contentTitle: String?) {
        if let contentTitle {
            title = contentTitle
        }
        savedTitle = title
        rawMarkdown = markdown
        blocks = parseEditorBlocks(markdown)
        openInMarkdownMode = !markdown.isEmpty && !markdownSurvivesRoundTrip(markdown)
        // The dirty baseline uses the same representation currentMarkdown()
        // produces, so an unchanged document never triggers a save.
        savedMarkdown = openInMarkdownMode ? markdown : serializeMarkdown(blocks)
        hasLoadedContent = true
    }
```

- [ ] **Step 2: Run the existing editor tests — must pass unchanged**

Run: `xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/EditorViewModelTests`
Expected: PASS with zero test edits (pure refactor).

- [ ] **Step 3: Commit**

```bash
git add Schrift/Features/Editor/EditorViewModel.swift
git commit -m "Extract install() content-installation routine in EditorViewModel"
```

---

### Task 6: Instant local phase + stale-while-revalidate core

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift`
- Modify: `Schrift/Features/Editor/EditorScreen.swift`
- Modify: `SchriftTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Consumes: `DocumentContentCacheStore`/`CachedDocumentContent` (Task 2), `install()` (Task 5).
- Produces (used by Tasks 7–12):
  ```swift
  // EditorViewModel additions
  enum DisplaySource: Equatable { case none, pendingSave, draft, clean }
  private(set) var displaySource: DisplaySource   // internal for @testable asserts
  var lastSyncedAt: Date?
  var hasLocalCopy: Bool
  let contentCache: DocumentContentCacheStore     // new init param, default DocumentContentCacheStore()
  // install gains a syncedAt parameter:
  private func install(markdown: String, title contentTitle: String?, syncedAt: Date?)
  private func installFetched(_ formatted: FormattedDocumentContent)
  ```
  `load()` behavior after this task: local phase precedence (pendingSave → draft → cache → none), spinner only for `.none`; revalidation preserves **today's** replace semantics (pending kept; draft tolerance-checked; clean/none installs the fetched copy silently) and writes the cache on every successful fetch; transient failure with a local copy is swallowed. Banner/comparison arrive in Task 7.

- [ ] **Step 1: Write the failing tests**

Add a per-test cache directory to `EditorViewModelTests` (same pattern as Task 4: `cacheDirectory` created in `setUp`, removed in `tearDown`). Replace `makeEnvironment` with:

```swift
    private func makeEnvironment(
        title: String = "Untitled document",
        autosaveInterval: Duration = .seconds(10)
    ) -> (viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, draftStore: PendingDraftStore, contentCache: DocumentContentCacheStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            contentCache: contentCache,
            autosaveInterval: autosaveInterval
        )
        return (viewModel, coordinator, draftStore, contentCache)
    }
```

Update every existing destructuring call site in the file from the 3-tuple to the 4-tuple. Then add:

```swift
    private func cachedEntry(markdown: String = "# Cached", syncedAt: Date = Date(timeIntervalSince1970: 1_000_000)) -> CachedDocumentContent {
        CachedDocumentContent(documentID: documentID, title: "Cached Doc", markdown: markdown, syncedAt: syncedAt)
    }

    func testCachedDocumentRendersWithoutLoadingSpinner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        // Failing network keeps the outcome deterministic: only the local
        // phase can have produced the content, and isLoading never flips.
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let task = Task { await viewModel.load() }
        // The local phase is synchronous — content is visible after the first
        // suspension, before the fetch resolves.
        await waitUntil { !viewModel.blocks.isEmpty }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertTrue(viewModel.hasLocalCopy)
        XCTAssertEqual(viewModel.title, "Cached Doc")
        await task.value
    }

    func testCachedDocumentSetsLastSyncedAtFromEntry() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        let syncedAt = Date(timeIntervalSince1970: 999_000)
        contentCache.save(cachedEntry(syncedAt: syncedAt))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.lastSyncedAt, syncedAt)
    }

    func testOfflineWithCacheKeepsContentAndShowsNoError() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertFalse(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasLocalCopy)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testOfflineWithNoCacheShowsError() async {
        let (viewModel, _, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.errorMessage, "Couldn't load this document. Pull to refresh to try again.")
        XCTAssertFalse(viewModel.hasLocalCopy)
    }

    func testStoredDraftRendersOfflineWithoutCache() async {
        // Regression for the current gap: drafts were unreachable offline.
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft Doc", markdown: "# Draft", updatedAt: Date()))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.displaySource, .draft)
        XCTAssertEqual(viewModel.title, "Draft Doc")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFirstFetchWritesCacheSoNextOpenIsInstant() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        stubLoad(content: "# Fresh")

        await viewModel.load()

        let entry = contentCache.content(for: documentID)
        XCTAssertEqual(entry?.markdown, "# Fresh")
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertNotNil(viewModel.lastSyncedAt)
    }
```

Note: the existing `stubLoad` helper stubs the formatted-content GET; `load()` also calls `listChildren` — check how `stubLoad` handles the children URL today (existing tests pass with it) and keep that handling.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/EditorViewModelTests`
Expected: BUILD FAILS — no `displaySource` / `hasLocalCopy` / 4-tuple.

- [ ] **Step 3: Write the implementation**

In `EditorViewModel.swift`:

1. Add state and the `DisplaySource` enum (near the other enums / vars):

```swift
    enum DisplaySource: Equatable {
        case none, pendingSave, draft, clean
    }

    var lastSyncedAt: Date? = nil
    var hasLocalCopy = false
    private(set) var displaySource: DisplaySource = .none
```

2. Add the dependency (after `saveCoordinator`) and init parameter:

```swift
    let saveCoordinator: DocumentSaveCoordinator
    let contentCache: DocumentContentCacheStore
    let autosaveInterval: Duration

    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        autosaveInterval: Duration = .seconds(10)
    ) {
        self.client = client
        self.documentID = documentID
        self.title = title
        self.saveCoordinator = saveCoordinator
        self.contentCache = contentCache
        self.autosaveInterval = autosaveInterval
        self.savedTitle = title
    }
```

3. Replace `load()` and `install(...)` with the split flow:

```swift
    func load() async {
        errorMessage = nil
        // The local phase runs once per installed document: load() re-fires
        // on pop-back (.task) — reinstalling would clobber a dirty editing
        // session with the cached copy. After the first install, load() is
        // revalidate-only.
        if !hasLoadedContent {
            restoreLocalContent()
            if displaySource == .none {
                isLoading = true
            }
        }
        await revalidate()
        isLoading = false
    }

    /// Local phase: synchronous, no network, no spinner. Chooses the display
    /// source by precedence — in-flight save, stored draft, cached copy.
    private func restoreLocalContent() {
        if let pending = saveCoordinator.pendingSave(documentID: documentID) {
            install(markdown: pending.markdown, title: pending.title, syncedAt: nil)
            displaySource = .pendingSave
        } else if let draft = saveCoordinator.storedDraft(documentID: documentID) {
            // New: shown before any fetch (fixes drafts being unreachable
            // offline). The server-wins staleness rule runs at revalidation.
            install(markdown: draft.markdown, title: draft.title, syncedAt: nil)
            displaySource = .draft
        } else if let cached = contentCache.content(for: documentID) {
            install(markdown: cached.markdown, title: cached.title, syncedAt: cached.syncedAt)
            displaySource = .clean
        } else {
            displaySource = .none
        }
        hasLocalCopy = displaySource != .none
    }

    /// Revalidation: the awaited structured tail of load() — no unstructured
    /// Task. Classification of the outcome happens when the fetch completes.
    private func revalidate() async {
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            apply(formatted: formatted)
            await loadChildren()
        } catch {
            // With a local copy on screen a passive revalidation failure is
            // swallowed — the stale copy stays readable (offline reading).
            if displaySource == .none {
                errorMessage = "Couldn't load this document. Pull to refresh to try again."
            }
        }
    }

    private func apply(formatted: FormattedDocumentContent) {
        switch displaySource {
        case .pendingSave:
            break // in-flight content is newer than the server copy
        case .draft:
            if let draft = saveCoordinator.storedDraft(documentID: documentID),
               formatted.updatedAt <= draft.updatedAt.addingTimeInterval(pendingDraftClockTolerance) {
                break // draft trusted; keep it on screen
            }
            installFetched(formatted) // server wins (today's behavior)
        case .clean, .none:
            installFetched(formatted)
        }
        updatedAt = formatted.updatedAt
    }

    /// Installs the fetched server copy and records it in the content cache.
    private func installFetched(_ formatted: FormattedDocumentContent) {
        let now = Date()
        install(markdown: formatted.content ?? "", title: formatted.title, syncedAt: now)
        displaySource = .clean
        hasLocalCopy = true
        contentCache.save(CachedDocumentContent(
            documentID: documentID,
            title: title,
            markdown: formatted.content ?? "",
            syncedAt: now
        ))
    }

    private func install(markdown: String, title contentTitle: String?, syncedAt: Date?) {
        if let contentTitle {
            title = contentTitle
        }
        savedTitle = title
        rawMarkdown = markdown
        blocks = parseEditorBlocks(markdown)
        openInMarkdownMode = !markdown.isEmpty && !markdownSurvivesRoundTrip(markdown)
        savedMarkdown = openInMarkdownMode ? markdown : serializeMarkdown(blocks)
        hasLoadedContent = true
        if let syncedAt {
            lastSyncedAt = syncedAt
        }
    }
```

4. In `EditorScreen.swift`, add the pass-through parameter:

```swift
    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        reach: LinkReach,
        ...
    ) {
        _viewModel = State(initialValue: EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: saveCoordinator,
            contentCache: contentCache
        ))
        ...
    }
```

(Only the two shown lines change; keep the rest of the init verbatim.)

- [ ] **Step 4: Run the full editor test class**

Same command as Step 2. Expected: new tests PASS. Existing tests: `testLoadParsesMarkdownContentIntoBlocks` etc. still pass (fetch path unchanged for `.none`). If an existing draft-priority test asserted on intermediate state that changed (draft now visible *before* fetch), update only assertions that check ordering, never the final displayed content.

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/EditorViewModel.swift Schrift/Features/Editor/EditorScreen.swift SchriftTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Instant local content phase + revalidation tail in EditorViewModel"
```

---

### Task 7: Staleness comparison, "Updated" banner state, title reconciliation

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift`
- Modify: `SchriftTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Produces (used by Tasks 8, 9, 12):
  ```swift
  var updateAvailable: Bool
  var hasUnsavedLocalContent: Bool            // caption rule 1 (view reads it)
  func applyPendingUpdate()
  // private: pendingFreshContent: (markdown: String, syncedAt: Date)?
  // private: displayedSourceMarkdown: String
  // private: reconcileClean(_ formatted: FormattedDocumentContent)
  // private: serverChanged(fetched: String) -> Bool
  ```
  After this task, a passive revalidation on clean content **never swaps blocks**: unchanged → bump `lastSyncedAt`; changed body → stash + `updateAvailable`; changed title → applied silently in both branches. Dirty content (isDirty) gets a silent cache update only. `startEditing()`/`markDirty()` clear the banner.

- [ ] **Step 1: Write the failing tests**

```swift
    func testRevalidateIdenticalContentBumpsSyncedAtWithoutBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        let old = Date(timeIntervalSince1970: 900_000)
        contentCache.save(cachedEntry(markdown: "# Same", syncedAt: old))
        stubLoad(content: "# Same")

        await viewModel.load()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertNotNil(viewModel.lastSyncedAt)
        XCTAssertNotEqual(viewModel.lastSyncedAt, old, "syncedAt advances on a confirmed sync")
        XCTAssertEqual(viewModel.rawMarkdown, "# Same")
    }

    func testRevalidateCanonicalizationOnlyDifferenceShowsNoBanner() async {
        // "* bullet" and "- bullet" parse to the same blocks; the serializer
        // canonicalizes. A cosmetic export difference must not banner.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "- bullet"))
        stubLoad(content: "* bullet")

        await viewModel.load()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertNotNil(viewModel.lastSyncedAt)
        // Comparisons converge on the fetched raw for future opens.
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "* bullet")
    }

    func testRevalidateChangedBodyStashesBehindBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")

        await viewModel.load()

        XCTAssertTrue(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# Old", "on-screen content untouched")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# New", "future opens get the fresh copy")

        viewModel.applyPendingUpdate()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# New")
    }

    func testRevalidateChangedTitleAppliesSilently() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Same"))
        stubLoad(content: "# Same") // stubLoad's fixture title is "Doc"

        await viewModel.load()

        XCTAssertEqual(viewModel.title, "Doc")
        XCTAssertFalse(viewModel.updateAvailable, "title alone never banners")
        // savedTitle followed, so no spurious save is enqueued on flush.
        viewModel.flushPendingChanges()
        XCTAssertNil(viewModel.saveCoordinator.pendingSave(documentID: documentID))
    }

    func testStartEditingClearsPendingUpdate() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        viewModel.startEditing()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# Old", "blocks unchanged")
    }

    func testApplyPendingUpdateWhileEditingIsANoOp() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.applyPendingUpdate()

        XCTAssertEqual(viewModel.rawMarkdown, "# Old")
    }

    func testNonRoundTrippableCachedContentOpensInMarkdownMode() async {
        // Destructive-save regression: the cached install must run the same
        // round-trip check as a fetch, or editing "*"-bulleted content would
        // silently rewrite it via a full-overwrite save.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "* bullet"))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertTrue(viewModel.openInMarkdownMode)
    }

    func testApplyPendingUpdateRecomputesRoundTripMode() async {
        // The banner apply must route through install() — a bare blocks swap
        // would skip the round-trip check.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "* bullet")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        viewModel.applyPendingUpdate()

        XCTAssertTrue(viewModel.openInMarkdownMode)
        XCTAssertEqual(viewModel.rawMarkdown, "* bullet")
    }

    func testRevalidateWhileDirtyUpdatesCacheSilently() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# Server")
        await viewModel.load() // banner set; now simulate editing instead
        viewModel.startEditing()
        viewModel.updateTitle("Edited")

        stubLoad(content: "# Server 2")
        await viewModel.load()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.title, "Edited", "edits untouched")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# Server 2")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILS — `updateAvailable` undefined.

- [ ] **Step 3: Write the implementation**

In `EditorViewModel.swift`:

1. New state (with the Task 6 vars):

```swift
    var updateAvailable = false
    private var pendingFreshContent: (markdown: String, syncedAt: Date)?
    /// The exact raw markdown the current display was installed from — the
    /// staleness comparison basis. NEVER compare fetched markdown against
    /// serializeMarkdown(blocks)/currentMarkdown(): the serializer
    /// canonicalizes (`*`→`-`, renumbering), which would give every
    /// non-byte-round-tripping document a permanent do-nothing banner.
    private var displayedSourceMarkdown = ""

    /// Caption rule 1: unsaved local content wins over "Synced X ago".
    var hasUnsavedLocalContent: Bool {
        isDirty
            || saveCoordinator.pendingSave(documentID: documentID) != nil
            || (displaySource == .draft && saveCoordinator.storedDraft(documentID: documentID) != nil)
    }
```

2. `install(...)` records the comparison basis — add one line before `hasLoadedContent = true`:

```swift
        displayedSourceMarkdown = markdown
```

3. `load()` resets banner state whenever the local phase (re)runs — the local
phase re-reads the cache, which may already hold a previously stashed fresh
copy, so banner state must never outlive the display it was computed against.
When the local phase is skipped (already installed), an existing banner stays —
it is still valid against the unchanged display, and the new revalidation
re-derives it anyway:

```swift
    func load() async {
        errorMessage = nil
        if !hasLoadedContent {
            updateAvailable = false
            pendingFreshContent = nil
            restoreLocalContent()
            if displaySource == .none {
                isLoading = true
            }
        }
        await revalidate()
        isLoading = false
    }
```

4. Rework `apply(formatted:)` — dirty guard first, then the clean branches go through `reconcileClean`:

```swift
    private func apply(formatted: FormattedDocumentContent) {
        defer { updatedAt = formatted.updatedAt }
        // Classify against *current* state: edits may have begun while the
        // fetch was in flight.
        if saveCoordinator.pendingSave(documentID: documentID) != nil || isDirty {
            cacheServerCopy(formatted)
            return
        }
        switch displaySource {
        case .pendingSave:
            break
        case .draft:
            if let draft = saveCoordinator.storedDraft(documentID: documentID),
               formatted.updatedAt <= draft.updatedAt.addingTimeInterval(pendingDraftClockTolerance) {
                cacheServerCopy(formatted)
            } else {
                installFetched(formatted) // server wins (today's behavior)
            }
        case .none:
            installFetched(formatted)
        case .clean:
            reconcileClean(formatted)
        }
    }

    /// Silent cache update while local edits own the screen — next open (or
    /// the coordinator's own conflict handling) deals with freshness.
    private func cacheServerCopy(_ formatted: FormattedDocumentContent) {
        contentCache.save(CachedDocumentContent(
            documentID: documentID,
            title: formatted.title,
            markdown: formatted.content ?? "",
            syncedAt: Date()
        ))
    }

    /// Clean content on screen: never swap it on a passive open. Titles are
    /// non-destructive and apply silently in BOTH branches (savedTitle follows
    /// so flushPendingChanges never enqueues a spurious save); only body
    /// differences drive the banner.
    private func reconcileClean(_ formatted: FormattedDocumentContent) {
        let fetched = formatted.content ?? ""
        let now = Date()
        if let fetchedTitle = formatted.title, fetchedTitle != title {
            title = fetchedTitle
            savedTitle = fetchedTitle
        }
        contentCache.save(CachedDocumentContent(
            documentID: documentID,
            title: title,
            markdown: fetched,
            syncedAt: now
        ))
        if serverChanged(fetched: fetched) {
            pendingFreshContent = (markdown: fetched, syncedAt: now)
            updateAvailable = true
        } else {
            // Raw may differ only cosmetically — converge the comparison
            // basis on the fetched raw so future comparisons settle.
            displayedSourceMarkdown = fetched
            lastSyncedAt = now
        }
    }

    private func serverChanged(fetched: String) -> Bool {
        guard fetched != displayedSourceMarkdown else { return false }
        return serializeMarkdown(parseEditorBlocks(fetched))
            != serializeMarkdown(parseEditorBlocks(displayedSourceMarkdown))
    }

    /// The "Updated" banner tap: swaps in the stashed fresh body. Guarded so a
    /// stray tap can never replace blocks mid-edit or clobber dirty content.
    func applyPendingUpdate() {
        guard !isEditing, !isDirty, let pending = pendingFreshContent else { return }
        install(markdown: pending.markdown, title: nil, syncedAt: pending.syncedAt)
        displaySource = .clean
        updateAvailable = false
        pendingFreshContent = nil
    }
```

5. Clear the banner when editing begins. In `startEditing(focusing:)`, after `errorMessage = nil`:

```swift
        updateAvailable = false
        pendingFreshContent = nil
```

And at the top of `markDirty()` (belt-and-braces for edits that bypass startEditing):

```swift
        if updateAvailable {
            updateAvailable = false
            pendingFreshContent = nil
        }
```

6. Anchor the comparison basis on save enqueue. In `flushPendingChanges()`, after `savedMarkdown = markdown`:

```swift
        displayedSourceMarkdown = markdown
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: all `EditorViewModelTests` PASS. The Task 6 test `testCachedDocumentRendersWithoutLoadingSpinner` stubs identical content, so it now exercises the "unchanged → bump" branch — verify it still passes.

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/EditorViewModel.swift SchriftTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Content-equality revalidation with Updated banner and silent title sync"
```

---

### Task 8: Failure classes, stale-draft server-wins, re-entrancy

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift`
- Modify: `SchriftTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Consumes: `discardStoredDraft(_:)` (Task 4), `DocsAPIError` (`.notFound`/`.forbidden`/`.sessionExpired` — all `Equatable`).
- Produces: terminal-unavailable state; generation-guarded revalidation (`private var revalidationGeneration: Int`); `private func becomeUnavailable()` (reused by Task 9's `refresh()`).

- [ ] **Step 1: Write the failing tests**

```swift
    private func stubStatus(_ code: Int) {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: code, headers: [:], body: Data(), error: nil)
        }
    }

    func testRevalidate404PurgesCacheAndShowsUnavailable() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(404)

        await viewModel.load()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertEqual(viewModel.errorMessage, "This document is no longer available.")
        XCTAssertFalse(viewModel.hasLocalCopy)
        XCTAssertNil(viewModel.lastSyncedAt)
        viewModel.startEditing()
        XCTAssertFalse(viewModel.isEditing, "editing disabled in the terminal state")
    }

    func testRevalidate403PurgesCacheToo() async {
        // Privacy: revoked-access content must not stay readable on disk.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(403)

        await viewModel.load()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertEqual(viewModel.errorMessage, "This document is no longer available.")
    }

    func testRevalidate401KeepsCacheReadable() async {
        // Cookie expiry must not purge the cache or offline reading dies on
        // every re-login.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(401)

        await viewModel.load()

        XCTAssertNotNil(contentCache.content(for: documentID))
        XCTAssertFalse(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testStaleDraftLosesToNewerServerCopy() async {
        // Server updated_at beyond draft.updatedAt + 120s tolerance → server
        // wins, draft removed (preserves today's server-wins rule).
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        draftStore.save(PendingDraft(
            documentID: documentID, title: "Old draft", markdown: "# Stale",
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        // stubLoad's fixture updated_at is 2026-01-15T10:30:00Z — far beyond
        // 1970-epoch + tolerance.
        stubLoad(content: "# Server")

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# Server")
        XCTAssertNil(draftStore.draft(for: documentID), "stale draft removed")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# Server")
        XCTAssertEqual(viewModel.displaySource, .clean)
    }

    func testDraftWithinToleranceIsKeptOnScreen() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        // Fixture updated_at is 2026-01-15T10:30:00Z; a draft stamped now is
        // far newer → within tolerance, draft stays.
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft", markdown: "# Draft", updatedAt: Date()))
        stubLoad(content: "# Server")

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# Draft")
        XCTAssertNotNil(draftStore.draft(for: documentID))
    }

    func testSecondLoadSupersedesFirstRevalidation() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")

        async let first: Void = viewModel.load()
        async let second: Void = viewModel.load()
        _ = await (first, second)

        // Whatever interleaving occurred, exactly one coherent outcome:
        // banner set with old content displayed, and no stale stash.
        XCTAssertTrue(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# Old")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — 404 currently swallowed (`errorMessage` nil, cache kept); stale draft not removed; etc.

- [ ] **Step 3: Write the implementation**

In `EditorViewModel.swift`:

1. Add the generation counter (with the other private vars):

```swift
    /// Monotonic guard: a completing fetch applies its outcome only if no
    /// newer load()/refresh() superseded it (latest-wins; .task refires on
    /// pop-back and .refreshable re-enters).
    private var revalidationGeneration = 0
```

2. `load()` and `revalidate()` become generation-aware:

```swift
    func load() async {
        errorMessage = nil
        if !hasLoadedContent {
            updateAvailable = false
            pendingFreshContent = nil
            restoreLocalContent()
            if displaySource == .none {
                isLoading = true
            }
        }
        revalidationGeneration += 1
        await revalidate(generation: revalidationGeneration)
        isLoading = false
    }

    private func revalidate(generation: Int) async {
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            guard generation == revalidationGeneration, !Task.isCancelled else { return }
            apply(formatted: formatted)
            await loadChildren()
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == revalidationGeneration else { return }
            becomeUnavailable()
        } catch {
            guard generation == revalidationGeneration else { return }
            // Transient (.network, .server, .rateLimited, .sessionExpired —
            // cookie expiry must not purge the cache): keep the local copy.
            if displaySource == .none {
                errorMessage = "Couldn't load this document. Pull to refresh to try again."
            }
        }
    }

    /// Definitive 404/403: the document is gone or access was revoked. Purge
    /// the durable copy (privacy), disable editing, show the terminal state.
    private func becomeUnavailable() {
        contentCache.remove(documentID: documentID)
        hasLocalCopy = false
        lastSyncedAt = nil
        updateAvailable = false
        pendingFreshContent = nil
        blocks = []
        rawMarkdown = ""
        displayedSourceMarkdown = ""
        displaySource = .none
        hasLoadedContent = false // startEditing guards on this
        errorMessage = "This document is no longer available."
    }
```

3. In `apply(formatted:)`, the `.draft` stale branch now removes the draft (replace the `installFetched(formatted)` line in that branch):

```swift
        case .draft:
            if let draft = saveCoordinator.storedDraft(documentID: documentID),
               formatted.updatedAt <= draft.updatedAt.addingTimeInterval(pendingDraftClockTolerance) {
                cacheServerCopy(formatted)
            } else {
                // Server newer beyond tolerance: today the stale draft would
                // never have been shown — server wins, and the draft goes
                // (re-checked inside discardStoredDraft; the user may have
                // produced a newer one while we awaited).
                if let draft = saveCoordinator.storedDraft(documentID: documentID) {
                    saveCoordinator.discardStoredDraft(draft)
                }
                installFetched(formatted)
            }
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: all `EditorViewModelTests` PASS. Also re-run `DocumentSaveCoordinatorTests` (unchanged, but exercises `discardStoredDraft`).

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/EditorViewModel.swift SchriftTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Classify revalidation failures, stale-draft server-wins, latest-wins re-entrancy"
```

---

### Task 9: `refresh()` — explicit pull-to-refresh intent

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift`
- Modify: `SchriftTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Produces: `func refresh() async` (Task 12 rewires `.refreshable` to it). Semantics: awaits the fetch; clean → applies fetched content **directly** (no banner) and clears any pending banner; dirty → silent cache update; transient failure → `errorMessage = "Couldn't refresh. Please try again."` even with local content; 404/403 → `becomeUnavailable()`; not-yet-loaded → falls back to `load()`.

- [ ] **Step 1: Write the failing tests**

```swift
    func testRefreshAppliesNewerContentDirectlyWithoutBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        await viewModel.load() // instant from cache, revalidation failed silently

        stubLoad(content: "# New")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.rawMarkdown, "# New", "explicit refresh applies directly")
        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertNotNil(viewModel.lastSyncedAt)
    }

    func testRefreshClearsAPendingBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        await viewModel.refresh()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# New")
    }

    func testRefreshFailureSurfacesErrorEvenWithLocalContent() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubLoad(content: "# Cached")
        await viewModel.load()

        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        await viewModel.refresh()

        XCTAssertEqual(viewModel.errorMessage, "Couldn't refresh. Please try again.")
        XCTAssertFalse(viewModel.blocks.isEmpty, "content stays readable")
    }

    func testRefreshWhileDirtyLeavesEditsUntouched() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Mine"))
        stubLoad(content: "# Mine")
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateTitle("Edited title")

        stubLoad(content: "# Theirs")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.title, "Edited title")
        XCTAssertEqual(viewModel.rawMarkdown, "# Mine")
        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# Theirs")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILS — `refresh()` undefined.

- [ ] **Step 3: Write the implementation**

The clean path diverges from passive revalidation only in the clean-and-changed outcome, so `apply`/`reconcileClean` gain a `userInitiated` flag (default `false` keeps every existing call site meaning unchanged):

```swift
    /// Explicit pull-to-refresh. Unlike the passive on-open revalidation it
    /// awaits the fetch (the refresh spinner reflects real work), applies a
    /// changed server copy DIRECTLY when clean (the user asked — no banner),
    /// and surfaces failures instead of swallowing them.
    func refresh() async {
        guard hasLoadedContent else {
            await load() // error-state retry: full initial flow, as today
            return
        }
        errorMessage = nil
        revalidationGeneration += 1
        let generation = revalidationGeneration
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            guard generation == revalidationGeneration, !Task.isCancelled else { return }
            apply(formatted: formatted, userInitiated: true)
            await loadChildren()
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == revalidationGeneration else { return }
            becomeUnavailable()
        } catch {
            guard generation == revalidationGeneration else { return }
            errorMessage = "Couldn't refresh. Please try again."
        }
    }
```

Change the two signatures and the clean-and-changed branch:

```swift
    private func apply(formatted: FormattedDocumentContent, userInitiated: Bool = false) {
        ...
        case .clean:
            reconcileClean(formatted, applyDirectly: userInitiated)
        ...
    }

    private func reconcileClean(_ formatted: FormattedDocumentContent, applyDirectly: Bool = false) {
        let fetched = formatted.content ?? ""
        let now = Date()
        if let fetchedTitle = formatted.title, fetchedTitle != title {
            title = fetchedTitle
            savedTitle = fetchedTitle
        }
        contentCache.save(CachedDocumentContent(
            documentID: documentID,
            title: title,
            markdown: fetched,
            syncedAt: now
        ))
        if serverChanged(fetched: fetched) {
            if applyDirectly {
                install(markdown: fetched, title: nil, syncedAt: now)
                updateAvailable = false
                pendingFreshContent = nil
            } else {
                pendingFreshContent = (markdown: fetched, syncedAt: now)
                updateAvailable = true
            }
        } else {
            displayedSourceMarkdown = fetched
            lastSyncedAt = now
            if applyDirectly {
                updateAvailable = false
                pendingFreshContent = nil
            }
        }
    }
```

(`revalidate(generation:)` keeps calling `apply(formatted: formatted)` — the default `userInitiated: false`.)

- [ ] **Step 4: Run tests to verify they pass**

Expected: all `EditorViewModelTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/EditorViewModel.swift SchriftTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Add refresh() intent: awaited, applies directly, surfaces errors"
```

---

### Task 10: Delete purges local state

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift`
- Modify: `Schrift/Features/Editor/EditorView.swift:125`
- Modify: `SchriftTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Consumes: `contentCache.remove(documentID:)` (Task 2), `discardPendingWork(documentID:)` (Task 4).
- Produces: `func handleDidDelete()`; EditorView calls it before forwarding `onDeleted`.

- [ ] **Step 1: Write the failing test**

```swift
    func testHandleDidDeletePurgesCacheAndDrafts() async {
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        draftStore.save(PendingDraft(documentID: documentID, title: "D", markdown: "# D", updatedAt: Date()))

        viewModel.handleDidDelete()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertNil(draftStore.draft(for: documentID))
    }
```

- [ ] **Step 2: Run to verify it fails** — BUILD FAILS, `handleDidDelete` undefined.

- [ ] **Step 3: Implement**

In `EditorViewModel.swift` (after `applyPendingUpdate()`):

```swift
    /// A successful local delete must purge every local copy — otherwise the
    /// document stays reachable from retained Search/Shared results and
    /// renders its full cached content indefinitely (transient revalidation
    /// failures are swallowed by design).
    func handleDidDelete() {
        contentCache.remove(documentID: documentID)
        saveCoordinator.discardPendingWork(documentID: documentID)
    }
```

In `EditorView.swift`, the options sheet (line 125): replace `onDeleted: onDeleted` with:

```swift
                onDeleted: {
                    viewModel.handleDidDelete()
                    onDeleted?()
                }
```

- [ ] **Step 4: Run tests** — `EditorViewModelTests` PASS; build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/EditorViewModel.swift Schrift/Features/Editor/EditorView.swift SchriftTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Purge content cache and pending work on document delete"
```

---

### Task 11: Subpages become fetch-aware (`[Document]?`)

**Files:**
- Modify: `Schrift/Features/Editor/EditorViewModel.swift:39` and `loadChildren()`
- Modify: `Schrift/Features/Editor/EditorView.swift` (subpagesSection)
- Modify: `SchriftTests/Features/Editor/EditorViewModelTests.swift`

**Interfaces:**
- Produces: `var subpages: [Document]?` — `nil` = not fetched this session (view suppresses the empty-state copy); `[]` = fetched, none exist. "Add a subpage" hidden when offline.

- [ ] **Step 1: Write the failing tests**

```swift
    func testSubpagesAreNilBeforeAnySuccessfulFetch() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertNil(viewModel.subpages, "offline: unknown, not 'none'")
    }

    func testSubpagesBecomeEmptyArrayAfterSuccessfulFetch() async {
        let (viewModel, _, _, _) = makeEnvironment()
        // Stub both endpoints explicitly: formatted-content, and an empty
        // paginated children list (do not rely on stubLoad's handling of the
        // children URL — a decode failure must now read as "not fetched").
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("children") {
                return MockURLProtocol.Stub(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"count": 0, "next": null, "previous": null, "results": []}"#.utf8),
                    error: nil
                )
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: self.formattedBody(content: "# Doc"), error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.subpages, [])
    }
```

- [ ] **Step 2: Run to verify failure** — BUILD FAILS (`subpages` is non-optional; comparisons/type mismatch).

- [ ] **Step 3: Implement**

`EditorViewModel.swift`:

```swift
    /// nil = no successful fetch this session (the view must not claim "no
    /// subpages" from the instant/offline path); [] = fetched, none exist.
    var subpages: [Document]? = nil

    func loadChildren() async {
        guard let results = try? await client.listChildren(documentID: documentID) else { return }
        subpages = results.results
    }
```

`EditorView.swift` — in `subpagesSection`, replace the count/empty logic (`viewModel.subpages` usages):

```swift
                Text((viewModel.subpages?.isEmpty ?? true) ? "Subpages" : "Subpages · \(viewModel.subpages?.count ?? 0)")
```

```swift
            if let subpages = viewModel.subpages {
                if subpages.isEmpty {
                    Text("Organize this document by creating subpages.")
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                        .padding(.horizontal, DocsSpacing.spaceXS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(subpages) { child in
                            SubpageRow(document: child, onOpen: { onOpenDocument?(child) })
                        }
                    }
                }
            }
            // nil (not fetched yet): just the eyebrow — never claim "no subpages".
```

And wrap the "Add a subpage" button (createChild is a network POST that fails silently offline):

```swift
            if !isOffline {
                Button {
                    ... existing button body unchanged ...
                }
                .buttonStyle(.plain)
            }
```

Check for any other `viewModel.subpages` usages (`grep -n "subpages" Schrift/Features/Editor/`) and update them for optionality.

- [ ] **Step 4: Run tests** — `EditorViewModelTests` PASS (some existing tests may assert `subpages` — adjust `[]` vs `nil` expectations to match the new contract); app target builds.

- [ ] **Step 5: Commit**

```bash
git add Schrift/Features/Editor/EditorViewModel.swift Schrift/Features/Editor/EditorView.swift SchriftTests/Features/Editor/EditorViewModelTests.swift
git commit -m "Subpages: distinguish not-fetched from empty; hide add offline"
```

---

### Task 12: EditorView chrome — caption, banner pill, offline copy, refresh wiring

**Files:**
- Modify: `Schrift/Features/Editor/EditorView.swift` (lines 54–56, 97–99 area, 204–206, 226–243)

**Interfaces:**
- Consumes: `syncStatusCaption` (Task 3), `hasUnsavedLocalContent`/`lastSyncedAt`/`updateAvailable`/`applyPendingUpdate()`/`hasLocalCopy` (Tasks 6–7), `refresh()` (Task 9), `EditorViewModel.SaveState`.
- Produces: final UI. View-only — verified by build + full editor test pass + preview.

- [ ] **Step 1: Gate the OfflineBanner and fix its copy** (line 54–56):

```swift
            if isOffline, viewModel.hasLocalCopy {
                OfflineBanner(note: "Reading the copy saved on this device")
            }
```

- [ ] **Step 2: Add the "Updated" banner pill** (directly after the offline banner, before the error text):

```swift
            if viewModel.updateAvailable, !viewModel.isEditing {
                Button {
                    viewModel.applyPendingUpdate()
                } label: {
                    HStack(spacing: DocsSpacing.space2xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                        Text("Document updated · tap to refresh")
                            .font(DocsFont.footnote)
                    }
                    .foregroundStyle(DocsColor.textBrand)
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .padding(.vertical, DocsSpacing.space2xs)
                    .background(Capsule().fill(DocsColor.gray050))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Document updated. Tap to refresh.")
            }
```

- [ ] **Step 3: Replace the hard-coded header subtitle** (line 237). Replace
`Text(isOffline ? "Saved on this device" : "Edited just now")` with:

```swift
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(syncCaptionText(now: context.date))
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                }
```

And add the precedence helper to `EditorView` (near `trailingActions`) — the selection lives in the view, the pure formatter produces only rule-2 copy:

```swift
    /// Caption precedence: (1) unsaved local content → save wording (a
    /// previously-synced doc with a stranded draft must not read "Not synced
    /// yet"); (2) synced → "Synced X ago"; (3) neither → "Not synced yet".
    private func syncCaptionText(now: Date) -> String {
        if viewModel.hasUnsavedLocalContent {
            if isOffline { return "Saved on this device" }
            switch viewModel.saveState {
            case .saving: return "Saving…"
            case .saved: return "Saved"
            case .failed: return "Couldn't save"
            case .dirty, .idle: return "Edited just now"
            }
        }
        if let lastSyncedAt = viewModel.lastSyncedAt {
            return syncStatusCaption(lastSyncedAt: lastSyncedAt, now: now)
        }
        return "Not synced yet"
    }
```

- [ ] **Step 4: Rewire pull-to-refresh** (line 204–206):

```swift
        .refreshable {
            await viewModel.refresh()
        }
```

- [ ] **Step 5: Build + run the whole editor suite**

Run: `xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SchriftTests/EditorViewModelTests -only-testing:SchriftTests/EditorViewTests`
Expected: PASS. Also open the `#Preview` in Xcode if available and eyeball the header caption + banner (manual, optional).

- [ ] **Step 6: Commit**

```bash
git add Schrift/Features/Editor/EditorView.swift
git commit -m "Editor chrome: sync caption, Updated banner, offline copy, refresh wiring"
```

---

### Task 13: Sign-out clears the content cache

**Files:**
- Modify: `Schrift/App/RootView.swift:31`

**Interfaces:**
- Consumes: `DocumentContentCacheStore.removeAll()` (Task 2; store-level behavior already covered by `testRemoveAllDeletesEveryEntry`).

- [ ] **Step 1: Implement**

In `RootView.swift`, the authenticated branch currently reads:

```swift
            AuthenticatedHomeContainer(serverURL: serverURL, onSignOut: { try? sessionStore.signOut() })
```

Replace with:

```swift
            AuthenticatedHomeContainer(serverURL: serverURL, onSignOut: {
                // Full document bodies must not survive sign-out on disk. The
                // metadata cache (DocumentCacheStore) and unsaved drafts
                // (PendingDraftStore) keep their existing behavior — a
                // recorded decision, see the 2026-07-03 spec.
                DocumentContentCacheStore().removeAll()
                try? sessionStore.signOut()
            })
```

(The store is stateless — constructing an instance here is safe by design, spec §1/§5.)

- [ ] **Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild build -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED. (The clearing behavior itself is covered by the store-level `removeAll` test; the closure is SwiftUI-view wiring.)

- [ ] **Step 3: Commit**

```bash
git add Schrift/App/RootView.swift
git commit -m "Clear content cache on sign-out"
```

---

### Task 14: Documentation sync

**Files:**
- Modify: `CLAUDE.md` (repo layout + Editor section + Persistence section)
- Modify: `docs/superpowers/specs/2026-06-30-docs-ios-design.md` (header + error-handling line + non-goal clarification)

- [ ] **Step 1: CLAUDE.md — repo layout.** In the `Features/` → `Editor/` line of the layout tree, append the cache: `block editor, Markdown toggle, save coordinator, drafts, content cache`.

- [ ] **Step 2: CLAUDE.md — Editor section.** In "Editor & the on-device save (`Core/Yjs`)", after the `DocumentSaveCoordinator` bullet, add:

```markdown
- Content is cached on-device in **`DocumentContentCacheStore`** (one JSON per
  document under Application Support, backup-excluded, ≤50 entries by
  most-recent `syncedAt` via file mtime): `load()` shows a local copy
  **synchronously** (precedence: in-flight save → stored draft → cached copy →
  network-with-spinner) and revalidates in the background — content equality
  (never re-serialized blocks) decides whether the "Updated" banner appears.
  The coordinator write-throughs the cache on save success; delete and 404/403
  revalidation purge the entry; sign-out clears the store. Offline is
  read-only. See `docs/superpowers/specs/2026-07-03-instant-local-doc-content-design.md`.
```

- [ ] **Step 3: CLAUDE.md — Persistence section.** After the UserDefaults-stores bullet, add:

```markdown
- `DocumentContentCacheStore` is the one **file-based** store (full document
  bodies are too large for UserDefaults): stateless over its directory,
  `isExcludedFromBackup`, cleared on sign-out, never logged. Its eviction
  selection is a top-level pure free function (`contentCacheEvictions`).
```

- [ ] **Step 4: 2026-06-30 design spec.** In the header block (after the `Revised: 2026-07-02` line), add:

```markdown
Revised: 2026-07-03 — offline **reading** was added: previously-opened
documents are cached on-device and render instantly with background
revalidation (see
`docs/superpowers/specs/2026-07-03-instant-local-doc-content-design.md`).
Offline *editing* remains out of scope.
```

Then amend the error-handling line reading `Network failure → retry affordance on the failed view; no offline queue/cache in v1` to:

```markdown
- Network failure → retry affordance on the failed view; no offline edit/sync
  queue in v1 (since 2026-07-03, previously-opened documents are content-cached
  on-device and readable offline).
```

And the Non-goals bullet `Offline editing/sync queue.` to:

```markdown
- Offline editing/sync queue. (Offline *reading* of previously-opened documents
  was added 2026-07-03; editing still requires connectivity.)
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-06-30-docs-ios-design.md
git commit -m "Docs: record content cache, offline reading, and load precedence"
```

---

### Task 15: Final verification

- [ ] **Step 1: Regenerate and run the entire suite**

```sh
xcodegen generate && xcodebuild test -project Schrift.xcodeproj -scheme Schrift \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: ALL tests pass, zero warnings introduced (check the build log for new warnings in changed files).

- [ ] **Step 2: Spec cross-check.** Walk the spec's Testing section (rev 2) line by line and confirm each listed case exists in a test added by Tasks 1–11. Known intentional deviations to confirm are documented and acceptable: the sign-out flow is covered at store level (`testRemoveAllDeletesEveryEntry`) + view wiring by build; `pendingFreshContent` is a `(markdown, syncedAt)` tuple rather than the spec sketch's bare `String` (records the sync time the banner content was fetched at).

- [ ] **Step 3: Manual smoke test (simulator, optional but recommended)**
  - Open a doc (spinner, first time) → back → reopen: instant, "Synced just now".
  - Toggle Work Offline in Profile → reopen the doc: content + "Reading the copy saved on this device"; tap a block: editing does not start.
  - Edit the doc elsewhere (web) → reopen in app: "Updated" pill; tap → content swaps.
  - Pull to refresh: content updates directly, no pill.

- [ ] **Step 4: Commit any leftover fixes, then hand off for review**

```bash
git status   # confirm clean
```
