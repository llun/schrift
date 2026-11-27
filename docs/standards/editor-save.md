# Editor & the on-device save (`Core/Yjs`)

- **Hide completed is a reading presentation preference, off by default and local
  to the editor session.** `ChecklistReadingPresentation` derives visible rows,
  hidden count and original source indices from the current full `blocks`; everything
  nested under a hidden item (its `indent` subtree: list items and the nested
  image/attachment/link leaves among them) and the *flat* (indent-zero)
  image/attachment leaves directly after it are hidden along with it (up to the first
  non-media block — the server export flattens a nested photo to exactly that shape;
  a nested leaf after the subtree is a sibling under another parent and stays; a
  queued-photo placeholder always stays visible, even inside a hidden subtree, without
  ending it), while the count stays items-only; never
  replace the model array or feed that projection to the serializer, save coordinator
  or collaboration bridge. Toggling must not call a dirty/save/live-write funnel.
  A tick made on the reading surface while hiding stays on screen, checked, for a
  short beat (`ChecklistSettling`, honoured by the presentation's `settling` ids) and
  only then hides inside the collapse animation — never tick and hide in one
  transaction, or the row animates out still drawn unticked.
  Editing always exposes every block. The reading controls remain reachable when
  all items are hidden; an all-hidden list is not an empty document. Preserve
  `EditorBlockAdornment`'s first-line alignment and dense hit-target rules.
  Reading checklist chrome and hidden rows make the two canvases unequal, so their
  mode handoff snapshots measured visible block IDs, preferring the next visible
  survivor (then previous) when Done hides the anchor. Ordinary documents retain
  the offset handoff below. Verify production EditorView scrolling and reveal at
  default/accessibility sizes, beyond pure projection tests.
- **List items and media leaves nest through `EditorBlock.indent`, never a tree.**
  The editor's `blocks` stay flat; a block is a child of the nearest earlier list
  item one level shallower. Two kinds nest: bullet/numbered/checklist items, and
  **leaves** (`blockNestsAsLeaf`: an image, an attachment, or a paragraph that is
  nothing but one `[label](url)` link — the origin-less spelling of an attachment,
  which must nest exactly as the attachment does). `normalizedListIndents` is the
  invariant: each nesting block is clamped to `nestingBase` of the block above
  (one level under a list item, level with a nested leaf — a leaf never has
  children — zero after anything else), at most `maxListIndent`; everything else is
  zero. A document with no nested leaves normalizes exactly as before. `markDirty`
  re-applies it after every edit — so no mutator has to reason about the items
  around it, and a new mutator must keep funnelling through `markDirty`.
  Indent/outdent (`shiftingListItem`) moves an item **with its subtree**, nested
  leaves included (`listSubtreeEnd`). A leaf has its own pure indent/outdent
  (`leafIndentRange`, `indentingLeaf`, `outdentingLeaf`, behind
  `EditorViewModel.indentLeaf`/`outdentLeaf`): its range's lower bound is the next
  block's indent when that block is a nested sibling (leaf or item), so a leaf
  never orphans the siblings after it — outdenting past that bound moves the leaf
  to just after its parent's subtree instead. `moveBlock` re-levels a moved leaf
  (`movedLeafIndent`: it joins nested children it lands among, otherwise keeps its
  level where the block above allows it; an optional `indent:` is clamped). Tab is
  consumed on every list item even when it can't move, so a list
  never gets a literal tab. Both surfaces inset a row — leaf rows included, on both
  reading and editing surfaces and the queued-photo card — by
  `EditorBlockMetrics.listIndentInset(indent)` **unconditionally** (zero at the top),
  so indenting never changes the row's structure or recreates its `UITextView`.
  `numberedIndex` counts per level, skipping deeper items and deeper nested
  leaves (a photo under item 1 does not restart item 2). Nesting has **no
  live-write spelling** (`BlockNoteWrite` can *insert* a nested subtree — the Docs 6
  save opts in with `allowsNestedInserts: true`; the live path's default refuses one —
  but diffs only a flat list; the projection reads a
  nested `blockGroup` as opaque), so `markDirty` sets `hasUnmodelableLocalEdit` and
  takes the classic path while any block is nested (`nestsBlocks`, keyed on
  `indent > 0`, so a nested leaf latches it too) — keep that if you touch it.
  **A nested link line that an edit leaves unable to nest steps out *past* its
  nested siblings** (`detachingUnnestableBlocks`, via the editor's
  `detachBlocksThatNoLongerNest` before `markDirty`): typing past the link, cutting
  it with Return, merging prose into it, an inline marker, removing the link, or
  converting it to a heading. Normalization would otherwise zero it *in place*, end
  the list there and flatten every nested sibling after it — a photo under the same
  item. An edit that keeps it a link line keeps its level; Return at its end puts the
  new empty line past the nested run (a nested paragraph has no markdown spelling);
  backspace at its start outdents it (`outdentingLeaf`) before it merges into
  anything, the way a nested list item steps out first. `convertBlock` detaches only
  a block that *was* a nested leaf — a nested list item converted to a paragraph
  keeps its old in-place behaviour.
- **The server's markdown export flattens nested leaves; a JSON read overlay
  restores them.** BlockNote 0.51.4's `blocksToMarkdownLossy` prints a photo
  or file nested under a list item as a column-zero line after a blank one — and
  restarts the list it interrupted at the top level (`* a` with children
  `[image, * b]` exports as `* a`, the image, `* b`, all flat; the items after the
  break keep their depth *relative to the first one*, so `T{img, Sub{SubSub}}`
  exports `* Sub` flat and `  * SubSub` one level under it). So the markdown from
  `formatted-content/` carries a nested leaf **flat**, and the parser keeps that
  shape flat. The nested spelling the parser reads (`parseNestedLeaf`) is the app's
  own, written by `serializeMarkdown`: tight, at the parent's content column, no
  blank line (`- [ ] Task\n  ![photo.png](url)\n  [report.pdf](url)\n- [ ] Next\n`).
  **The editor's content reads put the nesting back** from the document's BlockNote
  tree (`DocsAPIClient.formattedContentTree` → `formatted-content/?content_format=json`,
  whose `content` is the block array with `children`): `EditorViewModel
  .recoveringLeafNesting` runs between the content fetch and `apply`/`installFetched`
  at all three fetch sites (open/revalidate, pull-to-refresh, keep-the-server), so
  install, cache, baseline and every comparison see one body. It asks only when
  `markdownMayHideLeafNesting` (a leaf directly after a list item — the only shape the
  flattening produces) and the read is still permitted, and every failure — transport,
  decode, a tree whose `updated_at` differs from the markdown's, a tree that does not
  fit — installs the flat export exactly as before; it never throws. The overlay
  (`leafNestingOverlay`, `LeafNestingOverlay.swift`) is pure and answers **three
  ways**: `.recovered(markdown:)` (the tree restores nesting), `.confirmedFlat` (the
  tree was read, matches, and nests nothing but the list items the export already
  shows) and `.unknown` (everything else — every failure above included). It is
  **all-or-nothing**: list items (by kind), images and attachments are *anchors*,
  both sides list theirs in document order (the tree pre-order, with depth), and the
  sequences must match exactly; every anchor must sit under list items only in the
  tree; each anchored block takes its tree depth (list items the export pulled up
  included), `normalizedListIndents` must keep every one of them, and the result must
  read back as the markdown under the export's flattening and round-trip through the
  parser — else `.unknown`, and the flat body is installed. A tree that nests
  something the export cannot show and the overlay cannot restore (a paragraph or a
  preview `pdf` under an item) is `.unknown`, never `.confirmedFlat`. Media nodes that export nothing
  (a docs `pdf` with the default `showPreview`, a url-less placeholder) are not
  anchors; a `video` anchors as an image (it exports image syntax); a link-only
  paragraph and an off-origin file are not anchors, so a tree `file` whose url is not
  this server's declines the whole overlay. The tree decode is minimal, defensive and
  **depth-capped** (`BlockNoteTreeNode.maxNestingDepth`, 64 → `.decoding`), the
  `Lib0Decoder` lesson. Because a body cached flat compares equal to its restored
  revalidation, `reconcileClean` installs a fetch that *adds* leaf nesting
  (`fetchedMarkdownRevealsLeafNesting`) on a clean, non-editing screen even though
  `serverChanged` says no. That check compares against **`serializeMarkdown(blocks)`,
  never `displayedSourceMarkdown`**: a reveal that lands mid-edit is deferred, but the
  clean branch's fallthrough still converges the comparison basis on the nested
  spelling while the blocks stay flat, so a basis-keyed check short-circuited on every
  later fetch — the nesting was never shown and the next edit's save un-nested it on the
  server. Keyed on the blocks, the first read after Done installs it (and it reveals
  `serverCopy`, so a follow-up read whose tree fails still carries it). The reverse
  needs **positive evidence**: only
  `.confirmedFlat` installs a flat body over a screen that nests a leaf (a co-author
  un-nested it on the web), again only clean and outside an editing session. An
  `.unknown` flat read is *not* evidence — it is what a transient failure, a server
  without the JSON format and a stale pairing all produce — so it never un-nests the
  screen, and `serverCopyKeepingLeafNesting` keeps the nested spelling of the same
  content in the cache and the baseline too (`reconcileClean`, `cacheServerCopy`, and
  `installFetched` against the cached copy — which is what "Keep the server version"
  installs through); without that, one failed tree read rewrote
  the cached nesting flat and the next (offline) open showed it flat. Because the two spellings differ, `canonicalMarkdown` is
  **leaf-nesting insensitive**: it runs both sides through `flattenedLikeServerExport`,
  the model of exactly what the export does (verified against
  `@blocknote/server-util` on every shape in `LeafNestingOverlayTests`; zeroing leaf
  indents and renormalizing instead re-attaches a *second* sibling after the leaf,
  which the export does not), so a draft holding nested leaves never reads as
  diverged from the server's flat export of the body it pushed — no false conflicts,
  no "server changed" churn. The cost is that a change that only nests or un-nests a
  leaf is invisible to those comparisons, which is why only the tree's verdict moves
  it. A first open with no cached copy and an `.unknown` read still shows the flat
  export, exactly as before the overlay.
- **Only leaf blocks are draggable in edit mode.** A long press on a divider,
  image or attachment (`blockIsReorderable`) picks it up; on a text row the same
  press belongs to `UITextView`, so don't extend the gesture there without a
  separate handle. The gesture is a UIKit long press (`BlockReorderGesture`), not
  a SwiftUI `DragGesture`, for the same scroll-arbitration reason as
  `SwipeRevealGesture`. The drop index is the pure `blockReorderDestination`
  (a row the lazy canvas hasn't realized keeps its original side), applied by
  `EditorViewModel.moveBlock`, an ordinary edit that keeps the block's id. The
  drop math reads the dragged row's centre once, at `.began`, and skips that row
  when counting: its recorded frame *does* follow the drag offset, so reading
  `blockFrames[draggedID]` at drop time would count the translation twice.
  **The drag has a horizontal component for images and attachments only** (a
  divider never nests — `blockNestsAsLeaf`): the recognizer reports a `CGSize`
  (window-space, like the vertical), `leafDragIndentSteps` turns the width into
  whole levels of `EditorBlockMetrics.listIndentStep` (flipped under right-to-left —
  unit-tested only; the RTL drag still needs on-device verification),
  and `leafDragPreviewIndent` adds them to the level a plain move to the *live*
  destination gives (`movedLeafIndent`), clamped into `leafIndentRange` **evaluated
  in the array after the move** — never the range where the leaf stood. The row
  previews the level with an x offset and a `.selection` tick; drop calls
  `moveBlock(blockID:to:indent:)` (a slide alone moves to the same index). Keep
  the clamp: an unclamped level strands the leaf or orphans its later siblings.
  VoiceOver reaches the same edit through Indent / Outdent actions on the row
  (`indentLeaf` / `outdentLeaf`, gated by `canIndentLeaf` / `canOutdentLeaf`).
- **The editor draws every document twice, and `EditorBlockStyle` is the only
  thing keeping the two drawings the same.** The reading surface is SwiftUI
  `Text` (`MarkdownBlockView`) and the editing surface a UIKit `UITextView`
  (`BlockTextView`); those are different frameworks with different font and
  layout APIs, so each used to carry its own copy of what a block looks like —
  and the copies drifted until tapping a paragraph re-laid-out the entire page
  (22pt vs 16pt gutter, so every line re-wrapped and slid 6pt left; 12pt vs 6pt
  between blocks, cumulative; a whole header metadata row with no editing
  counterpart; a quote losing its panel and its brand bar; a prose `.unknown`
  block turning into monospace in a panel; a 20pt checkbox shrinking to 17pt; a
  completed to-do losing its strikethrough), and then jumped *again* on the first
  keystroke when the save-status strip appeared above the canvas.
  **So: never reach for a `DocsFont`/`DocsSpacing`/`DocsColor` token directly to
  decide how a block's *text* is drawn, or how the row around it is spaced.**
  That is the part that drifted, and it goes through
  `Schrift/Features/Editor/EditorBlockStyle.swift`. (The leaf arms — divider,
  image, attachment, and the two "this url is not ours" text fallbacks — do name
  tokens directly, in both surfaces, and that is fine precisely because *both*
  name the same ones and `testLeafRowsOccupyTheSameHeightOnBothSurfaces`
  measures those rows on both surfaces — a claim that was false when first
  written, because the parity fixtures were built from "every kind that carries
  text" and so contained no leaf at all. If you add a leaf kind, add it there. A token in a
  leaf is a shared constant; a token deciding a text row's font is a second copy
  of the table.)
  - `EditorBlockMetrics` — gutter (`DocsSpacing.gutter`, the app-wide page inset
    the editor's own error banner and formatting bar already used), inter-block
    gap, adornment gap, checkbox size + hit padding, quote/panel padding,
    divider padding, header spacings.
  - `blockTextAppearance(for:text:)` → raw tokens, converted to `Font`/`Color`
    by the reading surface and to `UIFont`/`UIColor` by `blockTextStyling` (the
    raw-value split the design-system style resolvers use). It takes the
    **text**, not just the kind, because `.unknown` is the one kind whose
    appearance depends on it — a paragraph that merely spilled across lines is
    body prose on both surfaces, and only a table/HTML fragment is verbatim
    monospace in a panel. `blockTextStyling` therefore takes the whole
    `EditorBlock`; its `isCodeLike`/`allowsNewlines` deliberately stay keyed to
    the **kind**, because a prose `.unknown` is still literal multi-line text
    however it is drawn.
  - `editorBlockDecoration(_:)` — the quote bar and the verbatim panel, as **one
    modifier both surfaces apply**. It varies only padding/background/overlay
    *values*; a structural branch there would recreate the `UITextView` and drop
    the keyboard on every `- `/slash/toolbar conversion (the standing rule that
    every editable kind shares one structural shape).
  - `EditorBlockAdornment` — bullet, number, checkbox. The checkbox is a
    `Button` where a toggle closure is supplied, including both production
    surfaces; reading has a separate text tap to enter editing. The symmetric
    positive/negative padding pairs grow the target and give every point back,
    so callers without a toggle callback occupy identical space. It is 24pt — larger than either
    surface used to draw it, since it is the document's one touchable adornment.
    Horizontal growth uses `checkboxHitPadding`; vertical growth uses
    `checkboxVerticalHitPadding`, half the block gap, so targets fit the row
    pitch without overlap. Check real taps near adjacent-row boundaries, not
    just the dimensions of an isolated padded glyph. The normal scheme includes
    `SchriftChecklistUITests/ChecklistHitTests` for those actual row-edge taps.
    Checklist rows use `checklistFirstLine`, centering the Material glyph's
    actual font bounds on the first text line's capital-height center. Reading
    uses SwiftUI's first baseline; editing uses the zero-inset text view's
    ascender. These metrics live in `EditorBlockStyle` and scale with Dynamic
    Type. Do not substitute top alignment or a fixed 44pt box: equal row heights
    do not prove first-line alignment. `ChecklistPresentationTests` measures
    visible glyph/text pixels on both real surfaces for checked/unchecked,
    single/wrapped, default/accessibility cases, and exercises the hosted editor
    through toggle, end typing, formatting, and mode transitions.
    A non-scrolling `BlockTextView` must hide its own four `UIScrollEdgeEffect`s;
    the enclosing document scroll view owns scroll-edge chrome. On iOS 27,
    disabling scrolling alone leaves automatic edge blur active in isolated
    hosted rows. It obscures capital glyphs and can hide the first line entirely,
    making a pixel test report the second line as a displaced first line. This
    is an edge-effect rendering failure, not changed checkbox alignment metrics;
    the normal dense outer-scroll fixture was already sharp. Keep the 1pt
    alignment assertion, check complete capital-glyph ink height, and compare
    visible editing line count with TextKit's laid-out lines before interpreting
    an alignment failure. Do not fix this by shifting the checkbox or relaxing
    tolerances. The document's outer scroll effects remain enabled.
  - `EditorDocumentHeader` — the title plus the reach/status/presence row, drawn
    by **both** surfaces (`readingHeader` and the header `BlockEditorView` is
    handed). An untitled document shows the same "Untitled" placeholder on both;
    rendering an empty `Text` on one side and a placeholder on the other made the
    body move by a title's height on the swap.
- **The save status lives in that shared header's status slot, not in a strip
  above the canvas.** `saveStatusDisplay`'s precedence is untouched — a recorded
  conflict still refuses to claim a sync or to offer a retry that would only
  re-park — but `.none` now falls through to the reading sync caption instead of
  collapsing, so the slot is never empty and never changes height mid-keystroke.
  The trade is deliberate and worth knowing: the status **scrolls with the
  document** rather than staying pinned. Nothing becomes unreachable — the
  toolbar keeps **Done**, which flushes exactly as tapping **Save** does. Don't
  reintroduce a pinned strip without giving the reading surface an identically
  sized one, or the jump comes straight back.
- **Scroll position must survive the mode swap, and three separate things had to
  be right before it did.** The two surfaces are different `ScrollView`s, so the
  offset was simply discarded: tapping a paragraph three screens down opened the
  editor at the very top with the tapped block nowhere on screen. Every part of
  the fix below was **disproved on a device first** — each looked correct and did
  nothing:
  1. **Not `.scrollPosition(id:)`.** It reports the id of the item the scroll
     view is *aligned* to, and free-scrolling content is almost never aligned to
     one, so the binding stayed nil. The handoff is a raw **content offset**
     (`onScrollGeometryChange`), which is meaningful only *because* the two
     layouts are now the same.
  2. **Snapshot the offset at the swap, never track it continuously.** A
     `ScrollView` being torn down reports a final geometry of **zero**, which
     overwrote the anchor with "the top" at exactly the moment it was needed.
     `snapshotForSwap()` is called from the reading row's tap and from the
     toolbar's Edit/Done, before the surfaces exchange.
  3. **Re-apply the restore as the lazy rows realize.** The editing canvas is a
     `LazyVStack`, so at `onAppear` it has realized one screenful and the scroll
     **clamps** to it — measured ~108pt shy on a two-screen document. A bounded
     re-apply across a few runloop turns lets each pass realize what the last one
     scrolled past. The reading surface needs none of this (plain `VStack`), and
     it must **stay** non-lazy for a different reason: `AttachmentCardView`'s
     cache revalidation depends on off-screen rows still running their `.task`.

  `EditorScrollAnchorStore` is deliberately **not `@Observable`**: the offset
  changes every scroll frame, and there is no reason for any of that to
  invalidate `EditorView`. Note the cost this avoids is smaller than it looks —
  a probe counting `markdownInlineText` calls recorded **none** across a scroll,
  because `MarkdownBlockView`'s inputs are all `Equatable` and SwiftUI skips its
  body. Keep the store non-observable anyway; the point is that nothing needs
  invalidating, not that the alternative was measured to be catastrophic.

  The residual after all three is ~37pt on a two-screen document — the same
  cumulative line-box drift documented below, not a fourth bug.
- **A block-level attribute in the editing text view belongs in
  `baseTextAttributes`, nowhere else.** `applyInlineStyling` calls
  `textStorage.setAttributes(...)` over the whole range on every keystroke's
  restyle, so an attribute applied to the marked spans — or only to
  `typingAttributes` — is wiped a character later. That function takes the whole
  `BlockTextStyling` rather than the two or three fields it happens to need, so a
  new appearance field cannot be silently dropped at that call site.
- **Presence is drawn once, in the shared header, on both surfaces.** The
  Options button used to carry a count badge while editing because the editing
  canvas had no `PresenceBar`; it has one now, so the badge was a duplicate and
  is gone. `presentedPeerCount` (renamed from `presenceBadgeCount`) stays as the freshness rule (peer state is only
  as fresh as the last socket message, so offline suppresses it) and now gates
  the header's bar on **both** surfaces — the reading one previously drew its
  avatars offline. Don't re-add a second presence affordance to one mode only:
  that asymmetry is what the shared header exists to prevent.
- **The scroll anchor degrades, it never corrupts.** `install(...)` gives every
  block whose content changed a fresh `EditorBlock.id` (only unchanged blocks keep
  theirs — see the next bullet), so an anchor naming an edited block can go stale
  after a remote change; an unresolvable id simply scrolls nowhere and the surface
  opens where it is. `.header` and `.trailer` are stable across that, and the
  reading surface's own `.refreshable` is only reachable from the top, where the
  anchor is `.header`. Worth knowing before "fixing" a report of the editor
  opening at the top after a co-author's edit.
- **`install(...)` keeps the id of every unchanged block** (`reusingBlockIDs`,
  `EditorBlock.swift`): an LCS of old and new blocks under content equality (kind,
  text, indent), after trimming the common prefix and suffix. Re-minting every id
  made a one-paragraph revalidation re-identify the whole document — every row of
  the reading surface and the editing canvas rebuilt (a flash) and every block
  anchor stranded. Matching is **content equality only**: a changed, inserted or
  moved block still gets a fresh id, never a positional reuse, because an id is
  also the canvas's native text-view identity (`inputRowID`) and a surviving
  `UITextView` must not be handed a block whose text changed under it. A body with
  identical content leaves `blocks` unassigned. Everything else `install` does is
  unchanged — caret/focus/selection still clear, the dirty baseline and the
  round-trip source are still reset — and `inputRowIDs` is now **kept** rather than
  reset, so a surviving block keeps its row and a dead id stays reserved.
- **Known, accepted residual — an `.unknown` block can restyle mid-keystroke.**
  Its appearance follows its *text* (`unknownRendersAsProse`, per-line), so
  indenting the first line of a prose `.unknown`, or starting one with `|`/`<`,
  flips it to monospace in a panel under the caret. The alternative is what
  `main` did — style every `.unknown` as code unconditionally — which is what
  made tapping *any* prose `.unknown` reflow it, the defect this whole change
  exists to remove. A rare flip while typing a structural character beats a
  certain one on every tap, and the reading surface has always worked this way.
- **A table is drawn as a grid while reading, and edited as markdown.** A GFM
  table stays one `.unknown` block (its source is saved back verbatim); only
  `MarkdownBlockView` reinterprets it, via `parseMarkdownTable` and
  `MarkdownTableView` (`MarkdownTable.swift`), when the block's text is cleanly a
  table — anything else keeps the verbatim panel. Tapping it enters the editor,
  which shows the source in the panel, so a table is the one block whose height
  changes between surfaces — accepted, since editing it is editing its markdown.
  Columns share the width like a web table's and scroll sideways once they
  can't each keep `MarkdownTableColumnWidths.minimumColumnWidth`.
- **Known, accepted residual — the two frameworks' line boxes.** A SwiftUI
  `Text` carries slightly more leading than the same font in a `UITextView` with
  `lineFragmentPadding` and `textContainerInset` zeroed: measured at the Large
  content size, ~3.7pt at body 17 and ~7.3pt at title1 28, **per wrapped line**.
  So a paragraph is a hair shorter while editing. Single-line *adorned* rows
  (bullet, number, checklist) are equal because the SwiftUI adornment sets their
  height on both sides; wrapped rows can still accumulate the text-leading
  residual. Checklist first-line alignment is tested separately from row height.
  `EditorSurfaceParityTests
  .testEveryBlockOccupiesTheSameHeightOnBothSurfaces` hosts the real
  `MarkdownBlockView` against the real `BlockEditorRow` (which is internal for
  exactly this) and bounds the residual at `0.35 × the block's font size × its
  line count`, with a hard `delta >= 0` on the other side — an editing row that
  is *taller* means it has grown chrome the reading one lacks. Both historical
  offenders are caught by that band and were mutation-checked: reverting the
  quote's panel reds it at 19.7pt against a 5.95pt allowance, and reverting the
  `.unknown` prose treatment reds the `>= 0` side at −14.7pt. Closing the
  residual would mean reverse-engineering SwiftUI's line metrics into the text
  container's insets; don't, without evidence.
- **Known, accepted difference:** the reading surface autolinks bare URLs
  (`NSDataDetector`) and the editing surface does not, so a bare `https://…` is
  brand-coloured while reading and plain while editing. Closing it would mean
  teaching `InlineMarkdown` — the scanner the full-overwrite save re-parses — a
  construct it does not model, which is not worth a colour difference on one run
  with no reflow — `styleLinks` paints every link run, autolinked ones included,
  so the bare URL differs by an underline as well as a colour, and neither moves
  a glyph. Explicit `[label](url)` links *do* match: `markdownInlineText` paints
  them `textBrand` + single-underlined, as `InlineTextStyleResolver` does — except
  a link to another document on this server, which is a page chip on both
  surfaces (next bullet). A bare *document* URL is never a chip: a link run
  whose visible text is its own URL is never chip-marked (the system parser may
  autolink it before we do), so only an explicit link can add the chip's icon width.
- **A document link is a "page chip" on both surfaces, and it is display only.**
  `Features/Editor/DocumentLinkChip.swift`: rounded `brandFillSubtle` background,
  `textBrand` ink, **no underline**, a `description` (page) glyph before the title;
  external links keep the underline. Which links qualify is `isDocumentLink`, the
  exact rule `documentLinkAction` opens in-app (`DocumentLink.swift` — one rule,
  not two); the host comes from the required `serverOrigin` via
  `documentLinkHost(forOrigin:)`. The markdown never changes. **Reading** splits
  `markdownInlineText`'s output (`DocumentLinkChipAttribute`) into
  `inlineTextSegments`, composes icon image + word joiner + title by
  interpolation, and a `TextRenderer` (`DocumentLinkChipRenderer`, applied only
  to blocks with a chip) fills the backgrounds. **Editing** keeps the buffer
  byte-identical: the link's hidden `[` becomes a `.controlCharacter` glyph laid
  out as `.whitespace` `slotWidth` wide (`boundingBoxForControlGlyphAt`), and
  `DocumentLinkChipLayoutManager` paints the background and draws the icon into
  that slot — no character inserted, no offset map. Both reserve exactly
  `DocumentLinkChipMetrics.slotWidth` (whole points) and place the icon in
  `DocumentLinkChipIconBand` (inside the font's line box), so a line wraps at the
  same word and stays the same height on the swap
  (`EditorSurfaceParityTests`, `BlockTextRenderingTests`). While an IME is
  composing, `applyInlineStyling` restyles nothing (marked characters,
  attributes and selection are UIKit's) but recomputes the glyph pass's state
  from the current buffer (`refreshHiddenSyntaxWhileComposing`): `hiddenRanges`
  becomes the current syntax minus any range the marked text intersects (a
  composed character is never hidden; an adjacent `](url)` stays hidden), and a
  chip is kept only where its link does not overlap the marked text and its `[`
  is in that new hidden syntax. It then invalidates glyphs and layout for the
  whole block — glyph properties only, never text, attributes or selection — so
  nothing depends on whether TextKit shifted or regenerated glyphs after the
  edit, and syntax and chips before or after the composition stay hidden at
  their shifted indexes instead of re-wrapping the line on every CJK keystroke.
  A dropped chip returns on the first restyle after commit. A block with no chip
  before or after the keystroke skips all of this and composes exactly as it did
  before chips existed. Accepted residuals:
  the reading icon is not itself tappable (the title is); the trailing padding
  overlaps the next character on both surfaces rather than reserving width; two
  *adjacent* links to the same document merge into one chip while reading; and a
  link glued to the preceding letter (`x[Page](…)`) may break before the icon
  while reading but not while editing; and an explicit link whose label is its own
  URL (`[https://…/docs/<id>/](same url)`) is not a chip while reading, because it
  cannot be told apart from a bare URL the parser autolinked, but it is one while editing.

The backend stores content as an opaque base64 **Yjs CRDT** blob and has **no
markdown write endpoint**. Understand this before touching the save path:

- **Read**: `GET /documents/{id}/formatted-content/?content_format=markdown`.
- **Save, pre-Docs-6** (full overwrite): editor blocks → markdown → `MarkdownYjs.encode`
  builds a **byte-exact Yjs v1 update on-device** (a hand-written lib0 encoder in
  `Core/Yjs`) → `PATCH /documents/{id}/content/` with the base64 bytes, then
  `PATCH /documents/{id}/` for the title. **Two requests, no temporary document.**
  (This replaced an older 4-request temp-document technique that some dated plan
  docs still describe.)
- **Save, Docs 6** (incremental — the route choice is under
  [Networking](networking.md#networking-corenetworking)): `GET` the collaboration server's
  gc'd state → `BlockNoteIncrementalSave` integrates it into a throwaway `YDoc`
  (fresh random client id, never one the document holds; always `destroy()`ed),
  projects it **without** an interlinking origin, aligns the markdown's blocks with
  it (`BlockNoteAlignment`: an LCS over identical visible content leaves those
  blocks untouched — a lossy block's unmodeled props/marks survive — then gaps are
  paired positionally only where the old block is `.modeled` and the new has no
  children; the rest is removed/inserted) → `BlockNoteWrite.applyEdit` → `PATCH
  {"update": base64}` — **skipped** when nothing was minted or deleted (emptiness
  is read off the store, independently of the transaction encoder's update size)
  — then the title PATCH. The **content written is exactly the markdown**,
  the same overwrite semantics as the classic save. **This is not a merge of
  co-author edits:** the save diffs the editor's *whole* document against the
  server's state *at save time*, so a concurrent edit survives only if it lands inside
  the GET→PATCH window; an edit a co-author made to a block after this user loaded the
  document is **reverted** by the save unless the draft/conflict rules
  (`draftSyncDecision`, keyed on `updated_at`) catch it first. Those rules depend on
  Docs 6 bumping the document's `updated_at` when the collaboration server stores
  content, which upstream's UPGRADE.md says happens only when the collaboration server
  is configured with **`YHUB_JWT_PRIVATE_KEY`** — without it `updated_at` stops
  following editor edits, so that is a deployment requirement. Only blocks the
  alignment can anchor are left untouched — unchanged non-opaque blocks, plus
  `unknownNode:*` and document-link blocks — **plus every server block the markdown
  cannot spell that the user left alone** (`BlockNotePreservation`): before alignment,
  each non-`.modeled` server block gets a rule for recognising its markdown *shadow* in
  the same gap (a modeled node: the same node, runs and expressible props; anything
  else: the same words in order across a run of blocks — a table's pipe lines, a
  callout's emoji paragraph, a toggle and its flattened children; a media node: one
  block naming its URL), the shadow is replaced by an exact copy of the server block,
  and the pair is forced into the alignment so `BlockNoteWrite` writes nothing for it.
  Nodes the export never spells (`invisibleNodes`: a PDF preview, page break, math,
  diagram, columns) are kept where they were when no shadow is found. The web's columns are a
  `columnList` **directly in the `blockGroup`** (no `blockContainer`), carrying its own `id`;
  `YBlockProjection` projects it opaque as `unknownNode:columnList` with that id — projected
  id-less, it tripped the empty-id refusal below and **every** save of a page with columns
  failed as `.decoding` with no HTTP failure to show (seen on TestFlight 0.103–0.106). The `.text`
  words skip inline `math` (the export drops it without a trace) — except that a math block the
  editor models as one block (a paragraph, heading, quote or childless list item, matched by `.text`)
  gets no rule when another non-invisible top-level block shares its math-free words, so it is rebuilt
  from the markdown and loses its formula (main's behaviour before inline math was kept) rather than
  taking its look-alike's place; `.invisible` blocks keep their rule and are never counted, a
  `.listTree` is already tied to its base block, and a multi-block shadow (a table) is kept — and `.exact` compares the
  replica's runs coalesced like the parser's (an underlined word mid-sentence is scrubbed into
  its own run), or an untouched paragraph holding either was rebuilt and lost it. Anything the
  user edited no longer matches and is written from the markdown as before. A **nested
  list item** gets `Rule.listTree`: kept only when one *untouched* new block has the same
  text (each node's exact runs — punctuation, marks, link targets, but not the trailing blanks the
  list parsers strip or a split only an unknown mark made; only the words when the
  replica's inline content does not read as runs, such as a mention, and then only when no
  other item or base block reads alike), the same tree of nodes (`treeShape`) **and**, node
  for node, the same expressible props as the server item, because the editor models its structure and a re-indent or a
  nested tick keeps every word yet must be written — and only where `untouched` maps that
  block to the base block the server item was (`placingListTrees`, an LCS of the server
  blocks with the base), so two look-alike siblings cannot swap on a delete or reorder. Rebuilding untouched
  ones on every save (the old behaviour) deleted the subtree a co-author was typing in:
  keystrokes landing between the GET and the PATCH were lost, and two rebuilds of one item
  from the same state left both copies (TestFlight 0.103.0,
  `testAnUntouchedNestedListItemIsLeftInPlaceForACoAuthorTypingInIt`). Still rebuilt
  from the markdown: one the user edited (re-indented, ticked, re-worded, moved); every
  one when the save has no recorded base; one whose text, tree or expressible props a
  co-author changed on the server since the base; and one whose subtree holds no text, which
  has no words to match — a rebuilt one's nested media then resets web-set props the markdown does not carry
  (an image's `caption`, `previewWidth`, `textAlignment`; a file's `caption`). **Docs 6's
  `updated_at` is not a content clock** (yhub's compaction bumps it ~10 s after edits,
  best effort; any Django PATCH, the app's own title PATCH included, bumps it at once),
  so `draftSyncDecision` rule 2 can miss a co-author's fresh edit — a known gap that needs
  a content version for the baseline, not a quick fix. Refused as
  `.decoding` (nothing PATCHed): undecodable state, pending structs, a non-canonical
  root, a non-countable `blockGroup` child, or empty/duplicate block ids — the differ
  maps old blocks to live containers by position and id. The web's document-link
  node projects opaque without an origin so it is never text-reconciled (its one
  item sits where the link text has several characters); a second projection
  **with** the origin supplies its runs so an untouched one is still anchored and
  kept as a node instead of being flattened to a plain link. Known, accepted: an
  opaque/lossy block the user *changed* is rewritten from markdown (same as the
  classic save), and a web `file` node is anchored only via its `unknownNode:` reason
  (props and runs were fully read). `saveDocumentContent`'s half-land contract is
  unchanged: throws ⇒ body unconfirmed; non-nil ⇒ body landed, title failed.
- The encoder's output **must stay byte-identical** to what the real Yjs library
  produces; it is locked by golden hex tests (`YjsEncoderTests`). Do not "clean
  up" the byte layout. Marks and block props are **ordered tuple arrays** (order
  changes the emitted bytes) — never dictionaries. Advance the Yjs clock by
  `.utf16.count` but serialize bytes as `.utf8`. Build any JSON that embeds user
  data (e.g. a link URL) with `JSONSerialization`, never string interpolation.
- **Parse markdown conservatively** so a full-overwrite save never destroys
  content: anything the editor can't model is preserved verbatim as `.unknown`
  blocks; ambiguous inline spans stay literal. The one indented line that
  classifies is a **nested list item**: a list line directly under a list item (no
  blank line, spaces only — a tab stays verbatim), at or past that item's content
  column and less than four columns past it, and no deeper than `maxListIndent`.
  `serializeMarkdown` writes it back at the parent's content column (two spaces
  under `- `, three under `1. `), which is also what the server's export emits, and
  `canonicalizeLine` strips that indentation so the round-trip gate compares the
  item itself. On save it becomes a BlockNote child in a nested `blockGroup`
  (`BlockNoteBlock.children`, golden-pinned by
  `testNestedListChildrenGoInANestedBlockGroup`) — a **saved-bytes change**, signed
  off, that replaced writing nested lines back as literal-text paragraphs. Known,
  accepted: the parser measures against the *source* marker width and the
  serializer renumbers, so a child under a wider source marker than it gets back
  (`100. a` then a 4-space `- b`) reads verbatim first and nests after one save — no
  content is lost either way. A live snapshot never persists once
  `hasUnmodelableLocalEdit` is latched: it would encode the replica without the
  nesting and overwrite the classic save.
  The other indented line that classifies is a **nested leaf** (`parseNestedLeaf`):
  an image line, or a line that is nothing but one `[label](url)` link, indented
  **exactly** to an open list item's content column (no band — the app's serializer
  is its only writer), directly under the list (no blank line), spaces only, no
  deeper than `maxListIndent`. It is read conservatively: only when the run of
  nested leaves it starts is followed by something that cannot be a lazy
  continuation of it (end of document, a blank line, a column-zero fence, divider
  or classified line, or a nested list item) — otherwise the whole run takes the
  verbatim path, so a leaf is never classified while a sibling after it is not.
  `serializeMarkdown` writes a nested leaf tight at its parent's content column; a
  non-list block after one gets a blank line (or it would read back as a lazy
  continuation), and `canonicalizeLine` strips an indented leaf-shaped line's
  indentation on both sides of the round-trip gate. The queued-photo rewriter and
  remover (`markdownRewritingPendingAttachment`/`markdownRemovingPendingAttachment`) ask the
  parser which lines are this record's image blocks (`pendingAttachmentImageLines`,
  over `parseEditorBlocksTracingLines`), so they touch a nested queued photo — or a
  nested photo would be held by the save hold but never rewritable, a permanent
  wedge — and **only** an indented line the parser nests: an indented placeholder
  anywhere else (indented code, under prose, a wrong column, after a blank line) is
  verbatim text the hold never counted, and is left byte-for-byte alone.
  **Saved bytes of server-authored content do not move.** The server's export never
  writes an image or link line at a list item's content column directly under the
  item — it prints a nested leaf at column zero after a blank line (verified against
  `@blocknote/server-util` 0.51.4 on the shapes in `LeafNestingOverlayTests`) — so
  only the app's own nested spelling classifies as a nested leaf, and every document
  the server authored parses, and re-saves, exactly as it did before.
- A standalone `![alt](url)` line with an **absolute http(s) URL** is a
  first-class `BlockKind.image(alt:url:)` block (classified in the parser's
  `parseClassifiedLine` chain via `parseImageLine`, so classification and
  `canonicalizeLine` stay consistent). `alt`/`url` are raw `String`s — **never**
  round-trip the url through `URL`; the backend's `extract_attachments()` matches
  it byte-for-byte. It maps to a real BlockNote `image` **leaf** node (the markdown
  alt becomes `name`, since BlockNote renders the `<img>` alt from `name`). The
  encoder supports leaf blocks that carry props: `hasTextChild` excludes `divider`
  **and** `image`, and props are emitted for every block. The image byte layout is
  locked by a golden fixture (`YjsEncoderTests.testImageBlockIsLeafWithProps`)
  captured from `@blocknote/core@0.51.4` (the version the docs frontend pins) —
  the image block has **no `textColor`**, and `previewWidth` is emitted as
  `undefined` (`YAnyValue.undefined` → lib0 `writeAny` 127), not omitted. In the
  editor an image renders as a **non-editable leaf** (like a divider): it deletes
  as a unit, is never converted, and never receives inline markers. Photos are
  inserted through that same block: the slash-menu "Photo" item and the
  formatting-bar button run `prepare → upload → bounded media-check poll →
  insert`, and on that path the `.image` block is created **only on success** — a
  cancelled pick is a silent no-op, every failure sets `"Couldn't add the photo. Please try
  again."`, and no half-uploaded block reaches the server. If
  readiness can't be confirmed within the poll budget, the URL derived from the
  upload key is used rather than losing an upload that already succeeded.
  `PhotosPicker` is the out-of-process system picker — **no** photo-library usage
  description and **no** `project.yml` change (never pass `photoLibrary:`, which
  makes it in-process and *would* need one). `preparedJPEGData` rebuilds the upload
  from a bare `CGImage`, passing only the compression quality, so the original
  photo's EXIF — **including GPS coordinates** — is dropped: never copy the source
  properties into `CGImageDestinationAddImage` (locked by
  `ImagePreparationTests.testStripsGPSAndIdentifyingMetadata`). **Both** insert
  paths (blocks, reading) must verify the edit actually *added* an
  `.image` block before committing it — there were three until the Markdown source
  tab was removed (#52), which took the raw-markdown path and its guard with it — a fenced code block, open at the tail,
  wrapping the caret, or formed by a neighbouring block on serialization, swallows
  the image line, and `MarkdownYjs.encode` re-parses the same markdown the save
  sends. Never rewrite the source to make room; surface the friendly error. Anything
  ambiguous stays `.unknown` and renders **verbatim**: a relative url, an
  indented line, trailing text, a `]` in the alt, or a url with whitespace or
  unbalanced parens. The last one is load-bearing — `URL(string:)` accepts `(`
  and `)`, and the classifier splits on the line's *last* `)` while CommonMark
  ends the destination at the first *unbalanced* one, so `![a](u)(y)` would
  otherwise save a mangled url and drop the tail. Note the column-zero contract
  means an **indented** image now renders verbatim rather than as an image (it
  used to render as one); no content is lost either way. The one exception is an
  image line at exactly an open list item's content column, which is a nested leaf
  (see the parser bullet above).
- **An embedded image is fetched on render only when it is same-origin as the
  user's server; otherwise it is tap-to-load.** `![alt](url)` is author-controlled
  (a co-author, a web client, a live peer), so silently fetching an
  off-origin image would disclose the *reader's* IP/User-Agent/timing to a host the
  author chose (cookies are domain-scoped, so it is the request itself that leaks,
  not the session). `imageLoadPolicy(for:serverOrigin:)`
  (`Features/Editor/ImageLoadPolicy.swift`) decides: it composes `siteOrigin` on a
  **throwaway `URL(string:)`** on both sides (never re-normalizing
  `BlockKind.image.url`, so `extract_attachments()` byte-matching and the golden
  encoder are untouched) and fail-closes to `.confirm` on anything it can't parse or
  an empty server origin. It is a true origin test (scheme+host+port, host-not-suffix,
  IPv6, case-insensitive) and deliberately **stricter** than `documentLinkAction`,
  which ignores the port — a request is at stake here, not just tap interception.
  `serverOrigin` is derived once in `RootView` (`siteOrigin(for: serverURL)`) and
  threaded, required (non-defaulted), to **both** render sites — the reading
  `MarkdownImageView` and the editing `BlockEditorRow.imageLeaf` — so a new image
  render path is a compile error until it passes the gate; route any such path
  through `MarkdownImageView`. `ImageLoader` owns requests across mode swaps,
  joins duplicates, and checks persistent disk even offline. Consent is
  memory-only and keyed by exact URL plus session namespace; it survives modes,
  never a changed URL or replaced session. Cached external bytes render without
  another tap because no request is issued. Retry never bypasses consent.
  `ImageTransport` delegates to `ImageDataClient`, whose ephemeral session has no ambient cookies,
  credential storage or URLCache; only same-origin requests receive an explicit
  cookie snapshot. Redirects stay on the initial origin, with no userinfo or
  scheme downgrade. Downloads stop at 12 MiB; shared metadata validation rejects sources over
  48 MP before decoding bounded ImageIO thumbnails. Failure/offline states remain image cards with the URL.
  `ImageCacheStore` hashes server origin, opaque session namespace and full URL,
  uses Application Support with backup exclusion, and caps entries globally at
  100 / 64 MiB (no oversized-entry exception). The namespace is persisted by
  `SessionStore` across launches and rotated synchronously by
  `forgetSignedInIdentity`; handover removes the persisted namespace, and only
  signIn successfully saving its cookie snapshot persists the replacement. Never
  let failed confirmation or a failed Keychain write pair a new account's images
  with old restored cookies. All completions check scope before publishing or
  writing. Keep disk reads/thumbnail preparation out of view bodies: asynchronous
  loading prepares images, a 12-entry / 48 MiB NSCache reuses them, and each leaf
  retains its current URL/scope presentation. RootView clears bytes on sign-out. Never reuse SignedInUserStore as
  the namespace: it can be unknown while a new login's cookies are already live.
  Inject `ImageLoader.inert()` into previews/tests that embed either image
  surface; inert loaders issue no requests. The native editor's image previews (PR06e)
  call `ImageLoader` directly, without `MarkdownImageView`: the loader applies
  `imageLoadPolicy` and consent, and `NativeBlockControls.sessionImages` repeats
  `matchesSession` against the document's required `serverOrigin`; keep any new native image
  path behind both. Keep pending-photo branches ahead
  of remote loading and never clear their store with this re-downloadable cache.
- **A generic file attachment (PDF, docx, …) is a first-class leaf block, and
  classification is enabled by an origin.** The web's BlockNote `file` block and
  docs' custom `pdf` block both export as a standalone `[name](url)` line, so
  `parseEditorBlocks(_:serverOrigin:)` mints `BlockKind.attachment(name:url:)`
  for one `parseAttachmentLink` accepts. The origin **defaults to `""`, which
  classifies nothing**, so every caller that doesn't pass one keeps today's exact
  behavior. Three gates must all pass, and each is load-bearing: the link shape is
  unambiguous (the
  `parseImageLine` conservatism — anything doubtful stays prose, which is
  lossless); `siteOrigin(for: url) == serverOrigin`, which is **what makes
  auto-download safe with no consent flow** (an off-origin url is never an
  attachment, so no request is ever issued for one — stricter than the image
  gate, which offers tap-to-load); and the decoded path is exactly
  `/media/{doc-uuid}/attachments/{file-uuid}(-unsafe)?.{ext}` with both UUIDs
  validated, re-composed and compared against the url's own decoded path. Only
  `.paragraph` classifies: an attachment line adjacent to prose is part of a
  multi-line `.unknown` block, and a card there would misrepresent what a save
  writes back. An `-unsafe` key is routine (a `.docx` sniffs as `zip`), not a
  danger signal — only the server's `Content-Disposition` differs.
- **Classification lives in `flushPending`'s single-line branch and must stay
  there.** A `.attachment` serializes back to the identical line and is
  deliberately *not* column-zero-classified, so an origin-aware parse and an
  origin-less one produce the **same serialized markdown for every input**
  (`testAttachmentClassificationNeverChangesSerializedMarkdown`). That identity is
  the entire reason `canonicalMarkdown`, `draftSyncDecision`,
  `markdownSurvivesRoundTrip` and the save coordinator can go on parsing without
  an origin and stay correct. Move it into `parseClassifiedLine` and it breaks at
  once: an attachment line adjacent to prose splits into two blocks under one
  parse and stays one `.unknown` under the other, and the sync machinery starts
  seeing differences that aren't real. The origin reaches the **encoder** without
  passing through the coordinator at all — `MarkdownYjs.encode(markdown:serverOrigin:)`
  has one production caller, `saveDocumentContent`, which reads it off the client's
  own `baseURL`; it is not defaulted there, because a boundary that moves saved
  bytes must not be crossable by forgetting an argument.
  **The one sanctioned exception is a nested leaf** (`parseNestedLeaf`): an indented
  link line under a list item is classified outside `flushPending`, as a child
  block. It keeps the identity because **structure never depends on the origin** —
  whether the line nests at all is decided by its origin-free shape
  (`attachmentLinkShape`, gate 1 of `parseAttachmentLink` factored out) — and the
  origin decides only the child's kind: `.attachment` with one, a `.paragraph`
  carrying the same link without. Both are `blockNestsAsLeaf`, nest identically and
  serialize to the same line; the identity corpus covers nested cases, and
  `testNestingUnderAListItemNeverDependsOnTheOrigin` pins the structure half.
- **`.attachment` encodes as BlockNote's `file` node — never `pdf`, for any
  type.** Four props (`backgroundColor`, `name`, `url`, `caption`); no
  `textAlignment`, no `textColor`, no `showPreview`, no `previewWidth` — a
  *different and shorter* set than the image block's, so read the golden fixture
  rather than copying the image's prop list. The `pdf` node is refused because its
  `showPreview` defaults to true and such a block exports to nothing (see below),
  which would make it invisible here and let the next full-overwrite save destroy
  it. Landing this **changed saved bytes** for documents holding a standalone
  attachment link and required sign-off, exactly as the `_`-emphasis change did;
  all pre-existing goldens are unmoved because they parse origin-less.
- **`.attachment` is a leaf like `.image`**: deletes as a unit
  (`mergeBlockWithPrevious`), never converted (`convertBlock` refuses), never
  receives inline markers, `rendersInlineMarkdown` false, no `BlockTextView`. Both
  surfaces render the same `AttachmentCardView`, and both fall back to plain link
  text when the url no longer matches this server (a document opened after
  switching servers) rather than drawing a card that could never load.
- **Inserting an attachment mirrors the photo path exactly** — `.fileImporter`
  (out of process; no usage description, no `project.yml` change) → the same
  `attachment-upload` + media-check poll → `insertAttachmentBlock`, which is a
  structural twin of `insertImageBlock` down to verifying against the **saved**
  markdown before committing and never re-parsing the document (a parse mints
  fresh block ids, which would make a live forward diff as delete-all + reinsert).
  `sanitizedAttachmentFileName` enforces the union of two unrelated requirements,
  because the picked name is interpolated into both: multipart-header safety (no
  quote, CR, LF) *and* markdown-label safety (no brackets or parens, or the
  block's own `[name](url)` line stops parsing back as one link). Size is refused
  from the file system's answer **before** the bytes are read. File insertion is
  withheld offline and on a local document (Photo queues instead — see
  `PendingAttachmentStore` below); the **slash menu**
  routes that through `SlashMenuAction.requiresImmediateUpload`, while the formatting
  bar's **Attach** button (one slot, a tap swaps the row for Close + Photo + File)
  gates each choice with its own pure function — `canOfferPhotoInsertion` and
  `canOfferAttachmentInsertion`, the latter pinned to agree with the slash menu
  by `EditorFormattingBarTests`. Any file type is accepted (zip included): the
  server sniffs and stores it under an `-unsafe` key rather than refusing it.
  Only one upload runs at a time.
  **A file attachment has no offline queue.** Photos have the machinery for one
  (`PendingAttachmentStore`, the `schrift-attachment://` placeholder and the
  save hold — see the offline rules further down), and Photo is offered offline
  through it. To offer File offline too, follow that same
  path rather than growing a parallel one: the placeholder scheme, the hold and
  the replay are all type-agnostic, and only `parseImageLine`'s allowlist and
  the resolve step assume an image.
- **Attachment bytes go through `AttachmentLoader`, and its file names are the
  server's, never the author's.** The loader is app-scoped (built in `RootView`
  beside the collaboration manager, injected through the environment) so two
  cards showing one attachment de-duplicate a single download instead of racing
  two writers over one cache file; its state is keyed by **url string**, because
  `applyLiveRemoteChange` reuses a surviving `EditorBlock.id` and a live edit can
  swap the url under a card that never re-rendered. It is a sanctioned
  media fetch path alongside `ImageLoader` and must stay
  origin-pinned: `DocsAPIClient.mediaData(path:)` re-checks `isSameOriginPath`
  before issuing, exactly as `checkMedia` does. `AttachmentCacheStore` names each
  file `{document-uuid}_{file-uuid}[-unsafe].{ext}` from the classifier's
  validated parts — the display label is the one author-controlled string here and
  must never reach the filesystem, and the **document** id is in the name because
  the server's access check is per document: keying on the file id alone let a
  co-author of document B name a file id cached from document C and be served C's
  bytes with *no request at all*. It evicts by **last use** with a count *and*
  byte cap, never evicting the just-written entry. Clear the store in `RootView`'s
  `onSignOut` closure alongside `DocumentContentCacheStore`.
- **Five loader rules that each closed a real defect, none of them obvious.**
  (1) **Offline withholds the network, not the disk** — `loadIfNeeded(_:
  allowsNetwork:)`. Skipping the call while offline also skips the disk read, and
  since the loader is session-scoped a cold launch in airplane mode then showed
  "Available when online" over cached bytes, defeating the feature. `isOffline`
  is chrome only *because* of this parameter, not by default. (2) **A cancelled
  download is not a failure** — tapping a block swaps the reading surface for the
  editing one and tears the card's `.task` down mid-flight; recording `.failed`
  stranded the card, since `loadIfNeeded` never auto-retries a content failure (see (5) for transport ones).
  (3) **A `.cached` state is re-validated against the disk** on both appear and
  tap — eviction can delete the file under a live card (the reading surface is not
  lazy, so an off-screen card never re-runs its `.task`), and the same call is what
  makes recency last-*use*. (4) **Markup types are cached but never previewed**
  (`attachmentIsPreviewable`): QuickLook renders HTML through WebKit, which fetches
  remote subresources, reopening the very IP/User-Agent/timing disclosure the origin
  gate closes. Key that on the **extension**, never the `-unsafe` flag, which is
  routine for `.docx`.
  (5) **A transport failure is retried once, a content failure never.** `isTransportFailure`
  (`DocsAPIError.network` or a connectivity `URLError`) marks a `.failed` as retryable: the next
  `loadIfNeeded`/`resolve` with the network allowed (the cards' `.task` ids include `isOffline`, so the flip re-runs
  them) tries once; that attempt is not re-marked, so a second failure is retry-only. `ImageLoader` does this only
  after its consent check, so retry never bypasses consent.
- **A web `pdf` block with `showPreview: true` (the web default) exports as
  nothing** — BlockNote 0.51.4's markdown serializer has no `<iframe>` handler —
  so the app never receives it and a full-overwrite save has always silently
  dropped it. Accepted, pre-existing, and **not** something to work around in the
  app: the fix is a one-line y-provider patch on the server
  (`blockSpecs/Pdf.ts` → emit the `<a>` variant it already builds for
  `showPreview: false`), after which those PDFs classify here with no app change.
  Don't add a Yjs-content read path to chase them; see `docs/architecture.md`.
- Two view-model invariants protect the full-overwrite save: editing may only
  begin once `hasLoadedContent` is true (`startEditing` guards on it —
  otherwise autosave would overwrite the whole server document with an empty
  draft), and every path that puts content on screen must route through
  `EditorViewModel.install(...)` so the markdown round-trip safety check and
  the dirty baseline are never bypassed. **The one sanctioned exception is
  `applyLiveRemoteChange` (C1)** — the caret-preserving live-apply funnel. Unlike
  `install`, which keeps only unchanged blocks' ids and nulls the caret (a full
  server-wins swap), it mutates `blocks` in place reusing surviving `EditorBlock.id`s,
  recomputes the focused caret via the pure UTF-16 `transformedCaret`, and advances
  the dirty baseline to the projected content. It **never** calls `install`, never
  `enqueue`s a save, and never sets `isDirty`; it only runs while
  `canEngageLiveEditing` (loaded, clean, no pending save/draft/conflict, idle/saved)
  and hands back to the classic A5 + #76 machinery on the first keystroke. While it
  is applying, the A5 REST refetch is suppressed (`isApplyingLiveContent`) so a stale
  60 s REST snapshot can't `install` over live content and reset the caret. It is
  **read-only** — the outbound write path (C2, now wired end-to-end by C2c below) is
  a separate funnel that never calls `install` either. See `docs/architecture.md`
  ("Live editing (C1)").
- **Only a creation action opens editing automatically.** `DocumentEditorRoute(createdDocument:)`
  carries a reference-backed `NewDocumentEntryIntent`; ordinary routes carry none. Home's
  compact push, regular-width selection, Subpages add, and Pages drawer create all use it.
  `EditorViewModel` consumes it only after content is installed, through `canStartEditing` /
  `startEditing`. A just-created **server** document has no loading screen: its body is empty by
  construction, so when the local phase finds nothing and the intent is unconsumed,
  `seedNewlyCreatedDocument` installs `""` with a baseline that claims an empty body and **no**
  server clock (a clock would let a timestamp alone prove a push), and the screen enters editing
  at once.
  The fetch that follows still runs the ordinary rules: a server body it did not expect is stashed
  behind the "Updated" banner and the first edit records a conflict rather than overwriting it.
  This is the **one** sanctioned seed of a body not read from the server or the disk — it is
  keyed on the creation intent alone; never seed from an empty-looking fetch, a failed load or a
  default title. An ordinary open still waits for content, behind `EditorLoadingPlaceholder` (a
  page skeleton that fills the screen, so the theme's page colour reaches every edge).
  The editable shared header claims a
  separate one-time title-focus request and selects the existing title without clearing or
  dirtying it. Do not derive entry/focus from the default title, emptiness, connectivity, a
  pending-create id, or an appearance callback: refresh, reconnect, navigation restoration,
  rerenders, and local-to-server migration must never re-arm it. The title field uses a vertical
  axis so long titles wrap on both surfaces, including Dynamic Type.
- Saves go through **`DocumentSaveCoordinator`** (app-scoped; owns its `Task`s so
  navigating away never cancels a save; write-ahead draft to `PendingDraftStore`;
  per-document latest-wins coalescing; background-task assertion; draft replay). A draft
  belongs to the account that saved it: the store's plain reads, and so `storedDraft`, the
  titles and every replay, see only the signed-in account's, and none while it is unknown;
  protections read `allDraftsOfEveryAccount()` (see
  [`docs/offline-and-sync.md`](../offline-and-sync.md#drafts-belong-to-an-account)).
  View models **enqueue** on the coordinator — they never call the client to
  persist edits themselves.
- **A document created on this device has no server id, and four gates keep the
  pipeline from pretending otherwise.** `PendingDocumentCreateStore` records it
  (`PendingDocumentCreate`: `localID`, `title`, `parentID`, `createdAt`,
  `serverOrigin`, `ownerUserID`, `syncedServerID`, `replayBlockedAt`/
  `replayBlockedBuild`), the coordinator mirrors
  **every** record — protection is unconditional — and
  `isPendingCreate(documentID:)` is the predicate the holds key off. **Invariant: no *save* may ever name a pending-create id.**
  It is enforced at four gates in the coordinator, each load-bearing rather
  than defensive. (Scoped to saves deliberately: opening a local document names
  its id from places the coordinator does not own — `formattedContent`, the
  children fetch, the collaboration room, Options' delete and version history —
  and those are gated by `EditorViewModel.isLocalDocument` instead. The invariant and its enforcement now match. The create UI mints records now, so a *save* is fully guarded while
  those other paths are guarded by `EditorViewModel.isLocalDocument` instead.)
  1. **`enqueue` holds** — the same park-the-save branch the conflict hold uses.
     Without it, a keystroke PATCHes `documents/<local-uuid>/content/`, takes a
     404, and — a 404 being non-retryable — lands on `.failed`, which
     `runSyncPass` *skips*, wedging the document out of the replay meant to
     create it. Write-ahead and latest-wins still apply; only `start` is withheld.
  2. **`runSyncPass` skips it** — that pass GETs each draft's document before
     deciding, and its `.notFound`/`.forbidden` catch marks classic drafts
     `.failed` (waiting classic drafts are never deleted automatically). Skipping
     keeps local creates owned by the create replay, and the catch re-checks the
     same predicate so a local create is never marked failed as a missing server
     document.
  3. **`releaseHeldSave` refuses** — one of two paths that call `start`
     without passing through `enqueue`'s hold, reached from
     `clearResolvedConflict`, which the editor calls from five places. Releasing
     a hold on a local document would PATCH a nonexistent id straight into the
     `.failed`-then-skipped trap above. Its guard returns **before**
     `queued.removeValue`, so the held save is kept rather than dropped.
  4. **`finish`'s queued restart refuses** — the other such path: draining a
     settled save's queued slot calls `start` directly, re-applying the conflict
     hold and now the pending-create one too. Unreachable today (no save can be
     in flight for a local id), but it is the one place the invariant would
     otherwise be asserted asymmetrically, and the id migration is exactly the
     change that could make it reachable.

  `createLocalDocument(title:parentID:ownerUserID:)` mints the record **plus a
  seed draft** (so the editor's existing draft precedence renders it unchanged)
  and sets `.pendingSync` — nothing is syncing, but the work is on the device.
  **With the native editor on and no cached Docs 6 config there is no org to seed
  a replica from**, so the create affordances mint nothing (offline or under an
  unsent parent they show `create.needs_online`; a failed POST keeps its own error); `reviveAsLocalDocument` is exempt because it
  must never drop the content it carries.
  `discardPendingWork` drops the record with the draft, or a replay would resurrect
  what the user threw away. **But "a local delete is purely local" holds only while
  the record is un-checkpointed** — once `syncedServerID` is set the POST has landed
  and a real server object exists, while `isPendingCreate` is still true, so the
  local-id branch runs for exactly the case where it is false. `OptionsViewModel.delete()`
  issues the server `DELETE` there, via `syncedServerID(forLocalID:)`; without it the document survives and reappears in Home on
  the next list fetch with nothing on the device that knows about it. (`syncedServerID(forLocalID:)`
  is that accessor; `isPendingCreate` alone cannot answer it, since it stays true for a
  checkpointed record.)
  **The other direction is handled here, and must stay so**: once checkpointed,
  `pendingLocalDocuments` withholds the local row, so the **server** id is the only
  one the user is offered — and `isPendingCreate`, keyed on the local id, answers
  false for it. So `discardPendingWork` also matches a record by its
  `syncedServerID` and clears the record *and the local draft*. Without that a
  successful DELETE left both in place, the resume 404'd, the checkpoint cleared, and
  the next pass **re-POSTed the document from that draft** — a deleted document
  coming back with its old body. The 404 is indistinguishable from a co-author's
  delete, so the record has to go here, where the user's intent is still known.
  **Synthetic `Document`s (`localDocument(from:)`) must never enter a persisted
  metadata cache** — lists merge them at read time via
  `mergedWithLocalDocuments(fetched:local:)`, because a list load replaces its
  array *and* its cache entry wholesale, and a cached synthetic would afterwards
  be indistinguishable from a real document. `abilities.childrenCreate` is false and
  **nothing reads it** — creating a sub-page under a local parent works (it mints a second
  record, which the replay sends once the parent has a server id), and the affordances
  decide that themselves; it stays false because a
  `POST documents/{local-uuid}/children/` is a 404. `destroy` stays false even though deleting one now works, because nothing
  consults these abilities to decide whether to offer Delete (the sheet asks `isLocalDocument`),
  so flipping it would change no behaviour while costing the dictionary its one meaning: what
  the *server* would allow for this id, which is nothing.
  **Protection and ownership are separate, and conflating them cost content.**
  `isPendingCreate` is deliberately **unscoped** — a record minted against another
  server still names an id that would 404 here — while one `belongsToSession`
  test (origin **and** owning user) gates both what may be **listed**
  (`pendingLocalDocuments(parentID:currentUserID:)`) and what may be **sent**
  (`isReplayable`). Scoping the holds by origin instead left a foreign record's
  draft unguarded, because `runSyncPass` walks *every* draft: signing in elsewhere
  404ed and marked it `.failed`, leaving a dormant local document looking broken instead
  of preserved. Dormant means no requests *and* no failure stamp.
  Listing and sending share one test on purpose: origin identifies the server, not
  the account, and records survive sign-out — so *showing* user B another user's
  unsynced document is the worse half of the same disclosure, since B's edits
  would land in A's document when A signs back in. An **unattributable** record
  (nil owner) is kept and protected but neither shown nor sent;
  `createLocalDocument(title:parentID:ownerUserID:)` takes a **non-optional**
  `ownerUserID` so nil can only come from a future or damaged schema, and "I don't
  know whose this is" must never resolve to "anyone may send it".
  **That makes the signed-in user id a prerequisite for the whole feature**, and it is
  only ever learned from `client.currentUser()` — so `SignedInUserStore`
  (`dev.llun.Schrift.signedInUserID`) persists it, written through from the root task and
  Profile (each dropping an answer whose `epoch` moved during the request), handed over by
  `signIn(serverURL:userID:)` from the login flows' confirming fetch, and cleared at three moments — when a login hands over its cookies
  (`noteSessionCookiesReplaced`, the moment a possibly-different account takes over), at
  sign-in, and at sign-out — plus re-asked by Home whenever it is unknown. Without it, launching offline (the entire point) yields
  no user id, local documents are not listed, and none can be minted. It is a read-through
  struct rather than a caching `@Observable`, so a reader built before the first write
  cannot answer nil forever; not in the Keychain, because it is an identifier rather than a
  credential and `…WhenUnlockedThisDeviceOnly` would hide it from a background launch.
  **The replay also refuses to run while the *drafts* store cannot decode.**
  `PendingDraftStore.loadAll` is all-or-nothing too, so one bad blob makes every
  `draft(for:)` answer nil — and `runCreatePass` would read that as "every body is empty",
  POST each record under its mint title, pass `finishMigration`'s both-drafts guard on the
  same nil, enqueue `""`, and `removePendingCreate` — turning a schema slip into destroyed
  content, which is why it asks (`holdsUnreadableData`). Not the *only* irreversible
  consumer, though: `init`'s conflict rehydration reads the same empty answer and silently
  drops every persisted hold, after which the next `enqueue` full-overwrites a server body
  the user was warned about — that one predates the replay. **The hold is now sticky**:
  `save` and `remove` quarantine unreadable bytes before reusing the live key. The first
  blob lives at `…pendingDrafts.unreadable`, further distinct blobs at
  `…pendingDrafts.unreadable.additional`; none is discarded by another document's write.
  `recoverQuarantinedDrafts` retries decoding all blobs, merges newer drafts, writes the
  live key before clearing quarantine and is idempotent. A failed recovery retains every
  blob and the hold. Recovery callers must recreate the coordinator to rehydrate recovered
  conflict stamps before replay; there is no automatic recovery UI yet.
  **Every field added to `PendingDraft`/`DraftBaseline` must still stay Optional-on-decode**;
  quarantine is recovery protection, not a reason to break existing drafts.
  **The create store's `try?` decode is all-or-nothing, so an undecodable blob means the
  records are *unknown*, not absent** — which would disarm every hold and let the
  next sync pass stamp `.failed` or a conflict onto offline-created classic documents
  (nothing is deleted either way). `holdsUnreadableData` detects it and suppresses
  `runSyncPass`'s 404/403 refusal and `.discardServerWins` conflict stamp for classic
  drafts so unknown local creates stay untouched (a native draft with `replica != nil` is
  marked `.failed` before that guard). Two details make that
  real rather than nominal — the unreadable bytes are **quarantined** to
  `…pendingCreates.unreadable` before the live key is reused (every
  read-modify-write here reads through a `loadAll` that answers empty for a corrupt
  blob and would `persist` over it), and the flag is **sticky** while a quarantine
  exists, because a clean live key next launch would re-arm those branches against the
  protected classic drafts. Every field added to the record must stay Optional-on-decode for
  the same reason.
  **The replay (`runCreatePass`) runs inside `syncPendingDrafts`'s coalesced loop,
  before `runSyncPass`, and has no triggers of its own** — sharing the funnel is
  what stops two overlapping reconnects POSTing the same record twice. It asks
  `/users/me/` once per pass (only when there is work) because `isReplayable`
  needs the account and this is the layer that can await it; a failure leaves
  everything unreplayable, which is correct rather than a reason to guess.
  **Two dependent creates are ordered by a gate plus a rewrite, never by `createdAt`**
  (2026-08-06, which is what let sub-pages of unsynced parents ship). `runCreatePass`
  skips any record whose `parentID` names a record still in `pendingCreates` — keyed on
  `isPendingCreate`, so it holds through checkpointing, because it is the *migration* and
  not the POST that repoints the child. `migrateCreatedDocument` then rewrites every record
  naming this `localID` to the server id, **immediately before `removePendingCreate`**.
  That order is the safety argument, not a preference. Each `updatePendingCreate` is its own
  whole-store write, so N sub-pages means N+1 writes and a kill can land between any two —
  what holds is that **the record's presence gates every child, whatever subset of the
  rewrites has landed**: record present ⇒ all still gated and the next pass redoes the
  migration; record gone ⇒ the loop completed, so every child names a live server id and
  `POST documents/{serverID}/children/` is valid (the checkpoint proves that document
  exists). The reverse order admits the one unsafe state — record gone, child
  still naming the dead local id, nothing gating it — in which the child POSTs
  `documents/{local-uuid}/children/`, 404s, probes, 404s again, and is **silently
  re-rooted**. Because the pass re-reads each record from the mirror, a parent and its
  sub-pages replay in one pass to any depth; `allCreates()`' oldest-first order is now only
  an optimization on top of the gate (a clock change that reverses two records costs a
  trigger, never a document). Every reason the parent is held holds its sub-pages too —
  `.failed`, replay-blocked, open editor, foreign account — and in each the child's body
  stays on disk and protected: it costs the sync, never the content.
  **`discardPendingWork` cascades through the local subtree** for the same reason the gate
  exists: an orphaned record is listed by nothing (`pendingLocalDocuments` filters on an
  no level keyed by a dead id, Home asks for `nil`) yet still holds a document body, and it is a record
  no gate holds any more, so the replay would re-root it and a deleted document would return
  to Home. `discardLocalSubtree` runs from **both** branches — keyed on the passed id when
  un-checkpointed, on `checkpointed.localID` otherwise, since a checkpointed parent is met
  and deleted under its *server* id while its sub-pages still name the local one
  (`hasPendingLocalChildren`, which the confirmation alert's extra line keys off, resolves both
  ids the same way — and **answers for the cascade, not for the relation**: a sub-page created
  offline under an ordinary *server* document is an ordinary record too, but deleting that
  document takes neither branch, so the sub-page survives and the probe later re-roots it, and
  announcing a deletion there would put a false sentence in a destructive confirmation).
  Three ordering rules: **every record in one
  store write**, the root's included (`PendingDocumentCreateStore.remove(localIDs:)` — a loop
  would leave a half-deleted subtree, i.e. the dangling-record resurrection reached through a
  kill); **records before drafts** (a draft with no record is inert and only 404s/fails if synced,
  a record with no draft POSTs an empty document); and **a sub-page whose editor is open is
  re-parented to the root rather than deleted** — every other record remover defers to an open
  editor, and this is the only one that would take a live screen's disk backing, while merely
  *skipping* it would leave it to be re-rooted by the probe later anyway. No descendant gets a
  server `DELETE` and none needs a content-cache purge: the gate held it back for exactly the
  window in which the cascade runs, so it is provably un-checkpointed. The walk is iterative
  and `visited`-guarded — it reads decoded data, where the shape is a tree only by
  construction.
  **Its ordering is the safety property**, and each step exists for a failure that
  was reasoned about: persist `syncedServerID` **first** (no idempotency key
  exists, so this write landing before anything else is the only thing between a
  process death and a duplicate — a checkpointed record resumes at migration
  instead of re-POSTing); stamp the baseline; move every id-keyed thing including
  **`queued`** (a copy of the newest keystrokes — hygiene rather than a rescue, since
  for a pending create it always agrees with the draft: `enqueue` write-ahead-saves
  from the same `save` it parks, and no save is ever in flight to make them diverge)
  (and write the draft under the
  new id *before* removing the old one — in between it is on disk twice, which is
  the point; the reverse order is what leaves a window with it nowhere); insert into the list caches so
  the document doesn't vanish from Home before the next fetch — the **recents** insert
  roots-only (a sub-page *is* appended to the children cache), and **neither cache ever
  fabricated**, since `nil` (never fetched) and `[]` (fetched, empty)
  are read as different by the lists' "is this known" logic, and Home's feed is
  fetched without a parent filter so a sub-page's place there is the server's answer
  to give; **remove the record
  last**, because it is what keeps the holds in force; then enqueue the content.
  **A replay never runs while an editor is open** on that document
  (`retainOpenEditor`/`releaseOpenEditor`), wired from `EditorView`'s `onAppear` for
  **every** document rather than only locally-created ones — the server-id guard's
  motivating case is an ordinary document opened from Home whose id a checkpointed record
  is about to migrate *onto*. **The hold is released when the view model is deallocated,
  not on `onDisappear`**: that fires on mere invisibility (a tab switch), and releasing
  there let the replay re-key a document whose screen was about to return, after which the
  editor held a dead id — a 404 teardown, and post-return keystrokes enqueued against an id
  no hold covers, then marked `.failed` on the next sweep. The cost is that any editor left pushed holds its document
  until the user pops back. Why it matters: migration re-keys everything, and
  `EditorViewModel.documentID` is a `let` captured by four sibling view models and
  by pushed `NavigationPath` values, so a live screen cannot follow the id and
  would keep writing under one the holds no longer cover. Deferring makes mid-swap
  edit loss unrepresentable. Everything that can change during the await is
  re-checked after it — **and a boolean is not enough**: a save for the *server* id that
  starts **and settles** inside the resume's fetches leaves `inFlight`/`queued` nil and
  removes its own draft, so the resume snapshots `saveMarker(documentID:)` before fetching
  and bails on `mayPredateSave`, exactly as the editor's revalidation does. Otherwise: the record is re-read from `pendingCreates` (a delete during
  the POST must not be undone — acting on the stale copy would POST a document the
  user threw away and orphan it server-side; it would *not* resurrect the record,
  which every `updatePendingCreate` on that path already guards) and `hasOpenEditor`
  is asked again.
  **A resume whose document is gone takes the body back before it drops the
  checkpoint.** A death inside the migration can leave the only copy under the
  *server* id, and the checkpoint is the last thing tying it to the record — so
  clearing first **orphans** the body: the re-POST mints a different server id and
  its body chain never looks under the old one, so it builds an **empty** document,
  and the stranded draft is left failing under a dead id once `runSyncPass` GETs it and takes the same 404.
  **And it starts over only when nothing is left under that id.** A bare `.notFound` is not
  proof the document is gone (invariant 0c), yet two effects hang off that
  premise: discharging the conflict drops the held keystrokes, and clearing `syncedServerID`
  disarms the server-id suppression — after which `runSyncPass`, next in the *same* pass on
  the *same* 404, marks the draft failed while a re-POST mints a separate document. Gating on *concurrent* activity is insufficient, because
  the user who typed under `serverID` and navigated away leaves no such witness and theirs is
  the work at stake; the sufficient question is whether anything remains to lose, so the
  start-over requires `draftStore.draft(for: serverID) == nil` — **and `!mayPredateSave(marker)`
  beside it**, because a save that started *and settled* inside the resume's fetch window has
  `finish` remove its draft, manufacturing the very emptiness the first gate reads as safe while
  the 404 may predate it (that one duplicates the document; the draft-absence gate closes the
  different harm of losing the body), plus `!hasOpenEditor(serverID)` — clearing the checkpoint
  disarms the sweep's server-id suppression, and `runCreatePass` guards only the *local* id, so
  a screen writing under `serverID` would be left unprotected — and the take-back carries the
  concurrency conjuncts for its own reason (it can run under a live editor on the server id,
  where removing the draft yanks the screen's backing and splits the conflict mirror). A
  genuinely deleted document then strands — checkpointed, unreachable, lossless — which is
  the `.forbidden` resume's accepted outcome and wants the same owed affordance. An earlier
  revision discharged instead, to stop exactly that strand; it ranked the harms backwards.
  (That
  draft is never covered by the pending-create hold in either ordering — the hold is
  keyed on the local id. The ordering decides whether the body is still *reachable*,
  not whether it is protected from that sweep — the checkpointed window has its own
  server-id suppression there, and this branch is about the state after the checkpoint is
  cleared.) Move-then-clear is self-healing across a kill between the two writes;
  clear-then-move reproduces the very loss it closes. Guarded on the local draft
  being absent, or a `serverID` draft that is the *user's* work would overwrite it.
  **Both of those re-checks are keyed on the *local* id, and the migration writes under the
  *server* id — so it defers on that side too.** A checkpointed record is withheld
  from `pendingLocalDocuments`, so the local row disappears and the server document
  returns in an ordinary list fetch, indistinguishable from any other: the user can
  open it, type, and have a save on the wire under `serverID` while a local-id-only
  guard sees nothing. Migrating then overwrites that draft (dropping its
  `lastPushedMarkdown` and conflict stamp), replaces its `queued` keystrokes, and
  records a conflict against an in-flight save — which the conflict invariant
  forbids. So it also bails on an open editor, an in-flight or queued save, or a
  draft under `serverID` that is provably the user's (**a server-id draft is *ours*
  only once the local one is gone** — that is what defines the partial-migration
  window — note a death *between* the two draft writes leaves **both** present, so
  that window defers rather than migrating). Deferring clears itself only for the
  **both-drafts** guard, where the same pass's `runSyncPass` pushes that draft and
  `finish` removes it; `runSyncPass` skips a document with `inFlight`/`queued` set, so
  `finish` alone drains those. The migration
  waits for the **next** trigger though — `finish` does not kick the funnel and the
  `repeat` loop only re-runs on `needsAnotherSyncPass` — so a foreground, a
  reconnect, or the editor release completes it; releasing an editor on the
  **server** id kicks the funnel for exactly that reason. **Two** shapes never clear
  themselves — a `.failed` push, which `runSyncPass` skips, and a recorded
  **conflict**, which waits on the user and (unlike the in-memory `.failed`) is
  persisted on the draft, so it is the more durable of the two. A `queued` slot on
  its own is *not* one of them: filled behind an in-flight save, `finish` drains and
  starts it, and the obstruction goes with no trigger — the self-perpetuating queued
  slot *is* the conflict hold. Both bodies stay on disk, so this costs the sync,
  never the content.
  **An empty local body is never offered as a conflict** — with nothing local to
  contribute, "Keep my version" would PATCH `""` and wipe the document, so the
  migration adopts the server — **title included, writing nothing back.** (Its discharge of
  any conflict for that id rests on having removed every local trace, which is false when the trace is an unflushed dirty screen — see the owed list
  in `docs/offline-and-sync.md`.) The test is
  **canonical** emptiness, not absence and not a raw `isEmpty`: the seed draft is
  present-and-empty, so a nil check lets a created-renamed-never-typed document through,
  and a raw check lets a `" "` body through — both arming the very "Keep my version"
  wipe the branch exists to prevent. Two
  attempts to preserve a local rename there were both wrong: pushing the server's
  own markdown back to carry it re-encodes via `MarkdownYjs`, where a co-author's
  table is an `.unknown` block that round-trips as literal paragraphs (the app's
  only full-overwrite of content no local user authored); and a title-only PATCH
  writes a name **nothing here can show is the newer one** — it falls back to the
  server's own for a never-typed-into document, and the branch only fires once the
  server has a body, i.e. after
  elapsed time in which a web rename is at least as likely. Accepted residual: a
  rename made here on a body-less document is lost when the server has moved on.
  **No failure strands content**: transport/5xx/
  `.sessionExpired` retry later; a failed sub-page create **probes the parent** and
  promotes to a root only on the probe finding the parent **gone** (404). Not a bare 403
  — an ancestor-access recompute 403s transiently and would 403 the create too, the same
  reason the resume path drops a checkpoint only on `.notFound`; a 403 probe is terminal
  instead, since the create error is non-retryable and still owes an end state. A
  reachable parent means the create itself was rejected: also terminal, as the root path
  treats the same error. **`.routeNotFound` returns before any of this, root or sub-page**
  — a missing route is a fact about the server, and the probe tests `documents/{p}/`, a
  different path from the one that 404'd. `abilities.childrenCreate` is deliberately not
  consulted: it decodes `?? false`, so absent and denied are indistinguishable, and both
  reach the same terminal outcome anyway. Anything else rejected
  on the merits goes `.failed`, which stops the retry loop but is **not** reachable
  by the reading surface's "tap to retry" (`saveNow` no-ops while `pendingSave` is
  non-nil, which a local document with content always has), so a relaunch is the
  escape until the UI offers a create-specific one. **The one rejection that is
  persisted is `.decoding`**, which arrives *after* a 2xx: the server very likely
  built the document (`.decoding` proves 2xx-and-unreadable, not 201-created — a
  gateway answering `200` with HTML created nothing) and no checkpoint could be
  written, the id having been in the body that failed to decode. So the in-memory
  rule would POST and abandon another every launch —
  the `is_favorite`-as-required-`Bool` incident, on a loop. It stamps
  `replayBlockedAt` **scoped to the app build** (`isReplayBlocked(forBuild:)`);
  a blanket block would make that same incident unrecoverable by *shipping the
  fix*, which is worse than the littering it prevents. A stamp from another build
  is spent, so a fixed build retries once, and the gate excludes blocked records
  so they cost no `/users/me/` round trip either.
  **A resume takes its baseline from `formattedContent`, never from `document`**
  (it calls both — `document` only feeds the list caches). The latter carries no
  body, so using it stamped `markdown: ""`, asserting an empty server nothing had
  checked; an *unchecked* `""` is provable only on the fresh-POST path. (Distinct from
  the diverged baseline's `""`, which comes with a nil clock and asserts nothing about
  the server — see above.) And because a resume can
  find a body that arrived while the document sat checkpointed — live and editable
  on the web — the migration **records a conflict** when the server's body differs
  from ours (compared canonically) instead of pushing. Recording it *first* is what
  makes that work: the record is already gone by then, so an unrecorded conflict
  would let the enqueue go straight to `start` and full-overwrite the server's body,
  whereas with one recorded the same enqueue takes the ordinary hold and the pill
  asks the user.
  **The seed draft carries no `DraftBaseline`, and the replay must stamp one.**
  Nil is the only honest value at mint time (there is no server state yet), but a
  baseline-less draft routes to `draftSyncDecision` rule 3's 120 s tolerance — and
  the moment a create POST lands, the new document's `updated_at` is *now* while
  the draft's is hours old, which is the point of creating offline. Rule 3 would
  answer `.discardServerWins` and raise a false conflict against the empty document
  the POST just made. **But it must say what the body *descends
  from*, not what was observed** — where those differ, stamping the observation is
  self-defeating: a diverged resume would hand `draftSyncBodyDecision` rule 2 a proof
  (`serverUpdatedAt <= baselineDate`, trivially true of the state it was copied
  from), so the next revalidation answers `.push(.descendsFromBaseline)`,
  `releaseConflictIfProven` clears the conflict the migration just recorded, and the
  held save full-overwrites the co-author **by way of** the conflict meant to stop
  it. Diverged, the baseline is therefore a `nil` clock and an empty body — what an
  offline body actually descends from — which re-reaches `.conflict` while staying
  non-nil so rule 3's clock-tolerance fallback never runs. **The baseline is not the only proof that has
  to be withheld.** Rule 1 (`serverHoldsOurLastPush`) is consulted *before* rule 2, and
  `enqueue` stamps the draft's `lastPushedMarkdown` from
  `lastConfirmedPushMarkdown[serverID]` — which can hold the very body just conflicted
  against, since a checkpointed document is met under its server id and the user's save
  there may already have landed. So the diverged path clears that map entry too;
  otherwise the honest baseline is never reached and the held save overwrites the
  co-author anyway. The general rule: **the migration must withhold every proof, not
  just the baseline.** (One benign exception to "forever": if the co-author *empties*
  the document first, rule 2's body tiebreak matches `"" == ""` and releases — their
  deletion is undone, but the server held nothing.) Undiverged it is the server state
  it actually **observed** — the create response
  on a fresh POST, where `markdown: ""` is provable, and a `formattedContent` fetch
  on a resume, where it is not.
- **A document deleted while the server is out of reach is queued as a *tombstone*, and
  every other pipeline is held off that id until it lands.**
  `PendingDocumentDeleteStore` (`dev.llun.Schrift.pendingDeletes` + quarantine, sticky
  `holdsUnreadableData`, backup-included, survives sign-out) records
  `PendingDocumentDelete { documentID, requestedAt, serverOrigin, ownerUserID }`, mirrored
  into the coordinator behind the observable `pendingDeletesVersion`. **`documentID` is
  always a *server* id** — that is what keeps tombstones and create records from ever
  describing the same thing, since a create record names an id the server has never seen.
  A document that exists only here has nothing to DELETE, so `OptionsViewModel` completes
  that case locally and never mints one; a *checkpointed* record is tombstoned under its
  `syncedServerID`.
  **Two predicates, and the split is the same one `isPendingCreate`/`isListable` makes.**
  `isPendingDelete` is unscoped — protection is unconditional, and `runSyncPass` walks
  every draft on the device regardless of origin. `isListablePendingDelete` is scoped to
  origin **and** owner and is the only one the UI may ask: tombstones survive sign-out and
  the metadata caches are neither account-scoped nor cleared, so an unscoped row predicate
  would strike user A's document through user B's list and offer B a button cancelling A's
  deletion. It reads `pendingDeletesVersion` first, which is what makes a row strike (and
  un-strike on undo) without a list fetch.
  **Queue time never reads `isOffline`** (a read/control availability signal, so wrong
  in both directions): `retryableSaveFailure` plus a known `ownerUserID` queues, anything
  else keeps the error, and an unattributable deletion errors rather than silently going
  nowhere. Both server-addressed branches take the split — note the *common* checkpointed
  delete arrives through the **plain** one, since a checkpointed record is met under its
  server id — and the plain branch also gained the `.notFound` carve-out the checkpointed
  one always had. The queued path clears nothing local; see `handleDidQueueDelete` under
  the conflict-lifecycle rule below.
  **Five suppressions, each for a named failure.** `runSyncPass` skips a tombstoned draft
  pre-fetch and restates `isPendingDelete` (and `deleteStoreUnreadable`) in both the
  404/403 catch and the `.discardServerWins` branch so a tombstoned draft is never marked
  failed or stamped with a conflict while the deletion is cancellable or unknown. `runCreatePass` holds a record whose `parentID` is tombstoned — that parent is
  a *real* server document, so the POST would **succeed** and file a new sub-page into
  something about to be deleted — and refuses to resume a record whose `syncedServerID` is
  tombstoned, **which is the resurrection guard**: past it the resume reads the expected
  404 as "gone", clears the checkpoint, and the next pass re-POSTs the document the user
  deleted. No `finishMigration` change is needed.
  **`runDeletePass` runs first in the `syncPendingDrafts` funnel**, with its own
  `/users/me/` (not hoisted — that would reorder `runCreatePass`'s gates, several pinned
  by "not even `/users/me/`" tests), the session gate **before** the send (a foreign
  tombstone would take DRF's 403-as-404, which the ladder reads as "already deleted"), and
  an explicit outcome ladder rather than `retryableSaveFailure`, which lumps `.notFound`,
  `.forbidden` and `.routeNotFound` together where here they are three different answers:
  2xx/`.notFound` complete, `.forbidden` is **terminal and gives the document back** (this
  session may not make the deletion, so retrying forever would strike the row through for
  good), everything else keeps the tombstone.
  **The undo can lose its race, and leaving the local side untouched is not enough.** With
  the tombstone gone every suppression is off, so `runSyncPass` — later in the *same* pass —
  finds a draft whose document now 404s (because the pass just deleted it), passes all of
  its guards, and marks it failed under a dead id that can never sync.
  `reviveAsLocalDocument` honours the undo instead, re-minting the document locally with the
  body carried over so the create replay POSTs it — the same recovery the checkpointed path
  already got from its `.notFound` start-over. Accepted: it comes back as a root, under a new
  id.
  **`enqueue` holds for a tombstoned id.** The deleting screen pops and every fresh editor is
  gated at `load()`, but a *second, already-loaded* editor (same document pushed in two tabs)
  goes through neither.
  Both paths that clear a tombstone — `cancelPendingDelete` and the `.forbidden` refusal —
  **unwedge** that slot, because `runSyncPass` skips any document with a non-nil `queued` slot
  and a save left parked wedges it out of the replay for good. They clear it *without sending*:
  `releaseHeldSave` goes straight to `start`, a full overwrite with no reconciliation, and a
  tombstone survives launches so the parked body can be days old. The draft is write-ahead, so
  clearing the slot hands the body back to `runSyncPass` to reconcile normally. Neither touches
  a slot a **conflict** hold owns — that one is the pill's payload.
  `releaseHeldSave` itself refuses for a tombstoned id on the terms it already refuses for a
  pending create, and gained the **conflict** check its two sibling paths to `start` always
  had: safe to omit while `clearResolvedConflict` (which nils the conflict on the line before)
  was its only caller, and a full-overwrite of the co-author the moment a second caller
  appeared.
  **A landed deletion is announced** to every surface that strikes rows — Home, Shared, Search,
  the Pages drawer and the editor's Subpages — as a *fan-out*, since each keeps its own array
  and a single closure would let one subscriber overwrite another. Observers are held weakly
  and pruned (the coordinator outlives every screen), and each drops the row **and invalidates
  its in-flight fetch** — invariant 0b: one issued before the DELETE landed completes after it
  and writes the row, and the cache entry, straight back.
  **An editor whose own document is announced goes terminal**, not merely discarded. Latching
  `isDocumentDiscarded` while leaving `hasLoadedContent` true and no message meant every
  keystroke afterwards reached neither disk, nor server, nor an error — a live Save button that
  did nothing. The revive is the one completion that runs with an editor open, so it is
  reachable.
  **An unreadable delete store withholds the create pass's resume start-over**
  (`deleteStoreUnreadable`) — unknown tombstones disarm the resurrection guard, and a
  re-POSTed deleted document is the one consequence here no later launch can undo. Scoped to
  that branch, not the whole resume: nothing clears the quarantine, so withholding the resume
  outright would strand every checkpointed record on the install permanently.
  **`completePendingDelete` removes the tombstone last** — cleanup first, so a crash
  mid-way re-sends, takes the 404 and finishes idempotently — then fires `onDocumentDeleted`
  so a list holding the row drops it instead of letting it **un-strike** back into looking
  alive. The reverse order has a
  window where the deletion is forgotten while the draft and record survive: the row comes
  back and a checkpointed resume re-POSTs it. Same argument and direction as
  `migrateCreatedDocument`'s "the record is removed last". `DocumentCacheStore
  .removeDocument` never fabricates a list that was never cached (nil ≠ `[]`).
  See [`docs/offline-and-sync.md`](../offline-and-sync.md) for the accepted residuals.
- **The delete/pin ladder lives in one place — `Features/Documents/DocumentActions.swift` —
  and every surface goes through it.** It is the body of the old `OptionsViewModel.delete()`
  moved verbatim, returning `DocumentDeleteOutcome` (`.deleted` / `.queued(serverID:)` /
  `.failed`) instead of setting screen state; `OptionsViewModel` and the three swipe
  surfaces translate that into their own `errorKey`. Extracted rather than copied because
  the ladder had already drifted **inside a single function** (the plain-server branch was
  missing the `.notFound`-reads-as-deleted rule the checkpointed branch always had), and
  because ~70 lines of load-bearing reasoning would otherwise need keeping true in three
  places. **The proof of preservation is that `OptionsViewModelTests` passes unedited — if a
  case there needs changing, the extraction is wrong.**
  **An immediate delete now purges and announces** (`completeImmediateDelete`, the twin of
  `completePendingDelete` minus the tombstone: `purgeLocalTraces` then
  `announceDocumentDeleted`). This is genuinely new, and load-bearing in a way that is easy
  to miss: the editor used to be the only thing that cleaned up after a made deletion, via
  `EditorView`'s `onDeleted` → `handleDidDelete()`, and a list row has no editor. Skipping
  it leaves stale rows everywhere — and worse, **resurrects checkpointed documents**: such a
  document is met from a list under its *server* id, where `isPendingCreate` is false, so
  nothing clears the create record; the next resume takes the expected 404, clears the
  checkpoint, and the pass after that re-POSTs the document the user deleted.
  `purgeLocalTraces` → `discardPendingWork`'s `checkpointedRecord(forServerID:)` branch is
  what closes it. Consequently `EditorView`'s `onDeleted` no longer calls
  `handleDidDelete()` for a made deletion — the announcement reaches the screen's own
  `noteDocumentDeleted` → `handleDeletionLanded`, which does that *and* goes terminal, so
  the teardown is identical however the deletion was made. The queued branch keeps
  `handleDidQueueDelete()`; a queued deletion announces nothing.
- **Moving a document is `DocumentActions.move`, and it is the `setFavorite` posture, not the
  delete one: awaited, never optimistic, and with no offline queue.** `POST
  documents/{id}/move/` (`Core/Networking/DocumentMove.swift`) takes
  `{target_document_id, position}` and relocates the **whole subtree in one atomic server
  transaction**, so nothing here walks children. `DocumentMoveDestination` is deliberately
  asymmetric — the endpoint has no "no parent" target, so promoting a document to the top
  level is expressed as filing it *beside* an existing root (`.root(siblingRootID:)`,
  `last-sibling`), while `.under(parentID:)` is `last-child`. A **local** document needs no
  target: `.root(siblingRootID: nil)` re-parents its pending record on the device. Every
  rejection — no permission on the target, unknown target, a move into the document's own
  descendant — is a **400**, so it arrives as `.server(statusCode: 400)` and surfaces as
  `move_error`; there is no branch to write against it. A `.notFound` is a plain failure,
  deliberately unlike `delete`'s: "already deleted" is a coherent reading of a 404, but no
  state of the world makes an unmade move already done. The ladder's three states mirror
  `delete`'s, and the middle one matters for the same reason: a **checkpointed** record is
  still `isPendingCreate`, but the document the user means is the server one, so the move
  addresses `syncedServerID` — and `completeDocumentMove` is keyed on that id
  (`Document.identified(as:)` re-keys the row), because every cache entry and list row for
  such a document is written under it. **A synthetic row is dropped rather than re-keyed**:
  every surface that offers Move merges `localDocument(from:)` rows in at read time, and
  `identified(as:)` is precisely the operation that would make a leaked one undetectable — a
  client-minted id 404s on every fetch, a re-keyed one is indistinguishable from a real row.
  **Its record's `parentID` is re-pointed with it**: the POST has landed so nothing re-files
  from it, but the pending *migration* still reads it twice — `insertIntoListCaches` would
  write the document back into the recents cache as a root, and `runCreatePass`'s parent gate
  would hold the migration whenever the *old* parent is tombstoned. That re-point is only half
  the fix, because **`replayCreate`'s resume branch captures its record before two awaits**:
  `migrateCreatedDocument` therefore reads the parent from the **mirror**, not from its copy,
  or a move landing in that window is undone by the migration that raced it. Read it with
  `.map(\.parentID)`, never `?.parentID ??` — a nil parent is the legitimate *root* value, so
  the optional-chained form falls through to the stale copy for exactly the promotion case the
  read exists to fix. (`createPostsInFlight` covers the sibling window on the fresh-POST
  branch; this is the same class of bug on the branch that flag cannot reach.) A document already **queued for deletion** is refused outright: the tombstone
  outlives the move, so the only thing a successful one buys is a document deleted from
  somewhere else. And the picker must use the ladder's own local test (`isPendingCreate`
  **and** no `syncedServerID`), never `isPendingCreate` alone — the looser one makes the sheet
  call a checkpointed document local while the ladder moves it as a server one, after which
  every row in the picker fails. **And the picker re-checks a *local* destination at tap time**,
  because its list is a snapshot: a sync pass can POST, migrate and `removePendingCreate` a
  local destination while the sheet is open, after which its id names nothing anywhere. Nothing
  below that layer can catch it — a dead local id is indistinguishable from a server id, so
  `moveLocalDocument`'s cycle walk simply terminates and accepts — and the document would then
  be filed under an id that does not exist, take the 404, take the probe's 404, and be
  **silently re-rooted** while the user had been told the move landed.
- **A landed move's local settlement is `completeDocumentMove`, the twin of
  `completeImmediateDelete` and deliberately much narrower.** A move is not a deletion: the
  document still exists, so the **content cache and the document's own children level must
  stay** — purging them throws away a cached body and a cached subtree that are still exactly
  right, and blanks the document offline for nothing. What changes is placement:
  `childrenCache.removeDocument` sweeps the row from **every** cached level (the old parent is
  generally unknown — `Document` models no parent), then the row is appended to the new
  parent's level **only if that level was actually fetched** (nil ≠ `[]`, the
  `insertIntoListCaches` rule). **The sweep must run before the insert** or it strips the row
  it just filed. On the root lists, only the **recents** key moves (`removeRecentDocument` /
  `insertRecentDocument`) — never `removeDocument`, which would take the pinned and shared
  entries with it: a favorite is a per-user annotation the server keeps across a move, and
  shared-with-me membership is decided by access. Announce **last**, as both siblings do.
- **The move fan-out (`observeDocumentMoved` / `DocumentMoveEvent`) mirrors the deletion one,
  and its event carries the `Document`** — unlike a deletion, a move gives some surface a row
  to *insert*. The row is **Optional**: a caller holding an id rather than a row (the editor's
  Options sheet) passes nil, and the destination picks the document up on its next fetch
  rather than being handed a row with an invented `depth`/`path`. Four subscribers, and what
  each must do is not interchangeable: **Home** drops the row from `fetchedRecentDocuments` on
  a filing and inserts it on a promotion (both mutate a memo-key conjunct, so no memo trap),
  and **keeps the pinned and search rows** for the reason above; **the drawer** drops the row
  from every level and appends to a loaded destination, but unlike `dropDeletedPage` **keeps
  `children[movedID]`, `expanded` and `failedLoads`** — the subtree moved with the document
  and is as valid as it was; **the editor** adds or removes one Subpages row and otherwise
  **does nothing when the moved document is the one on screen** (its content, drafts, saves
  and collaboration session are all keyed by an id that has not changed, and the screen models
  no parent — the early return states that rather than leaving it to be inferred);
  **Shared and Search do not subscribe at all**, because a move changes placement, not access.
  Every subscriber bumps its own in-flight-fetch guard (invariant 0b) — the drawer blanket-bumps
  `mutations` for *every* loading level and the editor bumps `childrenGeneration`
  unconditionally, because the old parent is not in the announcement and a straddling fetch
  can carry the row either way.
- **Home's move override retires on *fetch ordering*, not on what the fetch says — and that is
  the one place `applyFavoriteOverrides`' shape must not be copied.** `applyMoveOverrides`
  (`Features/Home/MoveOverlay.swift`) folds a move into a recents fetch that predates it, by the
  usual rule (filter, never bump `loadGeneration`). A settled pin can be observed in the
  favorites action, but an unsent pin remains durable even when a fetch agrees; **placement is not
  observable here**: `Document` carries no parent id, and Home's feed is fetched without a
  parent filter, so whether it lists sub-pages is the server's answer to give. Retiring on
  content therefore reads an ambiguous signal as proof and wedges both ways — a filed document
  on a server whose feed *does* list sub-pages would be stripped from the array **and the
  persisted cache** on every load for ever (vetoing a later move back made from the web), and a
  promoted document that is then **deleted** looks exactly like "the fetch hasn't caught up", so
  the promotion branch would re-insert its own stored row indefinitely — resurrecting a deleted
  document into Home *and* the recents cache, past `deletedSinceLoad`, which filters the fetch
  and not the override. So each override records the `loadGeneration` current when the move
  landed: a fetch issued **after** that has asked the server since, so it is believed whatever
  it says and the override is spent. It exists only to protect fetches already in flight.
  The deletion observer additionally drops the override outright, for the window in which one
  is still live.
- **Pin/unpin is durable per server, account and document.** `DocumentActions.setFavorite`
  rejects client-only UUIDs and pending-delete ids before any request. An attributed session
  writes `PendingDocumentPinStore` before publishing its latest intent; repeated toggles
  coalesce by composite key and each receives a unique intent id. `DocumentPinCoordinator`
  belongs to the app-scoped save coordinator, and Home, Options, Shared and Search read its
  scoped overlay instead of writing optimistic flags into the unscoped metadata caches.
  A fetch agreeing with an **unsent** intent must never remove it. The normal sync funnel
  runs pins after deletions; deletion holds replay, undo releases it, and completed deletion
  removes pending and settled pin projections. Replay verifies `/users/me/` against the
  remembered owner and rechecks owner, deletion holds and intent after every await. An owner
  change or failed verification must honor a coalesced trigger by starting the requested pass
  with the current identity; never discard it through an early return. Transport,
  auth, rate-limit and 5xx errors remain pending; permission, missing endpoint/object and other
  4xx rejections restore the last known server bit and surface the existing pin error key.
  A superseded success advances the latest intent's rollback baseline, never removes it.
  Success/rejection persists a **scoped settled projection** before dropping pending work,
  so an older cache overwrite followed by relaunch cannot undo settlement. Fetch revisions
  protect older responses. A newer Home fetch caches the server answer and releases cached
  membership protection, while the scoped last-known bit remains durable for pagination gaps,
  older subpage metadata and rollback. Home passes an explicit cache-read marker, so live
  Work Offline reseeding matches relaunch rather than treating current caches as stale reads.
  Newer reads reconcile changes made on the web. Work Offline queues pins without
  networking; reconnect, foreground, launch, leaving Work Offline and successful re-login
  resume replay, including when a previously unknown identity is learned. Options receives
  the real navigation row, with cache lookup as a fallback. A landed move updates durable
  Recent fallback placement, so an outstanding unpin cannot reinsert a filed row. Fresh
  favorites-page membership remains independent of propagated flags; paginated absence
  cannot prove an unpin. Fresh Search/Shared/children flags reconcile settled observations,
  scoped to the owner and revision captured before the request. Projection helpers read
  revision before the unknown-owner guard so identity recovery invalidates every surface.
  The favorites list's version-compatible routing remains in `DocumentEndpoints`.
  Unattributed/preview callers retain the awaited online path and cannot queue offline work.
- **Each Home document renders in exactly one section: Pinned wins, Recent is the residue.**
  The feed is fetched *unfiltered* (`isFavorite: nil`), so the server returns a pinned
  document in both responses and it used to draw twice on one screen.
  `recentsExcludingPinned` (`FavoriteOverlay.swift`) subtracts one list from the other inside
  `recentDocuments`. Three rules travel with it. **Keyed on membership of the rendered pinned
  list, never on `isFavorite`** — the two genuinely disagree, because the favorites action is
  paginated and Home consumes only `.results`, so a favorite past page one is flagged in the
  feed and absent from `pinnedDocuments`; a flag-keyed filter would hide it from *both*
  sections, whereas membership can only move a row, never take it off the screen (every id
  removed is drawn by the Pinned section in the same body pass). **Not done server-side with
  `isFavorite: false`**, which would drop pinned documents from `fetchedRecentDocuments` and
  its cache, so an unpin — which only removes the row from `pinnedDocuments` — would leave it
  in no section until the next successful fetch. And the **memo key must carry the pinned
  ids** — at every writer that moves `pinnedDocuments` without moving
  `fetchedRecentDocuments`, which includes writers that assign the recents array a
  **value-equal** copy, since those leave the `fetched` conjunct satisfied.
  `applyingFavoriteFlag` returns one whenever the row's flag already matches — reachable by
  pinning a stale `searchResults` row against a feed the server already flags, where without
  the conjunct that row renders in *both* sections, i.e. the bug this whole bullet is about;
  `removeAll` returns one for an id the feed lacks, harmlessly, the filtered answer being the
  same either way. Work Offline reseeding must also retain durable pending pins
  (`testAPendingPinSurvivesAWorkOfflineReseed`); rendered membership still belongs in the
  memo key when raw arrays are value-equal. **Accepted residual:** Home
  has no pagination, so Recent is subtracted from and never topped up — a user whose whole
  first page is pinned sees no Recent section while their other documents sit on a page Home
  never requests. Note what this does *not* change: Home's top row was already
  `pinnedDocuments[0]` whenever anything was pinned, since `DocumentListView` has always drawn
  Pinned above Recent.
- **`abilities.destroy` / `abilities.favorite` are still not consulted, deliberately.** They
  decode `decodeIfPresent ?? false`, so absent and denied are indistinguishable — and the
  false negative is the harmful direction with no recovery: hiding Delete on a server whose
  serializer omits the key leaves no way to delete from a list at all. The false positive
  costs one request the server answers 403, which surfaces as a friendly error. It would
  also break the case that needs Delete most: `localDocument(from:)` mints `destroy = false`
  *on purpose*. The meaningful gates are `isLocalDocument` (withhold Pin) and
  `isDeletePending` (withhold both) — the same ones `OptionsSheetView` already applies.
- **A live-collaboration snapshot save reuses the same coordinator, not a second path.**
  `DocumentSaveCoordinator.enqueueLiveSnapshot(documentID:snapshot:projectedMarkdown:title:baseline:)`
  (C2b) PATCHes a full-state Yjs snapshot verbatim via
  `DocsAPIClient.saveLiveSnapshot(documentID:title:yjsUpdate:)` — bytes the collaboration
  manager already holds (`encodeSnapshotForSave`), **not** re-derived from markdown. It routes
  exactly like the classic body save (`saveContentViaRoute`): on Docs 6 the bytes are PATCHed
  to yhub as `{"update": base64}` (a full-state Yjs update is a valid incremental one, so no
  GET/diff is needed), while a pre-Docs 6 server takes the legacy
  `documents/{id}/content/` PATCH tagged `"websocket": true` (through
  `setContent(…, viaWebSocket:)`; the classic body stays byte-identical when false). Docs 6
  live sessions use the enabled y-websocket transport, and snapshot saves use this route. Its
  PATCH carries the whole snapshot and is subject to the deployment's request-size limit. Because
  reconcile is markdown-based, the coordinator carries the **projected markdown** as the
  `PendingSave.markdown` / draft body /
  `lastConfirmedPushMarkdown` stamp, so `finish`, the enqueue-hold, latest-wins coalescing,
  `draftSyncDecision`, and the content cache are all **reused unchanged** — the only branch is
  in `start` (non-nil `PendingSave.liveSnapshot` ⇒ `saveLiveSnapshot`). Today the persisted
  `PendingDraft` carries only `projectedMarkdown`, never the snapshot bytes, so a
  transiently-failed live save that `syncPendingDrafts` later replays goes through the classic
  `enqueue`/`saveDocumentContent` path, which re-derives the bytes from the markdown
  (`MarkdownYjs.encode` on the legacy route, a `BlockNoteIncrementalSave` diff against the
  server's state on Docs 6). Content is preserved and the replay is still conflict-checked like
  any other, but CRDT history for that one save is flattened. C2c wires this live-snapshot save
  into the editor (below); never bypass the coordinator to persist a live edit.
- **Drafts will carry the replica bytes — approved 2026-11-04; native component implemented
  in PR02a, production activation pending.** Native drafts now reference the scoped
  `ReplicaStore` checkpoint/journal through optional `PendingDraft.replica`; large bytes
  stay out of UserDefaults. The classic live-snapshot draft above remains Markdown-only.
  This bullet is the one place the raw draft's constraints live (`docs/architecture.md` and
  `docs/offline-and-sync.md` only point here):
  - The field stays **Optional-on-decode**, even with `PendingDraftStore` quarantine — the
    standing rule in the on-device create bullet ("every field added to
    `PendingDraft`/`DraftBaseline` must stay Optional-on-decode").
  - The draft **keeps `markdown`** beside the bytes: `draftSyncDecision` compares canonical
    markdown, and the classic paths still need a body.
  - The bytes are resent **only while the draft's markdown is canonically equal to their
    projection** — the same `canonicalMarkdown` test `draftSyncDecision` uses, not byte
    equality — **and** the scope/format/generation/revision matches the verified raw store.
    **Every `PendingDraft(...)` reconstruction** in `DocumentSaveCoordinator` (nine
    today: `enqueue`'s whole-draft rebuild — the trap the conflict-stamp carry rule already
    guards — plus the conflict stamp, `adoptServerTitle`, `finish`'s stamp,
    `commitResolvedAttachment`'s in-place draft rewrite, and the rest) must preserve/update
    raw provenance or hold the operation. They have been audited in the component checkpoint;
    the classic `.push` path must never flatten a raw-owned draft.
  - The bytes are document content: **never logged**, and they follow the draft's existing
    store policy — backup-included and **retained on sign-out**, never purged with the content
    cache. Native references stamp account/server/org/document identity, and the raw sender
    checks the current account. The open route rechecks the sign-in generation and
    account after every await (slice B); classic drafts still have no owner stamp.
  - **The owner marker outlives the draft.** `ReplicaOwnershipStore` (UserDefaults,
    versioned and checksummed, `origin|documentID` → scope) is written before any replica
    file. While it names a document, `enqueue` refuses every classic/live save,
    `canStartEditing` is false and `NativeEditorOpen` restores the replica regardless of
    the switch (read-only while it is off; re-enabling restores the same replica). A
    quarantined replica, another account's replica, corrupt marker data, or replica files
    without marker data all open read-only; never "not owned". `ReplicaStore.remove`
    clears it after the replica is unreachable; the only other clear is
    `clearNativeOwnership` for a marker with no replica and nothing unsynced, and the
    only rebuild is Profile's `repairReplicaOwnership`. Read ownership through
    `DocumentSaveCoordinator.nativeOwnership` / `replicaStore`, never a second store
    instance, and never fall back to `UserDefaults.standard` in tests.
    **Known limit:** if a server document created offline is discovered via a concurrent
    list refresh and opened/edited before the create `POST` checkpoints `syncedServerID`,
    seeding a non-empty unmigrated server-scoped replica makes `migrateLocalReplica` refuse
    with `alreadyExists`, halting migration and leaving that document read-only until
    resolved.
- **C2c wires the write path into the editor, behind the same weak-delegate seam C1 used
  for reads.** `EditorLiveWriteCoordinating` (`forwardLocalEdit() -> Bool`,
  `flushPendingLiveSnapshot()`) is implemented by `LiveEditingBridge` and held as `weak var
  liveWrite: EditorLiveWriteCoordinating?` on `EditorViewModel` — the collaboration manager
  never enters the view model, only this protocol does, and `EditorView` sets it once after
  lazily building the (single, dual-role) bridge.
  - **The mode split lives in `markDirty()`.** Its first line is
    `if liveWrite?.forwardLocalEdit() == true { …; return }`: in live mode a keystroke
    forwards to the replica (integrate + broadcast + schedule the snapshot debounce) and
    returns **without** setting `isDirty`, touching `dirtySince`, or starting the autosave
    timer — durability now belongs to the replica/snapshot, and staying clean is what keeps
    `canEngageLiveEditing` true across a run of keystrokes. `nil?.forwardLocalEdit() == true`
    is `false`, so with `liveWrite` unset (every pre-C2c test, any screen without a bridge)
    this is a provable no-op and the classic path is byte-for-byte unchanged — the standing
    proof is that every existing `EditorViewModel*Tests` test passes with no changes.
  - **The write gate (`canEngageLiveWrite`) is the C1 read gate plus one thing:**
    `canEngageLiveEditing` (loaded, clean, no dirty/pending-save/draft/conflict,
    idle/saved) **and** the last applied projection is `isFullyModeled`, with a valid
    write baseline, no pending remote frame, and fresh fail-safe/pending-struct checks.
    A synchronous replica notification invalidates that baseline before the replica can
    be written again; local forwards change only `localEditVersions`, not the inbound
    version or this modeled flag. A document with any
    `.unknown`/lossy/opaque block never satisfies this — it stays read-live but can never
    write-live, because such a projection can't round-trip back through
    `blockNoteBlocks(from:)` without the tracked `old` baseline silently desyncing from
    the replica.
  - **Downgrade never loses an edit.** Every mutator already mutates `blocks` *before*
    calling `markDirty()`, so by the time `forwardLocalEdit()` declines (delegate nil, gate
    closed, or a thrown `applyLocalEdit` from a fail-safing replica), the on-screen edit is
    already there for the classic path that runs next to persist. At worst this costs one
    extra classic autosave cycle, never content.
  - **The write baseline (`old`) is id-stable and re-synced, never re-parsed.**
    `MarkdownYjs.blockNoteBlocks(from: [EditorBlock])` (a new overload beside the
    markdown-parsing one) maps each `EditorBlock` straight to a `BlockNoteBlock` reusing
    `EditorBlock.id` as the BlockNote id — **never** a fresh `currentMarkdown()` re-parse,
    which mints new ids per call and would make every keystroke diff as a whole-document
    replace and clobber concurrent peers. The bridge captures this baseline
    (`lastAppliedBlocks`) only when the editor is known to equal the projection: on every
    engage (including a no-op empty diff) and again after every `applyLiveRemoteChange` —
    so a peer's edit landing between two local keystrokes re-syncs `old` before the next
    local diff reads it. A local forward advances the baseline itself.
  - **Remote projection/UI applies are coalesced to one per display frame; write-safety
    bookkeeping stays SYNCHRONOUS with integration.** `applyReplicaUpdate` still decodes,
    integrates, bumps `replicaVersion` and fires the per-document observer in the **same
    main-actor turn**. The observer immediately invalidates `lastAppliedBlocks` (`nil`)
    and marks a remote apply pending; it never leaves a stale baseline eligible for a
    local diff. Only the full projection/render, `liveChangeSet`, and the one non-install
    funnel (`applyLiveRemoteChange`) wait for `LiveRemoteApplyScheduling`'s next frame.
    Production uses a one-shot `CADisplayLink` in common run-loop modes; tests inject an
    immediate or manually advanced scheduler. All messages integrate immediately; a burst
    schedules once and projects the **latest** replica, with no sleeps. The view's later
    `.onChange(of: replicaVersion)` shares that pending apply and skips an already-applied
    version. `isApplyingLiveContent` and the write gate never project from a UI read.
  - **Flush BEFORE a local mutation, never from the post-mutation forward.** Every local
    content mutation calls `EditorLiveWriteCoordinating.prepareForLocalEdit()` before
    reading indices/ranges or changing blocks. It flushes a pending frame, restoring the
    editor and id-stable `lastAppliedBlocks` to the integrated replica before the edit.
    This is the sole exception to waiting for a display frame. `forwardLocalEdit` refuses
    a pending/invalid baseline; flushing there would already be too late and overwrite
    the keystroke. A buffered UIKit `updateText` rebases its local replacement onto the
    flushed peer text (`rebasedLiveInput`, character-safe with UTF-16 caret offsets),
    preserving disjoint peer changes. Native text events carry their committed selection
    so rebasing keeps the caret in UTF-16 space; Return carries its source buffer and
    transforms the supplied offset even after selection deletion flushed the frame. Ordinary
    pending-input/source-correction probes that decline must not flush: the later text
    callback still holds its pre-frame buffer. Composition (#226) keeps marked text on
    screen, updates only the held peer base during a frame, and uses its existing
    `rebaseComposition` policy at commit; a commit before frame delivery flushes first.
    `localEditVersions` still advance only on a local forward, never `replicaVersion` or
    `remoteChangeTokens`, so no local self-echo is scheduled.
  - **Observer and scheduler lifecycle follow the live entry.** Register the weak observer
    on every live-session **(re)acquisition**, never at bridge construction: the bridge
    can outlive a linger-teardown in SwiftUI `@State`. The manager drops the observer at
    teardown. `stopRemoteApplies` cancels the pending frame, invalidates its generation
    (even an already-delivered callback becomes inert), clears the baseline, and is called
    on disappearance after flushing local durability work. It never clears the manager's
    observer slot: another screen on the same document may have registered there first. Reacquisition
    re-enables the retained bridge and schedules catch-up for an existing replica, even
    when no new version edge arrives. Never register observers for documents without sessions.
  - **TOP SAFETY, restated at the debounce:** the bridge's ~60 s cancel-and-reschedule
    snapshot fire re-derives everything fresh (never trusts state captured at schedule
    time) — `encodeSnapshotForSave` returning `nil` means **skip, no PATCH**, and the
    projection is re-checked for `isFullyModeled` because it can have gone lossy between
    the forward and the fire. Only when both hold does `persistLiveSnapshot` enqueue
    through `enqueueLiveSnapshot`, advancing the classic dirty baseline
    (`savedMarkdown`/`serverBaseline`) so a later downgrade-to-classic save reconciles via
    `draftSyncDecision` rule 1 (its `lastConfirmedPush` already equals the live-pushed
    body) — never a false conflict against the app's own write.
  - Verified by an end-to-end integration test (engage → forward → remote apply →
    debounce-fires-a-snapshot → force fail-safe → next edit downgrades), a deterministic
    stale-baseline **race regression** (remote update integrated + `replicaVersion` bumped,
    then a local forward *before* the deferred re-sync — asserting the emitted update
    projects the real replica to the merged document, no corruption reaching peers), plus
    the existing C2a differential fuzz (unchanged; C2c adds editor callers, not new
    sync-engine surface). **Opt-in behind the default-off `schrift.liveCollaboration`
    flag — the C3 Profile toggle (Profile → Preferences → "Live collaboration", an
    `@AppStorage(LiveCollaborationPreference.key)` switch) is the only writer. The
    default stays off; the on-device end-to-end WebSocket check is not yet
    verified with a TestFlight build. The flag is read lazily, so a
    flip affects newly requested sessions, not screens already open.** Docs 6's yhub
    collaboration server speaks plain y-websocket at
    `/collaboration/ws/v1/{org}/{documentID}`, not Hocuspocus. Its transport is enabled;
    `supportsLiveCollaboration` requires an advertised collaboration URL, and the separate
    default-off user preference still gates session availability. See
    `docs/architecture.md` ("Editor wiring — the write path complete (C2c)" and the
    "C3 (shipped)" paragraph).
- **A4 adds yhub framing beside Hocuspocus; A5 enables it in production.**
  `CollaborationWireProtocol(config:)` selects `.yWebSocket` when
  `ServerConfig.usesCollaborationYDocServer`, otherwise `.hocuspocus`. The transport alone
  adds/removes the document-name prefix; the session shares `SyncMessage` and
  `AwarenessCodec` payload handling. y-websocket uses type 0 sync (step 0/1/2), type 1
  awareness, and type 3 query-awareness, with **no auth message**; Hocuspocus's type 4
  SyncReply is not a y-websocket sync frame. The empty awareness keepalive (`AQEA`) is
  valid and leaves peers/replica unchanged. The new endpoint is
  `/collaboration/ws/v1/{org}/{lowercase UUID}` with no trailing slash: use
  `CollaborationEndpoint`'s API-origin scheme/host/port and explicit `Origin`/cookies.
  Only the validated org comes from config (the Networking rule above), never its host.
  y-websocket awareness nests the name/color in `user`; Hocuspocus keeps its flat shape.
  **A writer renews its awareness every 15 s with a strictly higher clock** (y-protocols'
  `outdatedTimeout / 2`); peers drop a state not renewed for 30 s, so a single announce made the
  web show us for ~30 s at most. The query-awareness reply also bumps the clock, since an equal
  clock does not refresh a peer's timer. The renewal stops on stop/disconnect; readers never send it.
  The awareness clientID is the session's own random id, not the replica's `YDoc.clientID`:
  yhub relays any id and the web never joins the two, so they need not match.
  The editor passes **`Document.abilities.update`**, never inferred link role, into session
  acquisition (both navigation surfaces already carry the document as `pinRow`). Missing
  metadata fails closed. Readers receive/project updates but publish no awareness (including
  replies to query-awareness), cannot broadcast edits, and cannot snapshot or report an edit
  handled live. `canProjectReplica` checks sync/replica health; `canWriteReplica(for:)` adds
  the update ability and is checked by the bridge before forwarding. Retain permission across
  suspend/resume. Reconnect answers a server's step1 with the retained replica's step2 diff,
  **including the delete set**: a deletion-only suspended edit does not change its state
  vector and must still reach the server. Do not gate state replies on replica health. Readers
  send none: a reader must not publish, whatever its replica holds. An entry keeps one ability
  (the latest caller's) and keeps its replica across a writer→reader flip, so that replica may
  carry edits whose broadcast failed; they go out again only if a writer reopens it.
  Production enables yhub when the server advertises a collaboration URL. The manager's
  server-support seam remains available to tests. The independent default-off
  `schrift.liveCollaboration` user preference still gates session availability.
  A server permission change mid-session is not re-read by the client; the server enforces
  write permission, and refetching abilities on reset belongs with native live editing (phase 2 PR09b).
  **Switch-on evidence (S4/S5):** on the real yhub server,
  snapshot and live sync for a document filled with every web block were byte-identical;
  Schrift's core re-encoded them identically to yjs 13.6.33; the web cursor arrived as
  y-prosemirror relative-position JSON and resolved correctly; off-main decode passed.
  The on-device end-to-end check is not yet verified with a TestFlight build.
  Rollback is reverting `ServerConfig.yWebSocketLiveCollaborationEnabled` to `false`.
  A dropped socket does not reconnect automatically: it is rebuilt on a network reachability
  change or foreground resume. Peer edits stop arriving until then; local edits still reach
  yhub through the ~60 s HTTP snapshot. `runSyncPass` skips a draft (before and again after
  its GET) while `hasHeldLiveReplica` is true: the entry can write (`canUpdate`) and holds a
  replica that has not fail-safed. Such a replica sends its own step2 diff, so replaying the
  markdown could insert the same edits as new Yjs items. A reader never sends step2, so its
  draft is never skipped. After the session's initial step2 exchange,
  `LiveEditingBridge.initialSyncDidChange` re-persists the replica snapshot through
  `persistLiveSnapshot` **only while the stored draft's markdown is canonically equal to the
  replica's projection** (`canonicalMarkdown`, the test `draftSyncDecision` uses) **and the
  title passes the same rule**: `draftSyncDecision` with the draft's baseline and title, the
  session's `knownServerTitle`, and no server timestamp. A co-author's rename the user never
  made (adopt) or two different renames (conflict) leave the draft, since the snapshot PATCHes
  the on-screen title; so does an unknown server title. `canonicalMarkdown` ignores leaf
  nesting. `knownServerTitle` is session-only and updated by editor fetches and landed saves;
  a co-author's title-only rename changes no Yjs content, so it does not refresh over the live
  socket and the gate can still approve the old local title. This is the pre-existing live-title
  gap: the gate narrows it but does not close it. A draft that differs only by a leaf's indentation
  is re-persisted flat: content
  is kept and leaf structure follows the replica. The normal
  successful save path then clears that draft. Any other draft holds edits the replica lacks
  (typed on the classic path after a failed snapshot disengaged live mode, typed with no
  replica, or restored by reopening a `.pendingSync` document), so the bridge does nothing and
  never overwrites or clears it. When the manager tears down an idle entry that held a replica
  (`teardownIfIdle`, or the idle drop in `suspend()`), it fires `onHeldReplicaReleased`, which
  `RootView` wires to `syncPendingDrafts()`, so the skipped draft gets its classic replay. A
  replica fail-safe does not fire `onHeldReplicaReleased`: a draft skipped while it was held
  waits for the next normal sync trigger (reconnect, foreground, launch). A
  kill before reconnect leaves no replica, so the draft replays once. What stays: a skipped
  draft waits while the editor holds the replica and no socket is rebuilt, and classic saves
  outside `runSyncPass` (the retry, an autosave after live mode disengages) can still race the
  socket, as they already could on legacy servers.
- **The replica broadcasts the formatting-cleanup update it makes on its own.** An inbound
  update that touches a formatted text makes `cleanupTransactions` open a second, local
  transaction with origin `nil` (B4). yjs providers broadcast that transaction's update like
  any other, so `DocumentCollaborationManager` wires `YDoc.onUpdate` on each replica and
  sends origin-`nil` updates through the entry's session exactly like `applyLocalEdit`
  (fire-and-forget on the main actor, entry re-read at fire time). It never bumps
  `replicaVersions`/`remoteChangeTokens`/`localEditVersions` — the cleanup is derived from
  an inbound update, not a new remote change or a local edit — and a reader never publishes.
- **The 404/403 refusal and `.discardServerWins` branches have a third suppression, keyed on the *server* id.**
  `isPendingCreate` covers the local id only, so it misses the draft the migration writes
  under `serverID` before removing the local one — which in that window is the **only
  copy**. Both branches therefore also skip any id a checkpointed record
  is waiting to migrate onto. Only those branches, never the push: the push is what clears
  `finishMigration`'s both-drafts guard.
- **A photo picked with no network becomes a placeholder image block, and a
  *content-keyed* save hold is what keeps it off the wire.**
  `PendingAttachmentStore` mints `schrift-attachment://<localID>` and stores the prepared
  JPEG beside the record (UserDefaults records + files under Application Support
  `dev.llun.Schrift/PendingAttachments`, **backup-included** — until the upload lands
  those bytes exist nowhere else, so this deliberately omits
  `DocumentContentCacheStore`'s `isExcludedFromBackup` line and has **no eviction**;
  `contentCacheEvictions` selects by recency and here would delete the only copy of a
  photo still on screen). Records follow the *create* store's corruption discipline —
  quarantine-on-detect plus a **sticky** `holdsUnreadableData`, now also used by
  `PendingDraftStore` — because the first write after a corrupt
  read would otherwise rebuild the blob and leave every surviving placeholder
  record-less, each one holding its document's saves with nothing left to explain why.
  Every field added must stay Optional-on-decode.
  - **The scheme is allowlisted in `parseImageLine`** (the only non-http scheme that
    classifies) so a queued photo is a real `.image` block: `addsImage` verifies an
    insert by re-parsing and counting image blocks, and an `.unknown` block would both
    fail that check and drop the document out of live-write eligibility.
  - **What keeps it off the server is `markdownReferencesPendingAttachment`**, asked of
    the markdown a save is about to push at every path that can reach `start`:
    `enqueue`'s park (a fourth disjunct beside pending-create/conflict/in-flight, and a
    third in the `.pendingSync` stamp — that one additionally gated on nothing being
    in flight, since this is the first hold that can co-occur with a real save on the
    wire), `releaseHeldSave`, `finish`'s queued restart, and
    a pre-fetch skip in `runSyncPass`. **Keyed on content, never on the store** — a store
    that cannot be decoded stalls the replay instead of leaking a placeholder — and
    because each gate parses the save in front of it, a document with *two* queued photos
    releases only when the last one lands, with no per-record bookkeeping.
  - **The replay is `runAttachmentPass`**, in the coalesced funnel between the create
    replay and the draft replay (after creates — a photo in a locally-created document
    has no server id to upload against; before drafts — the upload is what releases the
    hold). Two-phase like the create replay: the resolved URL is checkpointed onto the
    record **before** any rewrite, so a death between the two resumes at the rewrite
    instead of uploading a second copy. Everything after the upload is **one synchronous
    main-actor turn with no awaits** (draft, queued slot, open editor, record removal,
    re-enqueue), because an open editor can flush at any suspension point with blocks that
    still name the placeholder — a split rewrite could drop the record and then have that
    flush reintroduce a placeholder nothing can resolve. The hand-back is a
    **re-`enqueue`, not a release**: nothing can rewrite a parked `PendingSave` in place,
    `enqueue` re-derives every hold from the content, and a draft left by a previous
    process has no parked save to release at all. A rewritten queued slot is rebuilt
    **classic** (`liveSnapshot: nil`) — CRDT bytes still encode the placeholder and
    `start` prefers them. Gate order per record: re-read the mirror → session scope
    (origin+owner, failing closed; a foreign record is kept, silent, and **never
    collected**) → collection *before* the failure skip (else a failed record for a
    deleted document is never cleaned up; deferred while an editor is open) → terminal
    skip → parent-create gate. `migrateCreatedDocument` re-keys these records **before**
    `removePendingCreate`, beside the children re-key and for the same reason.
  - **Native records (PR13b) are not this pass's:** they carry `native` and no placeholder, so the
    classic collection would delete them; the pass hands each one whose owner is the signed-in
    account to `runNativeAttachment` (the PR13b bullet) and moves on.
  - **Those four gates cover the REST save path only.** `insertImageBlock` calls
    `markDirty()`, whose first line forwards to `LiveEditingBridge.forwardLocalEdit` and
    **returns without enqueuing** — so an edit made while a live session is engaged is
    broadcast to peers and never becomes a save for these gates to hold, and
    `canEngageLiveWrite` cannot catch it either (`YBlockProjection.classifyImage` models
    *any* string url, so a placeholder block is `isFullyModeled`). The photo-insert path
    therefore **refuses to queue while `liveWrite?.isHandlingLocalEditsLive` is true**,
    checked *before* the insert rather than after — that protocol member is
    `forwardLocalEdit`'s own condition without its side effects, and a nil delegate reads
    false so every classic path is unchanged. Keep this guard: it is the one case where
    "the save hold catches it" is false.
  - **Photo insertion is un-gated; File insertion is not, and the asymmetry is
    deliberate.** `canOfferPhotoInsertion(hasTarget:canInsertPhoto:)` dropped
    `isOffline`/`isLocalDocument` (the `editorToolbarActions` discipline), while
    `filteredSlashItems` keeps them and filters on
    `SlashMenuAction.requiresImmediateUpload` — true for `.insertAttachment` alone. A
    photo has somewhere to go when the network doesn't; a file does not yet, and giving it
    one means a placeholder shape the parser classifies, a hold that recognises it, and a
    replay branch that uploads it. `insertPhoto` queues directly when offline or local,
    falls back to the queue on a retryable failure, and errors on a rejection on the
    merits. `insertImageBlock` now **reports** whether the image landed, so a queued photo
    swallowed by a fenced code block drops its record instead of stranding bytes.
  - **Rendering branches ahead of `MarkdownImageView`** at both surfaces: a placeholder
    can never match an http(s) origin, so `imageLoadPolicy` would fail closed to a
    tap-to-load card whose host is a UUID. `PendingAttachmentImageView` reads the bytes
    from disk and never issues a request; its `.missing` state is the escape hatch for a
    record-less placeholder (the only way to clear that hold is removing the block), and
    the display is owner-scoped so one account never sees another's photo.
  - **The rewrite is keyed on the record, not on the placeholder's spelling.**
    `pendingAttachmentID` accepts a trailing slash and either case, so the predicate
    treats those as the same photo; a rewriter matching the canonical URL byte-for-byte
    would hold a document it could never release. The rewriter also splits lines exactly
    as `parseEditorBlocks` does (CRLF *and* lone CR), for the same reason — disagreeing
    about a line boundary is a permanent hold, not a cosmetic difference.
  - The predicate **parses**; a substring test would hold a document's saves because
    someone quoted the scheme in a code block, where there is no image leaf to delete and
    therefore no escape from the hold. The `contains` check is only a fast path.
  - `runSyncPass`'s skip is **load-bearing, not an economy**: the `.push` branch would be
    held by `enqueue` anyway, while `.conflict` or `.discardServerWins` would record a
    conflict before attachment replay uploads and rewrites the placeholder.
  - `releaseHeldSave` also gained a **conflict** guard, as defence in depth rather than
    as any path's primary gate: nothing can rewrite a parked `PendingSave` in place, so
    the attachment replay re-`enqueue`s the rewritten body (which re-derives every hold
    from the content) instead of releasing this slot directly. It earns its place anyway —
    this is one of the three ways to reach `start`, and a document can pick up a conflict
    while a photo sits queued offline, where releasing would full-overwrite a diverged
    server body from a background pass with no pill answered.
  - `saveMarker.hadPendingSave` stays `inFlightContent != nil`: a parked save is not on
    the wire. Do not "fix" it to consult `pendingSave` — that wedges "keep the server
    version", which is the lesson the conflict hold already paid for.
- **Draft replay is `syncPendingDrafts()`, and it is repeatable** — the funnel for
  the reconnect (`ConnectivityMonitor`), foreground and launch triggers.
  `recoverDrafts()` is just the once-per-process launch wrapper over it. An overlapping
  trigger is **coalesced, not dropped** (a reconnect landing mid-pass would otherwise be
  lost until the next foreground cycle). Because it now runs on documents the user is
  *looking at*, three things follow: it **skips a `.failed` draft** (a retry candidate
  whose "Couldn't save" affordance is on screen); a beyond-window **`.pendingSync`** draft
  is never discarded but **recorded as a conflict** (skipping it silently stranded it —
  never pushed, never discarded, no pill, so the only escape was a retry tap that
  overwrote the newer server copy unasked); and a stale **legacy** (baseline-less) draft
  is never deleted by `runSyncPass` — `.discardServerWins` records a conflict on both
  launch and mid-session passes so the user chooses Keep mine / Keep server, and a
  404/403 marks a waiting classic draft `.failed` rather than deleting it (matching native
  drafts). `EditorViewModel.reconcileDraft` records the same conflict when the editor
  opens the draft first.
- **A failed save is classified, not just failed.** `retryableSaveFailure` routes a
  transient/transport failure (offline, 5xx, rate limit) to **`.pendingSync`**
  ("Saved on this device · syncs when online") rather than the hard `.failed` reserved
  for a save the server rejected on the merits. `.sessionExpired` is *not* retryable.
- **Draft-vs-server reconciliation is `draftSyncDecision`** (`DraftSyncDecision.swift`),
  not a bare clock comparison. In order: (1) the server body still equals what we last
  pushed (`lastPushedMarkdown`) ⇒ the last writer was us ⇒ `.push`; (2) the draft carries
  a **`DraftBaseline`** and the server hasn't moved past it (by timestamp, or the body
  still equals the baseline body — a web *rename* bumps `updated_at` without touching
  content) ⇒ `.push`, otherwise ⇒ **`.conflict`**; (3) no baseline (a legacy draft) ⇒ fall
  back to `pendingDraftClockTolerance` (120 s added to the draft's client timestamp;
  within the window the draft wins, beyond it `.discardServerWins` is returned, which
  `runSyncPass` records as a conflict rather than deleting the draft). **A
  baseline-carrying draft is never silently discarded** — the tolerance rule is only the
  legacy path.
- **A conflict is detected and *asked about*, never auto-merged** (there is no on-device
  Yjs decoder and no CRDT). `.conflict` records a `SyncConflict` (the server's
  `updated_at` only — no server markdown, so "keep the server" must re-fetch), which
  makes `enqueue` **hold** the push: it writes the draft and the queued slot but starts
  no save, so an autosave can never overwrite the conflicting server copy unasked. Both
  detection sites record it — `syncPendingDrafts` and the editor's `reconcileDraft`,
  *including* `reconcileDraft`'s `.pendingSync`/`.failed` early return, or a "tap to
  retry" would push over a web edit the app had already fetched. `resolveConflictKeeping‐
  Local` releases the held push **and advances the draft's baseline** to the server state
  the user chose to overwrite (or a failed push would re-detect the identical conflict
  forever); `resolveConflictKeepingServer` is the one sanctioned discard and **fetches
  before it discards** (a failed fetch must not cost the user the only copy of their
  work). Every purge path (`discardPendingWork`, `suppressLocalWriteThrough`,
  `handleDidDelete`, the create migration's **adopt-the-server** branch, which deletes
  every local trace for that id, the replay's **start-over**, whose id is now dead, and
  `completePendingDelete`, which runs `discardPendingWork` first for exactly this reason)
  clears the record, or the enqueue-hold
  wedges the document's save pipeline permanently. **`handleDidQueueDelete` is the one
  sanctioned non-clearing sibling** — a *deferral*, not a purge: it ends the editing
  session for a deletion that is queued and still cancellable, keeping the draft, the
  record and the caches because those are what the undo restores. It cannot wedge
  anything, because nothing can enqueue for a tombstoned id (the sync pass skips it, the
  create pass will not resume onto it, and the screen is on its way out), and it is
  discharged by exactly two terminals: the undo, or the completion. **Invariant: a conflict is only ever recorded with no save in
  flight** (`apply` diverts whenever `pendingSave != nil`, so `reconcileDraft` is
  unreachable during a save; `syncPendingDrafts` guards on both; the **create
  migration** holds by an explicit check, *not* by the tempting argument that the
  id was just minted — it only records on the **resume** path, where the id may
  come from a previous process, may have returned in an ordinary list fetch since,
  and may already carry a save this process started, so what holds it is
  `finishMigration`'s `guard inFlight[serverID] == nil, queued[serverID] == nil`
  immediately before the record),
  which is why
  `SaveMarker.hadPendingSave` asks whether a save *reached the network*
  (`inFlightContent != nil`) and **not** `pendingSave(_:) != nil` — the held slot is
  never sent, and counting it wedged "keep the server version" permanently.
- **The conflict record is persisted with the draft** (`PendingDraft.conflictServerUpdatedAt`,
  rehydrated into `conflicts` in the coordinator's `init`). An in-memory-only record meant a
  conflict the app had already *detected and shown the user* evaporated on process death: on
  the next launch the editor renders the stored draft synchronously and unblocks editing
  **before** any revalidation returns, so a Done tap reached `enqueue` with no hold in force
  and full-overwrote the body the user had just been warned about. `enqueue` rebuilds the
  whole draft, so every draft write must carry the stamp forward or the next keystroke erases
  the hold.
- **The conflict record's lifecycle is an invariant, not a detail: a record is meaningful
  *only while local work exists that would overwrite the observed server body*.** Record it
  the moment such work appears; release it the moment it is gone. Both halves are
  load-bearing, and both were got wrong before they were stated: recording where there is no
  local work (entering edit mode) leaves a **phantom** pill and an enqueue-hold that nothing
  clears and whose "Keep my version" has nothing to push; failing to release a record that
  has become moot (the co-author reverted, the user discarded, our own push landed) **parks
  every future save for that document forever** behind a question with nothing left to ask,
  and leaves a destructive "Keep the server version" armed against unrelated new work. So:
  `markDirty` records (local work is being created) but `startEditing` does **not** (it only
  hides the banner — and it must *keep* the stash, or the first real keystroke has nothing
  left to detect); `reconcileClean` **clears**, because `apply` only reaches it with no
  pending save, no draft and not dirty, i.e. no local work by construction. Only a `.push`
  decision clears at the other sites — `.discardServerWins` is **not** "no conflict", it is
  rule 3 firing for a legacy draft the server has moved past, which `runSyncPass` records.
- **Detection runs in `apply`'s dirty branch too**, not only via `reconcileDraft`. That
  branch (`pendingSave != nil || isDirty` → `cacheServerCopy`) used to return without
  consulting the decision, which made the whole safety net depend on **keystroke timing**:
  a queued offline draft whose revalidation proved the server had moved on got its push
  held — *unless* the user happened to type one character while that fetch was in flight,
  in which case nothing was recorded and the next autosave full-overwrote the web edit the
  app had just fetched. Detection there is gated on `pendingSave == nil` (preserving the
  no-save-in-flight invariant) and feeds rule 1 from
  `DocumentSaveCoordinator.lastConfirmedPush(documentID:)` — **not** from the stored draft,
  which is nil right after a save lands and would make our own just-pushed body read as a
  diverged server and raise a false conflict against the user.
- **A held save must never read as a saved save — while editing either.** Detection
  on the dirty branch means a push can now be held *mid-session*, so the surface the user is
  actually looking at while typing is the editing surface's save-status row
  (`SaveStatusIndicator`), not the reading caption. Its pure
  resolver `saveStatusDisplay` therefore applies the same precedence rule 0 as `syncCaption`:
  a recorded conflict outranks the save state, because nothing is being sent and **no
  affordance here can send it** (`saveNow` re-enqueues straight back into the hold). It shows
  a passive "Saved on this device" (`cloud_off`) rather than "Saving…"/"Saved" — which would
  claim a sync that is not happening — and offers no `.failed` "tap to retry", which would
  only re-park. The conflict pill (rendered during editing too) stays the sole affordance.
  The one carve-out is `.dirty`, which keeps its **Save** funnel: the newest keystrokes are
  not on disk until the flush writes the draft, so "Saved on this device" would be a lie
  there, and the tap is exactly what persists them.
- **A save PATCHes the title too, so the title gets its own rule — a *merge*, not a
  dialog.** Title and body are independent fields, so `DraftBaseline` carries the server's
  **`title`** next to its `markdown`, and `draftSyncDecision` returns
  **`.push(title:evidence:)`** — the title the replay must PATCH, resolved by
  `draftTitleOutcome`, never the caller's to pick (the `evidence` is the body half, from
  `PushEvidence`, and rides through untouched). Given the baseline's title `b`, the draft's
  `d`, the server's `s`: `d == b` (only the server renamed) ⇒ **adopt `s`**; `s == b` or
  `s == d` ⇒ push `d`; all three differ (two renames) ⇒ **`.conflict`**; `b`/`s` unknown, or
  the server no newer than the baseline, ⇒ push `d` (so a **titleless legacy baseline behaves
  exactly as before** — nothing adopted, no conflict invented). Before this, a web rename left
  the body untouched, so it *was* rule 2's body-equality `.push` — correctly — and the replay's
  title PATCH then silently reverted the co-author's rename with no prompt. Adopting a title
  advances the baseline's **title** with it (`adoptedBaseline`) — otherwise a *second* remote
  rename reads as "both renamed" — and the date short-circuit is what makes **"keep mine"
  stick**: `resolveConflictKeepingLocal` advances the baseline's timestamp, so a failed push's
  retry can't re-raise the title conflict the user just answered.
- **The editor must not push a title behind the replay's back.** It **never refetches on
  foreground** (it only flushes) — and foreground/reconnect is exactly when
  `syncPendingDrafts` runs — so a background replay can adopt a rename, push it, and land it
  entirely behind an open screen still showing the old title, whose next flush would PATCH the
  old name straight back. So: `reconcileDraft` **and** `apply`'s dirty branch adopt a resolved
  title onto the screen and the stored draft (`adoptServerTitle`, which rewrites the draft
  without starting a save); the coordinator tracks `knownServerTitles` (a landed save, plus
  every fetch that clears `mayPredateSave`, via `noteServerTitle` in both `apply` and
  `installFetched`); and `adoptQueuedTitleIfUnseen` runs in **both** save funnels, preferring
  the queued save's title, then the draft's, then the known server title — unsaved local work
  holds a title the server doesn't have yet. An **unflushed local rename** (`title !=
  savedTitle`) outranks all of them; it is what makes a reconcile call two titles a conflict
  rather than a merge.
- Content is cached on-device in **`DocumentContentCacheStore`** (one JSON per
  document in the signed-in account's folder under Application Support, backup-excluded,
  ≤50 entries per account by most-recent `syncedAt` via file mtime): `load()` shows a local copy
  **synchronously** (precedence: in-flight save → stored draft → cached copy →
  network-with-spinner), then revalidates silently as the awaited structured
  tail of `load()` (deliberately no unstructured `Task`; a generation counter
  makes superseded fetches no-ops) — content equality (never re-serialized
  blocks) decides whether the fetched body counts as a change at all.
  The coordinator write-throughs the cache on save success; delete and 404/403
  revalidation purge the entry; sign-out clears the store. See
  [`docs/offline-and-sync.md`](../offline-and-sync.md).
- **Offline is editable, and since the create UI landed a document can be created
  offline too.** The three reading-surface edit gates (the block tap,
  "Start writing", and the toolbar's Edit action) were lifted 2026-08-01;
  `editorToolbarActions(isEditing:isLocal:isOffline:)` gates only Share on availability;
  Edit/Done stay reachable offline when content has loaded. What makes this safe is that the save
  pipeline was already built for it: `enqueue` persists the draft **before** it
  attempts the PATCH, `retryableSaveFailure` routes a transport failure to
  `.pendingSync` rather than `.failed`, and `syncPendingDrafts` replays through
  `draftSyncDecision` on reconnect/foreground/launch. The one entry guard left is
  `startEditing`'s `hasLoadedContent` — **do not add an offline check back**; a
  document with nothing loaded is the case that guard exists for, online or off.
  **Within the editor's own surfaces the dividing line is whether the action
  POSTs**, and it cuts through the editing surface itself: every block
  transformation is a local edit the draft pipeline queues, and so is **inserting a
  photo** (it becomes a placeholder `PendingAttachmentStore` uploads later), but
  **inserting a file** uploads a multipart attachment that has no queue, so it stays gated
  offline in *both* entry points — the File choice behind the bar's Attach button is
  disabled (via `canOfferAttachmentInsertion`), and `.insertAttachment` is dropped from the
  slash menu by the pure `filteredSlashItems(query:isOffline:isLocalDocument:)`
  (`requiresImmediateUpload`). Offering it would open the picker only to fail. **File also
  gates on `isLocalDocument`** at both entry points: a create that 500s with the network fine
  mints a local document while `isOffline` reads false, and the upload would POST a
  client-minted id for a 404 and an impossible retry.
  The editor's two **create** buttons are **ungated** — neither on `isOffline` (a failed
  POST falls back to a local document the replay sends later) nor on the parent (2026-08-06:
  the replay orders two dependent creates). With the native editor on and no saved server
  setup they create nothing: "Add a subpage" offline, or either button under
  an unsent parent, shows `create.needs_online`, and a failed POST keeps its own error. Where the parent is itself local,
  `EditorViewModel.addSubpage` and `PagesTreeViewModel.addPage` mint **directly, issuing no
  request** — the POST would address `documents/{local-uuid}/children/` and take a 404, which
  `retryableSaveFailure` correctly refuses to retry, so the transport fallback beside it
  could never fire and the user would be told a possible thing was impossible.
  `EditorViewModel.mergedSubpages` reports a local parent's level as known-**empty** rather
  than nil for the same reason `loadChildren` is gated: the server provably holds nothing
  under an id it has never seen, and nil rendered a bare "Subpages" heading with no rows and
  not even the line saying there are none.
  **This is a rule about the editor's surfaces, not an app-wide invariant — do
  not read it as an inventory.** Several POSTing affordances elsewhere are
  deliberately ungated: Home's **`+`** now creates *locally* under Work Offline or on a
  retryable failure, and errors with `home_error_create` only on a rejection the server
  actually made (or when no account id is known). With the native editor on and no saved
  server setup it shows `create.needs_online` offline and keeps `home_error_create` on an
  online failure. The three create buttons (Home `+`,
  Add subpage, Pages "New page") are disabled while their create is in flight
  (`isCreatingDocument` / `isAddingSubpage` / `isAddingPage`; a second call returns nil
  without a request, or repeated taps on a hanging POST mint duplicates), and Home and
  the editor mint locally with no request whenever `availability.isOffline` (path down or
  Work Offline); the drawer has no availability and still POSTs first. Also the Options
  sheet's local actions (including queued Delete), which remain reachable offline.
  Share is hidden in the toolbar and Options while offline; Version history is
  disabled with a localized explanation. An already-presented Share/history sheet
  is dismissed when availability disappears.
  Two decisions ride with this. (a) **`isOffline` never gates durability or a save
  decision** — it gates chrome (the banner, the `.pendingSync` retry affordance,
  and the document header's `PresenceBar`, via `headerPeers`/`presentedPeerCount`
  — that was the Options button's presence *badge* until the shared header gave
  both surfaces a bar, and note the gate now reaches the reading surface too)
  plus the POST-only File affordance, and the Home `+` and editor Add-subpage
  create paths, which read `availability.isOffline` only to skip straight to the
  local mint they would fall back to anyway (durability is unchanged).
  Nothing about whether an edit is kept, queued, or replayed reads it.
  **Availability for editor/Home search controls uses one injected
  `OnlineAvailability`**, reading Work Offline and the live `ConnectivityMonitor`
  path. A satisfied path does not promise a usable server: 401/authentication,
  403/permission, conflicts, save failures, 429 and 5xx keep their existing error
  paths; they never disable controls by pretending the network is offline.
  Home may report a transport load failure through its own offline banner, but
  this historical fetch outcome is not the control-availability signal. A
  **cancelled** load is no outcome at all: Home and Shared return from the load's
  `catch` on `Task.isCancelled` before touching `loadFailedOffline` or the error
  (`URLError.cancelled` reaches them wrapped as `.network`), and their `.refreshable`
  runs `refresh()` in an unstructured `Task` it awaits, so SwiftUI cancelling the
  action's own task cannot fail the fetch (the Share sheet's member list does the same).
  `OnlineAvailability.showsOfflineStatus` adds transport evidence (connectivity-class
  `URLError`s reported by `DocsAPIClient` — a connection that black-holes requests, such as
  plane Wi-Fi without a purchase; a captive portal's TLS failures are deliberately not
  covered — cleared by any HTTP response or any path callback) for **status display
  only** — the editor's offline banner and sync caption wording; controls and
  `permitsResponse` keep `isOffline`, and the pending-sync **retry stays a control**
  (`syncCaption`'s `isPathOffline`), since a control disabled on failure evidence would
  make no request and never recover. **The offline *banners* (editor, Home, Shared)
  additionally debounce that evidence** through `DebouncedStatus`
  (`OnlineAvailability.transportOfflineEvidence`, shown after ~1.5s of continuous evidence
  and hidden after ~1s of recovery; Work Offline, a deliberate choice, is OR-ed in
  *outside* the debounce via `OnlineAvailability.isWorkOffline`, so switching it off hides
  the banner at once), and banners/error text animate in and out (`.snappy`, off under
  Reduce Motion) — display only, never what controls, `permitsResponse` or saves read.
  Home and Shared keep a visible load error across a *silent* reload (cleared on success,
  a new error, a dismiss or a user-initiated refresh; a successful search clears
  `home_error_search`). Each report carries its request's start instant and an
  `.unreachable` that started before the last clearing event is dropped as stale. The save
  status reads `connectionAppearsDown` (path or evidence, not Work Offline, which still
  sends saves). Draft sync fires on `appearsOffline`'s true→false edge; live sockets
  reconnect on the real path edge only.
  Cache/draft restoration precedes the editor's read guard. Uncached offline
  content explains that it must first be opened online; never show Empty document
  or Start writing without `hasLoadedContent`. A cached empty body is valid content.
  The Shared tab follows the same signal: `SharedViewModel` takes Home's
  `OnlineAvailability`, serves its cache with no request or error while
  offline, discards a response whose token no longer permits it, and
  `SharedScreen` keys its load on `availability.token` so a reconnect reloads.
  The iPad inline field is the server's search, so it is disabled with visible/accessibility
  explanations; the compact shortcut stays enabled because the pushed Search screen also
  searches the documents saved on this device (see "Search is on-device first, then
  server"). Keep PR #148's pushed Home Search route and retain its model/query. The
  server half of Search and Quick Access reads are withheld at the VM boundary too; do
  not rely on a disabled view to suppress requests.
  Reads capture an availability token (path and preference revisions) alongside
  their load/query generations. A response crossing offline/reconnect cannot
  install content/results/errors, even if availability has returned before it lands.
  Unavailable transitions stop an uncached editor's spinner immediately, and a
  superseded load cannot stop a newer spinner. Reconnect reloads the same editor
  without clearing unrelated action/save errors or replacing local work.
  **Work Offline still does not hold saves**: write-ahead persistence, conflict
  decisions and replay remain in the save coordinator, independent of read/control
  availability. With that preference on, a save may PATCH successfully while reads
  are withheld. The pending-sync retry caption stays passive under Work Offline;
  foreground/reconnect replay and the editing Save action retain their behavior.
- **A clean copy always ends up showing the server's body.** `apply` takes no
  "user initiated" flag: passive `load()` and pull-to-refresh apply identical
  content rules, and `refresh()` differs only in surfacing failures (and in its
  `hasLoadedContent` fallback to `load()`). Applying the fetched **title** while
  stashing the fetched **body** is exactly what produced "remote edits never
  arrive, only the title does" — don't reintroduce it. The **"Updated" banner**
  (`updateAvailable`/`pendingFreshContent`) is reserved for the destructive case
  in the *clean* branch: a revalidation landing while an **editing session**
  holds the caret (the user taps into the synchronously-rendered local copy
  while the fetch is still in flight). It surfaces when editing ends, and
  `markDirty` drops the stash — and **records a conflict as it does** (a server body the app
  fetched *and showed the user* cannot be silently overwritten by the next autosave);
  `startEditing` only hides the banner and deliberately **keeps** the stash, or the first
  real keystroke would have nothing left to detect. **This holds in the live-write branch
  too (C2c)** — `markDirty`'s `liveWrite?.forwardLocalEdit() == true` branch calls the same
  `abandonPendingFreshContent()`, not a silent drop, because a stash can still be sitting
  there while a live session is engaged (a pull-to-refresh isn't suppressed by
  `isApplyingLiveContent` the way the A5 change-signal is) and may hold a co-author's
  REST-originated edit the live replica never saw. A divergent stash records a conflict,
  which flips `canEngageLiveEditing` false so the next `persistLiveSnapshot` is held by the
  coordinator's enqueue-hold instead of full-overwriting it, and the document downgrades to
  classic; a non-diverged stash still drops silently, exactly as before.
  Every content swap (initial load, clean revalidation, explicit "Keep the server
  version") routes through `install(...)`, which clears
  `focusedBlockID`/`cursorRequest`/`selection` because every swap re-identifies the blocks.
- **Four invariants keep the full-overwrite save from eating content.** Every one
  was learned the hard way; each has a named regression test.
  0. **Never enqueue a save for content that isn't loaded.** `startEditing` guards
     the *entry* to an editing session on `hasLoadedContent`; `flushPendingChanges`
     guards the *exit* on it and on `isDiscarded`, and
     `becomeUnavailable`/`handleDidDelete` end the session (cancel the autosave,
     clear `isDirty`) before dropping the content. Without that, a 404/403 landing
     mid-edit cleared `blocks` while the autosave timer kept ticking — the next
     flush serialized `[]`, enqueued an **empty document**, and overwrote the user's
     draft with it; a *transient* 404 then let `recoverDrafts()` replay that
     emptiness onto the server. `becomeUnavailable` **flushes first**, while the
     blocks still hold the edit: `enqueue` is write-ahead, so the user's text lands
     on disk and `recoverDrafts()` replays it if the 404/403 was transient.
  0b. **A purge must survive its own in-flight save.** Both purge sites tell the
     coordinator, or `finish`'s success path write-throughs the content cache and
     recreates what was just removed — on a 403 that is *revoked content
     reappearing on disk*. `handleDidDelete` → `discardPendingWork` (drops the
     draft too); `becomeUnavailable` → `suppressLocalWriteThrough` (**keeps** the
     draft — a 403 revokes access, it doesn't delete the user's unsaved work).
     **A purge must equally survive its own in-flight *revalidation*.** A content
     GET issued before the purge can be answered with a 200 after it — and before
     SwiftUI cancels the editor's `.task` — reaching `apply` → `reconcileClean`,
     which write-throughs the cache unconditionally and re-caches the body just
     removed; it then renders from retained Search/Shared results until eviction.
     So `handleDidDelete` bumps `revalidationGeneration` exactly as it already
     bumps `childrenGeneration`. Every `revalidate`/`refresh` path re-checks its
     captured generation before `apply` **and** before `becomeUnavailable`, so
     this also stops a delete racing a fetch that then 404s from tearing down a
     document already being deleted. `becomeUnavailable` needs no such bump: it
     is only ever reached *from* a generation-checked catch, so it is by
     construction the **newest** fetch — an older one may well still be in
     flight (nothing serializes `load()` against a pull-to-refresh `refresh()`,
     and the synchronous local phase sets `hasLoadedContent` before `refresh()`
     reads it), but an older fetch already fails that same guard on resume and
     returns before it can re-cache. Bumping there would invalidate nothing.
  0c. **A delete is terminal; a 404/403 is not.** Deleting pops the screen, so
     `isDocumentDiscarded` is a latch and gates the save funnels. A 404/403 leaves
     the screen mounted with its pull-to-refresh, and every 404 maps to
     `.notFound` — including a proxy hiccup — so `isUnavailable` must **not** gate
     them. Gating a save on it made every funnel silently return on a recovered
     document while the caption still read "Edited just now".
     **It is discharged by a fetch whose body actually reached the screen** —
     `markAvailableAgain()`, called *after* `apply` and gated on `hasLoadedContent`.
     Both weaker rules stranded a real screen: discharging inside `install(...)`
     misses `reconcileDraft`'s draft-wins exits (which never install), leaving the
     document dead with pull-to-refresh no-oping; discharging *before* `apply` clears
     the terminal message for a response `apply` declines (`mayPredateLocalSave` is
     true whenever a save was in flight when the fetch was issued — and this
     teardown's own flush starts one), leaving a blank body, no error and no spinner.
     For the same reason `reconcileDraft` re-installs the draft when
     `!hasLoadedContent`.
  1b. **A stored draft that wins the tolerance rule with `saveState == .idle` and no
     pending save has no funnel at all** — `flushPendingChanges` needs `isDirty`,
     `saveNow` and the retry caption need `.failed`, `recoverDrafts` runs once per
     process — and the draft would sit unpushed (or conflict once the server moves past the
     tolerance window). So `reconcileDraft`
     **hands it back to the save pipeline**, keyed off *that state*, never off which
     screen instance recovered it: a fresh view model (pop back, reopen — the natural
     reaction to "no longer available") restores the draft locally and recovers
     nothing. Two paths produce the state: `becomeUnavailable` (`suppressLocalWriteThrough`
     drops the queued save; `finish`'s discarded branch resets to `.idle`, not
     `.failed`) and an offline launch where `recoverDrafts` gives up. Symmetrically,
     `finish`'s discarded branch **removes a draft the PATCH confirmed** — saved work
     is not unsaved work, and replaying it would clobber a co-author.
     While `isUnavailable` holds, `load()` skips the local phase
     (or the purged body — or the draft the teardown just wrote — is re-rendered with
     the warning cleared) and shows **no spinner**: `readingSurface` owns the only
     `.refreshable`.
  1. **A stored draft is unsaved work regardless of `displaySource`.** A save
     failing mid-session leaves `.clean` on screen with the user's only copy in
     `PendingDraftStore`. So `apply` consults `saveCoordinator.storedDraft(...)`
     *before* it switches on `displaySource`. `hasUnsavedLocalContent` follows the
     same rule, gated on `hasLoadedContent` (a torn-down document claims nothing)
     — its two guarded draft reads are exhaustive only because `enqueue` is the
     sole **creator** of a draft and sets `pendingSave` synchronously; add another
     creator and it must read the draft unconditionally. (`finish` and
     `resolveConflictKeepingLocal` also *write* the store, but only ever refresh an
     **existing** draft in place — the stamp and the baseline — so they create nothing
     the guarded reads could miss.) A failed save pins the
     document (every revalidation and pull-to-refresh no-ops while its draft is on
     screen), so the reading surface's **"Couldn't save · tap to retry" caption is
     load-bearing** — it is the only affordance that unpins such a document,
     which is why it outranks the offline wording (tap-to-edit reaches `saveNow`
     too, and now works offline, but it is not a *retry* — it re-enters the
     session rather than resending). **Waiting drafts are never discarded automatically.**
     A draft whose save failed *this* session or is queued for sync is owned by the
     on-screen retry/pending affordance, so `reconcileDraft` returns early on
     `saveState == .failed` **and `.pendingSync`** without re-enqueueing behind it.
     That early return still **records a conflict** on the way out if
     the fetch shows the server diverged — detection is non-destructive, and skipping it
     let a "tap to retry" overwrite an already-fetched web edit. The comparison mixes clocks — `draft.updatedAt` is the device's,
     `formatted.updatedAt` the server's **last write** — so a slow device shrinks
     the window from the draft's side, and even the user's own partially-landed
     save (content PATCH applied, title PATCH failed) can read as "newer".
  2. **Never install or cache a response that may predate one of our own saves.**
     A revalidation issued while a save was in flight can be answered from the
     server's pre-save state; installing it resurrects exactly what the save
     replaced, and the next full-overwrite save pushes that back to the server.
     Snapshot `saveCoordinator.saveMarker(documentID:)` *before* issuing the
     fetch and check `mayPredateSave(_:)` after — a boolean "was a
     save pending?" is not enough (a save can start *and* settle during the
     await), hence the coordinator's monotonic settled-save count.
- `displaySource` must never stay pinned at `.pendingSave` once that save has
  settled — pinning it stranded the screen: every later revalidation **and**
  every pull-to-refresh no-oped in silence. Reclassify (a surviving draft ⇒
  `.draft`, otherwise `.clean`). See
  [`docs/offline-and-sync.md`](../offline-and-sync.md).
- **The block editor draws its markdown syntax at zero width — it never removes
  it.** `BlockTextView`'s buffer *is* `block.text`, the raw markdown the
  full-overwrite save re-parses, and it always will be. Inline marks render as
  rich text (`[a](b)` shows a blue underlined `a`) because `EditorUITextView` is
  a **TextKit 1** view (`EditorUITextView.textKit1()`; the default TextKit 2 has
  no equivalent) whose `NSLayoutManagerDelegate` marks the syntax characters'
  glyphs `NSGlyphProperty.null` — not drawn, zero advance, **indexes intact**.
  So `UITextView.text.length == block.text.length` at all times, and every
  `NSRange` in the editor (`splitBlock`, `mergeBlockWithPrevious`,
  `applyInlineMarker`, `detectMarkdownShortcut`, `cursorRequest`, `selection`)
  stays a *source* offset. **Never introduce a display↔source offset map**: a
  rich in-memory run model (or `NSTextAttachment` link chips) needs one at six
  call sites, in the one subsystem whose defining rule is that a full-overwrite
  save must never eat content. `BlockTextRenderingTests` pins the width collapse
  and the buffer length; if TextKit 1 ever stops honouring `.null`, fall back to
  drawing the syntax dimmed but visible — not to an offset map. (The page chip is
  the one glyph that is *not* `.null`: a document link's hidden `[` is a
  `.controlCharacter` laid out as fixed-width whitespace for the chip's icon —
  still never drawn, still one glyph per character; see the page-chip bullet.)
  The corollary is a property worth keeping: **any edit that breaks a mark's
  syntax simply makes it render as literal text.** Backspacing `[R](url)` down to
  `[](url)` stops it being a link and reveals it. Nothing is silently lost,
  because the buffer is the content. That is why there is no atomic
  "delete the whole link" rule — only `caretBeforeBackspace`, which skips the
  caret back over a hidden run so backspace deletes the label's last letter
  rather than a lone `)`. Its sibling `snappedSelection` keeps the caret out of
  the interior of a hidden run and stops a selection bisecting one.
- **Focus must be retried when a block's text view joins a window.** A lazy row
  can consume its cursor request and finish both model updates while detached.
  `EditorUITextView.didMoveToWindow` rechecks the coordinator's latest focus
  intent synchronously, with delegate echoes suppressed by the existing focus
  funnel. Do not rely on cursor-request clearing to cause an update after
  attachment, or defer a captured focus intent that could steal focus later.
  During a block-to-block handoff, the old row must keep its keyboard recipient
  until the new row takes first responder; resigning before attachment drops
  keystrokes without any delegate callback. A cleared focus or leaving blocks mode
  still resigns normally.
  The row's text, focus, and cursor readers must resolve current intent by ID during UIKit updates,
  while explicit body-time focus/cursor reads register SwiftUI observation so
  focus-only and cursor-only changes still update an unchanged row.
  bypassing SwiftUI's cached Binding value as well as its captured
  `EditorBlock` value: a queued row snapshot can otherwise overwrite a newer
  keystroke and move the caret backward. Return and prefix shortcuts can also
  move the model caret before UIKit applies it: pending keyboard deltas go
  through `applyPendingKeyboardInput` to the current block/selection, gated by
  stable identity and the coordinator's consumed cursor token. Never forward
  the old row's whole buffer to the new block. Ignore obsolete selection echoes
  until the pending token is applied. Ranged source corrections must remain
  deltas against the retained source block, never restoring a moved suffix;
  validate the old UIKit buffer's correspondence and recognize consumed
  shortcuts before translating prefix coordinates. After a handled source correction,
  reject further old-buffer ranges until UIKit reconciles; repeated prefixes cannot
  establish valid coordinates after a length change. Publish typed text before
  restyling. While that publication is active, defer both text and caret
  reconciliation: Observation notifies before the write finishes. Reconcile
  after the outermost publication, never consuming a token against old text. `BlockTextFocusTests` covers these races,
  cancellation, repeated Return/backspace, identity, Unicode, and caret retention.
- **Marked input after a row transition belongs to the destination.** Keep model
  block IDs stable. The canvas uses session-local input row IDs so a split or
  merge can give the destination the existing native keyboard view; the retained
  source receives a separate row. Stored scroll anchors and recorded frames still
  name model block IDs; the editing canvas resolves them to direct input-row scroll
  targets so lazy rows remain reachable without replacing the native text view.
  Before native `setMarkedText`, prepare the pending destination's buffer, styling,
  and UTF-16 selection, then bind all callbacks to that destination until SwiftUI
  adopts it. Keep this binding through commit and immediate corrections; restoring
  the source buffer on commit corrupts subsequent correction coordinates. Never
  replace marked characters, attributes, or selection during model reconciliation.
  Process shortcuts and slash queries on commit even when the committed characters
  equal the provisional model text. Retired input row IDs stay reserved for the
  view model's lifetime (a content install keeps them too, since it now keeps
  unchanged block ids), and stale row callbacks/focus requests cannot reclaim them.
  Native regression tests must include commit, cancel, unchanged commits, ranged
  corrections after commit, same-row pending carets, and real canvas reconciliation
  with the same native view, marked range, and first responder.
- **Uncommitted marked text is never published.** While an input method holds marked
  text (`markedTextBlockID`), the model may hold those characters so the row can lay
  them out (`updateComposition(isMarked: true)`, or `updateText` on a block reported
  marked), but nothing calls `markDirty` for them: no live push to peers, no autosave,
  no draft. The commit's stale buffer would otherwise overwrite a peer's concurrent
  edit. The first marked write records the block's last published text in
  `compositionBaseText`, and `publishableBlocks` swaps it back in. Everything that
  serializes the document reads that, never `blocks`: the live bridge
  (`forwardLocalEdit`, its diff baseline and `liveChangeSet`) and `currentMarkdown()`
  (so every save and draft). An unrelated edit or a flush mid-composition therefore
  cannot carry the marked characters out, and the flush itself is not skipped.
  - The commit (`updateText(..., committingComposition: true)`, or the first
    `updateText` after `noteMarkedText(false)`) publishes **even when its text equals
    the last marked text**, clears the base text and runs the markdown shortcuts then
    (never while marked). The autosave timer drops its attempt while the composition is
    held (`holdsUnpublishedComposition`: editing mode, focused, still marked), and the
    commit re-arms it.
  - An unmark with no text event after it (a selection change) is settled on the next
    main-actor turn (`settleComposition`); `flushPendingChanges` and `finishEditing`
    settle too, and Done mid-composition counts as committed. `startEditing` and
    `install` reset the state.
  - A peer's `.update` to the composing block is not applied over the marked
    characters (`applyLiveRemoteChange`). The replica now holds the peer's text, so
    that becomes the held base (`compositionBaseText.text`; `publishableBlocks` and the
    bridge's `lastAppliedBlocks` then match the replica) while `original` keeps the
    text the composition began from. At the commit `rebaseComposition` merges the
    user's edit into the peer's text (`rebasedCompositionText`) and writes the merge to
    the model before publishing, so the bridge forwards peer text -> merge. Where `original`
    sits whole and once in the peer's text (a peer insert before, after or around it, such
    as `**…**`), the committed text replaces that occurrence and the caret moves by its
    offset. If `original` is empty, the peer's text then the committed text. If it occurs
    more than once, the peer's text then the characters the user inserted, after one space
    unless the join already has whitespace. Only when the peer deleted or edited inside
    `original` does the committed text overwrite the peer's, consistently from the peer
    baseline. Never diff a composing block against a stale base: `applyEdit`
    splices at base-relative offsets, and a shorter replica text throws and tears the
    session down.
  - A composition whose block lost focus without an unmark is also settled by the next
    `markDirty` (live editing has no autosave timer) and by `noteFocusChange()`, which
    `BlockEditorView` calls when the text views move focus.
  - Nesting detachment still runs on marked text. Cover marked updates (no dirty, no
    push, no save, no draft), the commit, an unchanged commit, a flush, an unrelated
    edit, Done, a selection-only unmark, a lost focus and a peer update in
    `EditorViewModelCompositionTests`, and the merge against a real replica (peer insert, and
    a peer delete that takes the fallback) in `LiveEditingIntegrationTests`.
- **One inline scanner, not two.** `InlineMarkdown.layout(of:)` partitions a
  block's source into visible `spans` (styled) and hidden `syntax` (the
  complement of the spans, so the two cannot drift), plus its `links`.
  `InlineMarkdown.parse(_:)` — what `MarkdownYjs.encode` feeds on — is a
  *projection* of that same result. The editor's styling and the save path
  therefore cannot disagree about what a `*` means. Do **not** add a third
  engine: the reading surface's `AttributedString(markdown:)` is already a
  second one, and it is the **oracle** the scanner converges on — where they
  disagree, the scanner is wrong.
  Ranges are UTF-16; the scanner walks `Character`s and carries a
  prefix sum, because `NSRange` and grapheme clusters are not the same thing.
  Blocks whose text is literal (`rendersInlineMarkdown(_:)` — code blocks,
  `.unknown`, the leaves) hide nothing and style nothing.
  **`YjsEncoderTests` passing does not, on its own, prove the scanner is
  unchanged** — it builds its `[InlineRun]` fixtures by hand and never calls
  `parse(_:)`, and `MarkdownYjsTests` only checks node names and props. The
  bridge is `InlineLayoutTests.testParseProducesExactlyTheRuns…`, which pins
  `parse(_:)`'s output to the exact runs each golden fixture encodes (mark
  **order** included — it is part of the wire format). Touch the scanner and you
  must keep both halves green, or "the bytes didn't move" is an assumption.
  That gap hid a real divergence for as long as links have existed: yjs writes a
  mark value as `writeVarString(JSON.stringify(value))`, and JS does not escape
  `/`, but Foundation does — so the app emitted `{"href":"https:\/\/x"}` where
  yjs emits `{"href":"https://x"}`. Benign (`JSON.parse` reads both alike) but not
  byte-identical. `linkValueJSON` now passes **`.withoutEscapingSlashes`**; keep
  it, and reach for it in any future `JSONSerialization` output that must match
  `JSON.stringify`.
- **`_` is emphasis, by CommonMark's flanking rule, but only when it stands
  alone.** A `_` is a delimiter candidate only when neither neighbour is a `_`;
  it opens when left-flanking and (not right-flanking or preceded by
  punctuation), and closes under the mirror rule. So `_x_` is italic,
  `**_x_**` is bold+italic (what BlockNote exports), `snake_case` is content, and
  `__x__`/`___x___`/`___` stay literal — the runs-of-two-or-more carve-out is
  what keeps every such document byte-identical. "Punctuation" is CommonMark's:
  ASCII punctuation ∪ Unicode `P*`, spelled out in `asciiPunctuation` — **not**
  `Character.isSymbol`, which would wrongly emphasize `😀_x_😀` and `€_x_€` while
  `a+_x_+a` (ASCII `+`) genuinely is emphasis. Flanking reads the **whole**
  `chars` array, never the recursion's `bounds`: that is why `**_x_**` opens.
  Landing this **changed saved bytes** and required sign-off; before it, opening
  any web-authored italic document and letting it save destroyed the italic and
  wrote literal underscores into the server's text —
  `parse("**_word_**")` returned bold(`_word_`).
- **The app and the server spell italic differently, so `draftSyncDecision` compares
  parsed runs, not spelling — and nothing else does.** `InlineMarkdownWriter` (the native
  shadow, `lastPushedMarkdown`) and the formatting bar write `_x_`; the server's
  formatted-content export writes `*x*` (a real capture: `A paragraph with **bold**,
  *italic*, underline, ~~strike~~ and `` `inline code` `` marks.` — bold, strike and code
  agree, underline exports plain on both sides). Spelling-sensitive, every save of an italic
  document read back as a false `.conflict` (rules 0 and 1 miss, rule 2 sees a newer
  server), classic and native alike — and a resumed offline create recorded a false
  conflict in `migrateCreatedDocument`'s own rule-0 test. So the body rules, and that
  test, use `syncCanonicalMarkdown` (its emptiness is `canonicalMarkdown`'s): each
  `rendersInlineMarkdown` block's text becomes an encoding of `InlineMarkdown.parse`'s runs —
  exact text, marks as a sorted set (links by value), same-set neighbours joined. Only
  delimiter spelling, escapes and mark order drop out. **Never canonicalize by re-writing
  through `InlineMarkdownWriter`** (the first attempt): `normalized` moves whitespace out of
  bold/italic/strike, so `** a**` = ` **a**` and `2 * 3 * 4` = `2  _3_  4` — different runs,
  a missed conflict — and the writer returns nil for intraword/CJK `*x*`, disabling the
  compare for the whole block. **Everything else stays on strict `canonicalMarkdown`**:
  `serverChanged`/`reconcileClean` must reinstall a spelling-only server change, or the
  screen keeps `[bold, italic]` under an `[italic, bold]` baseline and the next Docs 6 save
  reads those blocks as user-touched (`BlockNotePreservation.sameContent` is
  order-sensitive) and drops their preserved props; and `projectionDigest` is persisted, so
  changing its form would strand stored native drafts. No saved byte moves — both save
  routes encode runs (`MarkdownYjs`). Pinned by `DraftSyncDecisionTests`
  (`testSyncCanonicalMarkdown…`, `testOurItalicPushReadBack…`),
  `NativeShadowExportParityTests.testTheRealCapturesMarksParagraphMatchesTheServerExport`
  (skips without `.review/`) and
  `EditorViewModelBaselineTests.testReconcileCleanInstallsASpellingOnlyServerChange` and
  `DocumentSaveCoordinatorReplayMigrationTests.testAnItalicSpellingOnlyServerBodyIsNotADivergence`. The
  parser still misreads `***x***` (bold `*x` + `*`) and `**a *b***`; if the server spells
  bold+italic that way, that is a parser bug this does not cover.
- **Code spans and links bind tighter than emphasis.**
  `matchUnderscoreEmphasis`'s closing search steps over them whole, or `` _`_` ``
  closes on the `_` *inside* the code span and destroys it, and `_[x](a_ b)_`
  tears the link apart — both persisted by the full-overwrite save. `*`'s
  `matchDelimiter` does **not** step over them; leave it that way, because
  changing it moves the saved bytes of every `*italic*` and `**bold**` that
  already exists. When `_` and `*` fight over the same characters the leftmost
  opener wins, which is also what CommonMark does.
- **An underscore opener never reaches past an interior opener** (equivalently,
  a closer pairs with the nearest opener, as in CommonMark). The search stops at
  an interior lone `_` that can open but not close (a left word boundary),
  because that starts a *new* emphasis. So `_foo _bar_`
  italicizes only `bar` and leaves `_foo ` literal — the first-closer search
  reached past it and italicized `foo _bar`, disagreeing with the reading
  surface. It is not a full delimiter stack (deeper `_`+`*` tangles still differ,
  the out-of-scope soup class), but it never drops a character and only ever
  emphasizes less — the conservative direction.
- **Never let one run carry the same mark key twice.** `*_x_*` nests italic in
  italic; a BlockNote format map has one entry per key, so `adding(_:to:)` skips
  a mark already present (links exempt — nested links carry distinct `href`s).
  The golden hex tests cannot catch a duplicate: they hand-build their runs.
- **Differential-fuzz the scanner against itself before believing a byte claim.**
  Compile the committed `InlineMarkdown.swift` and the modified one into two
  standalone binaries, run both over one corpus, diff. The invariant that
  matters is *"no input lacking the character you changed may diverge"* — that
  is what proved the dedupe and the untouched `*` paths were behavior-preserving.
  Add Foundation as a third binary for an independent oracle. It earns its keep:
  it caught the code-span precedence bug above, on inputs no one would think to
  write.
- **Authoring a link is the only asymmetric inline edit.** `wrapInlineMarker`
  can only wrap a selection in the same token on both sides, so it can never
  emit `[text](url)`; `MarkdownLinkEditing.swift` does that instead
  (`insertMarkdownLink`/`replaceMarkdownLink`/`removeMarkdownLink`, all pure).
  Tapping a link's *visible label* opens a `UIEditMenuInteraction` with Edit and
  Remove — hit-tested with our own `UITapGestureRecognizer`, because an editable
  `UITextView` does not deliver the iOS 17 `UITextItem` callbacks (a tap there
  means "place the caret"). `sanitizedLinkURL` is the gate: an allowlist of
  `http`/`https`/`mailto`/`tel`, `https://` prepended when scheme-less, and
  **`(`, `)` and `\` rejected outright** — `matchLink` ends the destination at
  the first `)`, does not balance parens, and never unescapes it, so no
  parenthesised URL survives the round trip. Removal re-inserts the **raw**
  label substring, escapes and all: re-inserting the *displayed* label would turn
  a `\*text\*` into italics. An input that can't be made safe inserts nothing.
- **A link to another document is just a markdown link.** The web editor stores
  one as a custom `interlinkingLinkInline` BlockNote node, but the server's
  markdown export flattens it to `[Title](https://<serverHost>/docs/<uuid>/)` —
  the inverse of `documentShareURL`, and indistinguishable from a pasted URL.
  Nothing in the markdown marks it as internal, so a `.link` run in a `Text`
  used to reach SwiftUI's **default** `OpenURLAction` and leave the app for
  Safari. `readingSurface` therefore installs its own
  `.environment(\.openURL, …)`, and `documentLinkAction` (pure, in
  `Features/Editor/DocumentLink.swift`) classifies the tap: `.openInApp(id)`,
  `.alreadyOpen` (the document on screen — swallow it; `NavigationPath.append`
  does not de-duplicate, so a self-link would grow the stack), or
  `.openInBrowser`. The fallback is **`.systemAction`**, never `.handled`, so
  every external link behaves exactly as before. A URL matches only when its
  scheme is `http`/`https` (never `javascript:`/`data:`/`file:`), its `URL.host`
  equals `serverHost` **case-insensitively and exactly** — compare `host`, not
  the string: `https://docs.llun.dev@evil.com/…` is hosted at `evil.com`, and
  `docs.llun.dev.evil.com` must not pass as a suffix — and its `pathComponents`
  are exactly `["/", "docs", "<uuid>"]`, which folds the trailing slash away
  while rejecting `/docs/<uuid>/versions/1` and `/docs/new/`. The port is *not*
  compared (`serverHost` carries none). None of this is a fetch guard — the id
  only ever reaches the client's own `documents/{id}/` path — it stops the app
  from *intercepting* somebody else's link.
- `EditorViewModel.openLinkedDocument(_:)` resolves that id to the `Document`
  the view pushes, **reusing a `subpages` entry when the link names a listed
  sub-page**: it is the same value `SubpageRow` would push, it makes the common
  case instant, and it is the only way the link works offline. Otherwise it GETs
  `documents/{id}/` (`DocsAPIClient.document(documentID:)` — the DRF retrieve
  route; metadata only, no `content`). A failure is **deliberately not**
  `becomeUnavailable()`: a 404/403 there concerns the *linked* document and is
  no evidence about the one on screen, which would otherwise be torn down —
  along with any unsaved edit — over a dead link. `.sessionExpired` stays
  silent, because the shared client's `onSessionExpired` hook has already raised
  the re-login sheet.
- **Typing `[[` links a page; the editor has two typed triggers, not one.** The slash
  menu opens on a *paragraph that starts with* `/` with the caret right after a
  whitespace-free "/query" (`slashQuery(text:kind:caret:)`, the native editor's rule;
  `refreshSlashQuery` closes it when the caret moves out, and never opens it); a choice
  (`applySlashSelection`) removes only that token and keeps the text after it, inline
  markdown included, with the caret at its start (a Divider goes above kept text, Photo
  and File insert after it); the page
  picker opens wherever the caret sits right after `[[` plus a query
  (`pageLinkTrigger(in:caret:)`, `Features/Editor/PageLinkPicker.swift` — pure, UTF-16,
  tested) in any block that renders inline markdown, and never while the slash menu is
  up. It is **derived, not stored**: `EditorViewModel.pageLinkPicker` recomputes from the
  focused block's text and `selection`, so backspacing past the `[[`, typing `]`, moving
  the caret out of the query, a ranged selection, or leaving the block closes it with
  no state to unwind. The only stored state is an Escape dismissal keyed to that `[[`'s
  offset (lapses once those brackets are gone) and the arrow-key highlight (reset by any
  new query). A query that has grown a space and matches nothing closes it too — the
  user is typing literal brackets. Choosing a row (tap, Return, or a hardware Up/Down
  then Return — `EditorUITextView` claims Escape as a key command **only while the card
  is up**, and Up/Down only while it also has rows (`pageLinkPickerClaims`), so caret
  movement is otherwise untouched, the empty state included) replaces `[[query` with
  `[Title](https://<host>/docs/<uuid>/)` built by `documentShareURL` +
  `insertMarkdownLink` — byte-for-byte the shape `isDocumentLink` matches, so it draws
  as a page chip — with the caret after it. Return with nothing to pick still splits.
  **Never during input-method composition**: while the focused block's text view holds
  marked text (reported by `BlockTextView.onMarkedTextChange`, and by
  `updateComposition`'s `isMarked` on the hand-off path, into `markedTextBlockID`) the
  card is hidden and nothing can be picked — `reconcile` leaves UIKit's buffer alone
  until commit, and the commit would overwrite an inserted link.
  **Candidates are this device's caches only, and only what this account is known to
  see** — neither metadata cache is cleared on sign-out and the children cache is not
  account- or server-scoped, so reading them wholesale would offer the previous user's
  titles (and write a dangling link into this account's document). So: `subpages`; Home's
  cached lists (`DocumentCacheStore`, injected as `listCache`) only where a fetch for the
  signed-in account wrote them — each list carries a `fetchedFor` stamp, set by Home's and
  Shared's successful loads, cleared by a save without an account or a local insertion,
  read via `documents(fetchedFor:)`. A Home load captures the owner when it *starts*, so a
  load started before the signed-in id is known saves both lists unstamped; therefore
  `HomeViewModel.refreshSignedInUser()` runs `load()` whenever the id changes (`refresh()` and
  `reauthenticated()` then pay one redundant fetch). And the cached children
  (`children(ofParents:)`) of exactly those pages plus this document. No children list under any other parent is
  read. It works offline and makes no request; the cache reads are memoized per `[[` so a
  keystroke never decodes `UserDefaults`. The current document, untitled documents,
  pending creates (their id is re-keyed when the create syncs, so a link would dangle)
  and pending deletes are never offered. Ranking (`rankedPageLinkCandidates`) folds
  case and diacritics, requires every query word, and orders title-prefix, word-prefix,
  then contains, newest first within each, six rows at most. The card
  (`PageLinkPickerView`) is the slash menu's glass sibling in the same
  `GlassEffectContainer`, hosted by `PageLinkPickerHost` so a caret move re-renders only
  the card; VoiceOver hears "Link a page" when it opens and "No matching pages" when the
  query stops matching.
