# Underscore emphasis: CommonMark's flanking rule

**Date:** 2026-07-10
**Status:** implemented
**Byte-change sign-off:** granted by the repository owner on 2026-07-10, before
implementation. See [Saved-byte delta](#saved-byte-delta).

## The bug

The editor's Italic formatting-bar button emits `_`. `InlineMarkdown` ignored
underscores entirely — deliberately, to protect `snake_case` — so the mark never
survived a save. That much was known.

What the differential harness showed is worse. Because the save is a **full
overwrite**, and because BlockNote exports emphasis as `_x_` (and bold+italic as
`**_x_**`), the old scanner *corrupted content it had never been asked to
create*:

```
old: parse("**_word_**")  ->  <_word_>{bold={}}
```

The italic is destroyed and two literal underscore characters are injected into
the document's stored text. Merely opening a web-authored italic document in
Schrift and letting it save mangled it, visibly, for every web user. The Italic
button was the symptom; the round trip was the disease.

Meanwhile the reading surface (`AttributedString(markdown:)`, CommonMark) has
always rendered `_x_` as italic — so the app showed the user emphasis that the
save then threw away.

## Why the obvious fixes don't work

**Switching the button to `*`** was tried in PR #50 and reverted.
`wrapInlineMarker` decided wrap-vs-unwrap from the *single character* on each
side of the selection. With source `**word**` and the word selected, both
neighbours are `*`, so it took the unwrap branch and produced `*word*` — bold
silently downgraded to italic, and since PR #50 draws markdown syntax at zero
width, invisibly so.

**Repairing only that unwrap branch** doesn't help either: wrapping then yields
`***word***`, which this scanner parses as bold(`*word`) + literal(`*`).

The fix is to make `_` mean what CommonMark — and therefore the reading surface
— already says it means.

## The rule

CommonMark's flanking rule, restricted to **lone** underscores.

A `_` is a delimiter candidate only when neither neighbour is a `_`. Runs of two
or more (`__x__`, `___x___`, the `___` divider, `snake__case`) stay literal.
This is the conservative choice: it holds every such document byte-identical,
and it is the same "a marker must not eat a longer run" rule the
`wrapInlineMarker` fix applies.

A lone `_` can **open** emphasis when it is left-flanking and either not
right-flanking or preceded by punctuation; it can **close** when it is
right-flanking and either not left-flanking or followed by punctuation. Start
and end of the block count as whitespace. `matchUnderscoreEmphasis` then takes
the first lone `_` that can close, honoring backslash escapes, requiring
non-empty, non-blank inner content — mirroring `matchDelimiter`.

Flanking is evaluated against the **whole** character array, never the
recursion's `bounds`: it is a property of the source text. That is precisely why
`**_word_**` opens — the opening `_`'s predecessor is `*`, which is punctuation.

### Code spans and links bind tighter than emphasis

The closing search steps over code spans and links **whole**. The differential
run below is what forced this: with a naive character walk, `` _`_` `` closed on
the underscore *inside* the code span and destroyed it (100 of the diverging
inputs were exactly this), and by the same mechanism a `_` in a link
destination — `_[x](a_ b)_` — tore the link apart. A full-overwrite save would
have persisted both.

`matchDelimiter`, which serves `*`, `**` and `~~`, does **not** step over them.
It is deliberately left alone: changing it would move the saved bytes of every
`*italic*` and `**bold**` in every existing document, which is outside the
signed-off delta.

### An opener never reaches past an interior opener

`matchUnderscoreEmphasis` stops its search at an interior lone `_` that can
**open but not close** — a `_` at a left word boundary (space before, letter
after), which begins a *new* emphasis. (Equivalently: a closer pairs with the
nearest opener, as in CommonMark.) So `_foo _bar_` italicizes only `bar`,
leaving `_foo ` literal, exactly as CommonMark and the reading surface do; the
naive first-closer search reached past the interior `_` and italicized
`foo _bar`. This is the conservative direction (an ambiguous leading `_` stays
content) and it never drops a character — it only ever emphasizes *less*.

It is **not** a full CommonMark delimiter stack. Deeper `_`+`*` (and `_`+`~`)
tangles like `_a _b_ c_` still differ (the scanner emphasizes `b`; CommonMark
emphasizes the outer span too), and Foundation's GFM strikethrough consumes a
`~` adjacent to a `_` in a way pure CommonMark does not — the same signed-off
out-of-scope class the greedy `*` matcher already lives with. The fix was validated by the same differential run below: it
moves 71 fuzzed inputs onto Foundation's answer and 1 off it (a pure `_`+`*`
soup string), drops zero characters, and keeps every output a subsequence of its
input.

### Punctuation is not `isSymbol`

CommonMark's "Unicode punctuation character" is *ASCII punctuation* ∪ *Unicode
`Pc, Pd, Pe, Pf, Pi, Po, Ps`*. Foundation's parser implements exactly that, and
the difference is observable:

| input | Foundation | why |
|---|---|---|
| `a+_x_+a` | *em* | `+` is ASCII punctuation |
| `😀_x_😀` | literal | `😀` is `So` — not punctuation |
| `€_x_€` | literal | `€` is `Sc` — not punctuation |

Swift's `Character.isSymbol` is true for all three. So the predicate is
`c.isASCII ? asciiPunctuation.contains(c) : c.isPunctuation`, with
`asciiPunctuation` spelled out verbatim from the spec. Using
`isPunctuation || isSymbol` would wrongly emphasize `😀_x_😀`.

### Mark dedupe

