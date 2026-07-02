# Notion-like Block Editing with Markdown Toggle (Schrift iOS)

> Status: implemented (2026-07-02). An embed of the web app's BlockNote editor
> in a WKWebView was evaluated as an alternative (full fidelity via direct
> base64-Yjs PATCH, but experimental mobile touch support upstream, a JS build
> pipeline, and a pre-1.0 dependency); the native SwiftUI reimplementation
> below was chosen.
>
> **Amendment (2026-07-02, post-merge):** Superseded shortly after this plan by
> commit `b68c4c6`. `DocsAPIClient.saveDocumentContent` no longer uses the
> 4-request temp-document pipeline described below (POST temp `.md` → GET raw Yjs
> → PATCH → DELETE); it now encodes markdown to Yjs **on-device**
> (`MarkdownYjs.encode`) and PATCHes content + title directly
> (`Schrift/Core/Networking/DocumentSave.swift`). The method's signature is
> unchanged, so the `DocumentSaveCoordinator` / autosave / drafts design below
> still holds — only the internal request pipeline (and the "networking layer
> needs no changes" note) is out of date. Kept as a dated record.

## Context

Schrift's editor today is two disconnected surfaces: a **read-only** block renderer (`MarkdownBlockView` over a 5-case `MarkdownBlock` enum) and an **edit mode** that is a single raw-markdown `TextEditor` with a formatting bar that blindly appends tokens to the end of the string. The web app (suitenumerique/docs) uses BlockNote — a Notion-style block editor (tap a block to edit in place, Enter splits, Backspace merges, "/" slash menu). The goal is to bring that editing experience to iOS **natively** (per the repo's zero-dependency design spec), plus something the web doesn't have: a **toggle to view/edit the raw markdown source**.

Hard constraint: the backend stores content as an opaque Yjs blob with **no markdown write endpoint**. Saves go through the existing 4-request pipeline (`DocsAPIClient.saveDocumentContent` in `Schrift/Core/Networking/DocumentSave.swift`: POST temp .md doc → GET raw Yjs bytes → PATCH real doc → DELETE temp) as a **full overwrite**. So markdown remains the interchange format both ways, and round-trip fidelity is safety-critical: with autosave, any markdown construct the parser can't model would be silently destroyed on save. The networking layer needs **no changes**.

**User-confirmed decisions:**
1. **Native SwiftUI block editor** (no WKWebView/BlockNote embed, no dependencies).
2. **Autosave + manual Save** (debounced autosave, flush on exit/background, plus explicit save affordance).
3. In scope: **slash menu**, **markdown typing shortcuts**, **more block types** (numbered lists, fenced code, divider). Drag-to-reorder is explicitly out of scope this iteration.
4. **Blocks ⇄ Markdown toggle** while editing.

## Architecture overview

