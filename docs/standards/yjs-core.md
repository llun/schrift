# The Yjs CRDT core (`Core/Yjs`) — the live replica

Separate from the from-scratch save encoder below, `Core/Yjs` holds a hand-written
Yjs **replica** (struct store + YATA integration) for live collaboration. Rules
that are easy to violate and expensive to discover:

- **Transliterate yjs; do not reinterpret it.** The store mirrors **yjs 13.6.33**
  (the version the Docs 6 frontend lockfile resolves) line for line, with the mirrored
  function and its `yjs.cjs` line (`@N`, 13.6.33 numbering) in a comment. Fixtures
  captured with 13.6.31 stay valid: the two releases share the v1 encoding and every
  cited function body except the `cleanupTransactions` deep-observer ordering fix. Its output becomes document state real web clients render, so a
  tidier rewrite that disagrees on one ordering is silent corruption. **Never
  "clean up" `YItem.integrate`** — the YATA conflict loop is the algorithm. A
  change there needs differential-fuzz evidence *and* human sign-off.
- **Three item models exist; don't conflate them.** `YEncoderItem`/`YEncoderContent`
  (`YjsUpdateEncoder.swift`) is the from-scratch encoder's single-client model — no
  origins, no parent, no links — and is what the shipping save path uses.
  `YItemRecord`/`YContentRecord` (`YUpdateDecoder.swift`) is the immutable wire
  record that exists so a decode→encode round trip is byte-identical; never mutate
  it. `YItem`/`YContent` is the live YATA operation. Adding a field means asking
  which of the three needs it.
