# PR-1: Image Block Round-Trip Fidelity — Implementation Plan

> **Amendment (2026-07-07, on completion).** Task 1's fixture capture against
> real `@blocknote/core@0.51.4` corrected one plan assumption: the image block's
> `previewWidth` is **not omitted** when unset — the library emits it with a JS
> `undefined` value (lib0 `writeAny` byte `0x7f`) right after `showPreview`. The
> shipped code therefore adds a `YAnyValue.undefined` case and includes
> `("previewWidth", .undefined)` in both the golden fixture
> (`YjsEncoderTests.testImageBlockIsLeafWithProps`) and the `MarkdownYjs` image
> mapping. The `alt → name` mapping was confirmed from the library source
> (`img.alt = props.name`). All 14 pre-existing golden-hex tests pass
> byte-unchanged. Because adding the `.image` enum case breaks every exhaustive
> `BlockKind` switch at once, the work shipped as two buildable commits
> (encoder leaf-with-props; then the `.image` case + parser/serializer/mapping/
> views/VM) rather than the per-task commits sketched below. The rest of the plan
> shipped as written.

**Goal:** Make a standalone `![alt](url)` line a first-class `.image` block through the whole pipeline (parse → serialize → Yjs encode → render), so a web-authored image survives an in-app edit-and-save instead of being flattened to literal text.

**Architecture:** Add `case image(alt: String, url: String)` to `BlockKind`; classify standalone http(s) image lines in the parser's `parseClassifiedLine` chain (which automatically keeps `canonicalizeLine`/`markdownSurvivesRoundTrip` consistent); serialize back byte-exactly; generalize the Yjs encoder so a leaf block (no `xmlText` child) can still carry props — a restructure that is provably byte-neutral for all existing golden fixtures; capture the real BlockNote 0.51.4 image-block byte layout empirically and lock it with a new golden test.

**Tech Stack:** Swift 6, XCTest, XcodeGen, hand-written Yjs encoder in `Core/Yjs`. One throwaway Node script (yjs + `@blocknote/core@0.51.4`) in the session scratchpad for fixture capture — never committed.

## Global Constraints

- **The 14 existing golden-hex tests in `SchriftTests/Core/Yjs/YjsEncoderTests.swift` must pass byte-unchanged.** If any existing fixture's bytes change, STOP and get human sign-off (CLAUDE.md safety rule).
- **STOP CONDITION:** if Task 1 cannot byte-match the real yjs/BlockNote output for an image block, PR-1 stops here and we reassess. We do not ship a writer that emits an image block the web can't read.
- BlockNote reference version: **`@blocknote/core` 0.51.4** — the exact version pinned by the La Suite Docs frontend (`src/frontend/apps/impress/package.json`). The fixture must be generated with this version.
- Verified image propSchema at 0.51.4: `textAlignment` ("left"), `backgroundColor` ("default"), `name` (""), `url` (""), `caption` (""), `showPreview` (true), `previewWidth` (optional number, default `undefined`). There is **no `textColor`** on the image block.
- `alt`/`url` are stored as **raw `String`**, never round-tripped through `URL` — the backend's `extract_attachments()` regex-matches the embedded value, so it must survive byte-for-byte.
- Zero third-party runtime dependencies. XCTest only. Format with `swift format --recursive --in-place Schrift SchriftTests` before pushing.
- Project is generated: run `xcodegen generate` before any `xcodebuild`.
- PR title (Conventional Commit): `feat: make standalone images first-class blocks that survive saves`.
- Recorded YAGNI decisions (do NOT implement): no relative-URL resolution in the read view (relative/ambiguous lines stay `.unknown` verbatim); no editable captions; no numeric `previewWidth` support (it is always emitted as `undefined`).

## Tasks

1. **Capture the golden image-block fixture** from real yjs + BlockNote 0.51.4 (throwaway Node script in the scratchpad). Validate the harness by reproducing an existing golden (`testParagraph` and `testDividerHasNoTextChild` both reproduced byte-exactly), then capture the one-image doc's bytes and record prop order + `previewWidth` handling. STOP CONDITION lives here.
2. **`.image` BlockKind, parser classifier, serializer.** `case image(alt:url:)`; `parseImageLine(_:) -> (alt: String, url: String)?` in `MarkdownParser.swift` added to `parseClassifiedLine`; `serializeBlock` emits `![alt](url)`.
3. **Encoder — leaf blocks with props, image mapping, golden fixture.** Hoist the prop loop out of the text-child branch (byte-neutral); `hasTextChild` excludes `image`; `MarkdownYjs.map` emits the `image` node; new golden locks the bytes.
4. **Editor UI and view-model behavior for `.image`.** Read-mode + edit-mode rendering as a non-editable leaf; delete-as-a-unit; never converted; never receives inline markers.
5. **Docs, formatting, full suite, PR + review loop.**

## Self-review notes

- Spec coverage: data model, parser, serializer, encoder, read view, edit view, stop condition, tests, and the regression bug-fix test (a standalone image maps to an `image` node, not a literal-text paragraph) are all covered.
- Type consistency: `.image(alt: String, url: String)` and `parseImageLine(_:) -> (alt: String, url: String)?` used identically across parser, serializer, encoder mapping, views, and view model.