- **Block model**: replace the payload-carrying `MarkdownBlock` enum with `struct EditorBlock: Identifiable` (stable `id: UUID`, `kind: BlockKind`, `text: String`). Payload-in-enum can't hand SwiftUI a `Binding<String>` into a case; kind+text can. A `.unknown` kind preserves unmodeled markdown (tables, images, nested lists, HTML) **verbatim** so full-overwrite saves never destroy content the editor doesn't understand.
- **Editing surface**: one `UITextView` per block via `UIViewRepresentable` (precedent: `WebLogin` representable). SwiftUI's `TextField`/`TextEditor` cannot detect Backspace-at-start, cursor offset, or programmatic selection — all required. Container is `ScrollView` + `LazyVStack` (`List` recycling fights per-row first-responders), `ScrollViewReader.scrollTo` for keyboard-following.
- **Source of truth**: `blocks` array while in blocks mode; `rawMarkdown` string while in markdown mode; new serializer converts blocks→markdown on toggle/save. View model owns focus (`focusedBlockID`), not `@FocusState`.
- **Save — non-blocking and screen-independent** (user requirement): saving must never block viewing or editing, and switching to another document must not cancel a pending or in-flight save. Two pieces:
  - `EditorViewModel` owns only the trailing **10 s debounce** (web uses 60 s, but full-overwrite semantics favor a shorter loss window; ~6 saves/min worst case is modest, and 429 already maps in `DocsAPIErrorMapper`). On fire — or on Done, `onDisappear`, doc switch, or `scenePhase` background — it hands a **snapshot** of `(title, currentMarkdown())` to the coordinator and the user keeps typing; edits during an in-flight save just mark dirty again. Today's `.disabled(viewModel.isSaving)` on the edit surface is removed; no mode is ever gated on saving.
  - New **`DocumentSaveCoordinator`** — a single `@MainActor @Observable` object owned by `HomeViewModel` (shared by `HomeView` and `HomeSplitView`, which both build `EditorViewModel`s from it — `HomeView.swift:53`, `HomeSplitView.swift:15`). It runs saves in **unstructured Tasks it stores itself**, so they survive editor teardown/navigation. Per-document serialization: at most one in-flight save per doc; newer snapshots coalesce into a "latest wins" queued slot that runs as soon as the in-flight one finishes. Re-opening a doc whose save is still pending/in-flight: `load()` asks the coordinator for `pendingSave(documentID:)` and prefers that content over the (stale) server response.
  - **Survives closing the app** (user requirement): (a) every enqueue **write-ahead persists** the snapshot to a new `PendingDraftStore` (UserDefaults-backed JSON keyed by documentID, same pattern as `DocumentCacheStore`) *before* any network call, and the draft is cleared only when a save of that exact content succeeds; (b) each save Task is wrapped in a `UIApplication.beginBackgroundTask`/`endBackgroundTask` assertion (injectable shim for tests) so the 4-request pipeline gets its ~30 s of background runtime to finish after the user swipes home; (c) on next launch, `HomeViewModel` calls `saveCoordinator.recoverDrafts()` — for each stored draft it fetches the doc's `updatedAt` and re-enqueues the draft if the server wasn't updated after the draft was written (if the server is newer, the draft is discarded rather than clobbering fresher web edits). So a save interrupted by suspension or process death is replayed, and content typed right before closing is never lost.
  - **Cancel is removed** (revert is a lie once anything autosaved) — replaced by **Done** + a save-status pill (Saving… / Saved / Unsaved·Save / Failed·Retry) that reflects the coordinator's per-doc state combined with the local dirty flag.
- **Read mode stays** (cheap, pull-to-refresh, read-only viewers); tapping a block in read mode enters edit mode focused on that block.

## Core model signatures

```swift
// EditorBlock.swift
enum BlockKind: Equatable, Sendable {
    case heading(level: Int)          // 1...6
    case paragraph
    case bulletItem
    case numberedItem                 // number computed from position, never stored
    case checklistItem(checked: Bool)
    case quote
    case codeBlock(language: String)
    case divider                      // text always ""
    case unknown                      // verbatim passthrough; text may contain \n
}
struct EditorBlock: Identifiable, Equatable, Sendable {
    let id: UUID; var kind: BlockKind; var text: String
}
func blocksContentEqual(_ lhs: [EditorBlock], _ rhs: [EditorBlock]) -> Bool  // ignores ids

// MarkdownParser.swift
func parseEditorBlocks(_ markdown: String) -> [EditorBlock]
func markdownSurvivesRoundTrip(_ markdown: String) -> Bool  // gate: false → open doc in source mode

// MarkdownSerializer.swift
func serializeMarkdown(_ blocks: [EditorBlock]) -> String
func numberedIndex(of index: Int, in blocks: [EditorBlock]) -> Int

// MarkdownShortcuts.swift
func detectMarkdownShortcut(text: String) -> BlockShortcutMatch?   // "# ", "- ", "1. ", "> ", "[] "…
func detectEnterShortcut(text: String) -> BlockShortcutMatch?      // "```lang", "---" on Enter
func wrapInlineMarker(text: String, range: NSRange, marker: String) -> (text: String, selection: NSRange)

// SlashMenu.swift
func slashQuery(text: String, kind: BlockKind) -> String?
func filteredSlashItems(query: String) -> [SlashMenuItem]
```

**Parser rules** (line-based state machine, classification anchored at column 0 on the *untrimmed* line):
- ```` ``` ```` fence opens `codeBlock` (content verbatim until closing fence/EOF); trimmed `---`/`***`/`___` → divider; heading/checklist/bullet/quote as today; `^\d{1,9}[.)] ` → numberedItem.
- Unclassified lines group into **maximal runs**: single "plain" line → paragraph; anything else (indented lines, `|` tables, `![` images, `<` HTML, multi-line runs) → **one `.unknown` block, bytes preserved verbatim**.
- Documented lossy canonicalizations: blank-line runs collapse, `*`→`-` bullets, ordered lists renumber 1..n.