- **`YContent.string` is `[UInt16]`, not `String`, and must stay so.** yjs's
  `ContentString.splice` transiently produces a lone surrogate before repairing it
  to U+FFFD (yjs#248); no Swift `String` can hold that. Both halves keep their
  length (one orphan out, one U+FFFD in) — the store depends on an item's clock
  range not moving when it splits.
- **A client's struct array is a reference (`YStructList`), not `[YStruct]`.** yjs
  splices into the one array the store holds; a Swift value array would splice into
  a copy and silently lose the split. Read-only helpers take `[YStruct]`; anything
  that splices takes the list.
- **Merge cleanup is mandatory.** yjs merges adjacent items on every transaction
  cleanup, so skipping it diverges from yjs's store after the first update. It is
  independent of gc: merging always runs, whether or not `doc.gc` is set.
- Transactions retain `YTransactionOrigin` bookkeeping, transliterating yjs: the origin is
  whatever the caller passes, nil by default (yjs `null`). `BlockNoteWrite.applyEdit` tags its
  edits `.localUser`; the callers that apply peer or server bytes (the collaboration manager,
  the Docs 6 server-state import in `BlockNoteIncrementalSave`) pass `.remote`. Any other
  `transact` is untagged unless its caller tags it — B4's format cleanup keeps yjs's null
  origin. Nested transactions keep the outer origin. `lastTransactionOrigin` is an internal
  test seam for the most recently cleaned transaction.
- **`YDoc.afterTransaction` is the change signal (B3), fired at yjs's `'afterTransaction'`
  point (@3337).** It runs in the observer phase, after every changed type's
  `_callObserver` (`YType.callObserver`, @5146) has filled `transaction.changedParentTypes`
  through `callTypeObservers` (@5035: the event is recorded at the changed type and every
  ancestor up to the root, in `changed` insertion order), and **before** the formatting
  cleanup and gc/merge, so coalesced typing still reads as inserts. Text events (`YText`
  and `YXmlText`, which share yjs's `YTextEvent`) carry a lazy `delta` that is valid only
  during the hook. Unlike yjs's delta getter it never opens a transaction to read itself.
  Element events carry no delta (plan §5: deltas cover `XmlText` only). The events are
  dropped after the hook so ARC doesn't keep the transaction and type graph alive. A
  `transact` opened inside the hook is queued and drained after the current transaction,
  as in yjs. Buffering and delivery to the UI belong to the engine (B6), not the core.
  **`changedParentTypes` is populated only while a hook or observer is set** — it exists
  for `afterTransaction` and the `YUndoManager` scope check alone, so with neither no
  events are built at all (yjs always builds them
  because `observe`/`observeDeep` are its consumers; Schrift has none). The B4
  formatting-cleanup arming is independent of it and still runs. Both the
  `changedParentTypes` lookup and `changed`'s insertion order are indexed by
  `ObjectIdentifier` (the order as nil-able slots), so a remote update touching N types is
  O(N), not O(N²) — a peer controls N, so a linear scan per event per ancestor is an
  algorithmic DoS.
- **`YDoc.onUpdate` mirrors yjs's `'update'` event, and it is how the replica's own
  cleanup reaches peers.** yjs emits `'update'` from `cleanupTransactions`'s `finally`
  block (@3388-3392) for **every** transaction with content — after gc/merge and the
  client-id re-roll, before the next queued cleanup — and a provider broadcasts every
  update whose origin is not itself. Schrift's hook fires at that exact point with the
  transaction's origin and a lazy `encode` closure over
  `YTransactionEncoder.encodeUpdate(transaction, duringCleanup: true)` (the same encoder
  the local-edit path uses; `duringCleanup` is the one caller allowed while the queue is
  still non-empty). Encoding is lazy so origins the listener ignores (a whole-document
  sync, every keystroke) cost nothing; `encode` is valid only during the call. A nil hook
  runs nothing, so no golden output moves. An encode failure is **swallowed**, never thrown out of cleanup: the event
  is a best-effort broadcast mirror; a store holding pending structs/deletes (which the
  encoder refuses) emits nothing for that transaction. `DocumentCollaborationManager` sets it per replica and
  broadcasts only origin `nil` (the B4 cleanup); `.remote` is an echo and `.localUser` is
  already broadcast by `applyLocalEdit`, and a reader (`canUpdate == false`) never
  publishes.
- **`pendingStructs`/`pendingDs` hold decoded refs, where yjs holds V2 bytes.** A
  deliberate, documented internal deviation — V2 is, in yjs, only a container for
  these two fields, and Schrift's wire is v1 end to end. Nothing stashed is ever
  transmitted, and a replica with pending structs must never be snapshotted to the
  server. Exact duplicates must stay deduped, or a relay's redelivery grows the
  stash without bound. See `docs/architecture.md` for the one known residual
  deviation (re-tiling + yjs#248).
- **yjs does not always converge, so don't assert that it does.** A split surrogate
  pair makes content order-dependent (yjs#248). The property to hold this store to
  is *"it converges exactly when yjs converges"*.
- **Remote-change format cleanup and gc are B4 (landed 2026-07-17); don't reopen
  them ad hoc.** On a *remote* transaction touching a `YType` with `_hasFormatting`,
  `cleanupTransactions`'s observer phase runs `YTextCleanup.cleanupYTextAfterTransaction`,
  deleting `ContentFormat` items concurrent edits made redundant; gc (`Item.gc`/
  `tryGcDeleteSet`, `doc.gc` default true) sweeps the replica's own deleted items into
  `ContentDeleted` tombstones and `GC` structs. Two transliteration invariants are
  load-bearing and proven only by the differential fuzz's nested-text formatting lane
  (a bare root type is never a concrete `YText`, so **only nested text fires the
  trigger** — this is BlockNote's actual shape): (1) format-value equality is JS
  `===`, spelled out by `YFormatAttrValue` (primitives compared by UTF-16 code
  units, objects by value-identity token, absent ⇔ `null`); (2) the cleanup's routing
  is **not confluent across clients** — `iterateDeletedStructs` must walk the delete
  set in yjs `Map` insertion order (`YDeleteSet.orderedClients`), never ascending,
  or a live mark is wrongly
  deleted. B4 unblocked the live write path (C2). See `docs/architecture.md`.
- **`YUndoManager` is yjs's `UndoManager` (@3614), core only (PR07a).** It subscribes
  with `YDoc.addAfterTransactionObserver` — never take the engine's single
  `afterTransaction` slot — and its observer runs right after that slot, before gc,
  so `keepItem` protects a captured deletion from the same transaction's gc. Every
  gc path must keep honouring `keep` (`tryGcDeleteSet` is the only one). Undo/redo
  run as local transactions with origin `.undoManager` (the manager's identity), which
  the manager always tracks so its own steps fill the opposite stack. Deliberate
  differences: origins match by value only (no constructor matching), stack events
  carry no `changedParentTypes`, and `destroy()` keeps the stacks and `keep` marks
  as yjs does (call `clear()` to release them). `YUndoManagerOracleTests` holds
  byte-identical node captures generated by an untracked `.review/oracle/gen-undo.js`;
  regenerate rather than hand-edit them. `trimUndoStack(to:)` is a Schrift addition
  (drop the oldest undo items, releasing their `keep` like `clear()`) for the bounded
  native history; the editor wiring is PR07b (see the document engine section).
- **Malformed input must throw, never trap.** Every clock is attacker-controlled
  (it arrives from a peer), and Swift's UInt arithmetic traps where JS goes
  harmlessly negative — a trap is a remote crash. `YStructIntegrator.validate`
  enforces the one ingest invariant that makes the rest provably safe: **every
  struct has a non-empty clock range whose end fits in a `UInt`**. Prefer
  root-causing to that invariant over sprinkling guards. Note it bounds only what
  would *trap*: a clock past `Number.MAX_SAFE_INTEGER` is harmless and yjs merely
  stashes it, so rejecting one would be **stricter than yjs** — the store must be
  neither more permissive nor more strict than the oracle.
  **A trap is not the only fatal fault — unbounded recursion is one too.**
  `Lib0Decoder.readAny`'s object/array tags nest, so a few KB of `75 01 75 01 …`
  is thousands of stack frames; the overflow is a machine fault that the
  fail-safe `catch` in `DocumentCollaborationManager.applyReplicaUpdate` — the
  thing that exists so malformed wire data can never take the app down — cannot
  intercept. `Lib0Decoder.maxAnyNestingDepth` (64) bounds it, throwing
  `anyNestingTooDeep` instead. A regression test in
  `DocumentCollaborationManagerReplicaTests` delivers such a frame end-to-end — before
  the cap it crashed the whole test process, and a regression will read as
  `Restarting after unexpected exit` rather than a normal failure, so don't
  misfile it as the concurrent-worktree flake. The cap is a **deliberate,
  documented narrowing**, not oracle parity: a JS decoder also refuses eventually
  (a catchable `RangeError`), but only in the thousands, so between 65 and that
  point Schrift is stricter than yjs. Accepted because real content nests two or
  three deep (BlockNote props are flat objects of primitives) and the refusal is
  contained — the update fail-safes rather than corrupting anything.
  **Any recursive path that walks attacker-shaped data needs the same
  treatment**; depth is input, not structure.
- **The delete and gc cascades are the other wire-reachable recursion.** They —
  the delete and gc cascades (`YItem.delete → ContentType.delete → YType.deleteChildren
  → YItem.delete`, and the `YItem.gc` twin) recurse once per nested `ContentType`
  level, and that depth is fully attacker-controlled by one inbound update (~7 wire
  bytes per level). Unbounded, a deep chain overruns the native stack — an
  `EXC_BAD_ACCESS`, *not* a Swift error, so it bypasses
  `DocumentCollaborationManager.applyReplicaUpdate`'s fail-safe `catch` and crashes
  the app (on the **simulator**, whose main-thread stack is large, the crash needs a
  ~20k-deep chain / ~140 KB; a real device's `@MainActor` main-thread stack is ~1 MB,
  roughly 8× smaller, so its floor is far lower). **Integration itself is iterative**
  (a deep chain integrates safely past 200k) — only *delete*/*gc* recurse, matching
  yjs, which likewise accepts deep integration and refuses deep delete/gc (a catchable
  `RangeError`). `YTransaction.maxTypeNestingDepth` (**256** — chosen for the device
  stack, ≲800 native frames even in Debug, and ~25× above realistic content) bounds
  both: `YItem.gc` is already `throws` so it refuses directly; `YItem.delete` is a
  **non-throwing** override so it flags `transaction.recursionLimitExceeded`, and
  `cleanupTransactions` — the one chokepoint every transaction (wire, local write,
  nested cleanup) drains through — converts the flag into a thrown
  `.recursionLimitExceeded`, discarding the half-marked store wholesale before gc/merge
  trust it. The two guards are symmetric (`enterDeleteRecursion`'s `< cap` and
  `YItem.gc`'s `depth < cap`), so both delete-set orderings refuse at the same depth.
  This is a **deliberate narrowing**, oracle-faithful at the accept/reject boundary
  (both refuse deep delete/gc, converge byte-identically below the cap — the golden
  `deleteNestedType` gc fixture is unmoved) but stricter than V8 in the [cap,
  ~V8-limit] band; accepted because real documents nest ~2 type levels per visual
  indent (~200 even for an absurd 100-indent doc), and a document that *does* exceed
  256 loses live collaboration (falls back to classic REST editing) but no data. The
  cap must be **re-measured on a real device, Release build** (a *simulator* Release
  build has the host's large stack and would give a false all-clear) before the
  `schrift.liveCollaboration` flag is defaulted on, and a deep-nesting differential-
  fuzz lane (both delete-set orderings, gc on/off) is owed then; landing behind the
  default-off flag with the unit + manager tests green is the accepted interim.
  **Load-bearing invariant the flag relies on:** the replica must be destroyed on any
  `applyUpdate` throw (as `applyReplicaUpdate` does) — a caller that caught and reused
  the same `YDoc` would leave `transactionCleanups` non-empty and skip the flag check
  on the next transaction. The
  traversal *bodies* are the untouched yjs transliteration — only depth bookkeeping
  wraps the one descent in each. `YDoc.destroy()`, `YStateEncoder`, `YItem.integrate`,
  and `YBlockProjection` are all iterative or opaque-at-first-level and need no cap.
- **The encode side (`YStateEncoder`, B3) derives the wire info byte — it never
  replays a stored one.** `encodeStateAsUpdate(doc, since:)` (full snapshot / diff
  against a state vector) and `encodeStateVector(doc)` transliterate yjs's
  `writeClientsStructs`/`writeStructs`/`Item.write`. The info byte is
  `content.ref | origin/rightOrigin/parentSub presence bits`, computed from the
  **live `YItem`** — **never** `YItem.info`, which is keep/countable/deleted/marker
  runtime flags, not the wire byte (`YUpdateReencoder`'s *record* round-trip replays
  the byte; the store encode cannot). Clients are written **descending** everywhere
  — struct blocks, state vectors, delete sets; the ingest-side `YDeleteSet.asBlocks()`
  is **ascending** and must never be reused for the wire. On a diff (`offset > 0`)
  the first struct's origin is substituted (`clock + offset - 1`) and its content
  sliced — that one line *is* the diff path. `encodeStateAsUpdate` **throws** while
  `pendingStructs`/`pendingDs` are non-nil (a deliberate narrowing: yjs folds pending
  in via `diffUpdateV2`, but a pending replica must never be snapshotted). Reuse
  `YUpdateReencoder`'s delete-set/state-vector writers (offset-free, proven);
  transliterate the rest. **`YTransactionEncoder.encodeUpdate(transaction)`**
  transliterates `writeUpdateMessageFromTransaction` (@3163) and
  `writeStructsFromTransaction` (@1674), reusing that same struct writer. Use it for
  local edits: it writes only new structs and the transaction's own sorted/merged
  delete set, never scans the whole store for historical tombstones, and returns
  nil when neither deletes nor clocks changed. It shares the pending-state refusal
  and descending client order. Return `tx` from the existing generic `doc.transact`
  closure and encode **immediately after the outermost call succeeds**, before
  another edit: cleanup must have filled `afterState` and finished gc/merging
  (yjs's update-event timing). Encoding while a transaction/cleanup is active throws.
  Keep `YStateEncoder` for full snapshots and peer state-vector replies, which need
  the whole delete set. `BlockNoteWrite` retains its `Data` API by mapping nil to
  the canonical empty v1 update `0000`.
- **The projection (`YBlockProjection`, B5) is total and reads *web-authored*
  replicas — it never authors content.** `project(_:interlinkingOrigin:)` folds an
  integrated replica back into `ProjectedBlock`s (the inverse of
  `BlockNoteYjs.emitInline`) and `projectedMarkdown` renders them to editor markdown.
  It **never throws and never traps** on any replica shape (clocks are
  attacker-influenced): anything unrecognised becomes a per-block
  `ProjectionFidelity` — `.modeled` (round-trips), `.lossy` (renders with the same
  parity the server's markdown export gives but write-back would drop data), or
  `.opaque` (no markdown spelling at all; a document with any opaque block is not
  `isFullyRenderable`, so C1 must not live-apply it). Do not "fix" an unexpected
  shape by guessing — project it opaque/lossy. `isFullyModeled` is the "safe to write
  back" contract C2 will gate on, so a **type-mismatched** prop value (a non-bool
  heading `isToggleable`, a non-string image `name`) must classify `.lossy`/`.opaque`,
  never `.modeled`. `interlinkingLinkInline` projects as a `[title](origin/docs/id/)`
  link only when the caller passes the server origin (exact parity with the export),
  else `.opaque` — never lossy, which would let a classic save flatten the link away.
- **`InlineMarkdownWriter` (B5) converges on the `InlineMarkdown` scanner — it is not
  a second parser.** The correctness property is
  `InlineMarkdown.parse(write(runs)) ≡ normalized(runs)`; where a spelling can't
  round-trip the writer returns `nil` (and `projectedMarkdown` escalates escaping,
  then goes opaque) rather than emit markdown that reads back as a different document.
  It holds a **locked copy** of the scanner's escaping/flanking predicates — a
  sync-lock test fails if they drift (the same discipline `isEscapable` uses). Any
  change to the writer must keep **both** the writer tests and the scanner's
  `InlineLayoutTests` green together; "the golden bytes didn't move" does not prove
  the scanner is unchanged (see the inline-scanner rules under "Editor & the
  on-device save").
- **The local-edit write path (`YWrite`, `TextSpanDiff`, `BlockNoteWrite`, B6) is
  pure `Core/Yjs`; C2a wires it into the live editor.** `YWrite` is the
  local-mutation primitive layer — list insert/delete (`typeListInsertGenericsAfter`/
  `typeListInsertGenerics`/`typeListDelete`) and map set (`typeMapSet`), each a
  faithful transliteration that mints local `YItem`s and integrates them through the
  existing YATA loop inside `doc.transact(local: true)`. `BlockNoteWrite.applyEdit(
  old:new:to:)` diffs two BlockNote block lists by id (insert/remove/kind-change/
  prop-change/move) and returns `YTransactionEncoder.encodeUpdate(tx)` after
  cleanup — only the structs and deletes this edit made (`0000` if unchanged).
  **The single writer, gated in two parts (B5b, plan decision 6).** Insertion is
  shared by both entry points — `insertBlock`/`insertContentElement` — so from-empty
  and new-block insertion stay byte-identical to the golden encoder on either path.
  A *surviving* block is reconciled by one of two paths, chosen explicitly at the
  call site:
  - `applyEdit` — the **live** path (`DocumentCollaborationManager.applyLocalEdit`)
    — reconciles through `BlockNoteWriter`'s intents: text through `replaceText`
    (one intent per run of the span `TextSpanDiff` chose, with explicit marks so the
    span never inherits a mark open at the caret), props and kind changes through
    `setBlockType` (same type sets only the changed props on the existing element;
    a kind change replaces the content element and keeps the container, `id` and
    nested group). The writer's own `transaction` sees the caller's open transaction
    and returns the empty update, so the whole edit stays one transaction and one
    broadcast. It addresses the block by the **container's live `id`**, not the
    caller's: the editor re-identifies a row after a remote structural change while
    the replica keeps the server's id, and the legacy reconcile never rewrote a
    survivor's id either. It also refuses an `old` whose text length disagrees with
    the live element — a lying-`old` guard, because the writer clamps a range (editor
    safety), so a lying `old` would silently rewrite the wrong span instead of
    failing, and the manager's fail-safe contract depends on the throw; the guard is
    skipped for inline-node blocks, which never take the writer path. Two kinds of
    survivor fall back to the legacy reconcile instead: a block type the writer does
    not edit (`quote`, `divider`, `image` — the projection models them, so the live
    path can reach them), and a block whose element holds an inline node — exact for
    `interlinkingLinkInline`, which the projection folds into a run whose text is the
    link title while the live element counts the node as one unit, so the writer's
    run-space offsets do not map to live offsets; defensive for mention/math/hard
    break, which the projection does not fold (it returns non-text inline content, so
    the block is `.opaque` and the live bridge never writes it). Both fallbacks are
    the code the live path ran before, so they cannot change a document; the
    alternative is a throw the manager turns into a fail-safe and a permanent
    downgrade to classic.
  - `applyEditLegacy` — the **Docs 6 incremental save**
    (`BlockNoteIncrementalSave`) — keeps the hand-authored `TextSpanDiff` +
    `YWrite` reconcile, byte-for-byte as before the writer landed. Plan decision 6
    does not re-point it in phase 1; `BlockNoteIncrementalSaveTests` pins its bytes.
  **Its strongest correctness gate is from-empty byte identity**:
  `applyEdit(old: [], new: blocks)` must be byte-identical to the shipping
  `BlockNoteYjs.encode(blocks)` golden encoder, which holds because `insertBlock`
  mints items in the encoder's exact order (blockGroup, container, element,
  `xmlText`+runs, props, nested `blockGroup` + children, id — a *new* block may carry
  children, inserted as a nested group exactly as `emitGroup` does and pinned by the
  nested from-empty anchors; `old` must stay flat, and a survivor whose new block has
  children is rebuilt, never reconciled). On the **legacy** path a text change is
  spliced in place only when
  the element's sole child is one `xmlText`; otherwise (y-prosemirror writes **no**
  `xmlText` for an empty paragraph; an inline node splits text into several) the
  element is rebuilt, since a splice would drop or misplace the edit. The writer
  path has no such restriction for a text-only element: `replaceText` addresses the
  right `xmlText` (and creates one when the element has none). An element holding an
  inline node still takes the legacy rebuild on both paths, because its run-space
  offsets do not map to live offsets. **Move is v1-coarse** — a reordered survivor is
  rebuilt whole (delete + re-insert), never relocated in place; reorders are rare
  and stay covered by full-snapshot fixtures.
- **`BlockNoteWriter` is the single writer: B5a's intent API, and since B5b the
  reconcile the live path uses** (`BlockNoteWrite.applyEdit`; the Docs 6 save still
  calls `applyEditLegacy`). It locates
  unique block ids by UTF-16 code units (opaque JS strings; normalization forms
  are distinct) and exposes replaceText, formatRange, splitBlock, joinBlocks,
  and setBlockType. Each intent opens a `.localUser` transaction and returns its
  incremental update after cleanup; `transaction` groups intents (nested calls
  return the empty update; the outer call returns the combined bytes). **A group
  is not atomic** — each intent validates before it mutates, but if a later one
  throws, the earlier ones stay in the store and the transaction's observers
  still deliver them while the call throws without bytes (yjs has no rollback);
  after a throw the replica, not the return value, is the truth. UTF-16
  offsets count inline XmlElements (mention/interlink/math/`hardBreak`, BlockNote's
  Shift+Enter) as one atomic unit, and no bound or caret ever lands inside a
  surrogate pair: a range grows to the whole character, a caret moves back to its
  start (yjs would splice the pair and write U+FFFD into both halves).
  Clamp ranges before calling `YTextOps` so formatting cannot pad with newlines.
  Code blocks allow no marks: `formatRange` is a successful no-op with an empty
  update, and `replaceText` drops supplied marks and inserts plain text, matching
  BlockNote's style commands and explicit/stored-mark typing. Converting back to
  a paragraph must not reveal formatting authored while it was a code block.
  Copied text uses **`InlineContent.pieces(for:)`**, the same single inline-shape
  builder as the encoder and B6; do not add another run-to-format builder.
  **Block intents follow BlockNote 0.56's own commands, verified in node, not
  reasoned from ProseMirror** (`BlockNoteWriterCaptures` inlines the captures):
  split is Enter — the new block is a list item for list items and a paragraph
  otherwise, always with default props, and takes the nested children; at offset
  0 of non-empty content an empty block goes above instead, so ids stay with
  their text. Join is `mergeBlocksCommand` — into the previous sibling's *last
  descendant*, the source's children lifted into its place; an empty block above
  with the same type and props is removed instead and the source keeps its id.
  Type change is `updateBlock` — `props` override, other props of the new type
  keep their existing value or default (`propSchemas`, the classic allowlist; the native
  engine's writer uses `nativePropSchemas`, which adds `quote` and Docs' `callout`). **Keeping
  the type sets only the changed props on the existing element** (a checkbox toggle
  or heading level is one attribute struct, byte-identical to BlockNote) — never
  rebuild the element there, or a collaborator's concurrent typing in it is lost
  on merge. Into a
  `codeBlock` the content becomes ProseMirror `textContent` (copying inline nodes
  there made real BlockNote delete the whole fragment on mount). Two deliberate
  deviations: the surrogate-pair snap above (BlockNote writes U+FFFD into both
  halves of a split emoji), and BlockNote's keyboard-level choices before those
  commands (Backspace resetting a list item, Enter resetting an empty list item or
  outdenting an empty nested block, merging a first child into its parent) are the
  caller's — the writer's split does not outdent, and the first sibling throws
  `noPreviousBlock`. Errors: `malformedBlock` means a broken replica;
  `unsupportedBlockType` means a valid block the writer does not edit (divider,
  image, quote, table, toggle list item, toggle heading split — including on a
  join's way to the previous last descendant, where BlockNote might merge) or one
  BlockNote refuses (splitting/joining a code block). The native table
  (`nativePropSchemas`) also edits quote, callout and toggle list items, and its
  callers split a toggle by passing `splitBlock(toggleOpen:)` (PR06b).
- **B6 deviates from yjs only in local-item *construction*, never in the store
  algorithm — verify at the document/projection level, not the store-structure
  level.** It rebuilds a changed text span wholesale from the new runs (not yjs's
  incremental per-character format delta) and its generic list-delete steps through
  interior `ContentFormat` items that yjs's own `deleteText` walks past — both
  harmless because the inserted span is **self-describing**: `TextSpanDiff` diffs
  runs as a **character-level (char, active-marks)** sequence (not UTF-16-unit),
  snaps both changed-range boundaries to **code-point boundaries** so a surrogate
  pair is never split across kept/changed regions (a split renders U+FFFD — yjs#248
  — on content the edit never touched), and its replacement pieces open the marks
  active at the new start and re-close to the kept suffix's marks at the end. So a
  store-dump comparison against yjs would **false-fail** on a correct B6 edit
  (different items, same rendered content) — B6 is instead verified by applying the
  same edit on both sides and comparing the **projected document** and cross-peer
  convergence; `YItem.integrate`/merge/gc/the encoders are untouched by B6. A
  differential fuzz run once with an out-of-tree harness (zero-dep rule) ran ~26k seeds /
  ~400k oracle-verified renders against node yjs across BMP, concurrent-convergence,
  and `mergeUpdates`/gc/`diffUpdate` interop lanes — 0 divergences after fixing one
  bug the fuzz found (a raw UTF-16-unit diff splitting a surrogate pair; the
  code-point snap above is the fix). **B5b's re-point was gated on a parity lane**
  (an out-of-tree harness, run once): 1000 seeds × 3 sequential random edits over
  paragraphs, headings, list items, check lists, code blocks, quotes, dividers and
  images — text edits with marks/links/emoji, prop changes, kind changes, inserts,
  deletes, moves and empty blocks — applying each edit to two identical replicas
  through `applyEditLegacy` and `applyEdit` and comparing the **projected document**
  (id, node, props, per-unit marks, fidelity) plus a from-empty render of `new`:
  3000 cases, 0 mismatches. The lane covers link **marks** only: `BlockNoteBlock`
  runs cannot express an inline node, so it never produced an
  `interlinkingLinkInline` — that shape is covered by
  `BlockNoteWriteLiveReconcileTests`. The one intended difference it surfaced: a code block
  whose runs carry marks (a document BlockNote cannot produce — the projection reads
  it as opaque `marked code`) keeps them on the legacy path and loses them on the
  writer path, which is BlockNote's own rule. No incremental byte pin moved: the
  writer's `replaceText` mints the same items as the legacy splice for the pinned
  cases (`b6TypingUpdateHex`, the split pin in `YTransactionEncoderTests`), so
  nothing needed re-capturing. `InlineContent.pieces(for:)`
  (`InlineContent.swift`) is the **one shared inline-shape builder** behind the
  from-scratch encoder (`BlockNoteYjs.emitInline`), `BlockNoteWrite`'s
  whole-subtree paths and `BlockNoteWriter`'s copies — don't add a second way to
  turn a run list into the open/carry/close-format sequence; `TextSpanDiff`'s own
  diff-specific piece builder emits the same `InlinePiece` vocabulary through the
  same `content(of:)` mapper, not a competing definition of inline shape. **INV
  1.24, restated for the single writer:** `BlockNoteWriter` is the only writer of
  in-place block edits (text through `YTextOps`, inline shapes through
  `InlineContent.pieces`), and `BlockNoteWrite` is the only block-level differ; the
  legacy `TextSpanDiff` + `YWrite` reconcile survives only as
  `applyEditLegacy` (the Docs 6 save) and as the fallback for block types the
  writer does not edit (`quote`, `divider`, `image`) and for elements holding an
  inline node (whose run-space offsets do not map to live offsets). Do not add a
  third reconcile.
- **`YRelativePosition` (B2) is the caret/selection primitive: a type ref, one item
  id, and `assoc`, transliterated from yjs's `RelativePosition` (@2301) and its
  codecs.** `fromTypeIndex` (@2421) captures, `resolve(in:)` (@2547) resolves to a
  `YAbsolutePosition` (type + visible index), `encode`/`decode` (@2477/@2515) are the
  binary form over the existing `Lib0Encoder`/`Lib0Decoder`, `json`/`init(json:)`
  (@2340/@2363) are yjs's JSON shape, and `compare` (@2609) is its equality. The
  headless engine uses it for selection and composition; no shipping editor caller
  yet. Reductions, all documented in the file:
  `followUndoneDeletions` follows the `YItem.redone` chain `YUndoManager` sets
  (`YStructStore.followRedone`, @9567); and the binary form is **lossy by design** — case 1 (an item id) carries no type,
  because the item's parent implies it — so a decoded mid-list capture has
  `type == nil` and only the end-of-type cases round-trip it. Two yjs behaviours that
  look like bugs and are not: an **unknown kind tag decodes without throwing** (yjs's
  `switch` has no `default`; the position is merely unresolvable), and an **unknown
  `tname` resolves to a fresh empty root** because yjs calls `doc.get(tname)`.
  `assoc` is load-bearing at `index == length`: `assoc 0` captures the end-of-type
  position (`item == nil`) and follows text a peer appends, `assoc -1` captures the
  last character's id and stays before it — the C2 end-of-paragraph IME fix, pinned
  by `YRelativePositionTests`. **Caller rules for the cursor path** (PR10a's `DocumentEngine.peerPlace` follows them; all in
  `resolve`'s doc comment): an unknown `tname` **creates that root permanently** in
  `doc.share`, so a peer-fed caller (awareness cursors) must only resolve names that
  already exist or that the schema owns (`document-store`); a **throw means a
  malformed position, not a corrupt replica** — drop the cursor and never latch
  `replicaFailSafe`; and `resolve` reads/mutates the live doc, so it runs on the
  replica's owner (since PR08b the `DocumentReplicaSession` actor), unlike the value and its codecs.
- **`YDoc.destroy()` is not optional.** The item graph is a mesh of strong cycles,
  so releasing a `YDoc` frees nothing; whoever owns a replica must tear it down.
- **`YTextOps` is the format-aware text write path (B4), and three of its rules are
  easy to "fix" wrongly.** (1) **Attribute maps are ordered** — `insertAttributes`
  mints one `ContentFormat` per changed key in iteration order, so the order decides
  the clock order of those items and therefore the update bytes; `YTextAttributes`
  keeps insertion order (a `dictionaryLiteral` keeps source order, which is JS
  object-literal order for the non-integer keys every schema uses), and a Swift
  `Dictionary` would not. (2) **Two equality rules over the same map** — the ops path
  uses yjs's `equalAttrs` (@6282, `YJSONValue.equalAttrs`): `===` first, then
  lib0 `equalFlat` for any two containers (arrays expose index keys, so `[]` equals
  `{}`; nested values compare with `===`, never by JSON text). The cleanup path
  uses only `===` (`YFormatAttrValue`); `YTextAttributeValue`
  carries both the raw JSON and a `YAttributeIdentity` token so each path gets
  its rule. Restoring/negating a value preserves that token on the new item
  (`YItem.formatIdentity`); decoding mints separate identities lazily, and tokens
  are never encoded. The event delta preserves tokens in its attribute maps too.
  Primitive numbers compare numerically; strings use UTF-16 code-unit equality,
  including inside flat objects: Swift canonical equivalence is not JS `===`. (3)
  **Out-of-range indices are yjs's, not the editor's** — an insert past the end
  appends, a delete past the end stops at the end, and a format past the end **pads
  the text with `'\n'`** (@6584, Quill's trailing-newline convention). Clamping for
  editor safety is the caller's (B5), not this layer's. The current BlockNote writer
  still uses `YWrite`/`TextSpanDiff`; B5 will wire it to `YTextOps`. `deleteText` reuses
  `YTextCleanup.cleanupFormattingGap` (@6604) rather than duplicating it, and a
  locally minted `ContentFormat` already sets `_hasFormatting` through
  `YContent.integrate` (@8991) — never edit `YItem.integrate` to do it.
  `YTextOpsTests` replays twelve yjs 13.6.33 captures op for op (both the
  state-vector diff update and the transaction's own `'update'` bytes, plus
  `toDelta()` after each), including the C2 boundary delete and a nested `XmlText`.
  **Fixtures must deep-clone attribute objects per op.** Because the cleanup compares
  object values by identity, reusing one `{href:…}` object across ops makes two
  `ContentFormat` items share a value object — a relation JSON cannot carry, so the
  recorded ops stop replaying (a shared-object random lane diverged at 1 of 100
  sequences; deep-cloned, 0 of 3000 ops). Within an op, yjs reuses the *same* value
  object when restoring/negating a current attribute. Schrift preserves that relation with
  the in-memory token, so deleting an unformatted insertion cleans up its restored
  object format exactly as yjs does. Encoding then decoding creates separate value
  objects in yjs and separate tokens here; identity is deliberately not serialized.
- **BlockNote 0.56 every-step goldens** (`BlockNote056*Tests`) inline eight captures from the phase 0 S3 spike
  from yjs 13.6.33, checking seed XML and all 17 edits. They hold XML and update bytes only; the captures' text deltas are not committed yet. B2's cursor positions are pinned separately by `YRelativePositionTests` (relative positions captured from yjs 13.6.33).
- **Verify against the oracle, not against reasoning.** Golden fixtures
  (`YIntegration*Tests`) pin each YATA branch from real yjs; the differential fuzz
  harness (an out-of-tree harness, zero-dep rule) compares the
  whole store against a node yjs oracle across randomized op scripts and delivery
  orders. **A green run only proves there is no bug in the shapes the generator can
  build** — 11,986 clean comparisons missed a critical bug because the corpus
  contained no `Skip`. So: measure branch coverage, and enumerate the input space
  from *yjs's own producers* — incremental updates, cumulative snapshots,
  `mergeUpdates`/`diffUpdate` output (the only source of Skips, and what a relay's
  persistence layer stores), gc'd peers, and hand-built malformed frames. The
  corpus needs at least *three* shapes: random-position inserts for the conflict
  loop's case 2; contiguous appends plus cumulative snapshots for
  `Item.integrate`'s offset>0 path (an overlapping struct only exists once a sender
  has merged a run); and merged/diffed updates for Skip handling.
- **A deviation "for safety" needs the same evidence as any other change.** Both of
  this store's worst bugs were in code written to be *safer* than yjs — a stash
  dedupe (which then let a `Skip` swallow a real item, losing content) and a
  "defensive" merge of duplicate client blocks where yjs simply overwrites. If you
  cannot demonstrate the deviation against the oracle, transliterate instead.
