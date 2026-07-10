# Remove the Markdown editing mode (block editor only)

Date: 2026-07-10

## Goal

Remove the **Markdown** tab from the document editor so the block editor is the
only editing surface. This drops both the user-facing Blocks/Markdown toggle and
the automatic "opens as Markdown" fallback for documents whose markdown can't
round-trip through the block model.

## Decision & content-safety note

The `.markdown` editing mode doubled as a content-preservation fallback:
`install()` set `openInMarkdownMode` when the loaded markdown didn't survive a
block round-trip, and editing then opened directly in the markdown source view so
a full-overwrite save couldn't normalize the content. Removing it was chosen
deliberately (full removal, not just hiding the toggle), accepting that:

- Unmodeled content is **still** preserved verbatim as `.unknown` blocks — that
  path is untouched.
- The residual risk is that *known* constructs (e.g. `*`→`-` bullets, ordered-list
  renumbering) can be normalized on the first edit+save of a non-round-tripping
  document. This already happens today the moment such a document is edited in
  blocks mode; removing the fallback just means it is the default surface.

To keep as much safety as is cheap, `rawMarkdown` is **retained as an internal,
non-editable field**. Reading-mode paths still treat it as the authoritative
loaded source:

- `currentMarkdown()` in `.reading` returns `rawMarkdown` (not a re-serialization).
- A photo upload that completes *after* the editing session ends appends to that
  source (`insertImageBlock`'s `.reading` branch). That branch is reachable **only
  after `finishEditing`**, so the preservation depends on `finishEditing` **not**
  clobbering `rawMarkdown` on a no-edit session: it re-syncs `rawMarkdown` to the
  serialized blocks only when they actually diverged from the loaded source
  (comparing serializations, so canonicalization alone is not a divergence). An
  untouched non-round-tripping document therefore keeps its original source, and a
  late insert appends to it rather than to the normalized serialization. Once the
  user genuinely edits, the edited blocks are the content and the resync is correct.

## Changes

### Deleted
- `Schrift/Features/Editor/MarkdownSourceView.swift` — the markdown source editing
  surface. (`project.yml` globs `path: Schrift`, so no project change.)

### `EditorViewModel.swift`
- `enum Mode` — drop `.markdown` (keep `.reading`, `.blocks`).
- Remove `openInMarkdownMode`.
- `install(...)` — drop the `openInMarkdownMode` computation; baseline becomes
  `savedMarkdown = serializeMarkdown(blocks)`.
- `startEditing(...)` — `mode = .blocks` (both the empty-seed and normal paths).
- `finishEditing()` — drop the `.markdown` branch; re-sync
  `rawMarkdown = serializeMarkdown(blocks)` **only when the blocks diverged** from
  the loaded source (`serializeMarkdown(blocks) != serializeMarkdown(parseEditorBlocks(rawMarkdown))`),
  so a no-edit session leaves the authoritative source intact.
- Remove `setMode(_:)`.
- `applyInlineMarker(_:)` — drop the `.markdown` branch.
- `insertImageBlock(url:)` — drop the `.markdown` branch (keep `.reading` + blocks).
- Remove the now-dead `insertAtCursor(_:)`, `markdownReplacingSelection(with:)`,
  `updateRawMarkdown(_:)`.
- `currentMarkdown()` — logic unchanged (`.blocks` → serialize, else `rawMarkdown`);
  refresh the doc comment (no more markdown mode).

### `EditorFormattingBar.swift`
- Remove `isMarkdownMode`; `hasTarget = focusedBlockID != nil`.
- Each button keeps only its blocks-mode action (drop the `insertAtCursor`
  branches).
- Link button `disabled = !viewModel.canEditLink`.

### `EditorModeBar.swift`
- Remove the `SegmentedControl` and the `modeIndex` binding; keep
  `SaveStatusIndicator`. Rename the type to `EditorSaveBar` (the "mode" concept is
  gone) and update `#Preview`.

### `EditorView.swift`
- `editingSurface` — drop the mode binding (use `EditorSaveBar`), remove the
  "opens as Markdown" note, render `BlockEditorView` directly, simplify the
  slash-menu guard to `if let query = viewModel.slashQueryText`.

### Tests
- Delete markdown-mode-only tests: `testSwitchingToMarkdownSerializesBlocks`,
  `testSwitchingBackToBlocksReparsesMarkdown`, `testCurrentMarkdownFollowsTheActiveMode`,
  `testLoadDefaultsToMarkdownModeWhenRoundTripUnsafe`, `testInsertAtCursorInMarkdownMode`,
  `testInsertPhotoFlushesTheSaveImmediatelyFromMarkdownMode`,
  `testLinkEditingIsUnavailableInMarkdownSourceMode`.
- Rewrite `testInsertPhotoPreservesALossySourceAuthoredDuringTheSession` to set up
  via a **loaded** lossy source (no `mode = .markdown`), still asserting the
  reading-mode insert preserves the authoritative source.
- Drop `.markdown` from `EditorFormattingBarTests`' mode iteration.
- Remove the `openInMarkdownMode` assertions in `EditorViewModelTests` /
  `EditorPhotoInsertionTests` (adapt the surrounding tests to blocks mode).
- Add regression tests for the removal's residual invariants: a non-round-trippable
  doc opened in blocks mode and closed **without** an edit enqueues no save
  (`savedMarkdown` baseline), a no-edit session then preserves the original source
  through a late photo insert, and an edited session re-syncs `currentMarkdown()` to
  the edited blocks.

### Docs (living, updated in lockstep)
- `CLAUDE.md` — drop "Markdown toggle" from the `Editor/` repo-layout line.
- `docs/superpowers/specs/2026-07-03-instant-local-doc-content-design.md` — the
  `install(...)` / `applyPendingUpdate()` / test-scenario references to
  `openInMarkdownMode` are updated to the unconditional `savedMarkdown` baseline,
  with a dated `Revised (2026-07-10)` note at the top.

### Kept
- All other `Markdown*` files (parser, serializer, shortcuts, block view, link
  editing) — core block-editor machinery, not the editing *mode*.
- `markdownSurvivesRoundTrip` — a tested pure round-trip-fidelity utility, no
  longer consulted for mode selection.