**Serializer**: heading `#…# text`, bullet `- `, numbered `N. ` (positional), checklist `- [ ] `/`- [x] `, quote `> `, code fenced (fence length = longest backtick run in code + 1, min 3), divider `---`, unknown verbatim. Adjacent list-ish blocks (bullet/numbered/checklist/quote) join with `\n`; everything else `\n\n`. Round-trip contract tested: `parseEditorBlocks(serializeMarkdown(blocks))` content-equals `blocks`.

**Block mutations (Notion semantics)** in `EditorViewModel`:
- `splitBlock(blockID:at:)` — Enter: remainder becomes new block below; list/checklist kinds continue (checklist unchecked), heading/quote → paragraph; Enter on an **empty** list item converts it to paragraph (list escape).
- `mergeBlockWithPrevious(blockID:)` — Backspace at offset 0: styled block first converts to paragraph; else merge text into previous (divider above → delete it); caret placed at old end of previous via a consume-once `CursorRequest`.
- `toggleChecklist`, `convertBlock(to:)`, `insertBlock(after:kind:)`, `applySlashSelection`, `applyInlineMarker`, `updateTitle`.

**Save coordinator** (new `DocumentSaveCoordinator.swift`):
```swift
@MainActor @Observable
final class DocumentSaveCoordinator {
    struct PendingSave: Equatable { let title: String; let markdown: String }
    enum DocSaveState: Equatable { case idle, saving, saved(Date), failed(String) }

    init(client: DocsAPIClient,
         draftStore: PendingDraftStore = PendingDraftStore(),
         backgroundTasks: BackgroundTaskProvider = .uiApplication) // begin/end closures; no-op in tests
    func enqueue(documentID: UUID, title: String, markdown: String)
        // 1) write-ahead: draftStore.save(draft) BEFORE any network call
        // 2) per-doc serial, latest-wins coalescing; runs client.saveDocumentContent in a stored
        //    unstructured Task (view-lifetime-proof) under a beginBackgroundTask assertion
        // 3) on success: clear draft iff it still matches the saved content
    func pendingSave(documentID: UUID) -> PendingSave?  // queued or in-flight content not yet persisted
    func state(for documentID: UUID) -> DocSaveState    // drives the status pill; observable
    func recoverDrafts() async
        // launch recovery: for each stored draft, GET the document; re-enqueue if server
        // updatedAt <= draft timestamp, else discard (web edits are fresher)
}

// PendingDraftStore.swift — UserDefaults-backed JSON, same pattern as DocumentCacheStore
struct PendingDraft: Codable, Equatable { let documentID: UUID; let title: String; let markdown: String; let updatedAt: Date }
final class PendingDraftStore {
    func save(_ draft: PendingDraft); func draft(for documentID: UUID) -> PendingDraft?
    func remove(documentID: UUID); func allDrafts() -> [PendingDraft]
}
```

**ViewModel state** (replaces `isEditing`/`isSaving` with computed shims where handy):
```swift
enum Mode { case reading, blocks, markdown }
enum SaveState: Equatable { case idle, dirty, saving, saved, failed(String) }  // derived: local dirty + coordinator state
var mode: Mode; var saveState: SaveState { get }
var focusedBlockID: UUID?; var cursorRequest: CursorRequest?
var slashQueryText: String?; var selection: NSRange?
let autosaveInterval: Duration   // init param, default .seconds(10) — injectable for tests
init(client:documentID:title:saveCoordinator:autosaveInterval:)
func currentMarkdown() -> String // serialize blocks or return rawMarkdown per mode
func flushPendingChanges()       // Done / onDisappear / doc switch / scenePhase: cancel debounce, enqueue snapshot now
```

**Markdown toggle UX**: slim `EditorModeBar` under the `NavBar` while editing — existing `SegmentedControl(segments: ["Blocks", "Markdown"], selectedIndex:)` + `SaveStatusIndicator`. Toggle blocks→markdown serializes; markdown→blocks re-parses (canonicalizes — acceptable, it's an explicit user gesture). Source view is a full-document `EditorUITextView` (monospace, smart quotes/autocorrect OFF so markdown isn't corrupted), which also makes the formatting bar cursor-aware in source mode.