`*_x_*` and `_*x*_` nest italic inside italic. A BlockNote format map has one
entry per key, and CommonMark collapses the pair to a single `<em>`; emitting
`italic` twice in one run would be a wire-format defect the golden hex tests
cannot see (they hand-build their runs). `adding(_:to:)` therefore skips a mark
whose key is already present. **Links are exempt** — nested links legitimately
carry distinct `href`s, and that behavior is unchanged.

Only `_` can reach this today, so the dedupe changes no bytes outside the
signed-off surface. The fuzz run below proves it.

## `wrapInlineMarker`

The unwrap branch now requires the maximal run of the marker's character on each
side to be **exactly** `markerLength`. A short marker can no longer eat a longer
run.

This fixes a bug reachable from the shipping toolbar, not just the reverted `*`
one: Italic (`_`) on a hand-typed `__word__` used to unwrap to `_word_`,
silently downgrading strong to em — the identical destruction, with the marker
that ships today.

Three behaviors invert, all intended and all pinned:

| call | before | after |
|---|---|---|
| `("**word**", {2,4}, "*")` | `*word*` (bold destroyed) | `***word***` |
| `("**word**", {2,4}, "_")` | `**_word_**`, parsed `[bold]` | `**_word_**`, parsed `[bold, italic]` |
| `("__word__", {2,4}, "_")` | `_word_` (strong destroyed) | `___word___` (literal) |

## Saved-byte delta

Everything not listed is byte-identical.

| markdown | saved before | saved after |
|---|---|---|
| `_word_` | text `_word_`, no marks | text `word`, `italic` |
| `**_word_**` | text `_word_`, `[bold]` | text `word`, `[bold, italic]` |
| `_foo_bar_` | text `_foo_bar_` | text `foo_bar`, `italic` |
| `*_word_*` | text `_word_`, `[italic]` | text `word`, `[italic]` |
| `_*_*` and other `_`+`*` soup | arbitrary | now matches CommonMark (see below) |
| `snake_case`, `a_b_c`, `5_000_000`, `_snake_case`, `_ word _` | literal | unchanged |
| `__x__`, `___x___`, `___` | literal | unchanged |
| `` `_x_` ``, `` _`_` ``, code blocks, `.unknown` blocks | literal | unchanged |
| `\_x\_` | literal | unchanged |

The one accepted regression: prose containing a deliberate lone `_FOO_` now
saves as italic `FOO`. That is CommonMark-correct, it is already what the
reading surface renders, and the escape hatch is `\_`.

The soup row is the delta's only surprise, and it is bounded: 64 of the 164,420
fuzzed inputs have their *visible text* reshaped rather than merely gaining an
italic mark. **Every one of them contains both a `_` and a `*`** — a `_` alone
or a `*` alone can never trigger it — and 61 of the 64 now agree with
Foundation's parser where the old scanner agreed with it **zero** times. The old
scanner was not "safe" on these inputs; it destroyed `*` characters instead of
`_` ones. The remaining 3 are `~~`/`*`/`_` tangles that neither scanner has ever
parsed the way CommonMark does.

## Differential test

The change was differential-tested against the pre-change scanner over
**164,420 unique inputs** (209,397 generated): all 9,330 strings of length ≤ 5
over `` {* _ a \ ` ~} ``, 200,000 seeded-random strings of length ≤ 12 over a
19-character alphabet (adding link syntax, whitespace, digits, `+`, `.`, `!`,
`-`, a non-BMP scalar and `é`), and 67 hand-picked adversarial cases.

Rather than transcribe the old scanner into a test — which would prove only that
the transcription matched — the committed `InlineMarkdown.swift` and the
modified one were each compiled into a standalone binary and run over the same
corpus, then diffed line-for-line. A third binary rendered each input through
Foundation's `AttributedString(markdown:)` as an independent oracle.

| | |
|---|---|
| diverging inputs | 4,213 |
| — gained an italic mark, visible text otherwise identical | 4,149 |
| — visible text reshaped | 64 |
| diverging inputs containing **no** `_` | **0** |
| reshaped inputs lacking both `_` and `*` | **0** |
| reshaped inputs that regressed against Foundation | **0** |
| divergences changing a non-italic mark key (bold, strike, code, link) | **0** |
| runs carrying a duplicated mark key | **0** |

The zero on the *diverging inputs containing no `_`* row is the load-bearing
one: it proves `adding(_:to:)` and every edit to the `*`/`**`/`~~`/code paths are
behavior-preserving on their own, because any change there would surface on an
input with no underscore at all.

Two earlier iterations failed this harness and were fixed because of it: the
code-span/link precedence bug above, and — in the harness itself — a check that
"escaped every `_` and asserted the divergence vanished", which was unsound
because it rewrote a pre-existing `\_` into `\\_` and freed the very underscore
it meant to neutralize. It was replaced by the invariants tabulated above. A
third issue — the nearest-opener pairing — was raised by a code-review pass and
then *confirmed* with the same two binaries against the Foundation oracle before
landing (71 inputs moved onto Foundation's answer, 1 off, zero characters
dropped).

The harness is not committed — it needs two versions of the same file to exist
at once. This section is its record, matching PR #50's precedent.

## Known limitations

- **`__x__` still diverges from the reading surface**, which bolds it while the
  scanner keeps it literal. BlockNote never emits `__` (it uses `**` for strong
  and `_` for em), so this only bites hand-typed markdown. Closing it means full
  CommonMark delimiter-run support (`_`/`__`/`___`), a much larger byte delta on
  content the server never authors. Deliberately out of scope.
- Italic on a hand-typed `__word__` therefore produces a literal `___word___`.
  Non-destructive — the text survives — but no emphasis is applied.
