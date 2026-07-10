# The block editor shows raw markdown instead of styled inline text

Date: 2026-07-10
Status: Implemented

## The report

> Help me fix the block edit that it shows markdown instead of just text as
> link. It should shows like in the web as normal text in blue (because it's a
> link text) and when tab on it can edit the link or remove the link
> completely. […] maybe review the editor and make it match the behavior to the
> javascript library using in here
> <https://github.com/suitenumerique/docs/tree/main/src/frontend>

The attached screenshot shows the **blocks editing** surface (the
`Blocks | Markdown` segmented control and the formatting bar are both visible)
rendering `[✅ Review](https://docs.llun.dev/docs/<uuid>/)` verbatim.

## Investigation

The app has **three** content surfaces, with three behaviors:

| Surface | Renders | Where |
|---|---|---|
| Reading | rich (`AttributedString(markdown:)`) | `MarkdownBlockView.markdownInlineText` |
| Blocks editing | **raw markdown source** | `BlockTextView` → `UITextView.text` |
| Markdown source | raw markdown source (by design) | `MarkdownSourceView` |

The reading surface is already correct: `markdownInlineText` renders
`[text](url)` as blue tappable text, and `readingSurface` installs an
`openURL` action so an internal link opens in the app (`DocumentLink`).

The editing surface is the leak. `BlockTextView` binds `block.text` — the raw
markdown source — straight into a plain `UITextView.text` under one uniform
font (`BlockTextView.swift:107`, `:114`). There is no `NSAttributedString` and
no inline styling anywhere in the editing path.

**The defect is not link-specific.** Every inline mark the save parser
understands leaks its syntax while editing: `**bold**`, `*italic*`,
`` `code` ``, `~~strike~~`, and `[text](url)`. Links are simply the case where
the leaked syntax is long enough to swamp the content.

Two adjacent defects surfaced during the investigation, both confirmed:

**1. A link cannot be created from the UI at all.** The formatting bar offers
only bold and italic (`EditorFormattingBar.swift:26`–`:31`), and both route
through `applyInlineMarker` → `wrapInlineMarker`, which is structurally
**symmetric**: it wraps a selection in the *same* token on both sides. It can
emit `**text**`; it can never emit `[text](url)`. Hand-typing markdown is the
only way to author a link today. So "tap to edit or remove a link" has no
counterpart for making one.

**2. The Italic button silently loses its formatting on save.** The button
emits `_` (`EditorFormattingBar.swift:29` → `applyInlineMarker("_")`), but
`InlineMarkdown` **deliberately ignores underscores** so that `snake_case`
identifiers survive (`InlineMarkdown.swift:90`). The reading surface uses a
*different* engine — Foundation's `AttributedString(markdown:)`, which follows
CommonMark and does italicize `_x_`. So the user applies italic, sees italic,
and the full-overwrite save writes literal underscores. The italic never
existed on the server.

These are the same failure in two costumes: **the editing surface and the save
parser do not agree about what the text means.**

## Root cause

`BlockTextView` was built as a plain-text view over a markdown string, and the
caret system was built on top of that assumption. `splitBlock`,
`mergeBlockWithPrevious`, `applyInlineMarker`, `detectMarkdownShortcut`,
`consumeCursorRequest`, `selection` and `CursorRequest` all carry **UTF-16
offsets into `block.text`** — and `block.text` is exactly the markdown that
`MarkdownYjs.encode` re-parses on every full-overwrite save.

That is why the obvious fix is the dangerous one. Displaying `Review` (6
characters) while the model holds `[Review](https://…)` (28) makes every one of
those offsets a *display* offset, requiring a bidirectional offset map at six
call sites — in the one subsystem whose defining rule is that a full-overwrite
save must never eat content.

## The approach

**Change what characters look like, never which characters exist.**

The `UITextView` buffer stays byte-identical to `block.text` at all times.
Content characters are styled; markdown syntax characters are suppressed to
**zero width** via TextKit 1 glyph suppression (`NSGlyphProperty.null`), which
removes them from layout while leaving them in the text storage with their
indexes intact.

This was verified before the design was accepted. Rendering
`See [Review](https://x.dev/) now` with `[` and `](https://x.dev/)` suppressed
produces a used width of **123.2666 pt** — identical to the width of the plain
string `See Review now` — while `NSTextStorage.length` stays 32 and
`numberOfGlyphs` stays 32.

Consequences, all of them load-bearing:

- `UITextView.text.length == block.text.length` **always**, so no offset map
  exists and every existing caret/selection call site is untouched.
- The save path re-parses the identical `block.text`. `YjsEncoderTests` must
  show a **zero-line diff**; if it doesn't, the change is wrong.
- Any edit that breaks a mark's syntax simply makes it render as literal text.
  Backspacing `[Review](url)` down to `[](url)` stops it being a link and
  reveals the syntax. **No edit can ever silently destroy content**, because
  the buffer *is* the content.

### One scanner, not two