**Slash menu**: docked panel above the formatting bar/keyboard (caret-anchored popovers are fragile in SwiftUI + representables; mobile Notion docks too). Items: paragraph, H1–H3, bullet, numbered, checklist, quote, code, divider. Dismiss on backspace-past-`/`, block switch, or zero matches + space.

## Files

New under `Schrift/Features/Editor/`: `EditorBlock.swift`, `MarkdownParser.swift`, `MarkdownSerializer.swift`, `MarkdownShortcuts.swift`, `SlashMenu.swift`, `SlashMenuView.swift`, `BlockTextView.swift` (custom `EditorUITextView` overriding `deleteBackward`, delegate intercepting `"\n"`, growing-height, model-driven focus — the hardest file), `BlockEditorView.swift`, `MarkdownSourceView.swift`, `EditorModeBar.swift`, `DocumentSaveCoordinator.swift` (screen-independent save queue with background-task assertion), `PendingDraftStore.swift` (write-ahead draft persistence + launch recovery).

Modified: `EditorViewModel.swift` (state machine + debounce, delegates saves to coordinator), `EditorView.swift` (three-mode body, Done action, flush triggers, tap-block-to-edit, editable title `TextField`, pass `currentMarkdown()` to Options sheet, drop save-time `.disabled`), `MarkdownBlockView.swift` (renders `EditorBlock` + new kinds), `EditorFormattingBar.swift` (selection-aware: bold/italic/code wrap selection; block-type conversions; disabled with no focus), `Features/Home/HomeViewModel.swift` (owns `let saveCoordinator = DocumentSaveCoordinator(client:)`, kicks off `recoverDrafts()` once at startup), `Features/Home/HomeView.swift` + `Features/Home/HomeSplitView.swift` (pass `viewModel.saveCoordinator` into `EditorViewModel`), `DesignSystem/Tokens/DocsTypography.swift` (add `DocsFont.code` monospace token), `DesignSystemCatalog/ComponentCatalogPreview.swift` (sample row).

Deleted: `MarkdownBlock.swift` (superseded). No `project.yml` changes (glob sources). No networking changes.

Also commit the plan doc as `docs/superpowers/plans/2026-07-02-editor-block-editing-markdown-toggle.md` (repo convention).

## Implementation phases (each commits green)

1. **Pure model layer**: `EditorBlock` + parser + serializer + `DocsFont.code`; migrate read path (`MarkdownBlockView`, VM `blocks`) to `EditorBlock`; edit mode unchanged for now; port `MarkdownBlockTests` → `MarkdownParserTests`, add serializer + round-trip tests. *Immediate win: saves stop destroying unmodeled content; read mode renders code/numbered/divider.*
2. **ViewModel state machine + save coordinator**: `Mode`/`SaveState`/mutations/`currentMarkdown`; `DocumentSaveCoordinator` + `PendingDraftStore` (write-ahead draft, per-doc serial, coalescing, view-lifetime-proof Tasks, background-task assertion, launch recovery) wired through `HomeViewModel` → both `EditorViewModel` construction sites; debounce in VM; `EditorModeBar` + status pill; Done replaces Cancel/Save; scenePhase/onDisappear/doc-switch flush; `load()` prefers `pendingSave`/stored-draft content; Options-sheet markdown fix. Tests: mutations, coordinator, draft store, autosave (short injected interval).
3. **Block editing UI**: `BlockTextView`, `BlockEditorView`, `MarkdownSourceView`; split/merge/focus/cursor/checklist/divider wiring; tap-to-edit from read mode; editable title.
4. **Shortcuts + slash menu**: detection functions + docked panel + wiring; tests.
5. **Formatting bar rework**: selection tracking, `wrapInlineMarker`, block-type actions, source-mode cursor insertion; tests.
6. **Polish/hardening**: `markdownSurvivesRoundTrip` gate (risky docs open in source mode with a footnote), failed-save retry affordance, accessibility labels, iPad split-view pass (VM rebuild on doc switch — verify flush), catalog rows.

## Tests (XCTest + existing MockURLProtocol pattern, inline fixtures)

- `MarkdownParserTests` (ports all existing `MarkdownBlockTests` cases) + fences/ordered/dividers/unknown-grouping/column-0 anchoring.
- `MarkdownSerializerTests`: per-kind output, list joining, numbered runs, fence escalation, trailing newline.
- `MarkdownRoundTripTests`: blocks fixed-point across all kinds/adjacencies; canonicalization fixed-point + non-blank-line preservation over ~10 realistic fixtures (tables, nested lists, images, HTML); `markdownSurvivesRoundTrip` cases.
- `MarkdownShortcutsTests`, `SlashMenuTests`: triggers, non-triggers, `wrapInlineMarker` selection math, filtering.
- `EditorBlockMutationTests`: split/merge/escape/toggle/convert/cursorRequest — no networking.
- `DocumentSaveCoordinatorTests` (new): enqueue triggers the 4-request pipeline; second enqueue during a slow in-flight save (delayed `MockURLProtocol` stub) coalesces to exactly one follow-up with the latest content; per-doc independence (doc A saving doesn't block doc B); saves complete even after the enqueuing view model is released (coordinator outlives it); `pendingSave` returns queued/in-flight content and clears on success; state transitions idle→saving→saved/failed; **write-ahead**: draft persisted before the first request fires, cleared on success, retained on failure and when newer content was enqueued mid-save; background-task shim begin/end called around each save; `recoverDrafts()` re-enqueues when server `updatedAt` ≤ draft timestamp and discards when the server is newer.
- `PendingDraftStoreTests` (new, mirrors `DocumentCacheStoreTests`): save/load/remove/allDrafts round-trip, corrupt-data returns nil/empty.
- `EditorViewModelTests` updated: load → `blocksContentEqual`; Cancel test → `testDoneFlushesPendingChangesAndExits`; autosave with `autosaveInterval: .milliseconds(40)` (no request before interval, enqueue after, debounce restart on typing, no-op skip when unchanged, failure → `.failed` stays editing, editing not gated while saving); `load()` prefers coordinator `pendingSave` content over server response; mode-toggle sync; `currentMarkdown()` per mode.
- `DocsTypographySpecTests`: code token. Untouched: `DocumentSaveTests`, `EditorViewModelChildrenTests`.

## Key risks

- **Round-trip destruction under autosave** is the top risk — mitigated by the `.unknown` verbatim block, the round-trip test corpus, and the source-mode gate; fidelity work (phase 1) deliberately lands before autosave (phase 2).
- **Representable feedback loops / first-responder churn**: equality-guarded `updateUIView`, coordinator reentrancy flags, consume-once `CursorRequest`; all isolated in `BlockTextView.swift`.
- **Save vs navigation races**: saves live in `DocumentSaveCoordinator` (app-scoped), so popping the editor or switching docs on iPad (`HomeSplitView` rebuilds the VM per selection) never cancels them; quick doc-switch-and-back reads `pendingSave` instead of stale server content; per-doc serialization prevents out-of-order overwrites from the 4-request pipeline.
- **App close / suspension / process death**: scenePhase flush + background-task assertion covers the normal swipe-home case (~30 s is ample for 4 requests); the write-ahead `PendingDraftStore` + launch recovery covers suspension expiry, system kill, and crashes. Recovery deliberately yields to fresher web edits (server `updatedAt` newer than draft → discard) to avoid resurrecting stale content under full-overwrite semantics.
- **Smart punctuation corrupting markdown**: disabled for code/unknown blocks and all of source mode.
- Edit mode shows raw inline markdown (`**bold**` visible) styled per block kind — live inline rendering is deliberately deferred.

## Verification

No Swift toolchain or CI exists in this environment (Linux; no `.github/workflows`), so verification is via the standard local flow after implementation:
1. `xcodegen generate` then `xcodebuild test -project Schrift.xcodeproj -scheme Schrift -destination 'platform=iOS Simulator,name=iPhone 17'` — full unit suite (parser/serializer/round-trip/shortcuts/mutations/autosave).
2. Manual pass in the simulator against a real instance: open a doc with tables/nested lists made on the web, edit a paragraph on iOS, save, confirm on the web that unmodeled content survived; exercise Enter/Backspace/slash/"# " shortcuts, checklist taps, Blocks⇄Markdown toggle, background-flush, iPad split view, hardware-keyboard Enter; and specifically: keep typing while the status pill shows "Saving…" (nothing blocks), then edit a doc and immediately switch to another doc (throttle network in the simulator to make the save slow) and confirm on the web that the save still landed; edit and immediately swipe to the home screen — confirm the save completes in the background; and kill the app right after backgrounding mid-save, relaunch, and confirm the draft is recovered and saved.