`InlineMarkdown.parse` (save) and `AttributedString(markdown:)` (reading)
are already two engines that disagree — that disagreement *is* defect 2 above.
A third engine for the editing surface would guarantee a third disagreement.

So `InlineMarkdown`'s scanner is refactored to emit **ranges**, and today's
`parse() -> [InlineRun]` becomes a thin projection of that same result. The
golden hex tests and `MarkdownRoundTripTests` are the proof it did not drift.

```swift
enum InlineMark: Equatable { case bold, italic, code, strike, link(String) }
struct InlineSpan: Equatable { let contentRange: NSRange; let marks: [InlineMark] }
struct InlineLinkSpan: Equatable { let range, labelRange: NSRange; let label, url: String }
struct InlineLayout: Equatable {
    let spans: [InlineSpan]      // visible content, styled
    let syntax: [NSRange]        // markdown punctuation, hidden
    let links: [InlineLinkSpan]  // hit-testing, edit, remove
}

func inlineLayout(of source: String) -> InlineLayout
```

The partition invariant carries the weight: **every character of the source is
either content or syntax.** `syntax` is computed as the complement of the
content ranges, so the two cannot drift apart. A backslash escape is syntax;
the character it escapes is content. A link's label is content; its `[`,
`](`, url and `)` are syntax.

### Caret rules

Hidden characters still occupy indexes, so three pure functions keep the caret
honest:

1. A collapsed caret never rests *strictly inside* a hidden run; it snaps to
   the nearer edge (ties resolve upward).
2. A non-empty selection expands outward so it never bisects a hidden run —
   you cannot select half of a URL.
3. `deleteBackward`, when the character behind the caret is hidden, first moves
   the caret to the start of that hidden run. Backspace after a link therefore
   deletes the last letter of the label, never a lone `)`.

There is deliberately **no** atomic "delete the whole link" rule. Rule 3 plus
the self-healing property above make one unnecessary, and an atomic rule would
surprise a user whose caret sits visually just past the label.

### Interaction

A `UITapGestureRecognizer` hit-tests through `closestPosition(to:)`. When the
resulting character index falls inside an `InlineLinkSpan.range`, a
`UIEditMenuInteraction` (iOS 16+) offers **Edit** and **Remove**. This avoids
the iOS 17 `UITextItem` / `primaryActionFor` delegate callbacks entirely, which
are suppressed in *editable* text views.

The menu only arms once the text view is first responder, so the first tap on
an unfocused block still focuses it.

Authoring: a `link` button in the formatting bar opens a sheet with Text and
URL fields, prefilled from the current selection (or from the link under the
caret, when editing an existing one).

### URL and label safety

`sanitizedLinkURL` is the gate between user input and markdown:

- scheme allowlist (`http`, `https`, `mailto`, `tel`); `https://` is prepended
  to scheme-less input. Never `javascript:`, `data:`, `file:`.
- whitespace and newlines rejected.
- `(` and `)` rejected. `InlineMarkdown.matchLink` stops at the **first**
  unescaped `)` and, unlike `parseImageLine`, does not balance parens — and it
  does not unescape the destination either, so `\)` would be stored *with* the
  backslash. Rejecting is the only option that cannot save a mangled URL.

A label's `]` and `[` are backslash-escaped. That is safe in the other
direction: `matchLink` honors escapes when locating the closing `]`, and the
label is then re-scanned by `scan()`, which unescapes it.

An input that cannot be made safe surfaces a friendly validation message and
**inserts nothing** — never a rewritten or mangled link.

## Also fixed

The Italic bar button emits `*` instead of `_`, so what the user sees is what
the save writes. `_x_` typed by hand still renders italic on the reading
surface and saves as literal underscores; that asymmetry belongs to
`AttributedString(markdown:)` and is not addressed here.

## Explicitly out of scope

- A rich inline-run **editing model** (`NSTextAttachment` link chips, display
  text ≠ source text). This is the change that would require the offset map,
  and it is the single largest risk to the full-overwrite save.
- Auto-converting typed `[text](url)`, pasting a URL over a selection, ⌘K.
  None of these were verifiable in BlockNote.
- A document picker for authoring interlinks. The *reading* side already
  resolves them via `documentLinkAction`.
- Tables, callouts, nested lists, toggle lists, headings 4–6, drag handles,
  undo/redo, a floating selection toolbar.
- "Open" in the link edit menu. Following a link mid-edit is a mode switch.

## Testing

| Area | Test |
|---|---|
| `inlineLayout` partition | content ∪ syntax == source, disjoint, sorted, in-bounds |
| scanner parity | `InlineMarkdown.parse(x)` == projection of `inlineLayout(x)`, over a corpus |
| glyph suppression | TextKit 1 stack in-test: width collapses, storage length unchanged |
| caret rules | snapping, selection expansion, backspace normalization (pure) |
| link editing | insert / edit / remove / sanitize, incl. rejected URLs |
| save path | `YjsEncoderTests` and `MarkdownRoundTripTests` **unchanged** |
| italic fix | bar emits `*`; the save parser reads it back as italic |
