# The document engine (`Features/Editor/Engine`, B6a/B6b)

The layer the native reader sits on. The native editor is the default;
`schrift.nativeEditor` is a Profile preference that only an explicit off turns back
to the classic editor.

- **Native reader (PR01).** On first open, or reopen from `.loading` or `.native`,
  `NativeEditorOpen` reads the preference before starting classic tasks or the live bridge;
  a reappearing mounted classic route keeps running its tasks during the reread. For an online
  Docs 6 document with no pending local content, `NativeEditorOpen` fetches
  `collaborationYDocState`. With the switch on, the classic editor is selected only for a
  pre-Docs 6 server, for pending local work (local document, pending deletion, checkpointed
  create, classic draft, pending save, unsaved classic content), and for an offline or
  unreachable open that has a cached classic copy. A failed config or raw-state fetch, an
  unreadable fetched state and a failed replica seed show the native `.unavailable` state with
  Retry; an offline open with no replica and no cached copy shows "Go online to open this
  page". There is no prefetch deadline: loading lasts until the fetch answers or fails, and
  URLSession's own timeouts apply. A superseded open (generation, account or availability
  moved) leaves the route to the newer open instead of selecting classic. Never replace a
  focused editor when the toggle changes.
  After selecting native, `NativeEditorOpen` runs `refreshOfflineCacheForNativeReader` off the
  critical path (in an owned task cancelled on close, supersede, or reconnect refresh) to fetch
  the server's Markdown export, reuse leaf-nesting recovery and `cacheServerCopy`, and preserve
  its title/server timestamp for the classic offline fallback. First-open header metadata (`title`,
  `lastSyncedAt`, and a `bodyIsUnknown` timestamp-only `nativeServerBaseline` when no cached
  baseline exists) is seeded at activation from the already-fetched state/detail responses so
  first paint never waits on the cache refresh. The deferred refresh skips cache writes while a
  save is in flight or pending, fills in the seeded baseline's body (clearing `bodyIsUnknown`)
  when `formatted.updatedAt` still matches the seed even while native edits are pending, never
  advances baseline/`lastSyncedAt`/`title` while native edits are pending, never regresses
  `nativeServerBaseline.serverUpdatedAt`, and never replaces `title` while the title field is
  focused.
  This refresh covers content only; it does not populate the children cache.
  It never installs classic display state or changes the classic load route, and its
  failure never blocks the native session.
  Since PR08b the read-only reader is `NativeEditorSession.inspect(state:)`: a one-shot
  projection with no replica session at all. An editable session's replica belongs
  to `DocumentReplicaSession` (PR08b bullet below), which destroys it on close, failed
  initialization and deinitialization. It never borrows the manager's replica.
  `NativeTextView` is selectable, non-editable TextKit 2 with one main scroller;
  never read its legacy layout manager or force full-document layout/measurement.
  `AttributedDocumentProjection` and `ProjectionRangeIndex` keep paragraph
  separators outside replica text. Snapshots carry `isOpaque` for preserved
  placeholders; unsupported nodes and invalid roots are explicit read-only states.
  Apply every origin without optimism. After settled patches, storage must equal
  a fresh attributed projection, comparing semantic attribute values. Text patches replace exact delta ranges; props/replacements
  rebuild one block slice. The session supplies fresh per-block projections for
  text/props patches: placeholder offsets are never replica text offsets, and
  fidelity-changing props/marks require a rebuilt slice. Structural edits insert/remove slices; only
  reset replaces all storage. Presentation changes may restyle without a Yjs write.
  PR01 has no native editing, persistence, sockets, rich block controls or legacy
  local-replica adapter. The isolated `SchriftNativeTestHost` hosts the production
  reader; `--native-large` chooses 5,000 paragraphs, `--native-media` (PR06e) images, tables
  and math with a local delayed image loader. No shipping launch arguments.

- **PR02a persistence checkpoint.**
  `Native/ReplicaStore` is a lock-serialized (PR08a), throwing draft store under Application
  Support's `dev.llun.Schrift/ReplicaDrafts`, scoped by server/account/org/document.
  Immutable checkpoint/journal bytes and directory entries are flushed before a
  checksummed manifest is atomically switched. Only referenced files are accepted;
  interrupted uncommitted files are ignored. Restore verifies every committed file
  and quarantines corruption with a sticky replay/write hold. Compaction switches
  first and retains every unsent local segment, including delete-only updates.
  Only a captured HTTP-confirmed outbox prefix may be acknowledged; later edits
  remain queued. These files are backup-included, never evicted and have no sign-out
  purge. `remove(for:)` (keep-server-version, `discardPendingWork`, so deletion; only for
  the signed-in owner — another or unknown account keeps its replica, marker and native
  draft while the rest of the delete completes) renames
  the scope folder to a tombstone before clearing the owner marker and deleting it.
  `ReplicaSaveAdapter.compactIfNeeded` compacts after an ack or raw capture once 64
  covered (non-outbox) segments exist. Production typing is wired by slice B (below).

- **PR02a typing checkpoint.**
  `NativeEditorSession.enableTyping(persist:scheduler:)` installs `NativeInputCoordinator`
  for the slice B open route and isolated tests. The delegate always refuses
  UIKit's own mutation and submits one `NativeEditCommand` (UUID, base revision,
  block-relative UTF-16 range) through `DocumentEngine.replaceText(_:persist:)`.
  Writer target and echo reprojection both resolve through `BlockIndex` without a
  document-wide ID walk. The engine buffers patches until the incremental update
  callback returns durably, then advances revision and delivers stamped emissions.
  The surface deduplicates exact command emissions, never all `.localUser` patches;
  untagged locals and `.other` rebuilds always apply. No whole-document projection
  or state encoding is performed per keystroke. Since PR08b same-block typing is
  predicted (shown before its append) and everything else waits for its result:
  see the PR08b bullet.
  Non-simple/unprojectable/opaque text, placeholders, invalid/surrogate-splitting
  UTF-16 ranges and inline object characters are rejected before mutation; ranges
  across separators and newline input are PR04b range commands (below). Marked text
  (IME) is handled by the PR03 composition session below; a composition this editor
  cannot support keeps the preserved read-only refusal. Undo arrived in PR07b (below). A write/cleanup/persistence failure freezes
  authoring and delivery, retains any returned unconfirmed bytes in memory and
  preserves the pre-edit display plus existing durable files; never retry against
  that mutated graph.
  `NativeTypingTests` exercises the real UIKit delegate, replayed storage equality,
  echo/repair/refusal/error cases and per-key counters on 5,000 paragraphs.
  The isolated native test host supports `--native-typing` with disposable raw
  checkpoint/journal files; its UI test checks keyboard input and a Return split.
  This flag belongs only to the test host, never the shipping app.

- **PR02a save/restore component checkpoint.**
  `ReplicaSaveAdapter.record` only appends local incremental bytes. Explicit save
  preparation verifies the durable store and captures an immutable outbox batch;
  `enqueueReplica` uses the same coordinator pending/in-flight/held slots, conflict
  stamps, title half-land result, permission errors and background-task lifetime.
  It verifies Docs 6 config/org and the current account before sending the existing
  collaboration-ydoc PATCH; it never takes the legacy snapshot route or a Markdown
  diff. A whole captured body batch is acknowledged durably before title is tried.
  Partial batches retain all bytes for idempotent retry. Later journal revisions
  retain the draft and `.pendingSync`, even if they share a Markdown shadow; the next
  replay re-stamps that reference and shadow from the current raw revision (same
  scope/format/generation, matching shadow, revision not ahead of the journal) and
  refuses anything else. A raw save never writes the classic content cache. Raw
  enqueue and "Keep mine" require the remembered signed-in owner (`SignedInUserStore`,
  nil fails closed); a failed raw capture after "Keep mine" reports `.failed`.
  `enqueueReplica` never takes a caller shadow: it re-captures the stored draft's
  verified one (`prepare(markdown:expected:)`, non-optional) or projects a first
  capture from raw (`prepare()`). `saveNow` retries a raw-owned `.failed`/
  `.pendingSync` draft through `retryReplicaDraft`, never the refused classic enqueue.
  `PendingDraft.replica` is optional-on-decode and stamps scope/format/generation/
  revision plus canonical shadow digest. Classic/live enqueues cannot overwrite
  such drafts. Conflict/title/finish rewrites preserve the reference; old-draft
  adoption, Markdown attachment rewrites and pending-create migration refuse it.
  Raw replay shares `draftSyncDecision` and title adoption but never deletes a raw
  draft on discard/403/404. A5's `isLiveReplicaHeld` skip stays before replay reads
  and is rechecked after account/fetch awaits; held native requests resume through
  the existing release funnel after that hold clears.
  `NativeEditorSession.restore` replays checkpoint+journal into a fresh non-colliding
  author client and initializes the engine from the durable revision. Server-state
  integration journals remote bytes before releasing display patches, including
  idempotent no-op updates; remote sequences never enter the local outbox. Disk or
  cleanup failure freezes the unsafe graph and keeps the accepted display intact.
  A restored durable session installs `onUnjournaledTransaction`: any unjournaled
  transaction freezes the engine rather than drifting `revision` from the manifest,
  and stops input with the storage-failed notice. Backspace at a block start is
  structural (PR04a below); at the document end (after the last separator, which
  no block owns) it is refused with a notice, like typing there.
  Still open: a total shadow for opaque/rich documents and old Markdown-draft migration
  (clean-replica removal on sign-out and local-create key migration landed in PR15). No live socket.

- **Native typing activation, behind the native switch.** `NativeEditorOpen.open(
  viewModel:isOffline:canUpdate:)` enables typing only when the switch is on, the server
  is Docs 6, the remembered signed-in user owns the scope, `canUpdate`
  (`pinRow.abilities.update`, nil fails closed) holds, the document is not a pending
  create/delete, `isLiveHeld` is false, `session.canType` (fully modeled with a Markdown
  shadow) and there is no classic draft or queued save (a classic draft stays classic
  until it syncs). An owned replica is restored offline-first, then
  `integrateServerState` merges the fetched raw state into the same owner; never install
  a converted response over it. An unowned eligible document is seeded by
  `ReplicaStore.create` (marker first) and restored. Anything else keeps PR01's in-memory
  read-only session with no marker. With the switch on, a failed fetch, an unreadable
  fetched state or a failed seed shows the native `.unavailable` state with Retry instead
  of the classic editor; only the switch-off, legacy-server and pending-local-work gates
  still select classic. Keep-server conflict resolution proves the fetched bytes install
  (`DocumentReplicaSession.validateInstallable`: decode, apply with no retained structs,
  project) before it closes the session or discards the replica, draft and conflict; an
  uninstallable state keeps all three and reports the error. Each persisted command calls
  `NativeReplicaSaveScheduler.schedule()` (classic `autosaveInterval`, 30 s cap), which
  hands the verified outbox to `enqueueReplica` with the content cache's server title
  and baseline. Close and inactive/background flush it; a reopened replica with an
  outbox and no pending save schedules one. When a native replica save fails
  retryably (5xx, timeout, 429, or a title PATCH failing after the body landed)
  while online and foregrounded (initialized from the scene phase),
  `DocumentSaveCoordinator` retries that document through its replay path on bounded
  exponential backoff (2 s doubling to 60 s, floored by 429 `Retry-After`, preserved
  across sync passes, offline and background, and reset on success, a new edit,
  sign-out, conflict, terminal failure or delete), skipping held or conflicted saves
  and cancelling on offline, background, sign-out or document delete. A refused
  capture freezes authoring and
  calls `noteReplicaCaptureFailure`. The native view shows `SaveStatusIndicator`
  (unsent journal bytes → "Saved on this device"); its tap is
  `NativeEditorOpen.saveNow`, never the classic `saveNow`. Reconnect calls
  `refresh`, which integrates again. Every await in open/integration rechecks the
  open's generation and `signedInUser.userID`; `EditorView` takes
  `SessionStore.signInGeneration` (via `EditorScreen`/`HomeSplitView`) and closes and
  reopens a non-classic route when it changes. With the switch on, a marker without a
  replica is cleared only through `clearNativeOwnership` (no manifest, quarantine,
  draft, queued or in-flight save) and the unowned route re-seeds it. Profile's
  recovery row also runs `repairReplicaOwnership`, which rebuilds corrupt or lost
  marker data from the scoped manifests and native drafts' scopes (folders without a
  manifest or quarantine are skipped; a quarantined, damaged or newer-format folder, an
  unreadable draft store, or two scopes for one document with no draft or single
  outbox to choose by writes nothing; a readable owner is never replaced; the failure
  alert then offers `setAsideUnreadableReplicasAndRepair`, which moves unreadable folders,
  bytes intact, to `ReplicaDraftsSetAside` and repairs again). A native
  draft owns its document without a marker entry; seeding never falls back to classic
  over replica data already on disk; classic `restoreLocalContent` never shows a
  native draft or save. Both login flows pass the confirmed id to
  `signIn(serverURL:userID:)` (remembered before the generation moves); a flush while
  the account is unknown keeps the save pending ("Saved on this device") and re-arms
  the debounce interval (floored at 1 s) instead of failing; `signOut` bumps `signInGeneration` too; the confirmation (`confirmSession`)
  treats an unparseable id as unknown, never as a failed sign-in.
  `SignedInUserStore.epoch` moves at every clear, and the Home/Profile `/users/me/`
  writers drop answers whose epoch moved. Close cancels `NativeEditorOpen.reopen`/
  `refreshInBackground`; the native cache refresh checks currency and discard. Native live content is its own socket (PR09a bullet below); a native session never takes the
  live write path. `NativeEditorActivationTests` covers these; the native host's
  `--native-open` fixture runs the real `EditorView` route offline over an owned
  replica (`--reset` clears it) and its UI test types, relaunches and checks the text.

- **PR03 IME composition, one block, with provisional recovery.** `Native/NativeCompositionSession`
  owns a UIKit marked-text composition. `setMarkedText`, and `setAttributedMarkedText`
  (the entry point the system Japanese/Chinese keyboards use), in a typeable block
  capture both replacement endpoints as a `RelativeEditorRange` **before** UIKit owns
  the marked range (an insertion at the caret, or a selected-text replacement inside one
  block), then let UIKit own the provisional range in storage. Provisional text is never
  written to Yjs. A composing keyboard asks the delegate before its first keystroke:
  for a `ja`/`zh`/`yue`/`ko` input mode a one-character insertion at the selection is
  allowed through to the overridden `setMarkedText`/`insertText` instead of becoming a
  Latin command (`allowsUIKitChange`); `textViewDidChange` restores the projection if
  UIKit ever changed storage behind the command path. While text is marked the whole
  view belongs to the composition: remote patches still enter the replica (the engine
  defers the composing block), but the coordinator queues every delivery (PR08b's
  composition rule; past 256 it asks for a `.reset` resync, PR08c), the surface defers theme/width restyles and offset commands and
  selection publication are refused, because document-wide UIKit offsets are stale until
  reconciliation. Commit (`unmarkText`, which writes what UIKit displays, or
  `insertText` replacing the marked text) resolves the anchors and writes the string
  **once** as one durable `NativeEditCommand` through
  `DocumentEngine.compositionCommitted(text:commandID:persist:)` (journal before
  publication, the same `ReplicaStore.append` path as typing), then delivers one
  `.other` rebuild; reconciliation replaces only the provisional block's storage slice
  (`provisionalBlockID`), applies the buffered patches, then the deferred restyle.
  Backspace inside marked text edits the marked string; an emptied composition cancels.
  A target deleted or replaced during the composition returns `.orphaned`: nothing is
  written and the commit is never redirected into a new text under the same block id.
  Cancel writes nothing and returns the caret to the composition start. Focus loss that
  never reached `unmarkText` writes nothing and keeps the text for recovery. A
  multi-block selection or an opaque/placeholder target keeps the preserved read-only
  refusal (`native_editor_marked_unavailable`).
  **Recovery.** With a replica store, every marked-text change rewrites
  `provisional.json` in the scope folder (`ReplicaStore.writeProvisionalRecoveries`,
  flushed temporary file + rename + directory flush); commit and cancel remove the
  entry. It is not in the manifest, journal or outbox, is never broadcast and is never
  replayed or committed automatically. An entry whose command id reached the journal
  was committed before a crash skipped its cleanup and is dropped on read. Orphaned
  commits and entries left by a crash or relaunch mid-composition are
  `pendingRecoveries`; `NativeEditorView` shows them with a notice
  (`native_editor_composition_orphaned` / `native_editor_recovery_interrupted`) and
  Insert at cursor (the ordinary command path; a refused caret keeps the entry), Copy
  and Discard. `remove(for:)` takes the file with the replica folder.
  `NativeCompositionTests` and `NativeCompositionRecoveryTests` drive synthetic
  `setMarkedText`/`unmarkText` on a real `NativeTextView`; the native host's
  `--native-ime` buttons do the same in the running `--native-open` route, and
  `testJapaneseKeyboardComposesAndConfirmsOnce` types with the real Japanese Romaji
  keyboard when the simulator has it enabled (skipped otherwise).

- **PR04a Return and boundary Backspace.** Each is one `NativeEditCommand` (`.split(offset:
  newID:)` / `.join`; `.replace` is typing) through `DocumentEngine.applyStructural(_:persist:)`:
  journal before publication, a stamped echo applied once, never the unjournaled freeze.
  It follows BlockNote 0.56's keyboard layer before calling the writer: Return →
  `splitBlock` (heading → heading + paragraph, list item → same kind, default props, the
  coordinator mints the one new id); Return in an empty list item → `setBlockType`
  paragraph in place (no block, so the minted id never reaches the model); Backspace at a
  heading/list item start → paragraph; only a paragraph `joinBlocks` into the block above
  (an empty same-type block above is removed instead). The returned caret is the lower
  block's start (the old id at offset 0 of non-empty text, where the writer inserts the
  empty block above) or the join point. Every refusal (opaque, placeholder, code, an
  unreadable or locked child that would move, inline nodes, the first block, a locked destination) throws
  `.unsupportedNativeInput` before `nativeCommand` is set; a `BlockNoteWriter.Error` thrown
  after arming but before any transaction (no stamped emission, so nothing was written) is
  also a refusal, never the freeze. Return shows the input notice,
  Backspace stays a quiet no-op. `replaceText` also accepts an empty text-capable element
  (the new block a split leaves), which the writer gives an XmlText. `NativeTextView.insertText`
  routes key-input Return exactly once (it never calls super, so the delegate is not asked);
  the delegate's newline branch covers other UIKit paths. The simulator's software keyboard
  deletes at a block start by replacing the separator before the caret (delegate or UITextInput
  `replace`), not `deleteBackward`: `replace(range:with:)` routes that exact shape to the same
  boundary Backspace. Marked text: Return commits the
  composition (PR03) and does not split. Patches insert/remove slices, never `.reset`, so
  the scroll offset holds. Quote and callout are in the native engine's writer schemas
  (`nativePropSchemas`, PR05b) and split/join like a paragraph; the classic table is unchanged.
  `NativeStructuralTests` (real view over a restored durable replica: split start/middle/end,
  heading/list/empty list, joins, resets, refusals, peer edit, Return→IME, scroll, relaunch,
  converged XML against the node captures) and the host UI test `testReturnAndBackspaceAreDurableStructureAfterRelaunch`.

- **PR04b selection and structural range input.** Anything `NativeInputCoordinator.replace`
  gets that is not one block's text without a line break is one `.range(NativeRangeCommand)`
  command (first block + start offset, end block + offset, plain text, coordinator-minted
  ids for the blocks its newlines create) through `applyStructural`: typing, Backspace or
  the keyboard delete key over a selection, Return over a selection, dictation's final
  result, UITextInput `replace`, paste and cut. Line breaks (CRLF, CR, U+2028/9, NEL)
  normalize to "\n" first. **Validate every block from first to last before arming**:
  opaque, placeholder, code, inline nodes, a toggle (PR06b: its split depends on view state) or a block outside the first
  block's group (another depth, or a middle block's children) anywhere
  throws `.unsupportedNativeInput` (notice `native_editor_range_unavailable`, no write,
  never the freeze). `BlockNoteWriter.replaceRange(from:at:to:at:lines:newIDs:)` takes
  indexed targets (no document walk) and writes one transaction, ProseMirror's replace:
  the first block keeps id/type/props + the first line; later lines are new blocks (list
  item kind, else paragraph, default props, like Return); the last line takes the end
  block's tail; blocks between and the end block are removed. It never walks past the
  group's end (the end must follow the start) and refuses nested children that would move.
  `NativeRangeCommandTests` checks a one-separator delete against the merge capture and a
  pasted "\n" against the split capture. The end-of-document boundary ends a range (the
  last block's text end, `ProjectionRangeIndex.textPosition(atUTF16:isUpperBound:)`) but
  is never a caret: deleting only the last separator is refused with a notice.
  `NativeSelectionCoordinator` publishes UIKit's selection (skipped while
  `NativeTextSurface.isApplyingPatch` or text is marked) as directed relative positions:
  direction comes from which end moved (Shift-arrows), and a non-empty range uses assoc 0
  at its start and -1 at its end so a peer's boundary insertion stays outside. It restores
  the view from `DocumentEngine.currentSelectionEndpoints()` after every patch except the
  editor's own stamped echo (`NativeTextSurface.onPatchApplied`); commands place their caret
  through `selection.place`. A command's storage edit and caret (`replace`, `applyStructural`)
  and a patch's restore reach the keyboard as one `inputDelegate` text change
  (`asOneKeyboardChange`): a caret set outside one makes UIKit accept a pending autocorrection
  or inline prediction at the range it last saw (`prepareForSelectionChange`), which turned
  "elsewhere" typed at a paragraph end into "elseeleresewhereh" (`NativeSelectionTests`).
  It sets `selectedRange` only when the restored range differs from the view's (setting
  it ends a handle drag): an edit after the selection never sets
  it; UIKit does not shift the range for storage edits before it, so those are corrected
  (`restoredSelections` counts sets, since a programmatic set sends no delegate callback).
  One vanished endpoint collapses to the survivor; both gone
  moves the caret to the start of the block after the head's old block, else the end of the
  one before. An endpoint in a placeholder clears the engine selection. `NativeClipboard`
  + the view's `copy:`/`cut:`/`paste:`/`pasteAndMatchStyle:` overrides: copy is one line
  per block (placeholders omitted; nothing copyable, or marked text, leaves the pasteboard
  alone), cut is copy plus one range delete (a refused delete leaves the pasteboard), paste
  reads only `UIPasteboard.string` and refuses whole, with `native_editor_paste_too_large`,
  more than 200,000 UTF-16 units or 2,000 lines (`NativeClipboard.maxPaste*`); the lossless rich
  clipboard is PR06d (below). `NativeInputCoordinator.pasteboard` is a seam (tests use
  `UIPasteboard.withUniqueName()`). The simulator's software delete key over a selection
  arrives as `shouldChangeTextInRanges` with the selection; XCUITest `typeKey` delivers
  nothing for delete/forward-delete. IME over a multi-block selection keeps PR03's refusal.
  Tests: `NativeSelectionTests`, `NativeRangeCommandTests`, `NativeClipboardTests` (shared
  `NativeEditingTestCase` harness) and the host UI test
  `testShiftArrowSelectionAcrossParagraphsIsReplacedDurably`.

- **PR05a inline marks, links and colours.** The engine projects with
  `YBlockProjection.project/projectBlock(nativeMarks: true)` (since PR06a through
  `NativeBlockProjection`; snapshots, `.replaceBlock`,
  `.reset`, `nativeSnapshot`): every stored mark stays in the runs, known or not, and none
  makes a block lossy, because the native save writes raw Yjs. The default (`false`) still
  scrubs what Markdown cannot spell for the classic live path, the save shadow and
  `BlockNotePreservation`; never flip it there. `BlockIndex.projectsAsText` therefore accepts
  any mark key (an unreadable link stays opaque), and `canType` is the native projection's
  `isFullyModeled` plus a classic-projection Markdown shadow, as `ReplicaSaveAdapter`
  captures it. A mark change is one `.marks(NativeMarkCommand)` (first block + start offset,
  end block + offset, only the changed keys; `"null"` removes) through `applyStructural`:
  every block with text in the range is validated before arming like `.range` (an end at the
  next block's start touches nothing there), values must be `"null"` or a JSON object with a
  readable link href, and one grouped transaction calls `BlockNoteWriter.formatRange(in:)` per
  block, so the text is untouched. `PatchBuilder.formatDeltas` splits a format range into one
  `.text` delta per run of uniform marks, so a mixed range is still marks-only. Values are
  BlockNote 0.56's: `{}` for bold/italic/underline/strike/code, `{"stringValue":"red"}` for
  `textColor`/`backgroundColor` (names in `NativeMark.colors`), `{"href":…}` built by
  `NativeMark.linkValue` like the Markdown writer. `NativeInputCoordinator`: `toggleMark` over
  a selection is off when every character has it, else on everywhere (a mixed run turns all
  on); at a caret it only sets the pending typing marks (ProseMirror's stored marks, dropped
  by a user selection change). Typing takes ProseMirror's `$pos.marks()` / `marksAcross`
  (`NativeMarkSelection`; link and unknown keys are non-inclusive) and sends them as
  `.replace(…, marks:)` only when they differ from what Yjs inherits (the character before), so
  plain typing inside a run writes the bytes it always did. At a run's start the explicit marks
  differ from Yjs inheritance, for example typing at offset 0 before a bold run now continues bold
  as ProseMirror does, so those bytes change. Code is treated as inclusive; this is unconfirmed
  against BlockNote 0.56. `activeMarks` (common marks of the selection,
  or the caret's typing marks) drives `NativeFormattingBar` in `NativeEditorView` (the classic
  bar's tokens and labels, `nativeEditor.format.<key>` identifiers, `.isSelected` when on) and
  the view's `typingAttributes`. Links reuse `LinkEditorSheet` and `sanitizedLinkURL`: an
  unchanged label is one `.marks` command, a new or edited label is one `.replace` with the link
  in its marks (one block only; across blocks it is refused with a notice), a caret inside a
  link edits the whole link, Remove writes `link: null`. Colours render as shared dynamic
  `UIColor`s from BlockNote's palette, so light/dark changes neither storage nor Yjs and a Dynamic
  Type restyle writes no transaction. Not yet: code's `excludes` (code and other marks combine),
  IME commits ignore a pending caret toggle, hardware ⌘B/⌘I. Tests: `NativeFormattingTests`,
  `NativeMarkOracleTests` (bold on/off byte-identical, typed marks/link/colour to the capture's
  XML), the host UI test `testBoldOnASelectedWordSurvivesRelaunch`.

- **PR05b block presentation and controls.** Chrome is drawn, never stored: no bullet,
  number, checkbox or emoji character enters storage or Yjs. `NativeBlockControls` is the
  TextKit 2 layout delegate, so every fragment is a `NativeBlockFragment` that draws the
  bullet, the number, the quote bar and panel, the callout box (BlockNote background name
  or `brandFillSubtle`) and emoji, the code panel, the solid divider and the dashed,
  labelled page break (never drawn as a divider) in the `AppTheme` colours resolved at draw
  time. `AttributedDocumentProjection` supplies plain-valued attributes the chrome reads
  (`nativeListNumber`, `nativeChecked`, `nativeCodeLanguage`, `nativeCalloutEmoji`,
  `nativeCalloutBackground`, `accessibilityTextHeadingLevel`) and indents scaled with
  Dynamic Type (`NativeBlockMetrics`). Numbers follow BlockNote's indexing plugin: a run
  starts at its first item's `start` (unset/0 is 1), later starts are ignored;
  `NativeTextSurface` renumbers after any non-text patch by setting only that attribute. A
  code block's "\n" is displayed as U+2028 (same UTF-16 length, one TextKit paragraph, one
  panel); copy uses the model's "\n". No syntax highlighting. Theme/labels/light-dark only
  invalidate layout; Dynamic Type restyles storage; neither writes Yjs.
  **Controls** are real `UIButton`s placed over the viewport's fragments in `layoutSubviews`
  (after `layoutViewport()`, re-placed on every storage edit): the checkbox (44pt, label
  "Mark as done"/"Mark as not done", value "Done"/"Not done", disabled without an input
  coordinator) and the code-language menu (the block's own language is always listed). The
  text view's `accessibilityCustomRotors` holds the system Headings rotor over every
  heading's text range in storage (not just the viewport). **Prop edits** are one
  `.props([ProjectedProp])` command each through `applyStructural` (checked, start,
  language, emoji, heading level): `isPropEdit` validates key, block type and value
  (start 1…999,999 or undefined, level 1…6, language 1–64 non-space characters, one emoji
  grapheme) before arming, and `BlockNoteWriter.setBlockProps` is `updateBlock`'s same-type
  path, never a type change; an unchanged value sends nothing. The **slash menu** reuses
  `SlashMenuView` (`available: NativeInputCoordinator.slashItems`: paragraph, heading 1–3,
  bullet, numbered, checklist, quote, code, and since PR06b toggle heading and toggle list;
  divider, photo and file wait for later slices): a
  paragraph that starts with "/" and has the caret after a whitespace-free "/query" shows
  it, and a choice is one `.blockType(node:props:removing:)` that deletes only that token
  (text after the caret stays, as in the classic editor) and
  `setBlockType`s in one transaction, as BlockNote's suggestion menu does. **Markdown typing
  shortcuts** reuse `.blockType` for block prefixes (a paragraph starting with `# `, `## `,
  `### `, `- `, `* `, `+ `, `1. `, `1) `, `[] `, `[ ] `, `[x] ` or `> ` converts on its
  trailing space, headings 4–6 stay literal, and a triple-backtick fence converts on Return
  with its language prop; only plain paragraphs, never table cells, locked blocks or scoped
  sources) and use `.markShortcut` for inline marks (`**x**`/`__x__` bold, `*x*`/`_x_` italic,
  `` `x` `` code, `~~x~~` strike: closing delimiter removes both delimiters and formats the
  body in one transaction, with code clearing other marks and the new mark off for subsequent
  typing; works in prose blocks and table cells, never in code blocks, code-marked text or
  opaque cards); typing shortcuts fire only on typing, never on IME composition or Paste and Match Style. The engine has no
  `NSRange`/UIKit (`DocumentEngineBoundaryTests`); the writer has `Range<Int>` overloads. Return in a code block, and pasting
  lines into one, is one `.replace` that keeps "\n" in the block (the engine accepts "\n"
  only for `codeBlock`). Under `nativeMarks` the projection also models `callout`,
  `pageBreak` and any numbered `start` (undefined or ≥ 1); the classic projection keeps
  them opaque/lossy. Since PR06c the save shadow spells them as the export does (see the
  PR06c bullet), so a callout or page break no longer makes the production route read-only. Tests: `NativeBlockPresentationTests`
  (checkbox, heading-level and type-change bytes/XML against the node captures),
  `NativeAccessibilityTests`, the host UI test `testCheckboxTapSurvivesRelaunch`
  (`--native-blocks` seeds a heading, checklist, code, lists, quote and divider).

- **PR06a tree projection, nested prose, indent/outdent.** `Core/Yjs/NativeBlockProjection`
  projects the whole `blockGroup → blockContainer → blockGroup …` tree in preorder: each
  block reads exactly as `YBlockProjection.projectBlock(…, nestedChildren: true)` (the
  classic per-block read; the default `false` keeps a block with children opaque for
  every classic caller, and a flat document projects identically), followed by its
  children one level deeper. `NativeBlockSnapshot` carries `depth`, the parent and a
  `NativeBlockHandle` (the index's per-engine `generation`, the integrated container
  `YID`, the string id as link metadata); `BlockSnapshot` gains `depth`/`parentID` only, so
  surfaces still compare semantically. A missing or repeated id makes that container
  opaque and it stands for its subtree (not projected; the index is non-canonical, so the
  engine refuses input and resets until it is fixed); a block at depth
  `NativeBlockProjection.maxDepth` (64) with children is opaque (bounded recursion).
  Opacity does not spread: an unknown block's children are ordinary blocks.
  `BlockIndex` indexes every block in preorder by the same descent rule
  (`nestedGroup(of:)`: exactly the content element then one group), with depth, parent,
  group, nested group and handle; `blockID(for:)` is the innermost container. A nested
  block's text keeps the `.text` fast path and its attributes `.props`. Any group
  membership or container child-list change rebuilds the index and diffs the preorder:
  removed ids, inserts anchored after the previous kept id, `.replaceBlock` for a kept id
  whose container, depth or parent changed (a clone-and-delete move), and a peer's
  reorder removes and reinserts only the span between the common prefix and suffix.
  **Tree commands** (`BlockNoteTreeCommands.swift`) are BlockNote 0.56's `nestBlock`/
  `unnestBlock` for one block: `sinkListItem` (last child of the previous sibling, in its
  group or a new one, its own children with it) and `liftListItem` (`liftToOuterList`:
  after its parent, the following siblings appended to its children, an emptied group
  removed). Yjs cannot reparent an integrated node, so each copies every raw value
  (`snapshot`/`insertCopy`, before writing) and deletes the original in one transaction;
  the string ids survive, the items do not, and a peer's concurrent edit inside the moved
  block lands in the deleted original, as with y-prosemirror. `.indent`/`.outdent` are
  one `applyStructural` command each, validated before arming (`requireMovable`): every
  moved block (the block and its children; for an outdent also the following siblings and
  theirs) must be non-opaque and unlocked, an indent needs a readable previous sibling
  in the same group and keeps the deepest moved block within
  `BlockNoteWriter.maxNestingDepth` (16), an outdent needs a parent; refusals are quiet
  no-ops. A move changes no text, so `NativeInputCoordinator.indent()/outdent()` keep
  the view's selection and re-capture it. Keyboard rules, BlockNote's order: Return in an
  empty list item resets it to a paragraph first, then Return in an empty nested block
  outdents it (not under an open toggle, which keeps empty children: PR06b); Backspace at a
  nested start follows the installed 0.56 `KeyboardShortcutsExtension.ts`: reset a
  non-paragraph, then merge into the block above (`joinBlocks` into the previous
  sibling's last descendant, or `BlockNoteWriter.mergeIntoParent` for a first child,
  whose children take its place and whose emptied group goes), and outdent only as the
  last fallback when that merge cannot happen (code or an unreadable block above). No
  node capture exists for a nested-source Backspace; `NativeStructuralTests` pins the
  order and `BlockNoteTreeOracleTests` the merge. Return splits a
  nested block into a sibling at its depth; a split or join that copies children checks
  them first; a range must stay in one group. `NativeTextView` binds Tab/Shift-Tab as key
  commands with priority over UIKit and routes a typed "\t" to `insertTab()` (two spaces
  in a code block, BlockNote's `indentLineWithTab`, else indent); the formatting bar has
  Outdent/Indent (`nativeEditor.format.outdent`/`.indent`, the classic strings).
  Rendering: each level indents one scaled `listGutter`, the projection stamps
  `nativeDepth`, and chrome, panels and checkboxes start at that indent; numbering is per
  sibling run (`listNumbers` keys the previous number by parent). The save shadow and
  `canType` use `NativeBlockProjection.markdownShadow`: a flat document's classic shadow,
  else the tree indented (Markdown keeps list nesting, other nesting reads flat), so a
  nested list stays typeable and savable (PR06c adds callouts, toggles and page breaks). Tests: `NativeTreeProjectionTests`,
  `NativeIndentTests`, `BlockNoteTreeOracleTests` (`f-sink-bullet`, `enter-empty-nested`)
  and the host UI test `testTabNestsTheSecondBulletAndSurvivesRelaunch` (`--native-tree`
  seeds two bullets and host-only caret/depth controls). Subtree
  move/copy/clipboard and drag-to-reorder are described below.

- **PR06b toggles and local folding.** Under the native flag (`nativeMarks`, as PR05b
  gated callouts) `YBlockProjection` models `toggleListItem` (BlockNote 0.56
  `defaultProps`, added to `BlockNoteWriter.nativePropSchemas`) and a heading with
  `isToggleable: true`; the classic projection keeps both opaque, so classic callers,
  preservation and golden bytes are unchanged. A toggle's title is its text and its
  children its nested group (PR06a's tree). `AttributedDocumentProjection` stamps
  `.nativeToggle` and indents the title one `listGutter`; `NativeBlockControls` places a
  real 44pt disclosure `UIButton` there (`nativeEditor.toggle.<id>`, label "Expand or
  collapse", value "Expanded"/"Collapsed", `accessibilityExpandedStatus`), enabled in the
  read-only reader too. **Folding is view state on `NativeTextSurface`**: `expanded`
  (block ids, in memory per open document; a toggle not in it is collapsed, BlockNote's
  `defaultToggledState` default) and `hidden` (per position, inside a collapsed toggle),
  recomputed after every non-text patch and fold change (a text patch moves no block). It
  never writes Yjs and never edits storage: `NativeBlockControls` is also the
  `NSTextContentStorageDelegate`, and `textContentManager(_:shouldEnumerate:)` leaves a
  hidden paragraph out of TextKit 2 layout, so storage, `blocks` and the range index
  stay the full projection and every patch (a peer's edit inside folded children
  included) lands as anywhere else; a fold change only invalidates layout
  (`onFoldChange`). A toggle whose direct child count grows opens (BlockNote's toggle
  frame `update`: a peer's new child, a Tab into it). VoiceOver never reaches folded
  content: `NativeTextView.accessibilityValue` is the storage text without
  `surface.hiddenRanges`, the Headings rotor skips hidden headings, and controls exist
  only for laid-out fragments. **The folded-content rule:** a `.range` or `.marks`
  command touching any hidden block is refused before arming
  (`native_editor_range_unavailable`; expanded, a mark range covers the children), no
  command targets a hidden block, a caret UIKit places in folded content moves past it in
  its direction (`revealCaret`), and Backspace whose merge target (the preorder block
  above) is hidden unfolds that toggle first (`surface.reveal`). **Keyboard**, the
  installed 0.56 `experimental_keyboard` + `KeyboardShortcutsExtension.ts` order, with
  the open state passed in `.split(offset:newID:open:)` (the block and its parent if
  expanded): an empty toggle resets (`emptyEnterResets`: toggle list item → paragraph,
  toggle heading → `isToggleable: false`, children kept); Enter at the start of
  non-empty text inserts an empty block above (a toggle list item keeps its type); open,
  the text after the caret becomes a new first child paragraph (a new group if none);
  closed, a split keeps the children with the toggle and the new sibling is a toggle list
  item or (for a heading) a paragraph; an empty child of an open toggle gets a new child
  after it, of a closed one outdents. Backspace at a toggle's start resets it the same way
  (`resetsTo`), then merges as before. A range touching a toggle is refused (writer and
  engine). The slash menu adds native-only "Toggle heading" (level 1, `isToggleable`) and
  "Toggle list" (`toggleHeadingSlashItem`/`toggleListSlashItem`, `SlashMenuAction.toggle`,
  never in `allSlashMenuItems`), each one `.blockType` `setBlockType`. Since PR06c every
  toggle shape has a Markdown shadow (below), so a toggle no longer makes the production
  open route read-only (`canType`). Tests: `NativeToggleTests`, `BlockNoteToggleOracleTests` (every
  command against `BlockNoteToggleCaptures`, captured from the installed 0.56 through the
  view's keydown handling: tiptap's `keyboardShortcut` command replays steps with
  `maybeStep` and drops the toggle commands' later steps) and the host UI test
  `testFoldedToggleKeepsItsChildrenWhileTypingElsewhere` (`--native-typing --native-toggle`).

- **PR06c rich-block save shadow.** `NativeBlockProjection.markdownShadow` spells the
  blocks only the native projection models the way the server's Markdown export
  (BlockNote 0.56 `blocksToMarkdownLossy`) does, checked against the real capture: a
  callout is a paragraph with its emoji, a space and its text (`👍 Text`; background
  dropped), a toggle list item is a bullet, a toggle heading a plain heading with its
  children flat, and a page break is dropped. These are rewrites of the classic tree
  (`exportSpelling`, matched by the classic opaque reasons), so the classic projection,
  `projectedMarkdown`'s self-check, preservation and golden bytes are unchanged, and a flat
  document with none of these blocks keeps exactly the classic shadow. A root subtree the
  classic rendering cannot spell like the export (`needsExport`: a toggle list item with a
  non-list descendant, as Return in an open toggle makes, or a callout or page break with
  children) is instead the export's own Markdown from `NativeExportMarkdown`, a port of
  0.56's `serializeBlocksExternalHTML` + `htmlToMarkdown`: a toggle's children go into its
  `<details>` as indented continuation paragraphs, except its leading list children, which
  move after them (`* T\n\n  c1\n  * sub` for either order); a plain block's children
  flatten after it; inline text is not escaped, each text node is wrapped in its own
  marks with its link innermost (a link a mark splits is two links), and `formatLink` writes
  the bare URL only when the label is the URL and that URL is not `http(s)://`/`www.` or
  reads back whole through `parseAutolinkLiteral`, else `[label](url)` escaped. A callout
  in such a subtree (with children, or inside a toggle) has no shadow: it is Schrift's
  own block and its export there is unconfirmed. The classic parser reads those indented
  lines as verbatim text, so the chunk skips the classic self-check (nothing to compare)
  and is joined to the classic segments by blank lines. Lossy like the export; the raw Yjs
  save still carries the real blocks. Besides those callouts, only a callout without a
  non-empty emoji (the native editor never writes one) has no shadow; math and diagrams gate
  as before (a familiar root table is spelled since PR11a, a familiar root column group since
  PR12a and a root media block since PR13a, bullets below). The writer spells italic `_x_` where the export writes `*x*`; conflict decisions
  compare parsed runs (`syncCanonicalMarkdown`), so that is not a conflict, but the port's
  verbatim chunks are compared as text. Tests: `NativeShadowExportParityTests` (the `.review/`
  capture item by item up to its table, the export's spellings, thirteen toggle shapes and
  sixteen links pinned byte for byte against the
  installed exporter, `canType`, a typed save and Return in an open toggle whose shadow
  `draftSyncDecision` reads as our last push).
- **Edge whitespace in the save shadow (fix after PR11c).** The classic rendering's
  self-check re-parses its Markdown, and the parser trims a line's edge whitespace (a
  leading space or tab even makes the line verbatim text), so a block whose text started or
  ended with whitespace had no shadow: a save captured right after typing a space (the
  10-second debounce, or a close) threw `unprojectableShadow` and froze authoring with
  "Couldn't save", and a document holding such a block opened read-only. Now a root subtree
  with a block whose text, or one of whose marked runs, starts or ends with
  `.whitespaces` or JS whitespace (`hasEdgeWhitespace`; never a code block, which is
  verbatim) is spelled by `NativeExportMarkdown.body`, untrimmed, and the whole shadow is
  trimmed like `htmlToMarkdown` (`result.trim() + "\n"`, `NativeExportMarkdown.trimmed`).
  `jsWhitespace` is exactly ECMAScript WhiteSpace and LineTerminator (U+0009–000D, U+0020,
  U+00A0, U+1680, U+2000–200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF), never
  Foundation's `.whitespaces`, which holds U+200B: JS keeps a leading U+200B, so
  `"\u{200B}# Heading"` stays a paragraph. What BlockNote 0.56 exports: a block keeps its
  edge spaces, tabs and NBSP verbatim and only the document's ends are trimmed; bold and
  italic move trailing whitespace out of their delimiters and keep leading whitespace inside
  (`** b**x`), strike, code and links keep both inside (`~~s ~~`, `` `c ` ``,
  `[ site ](url)`); a table cell is trimmed the same way. In such a subtree a childless
  callout outside a toggle (root or nested under a plain block or list, the shapes the
  classic rendering spells) is the paragraph `exportSpelling` makes of it (`exportNodes`;
  its whitespace export is unconfirmed: the harness's callout is a stub). **An edge space
  never takes a shadow away:** a subtree the port cannot spell (a nested image) falls back
  to the classic rendering, then to the classic rendering of the text with its edge
  whitespace trimmed (`edgeTrimmed`, as `syncCanonicalMarkdown` reads it; a false conflict
  at worst, never a freeze). Known limit: each flagged root is its own chunk, so a list it
  splits renumbers and turns loose, which `syncCanonicalMarkdown` does not see. Tests:
  `BlockNoteWhitespaceOracleTests` (`BlockNoteWhitespaceCaptures`, ws.mjs: 32 web
  fixtures with U+200B and U+FEFF, the shadow byte for byte the export except the split
  list, equal under `syncCanonicalMarkdown`) and `NativeShadowExportParityTests`
  (`testASaveRightAfterATrailingSpaceDoesNotFreeze`, `testAnEdgeSpaceNeverTakesAShadowAway`).
- **PR06e bounded previews and attachment sizing.** A block `AttributedDocumentProjection.isPlaceholder`
  (non-prose node or opaque) is **one U+FFFC attachment character** plus its separator:
  `displayText` is `attachmentCharacter`, so the range index, refusals and clipboard rules
  are unchanged and these blocks stay preserved and read-only (PR11–PR14 author them; a
  familiar table's cells are edited in the table editor since PR11a, media blocks in their
  inspector since PR13a, bullets below).
  The preview data is `Core/Yjs/NativeBlockPreview`, read by `NativeBlockProjection.projectBlock`
  into `NativeBlockSnapshot.preview` / `BlockSnapshot.preview` (a duplicate-id rewrite gets a
  `.preserved` one), so it travels in every snapshot, reset and `.replaceBlock` and a peer's
  table edit reaches the card. It is bounded (`Limits`: 6 × 4 cells, 4 columns × 3 lines, 4
  source lines, 80 UTF-16 units per string) and never a write-back source. Families: `.image`
  (showPreview not false: url, caption or name as alt, `previewWidth`), `.file` (video, audio,
  file, pdf, hidden-preview image), `.table`, `.columns`, `.source` (mathBlock, diagram; no
  renderer, owner decision) and `.preserved` (anything else, with a line of text).
  `Features/Editor/Native/NativeBlockAttachment.swift`: `NativeBlockAttachment` is equal by
  value (`NativeAttachmentContent`), so storage still equals a fresh projection; Foundation
  uniques equal attribute values, so two storages may share one immutable attachment.
  **Never set its `bounds`**: TextKit 2 then draws a file icon and never asks for a view
  provider (S1 finding 3, reconfirmed). The provider tracks view bounds and the
  `NativeAttachmentView` reports `content.size` as its intrinsic size. **The S2 fix, attachment
  paragraphs only:** `NativeAttachmentLayout.size` computes the card from the usable width,
  Dynamic Type and, for an image, `previewWidth` (capped at the width) over the remembered
  aspect ratio (else the 160 pt placeholder; 44–640 pt), and the paragraph's
  minimum = maximum line height is `content.lineHeight` (the card plus the separator font's
  descent, since the attachment sits on the baseline). Text line heights are never pinned.
  `NativeAttachmentGeometry` (usable width + known ratios) is part of the surface's
  presentation: `NativeTextView.layoutSubviews` calls `blockControls.updateAttachmentWidth()`
  before `super`, and `NativeTextSurface.updateAttachmentWidth` replaces only attachment slices
  in place (same length, no Yjs, deferred while text is marked); Dynamic Type rebuilds as
  before. **A download never restyles storage**: the image is fitted into the reserved box and
  its ratio (`ImageLoader.aspectRatio`, via `surface.aspectRatio`) applies at the next width
  or Dynamic Type change or open. Fresh projections in tests pass
  `geometry: surface.attachmentGeometry` (`NativeEditingTestCase.assertConsistent` does).
  Images use the environment's `ImageLoader` (optional; `NativeEditorView` passes it and
  `isOffline` to `NativeBlockControls`): the loader's own origin check, consent
  ("External image · tap to load", `approveAndLoad`), disk cache and offline state apply.
  `NativeEditorView` takes the document's `serverOrigin` (required, like the classic image
  sites) for `NativeBlockControls.sessionImages`, which mirrors `MarkdownImageView.matchesSession`:
  a loader whose scope is another server's shows no cached image, issues no request (load,
  tap or ratio) and reads as offline, and a load that finishes under a changed session is
  dropped. No loader issues no request. A loaded image's card stays clear on a theme change. Views
  exist only for laid-out fragments (`attachmentViewLoads`, `visibleAttachmentViews`); a
  theme change re-colours the realised ones. VoiceOver: each card is one element labelled
  `attachmentLabel` ("Image: alt", "Video: clip.mp4", "Table, 3 by 4", "Columns, 2", "Math",
  "node (preserved, not editable yet)"), a tap-to-load card is a button, and
  `NativeTextView.accessibilityValue` reads the label in place of U+FFFC. Strings:
  `native_editor_attachment_named`/`video`/`audio`/`file`/`pdf`/`table`/`table_more`/
  `columns`/`math`/`diagram`, the classic `editor_image_*` reused. Not yet: poster frames,
  file sizes (BlockNote stores none), opening media, a refreshed height when a ratio arrives
  for an image already on screen. Tests: `NativeAttachmentLayoutTests` (each family, the S2
  line/view agreement, load and width change, Dynamic Type, external and offline images,
  5,000 blocks / 200 previews realisation, a peer table edit, VoiceOver, the `.review/`
  capture when present) and the host UI test `testImagesAndTablesScrollWithoutJumping`
  (`--native-media`: same-origin images served by a delayed local closure, tables, math;
  drags to the end: every drag moves the cards together, by about its length until the
  document ends, a download moves nothing, and the host's `media.contentHeight` readout grows
  under 15% while the drags reveal the cards: pinned, an unlaid attachment paragraph's
  estimate is final (2,319 to 2,463 pt on the iOS 27 simulator, the text paragraphs'
  estimates), unpinned it grew 1,602 to 2,405 pt with no visible jump. Distances are not
  compared between drags: a loaded simulator's touch sampling moves the pan start by ~12 pt).
- **PR06d subtree commands and the lossless clipboard.** `NativeBlockAction` (menu order:
  move up, move down, outdent, indent, insert above, insert below, duplicate, copy, delete)
  acts on `NativeInputCoordinator.blockActionTarget()`: the caret's block, or the block a
  selection lies in (nil across blocks, while composing, in folded content). Three surfaces
  share `availableBlockActions()`/`performBlockAction(_:)`: the formatting bar's first
  button (`nativeEditor.format.block`, a popover `NativeBlockMenu` with
  `nativeEditor.block.<action>` buttons, availability worked out only when shown), a Block
  submenu in the long-press edit menu (`textView(_:editMenuForTextIn:suggestedActions:)`,
  unavailable actions `.disabled`), and `NativeTextView.accessibilityCustomActions`
  (available actions only, computed when VoiceOver asks). Labels come through
  `NativeEditorLabels.blockMenu`/`blockActions`; indent/outdent reuse the classic strings.
  **Commands** (`NativeEditCommand.Kind`): `.moveUp`, `.moveDown`, `.duplicate(newIDs:)`,
  `.deleteBlock`, `.insertBlock(newID:before:)`, `.insertSubtrees(payload:)`, each
  one `applyStructural` (`prepareBlockCommand`, validated before arming). Availability is
  `DocumentEngine.canApplyStructural` (the same preparation, nothing armed) and, for Copy,
  `hasLosslessCopy`; the menu never offers what the engine would refuse. Moves are
  BlockNote 0.56's `moveBlocksUp`/`moveBlocksDown` (`getMovePlacement`): past a sibling
  with children into its nearest child (after its last child going up, before its first
  going down), past the group's end out beside the parent, nothing at the document's
  first/last root block; `BlockNoteWriter.moveBlock` (`BlockNoteTreeCommands.swift`)
  clones and deletes like sink/lift and removes a nested group it empties. They take the
  container `YItem`, not a `Target`, because a divider or page break (modeled, not a writer
  schema type) moves too. Every moved or duplicated block must be readable and unlocked
  (`requireMovable`) and the deepest stays within `maxNestingDepth`; the selection keeps its
  offsets in the moved block (`remapping`). A peer's concurrent edit inside a moved block
  lands in the deleted original (pinned in `NativeBlockCommandsTests`). Duplicate inserts
  the clone after the subtree with every container id replaced in preorder
  (`Copy.replacingIDs`); delete removes the subtree (an emptied nested group too, never the
  document's last root block) and puts the caret at the next block's start, else the
  previous block's end; insert adds an empty paragraph with default props before the block
  or after its subtree. **Opaque content:** move, duplicate, indent and outdent are refused
  for any opaque block in the subtree; copy and delete need a proven lossless
  representation, `BlockNoteSubtreePayload.validate` over the raw `snapshot` (so a table
  of known nodes can be copied and deleted, an unknown node can be neither); inserting
  beside either is fine. `snapshot` now refuses an XmlText with attributes rather than drop
  them. **Payload** (`Core/Yjs/BlockNoteSubtreePayload.swift`, pasteboard type
  `dev.llun.schrift.blocknote-subtrees`): the copied containers as the Yjs v1 update of a
  scratch `YDoc` whose `document-store` holds one `blockGroup` of them (the same shape
  `BlockNoteYjs.encode` writes), lossless by construction. `decode` is a trust boundary:
  ≤ 2 MiB (`maxBytes`), ≤ 2,000 containers (`maxBlocks`, `.tooLarge`), container depth
  ≤ 16, no pending structs, one root group of containers each with a non-empty string `id`,
  exactly one content element in `contentNodes` and at most one non-empty group, only
  `inlineNodes` inside content, only XML types (`.malformed`). Before integrating anything it
  counts the decoded update's structs and delete ranges (≤ `maxStructs`, 100,000, `.tooLarge`),
  so 2 MiB of tiny structs cannot stall the main actor. Then `sanitized` strips what any app
  (or a Universal Clipboard peer) could plant: a link mark whose href `sanitizedLinkURL` would
  not write unchanged and an unknown mark key (outside `knownMarks`) carrying a URL are dropped
  (the text stays), embeds go, and a `urlProps` value (`url`, `previewUrl`, `src`, `href`) that is
  not empty or http(s) with a host refuses the payload. No provenance check (`changeCount`/HMAC):
  it would break pasting across launches. The engine decodes it in
  `prepareBlockCommand` (PR08a), mints a fresh id per container, checks the landing depth,
  and refuses an oversized payload with `DocumentEngineError.payloadTooLarge`. Pasted media is a
  placeholder like any other, so nothing is fetched.
  **HTML/Markdown paste parsers and slice-merge paste:** `BlockNoteHTMLParser` and
  `BlockNoteMarkdownPaste` parse untrusted HTML and Markdown into bounded, validated
  `BlockNoteSubtreePayload` blocks (headings clamped to 1–3, `https://` images only,
  unsupported markup dropped, prose line breaks split into separate blocks rather than
  writing `hardBreak` into prose, and Markdown-free plain text kept line-for-line as
  plain paragraphs). `.insertSubtrees(payload:replacing:)` applies a paste in one
  undoable transaction: in prose it deletes the selection, replaces an empty plain
  paragraph whole, merges leading/trailing textblocks into the surrounding blocks and
  splits around non-textblocks (keeping the end block when a non-textblock paste starts
  at offset 0); in a table cell it flattens to inline runs and `hardBreak`s; in a code
  block it inserts unmarked plain text; source editors, toggles, locked/opaque blocks,
  invalid nesting and oversized payloads are refused before arming. **Links render tappable only for
  `isOpenableLink`** (the classic writer's schemes: http(s) with a host, mailto, tel), so a
  collaborator's `javascript:` or deep link is plain text in the native view; the mark stays.
  The menu's Indent/Outdent go through `applyStructural` on the menu's target (keeping the
  selection), not Tab's caret rules, so they apply wherever the menu offers them. **Clipboard:**
  copy and cut write one pasteboard item (`writePasteboard`): the plain text, plus the
  payload when `NativeClipboard.wholeBlocks` finds whole sibling subtrees (from a block's
  text start to a block's text end, nothing shallower than the first block, later
  descendants of the last root only if folded); Copy block writes the subtree's payload and
  its visible plain text. Paste prefers media/files, then Schrift's own subtree or inline
  payloads, then same-origin document URL interlinking, then bounded HTML or Markdown-looking
  plain text pasted as blocks (falling back to plain text on empty or oversized HTML, or
  refusing when oversized without a plain-text fallback), and finally literal plain text;
  code blocks, source editors, and targets block paste refuses (toggles, locked-text blocks)
  stay on the plain-text path, while tables keep multi-cell selections and HTML tables in
  the table editor and flatten single-cell pastes. Paste and Match Style (beside Paste in the
  edit menu and via `⌘⇧V`) pastes bounded plain text from an explicit plain-text pasteboard
  type literally without converting HTML-only pasteboards (and fills a multi-cell selection
  with that plain text). Partial-block copies without inline objects stay plain
  text. Arbitrary single-subtree moves use `.moveBlock(NativeMoveDestination)`
  (`.before`/`.after`/`.firstChild(of:)`), `BlockNoteWriter.moveBlockAsFirstChild`,
  `NativeBlockReorder.dropTarget` (clamping depth, keeping tables, media and column
  groups at depth 0, and refusing folded toggles, locked/opaque blocks, own subtrees
  and no-ops), and `NativeInputCoordinator.moveBlock(_:to:)` (one undo step, selection
  following the moved block, within the document or one open column). `NativeBlockDragController`
  on `NativeTextView` drives the drag-to-reorder UI: a contextual `⋮⋮` drag handle beside the
  caret block (and pointer-hovered block on iPad, no permanent gutter, hidden for locked/opaque
  blocks and outside Editing mode) plus 0.4 s long-press on non-text cards (image, file, video,
  audio, pdf, divider, table, column group), a lifted preview card with nested-child count,
  horizontal slide snapping in list-indent steps with the shared 2 pt `brandFill` drop line
  (`NativeDropLayoutHelper`, shared with `NativeMediaDropController`), `CADisplayLink` edge
  auto-scroll (~56 pt), lift/selection/drop haptics, cancel without mutation, and a VoiceOver
  landing announcement. Tests: `NativeBlockCommandsTests`, `NativeBlockReorderTests`,
  `NativeBlockDragControllerTests`, `NativeClipboardTests`, `NativePasteAsBlocksTests` (round trip byte-identical but for ids,
  malformed/oversized payloads, web HTML, Markdown, slice merge, table cells, code blocks,
  source editors, Paste and Match Style + `⌘⇧V` + edit menu, single-step undo), `BlockNoteTreeOracleTests.testMovesMatchTheBlockNoteCaptures`
  (`BlockNoteMoveCaptures`, from the installed 0.56 `moveBlocksUp`/`moveBlocksDown` through
  the S3 harness in node/jsdom) and the host UI tests
  `testDuplicateFromTheBlockMenuSurvivesRelaunch` (`--native-tree`, whose host controls also
  read the first three blocks' text as `tree.texts`),
  `testDragHandleReordersParagraphBelowAnotherAndSurvivesRelaunch`, and
  `testDragHandleSlidesRightToNestParagraphUnderListItemAndSurvivesRelaunch` (`--native-drag`).

- **PR07b collaborative undo in the native editor.** `Native/NativeUndoManager` owns one
  `ReplicaHistory` (PR08a: the nonisolated Yjs side — the `YUndoManager`, its trim, the
  selection meta and `step`; `NativeUndoManager` keeps the UIKit side) and so one
  `YUndoManager` per typing session (since PR08b made by `DocumentReplicaSession` at
  `setWritable`, one shared history per replica session, `destroy()`ed and released when
  it closes; never persisted): scope the `document-store`
  fragment, `trackedOrigins` `[.localUser]` only, so a peer's update, a server fetch and the
  nil-origin format cleanup are never undoable. At most `maxDepth` (100) undo steps: an
  added step past it calls `trimUndoStack`, a nil-origin keep-only transaction the engine
  records as an empty patch (no revision, no freeze). **A step is a durable command:** the
  coordinator's `undo()`/`redo()` send one `NativeEditCommand` `.undo`/`.redo` (empty
  `blockID`) through `DocumentEngine.applyHistoryStep(_:step:persist:)`, which arms it like
  `applyStructural`, runs `YUndoManager.undo()/redo()` (origin `.undoManager`, so its patch is
  `.other` and unstamped), encodes the step's one transaction (the engine captures it in
  `record`; the engine never names `UndoManager`), journals it, then delivers. Refused before
  anything runs while composing, until a composition's rebuild is delivered, after a write
  failure or with a stale revision; the coordinator also refuses while marked text exists or
  the view is not editable (`canUndo`/`canRedo`). A native session has no live socket, so the
  journal's outbox is the one path an undo leaves by: saved by `NativeReplicaSaveScheduler`
  exactly once, like typing; the manager's replica and its nil-origin broadcast are untouched.
  **Grouping:** typing merges within `captureTimeout` (500 ms) while it continues from where
  typing left the caret (`typingCaret`; a tap or arrow first is a boundary); every
  `applyStructural` command (split, join, indent, outdent, moves, duplicate, delete, insert,
  paste, marks, props, block type, range), a composition commit and undo/redo call
  `stopCapturing()` before and after. **Selection:** each step stores
  `DocumentEngine.selectionBeforeCommand` (the relative selection when its first command was
  armed; a composition's is its start caret) in `meta`; a popped step restores it with
  `restoreSelection` before delivery, so the selection coordinator shows it (also called once
  after the step for a step with no visible patch). Relative positions follow `redone`, so a
  restored block's caret lands in its copy; one a peer deleted falls back like any restore.
  **System undo:** `NativeTextView.undoManager` is `NativeSystemUndoManager` (an
  `UndoManager` subclass whose `canUndo`/`canRedo`/`undo()`/`redo()` route to the
  coordinator; selector registrations dropped; a closure registration stays in `super`, at most one
  with `levelsOfUndo` 1, and never runs because `undo()`/`redo()` never call `super`), plus `undo:`/`redo:` responder actions enabled from
  `canUndo`/`canRedo`: Edit ▸ Undo/Redo, shake, ⌘Z/⇧⌘Z and the keyboard's undo all land
  here. A read-only view has none. Stack changes post `NSUndoManagerCheckpoint` for the
  keyboard's buttons. Tests: `NativeUndoTests` (typing/format/split/join/tree/block steps, a
  peer insert kept, remote never undoable, composition one step, journal before
  publication and one outbox entry, refusals, selection, bound, release with the session),
  `YUndoManagerTests.testTrimDropsTheOldestItemsAndReleasesTheirKeep`, and the host UI test
  `testHardwareUndoAndRedoAreDurableAfterRelaunch`.

- **PR08b `DocumentReplicaSession`, the ordered mailbox, optimistic typing plus barriers.**
  `actor DocumentReplicaSession` (`Native/DocumentReplicaSession.swift`) owns the
  native replica: `seed`/`restore` build it off main (restore replays checkpoint and
  journal into a fresh author), `inspect` is the read-only one-shot, `attach` returns
  the projection at revision R and the stream of everything after it in one turn.
  Main → session is one `ReplicaCommandMailbox` (`AsyncStream`, at most 256 queued, counted
  in `post`; a dropped message freezes authoring with the storage notice). `.detach` and
  `.close` always fit: a dropped close was never resumed, so the editor's close and the
  scope's next restore hung (CI's teardown hang in
  `testPendingTypingIntentsAndTheMailboxAreBounded`; `testACloseMeetingAFullMailboxStillClosesTheSession`). Every
  `ReplicaMessage` (command, select, composition begin/commit/cancel,
  `writeProvisional`, integrate, availability, copy payload, `setWritable`, drain,
  detach, close) is handled in one synchronous turn: **no await between the engine
  call, the journal append and the delivery yield.** The engine's surface there is a
  private `ReplicaPatchSink` that collects patches with each `.text`/`.props` block's
  settled projection (what `reprojectBlock` used to ask) and composition deferrals.
  Session → surface is `ReplicaDelivery` (revision, ordered events, the command's
  `ReplicaResult` `.applied/.refused/.stale/.invalidated/.failed/.composition`, the
  selection resolved for the surface's latest `seq`, mirrored `canUndo`/`canRedo`/
  frozen state, availability, clipboard payloads, drain markers, timings). The echo's
  `NativePatchStamp.surfaceID` names the surface whose command it is.
  **Owner decision (2026-11-10), option A:** same-block typing (`replace` in one
  block's text that `canPredict` accepts: the display-side half of
  `DocumentEngine.replaceText`'s guards) is shown at once
  (`NativeTextSurface.predict`) and posted, then journaled a few milliseconds later in
  order; its echo confirms it and repairs the slice if the journaled block differs.
  Every other command (split, join, ranges, marks, links, props, block type, indent,
  outdent, block actions, paste, undo/redo, composition commit/cancel, typing into a
  block the session once refused) is a **barrier**: shown when its result arrives;
  keys typed meanwhile are held as intents (`.insert`/`.deleteBackward`, from
  `NativeTextView`'s `typeKey`/`deleteKey` hooks, the delegate, UITextInput `replace`
  and a composing keyboard's direct character, also over a selection) and replayed; a
  selection the user makes meanwhile is settled by one rule at every barrier end (applied,
  refused, stale, failed): moved through what was shown since (a rollback a result caused
  included), it wins over wherever the
  barrier would put the selection (its caret, a kept or remapped range, a history step's),
  except in a block a delivery rewrote (a rebuild with the same text keeps its offsets), is captured again even when the view's
  range did not move (the session's copy may not survive the barrier's rebuild), and is then
  cleared; held keys replay after a composition's own answer; other actions return false.
  A barrier that meets a change its surface had not seen comes back `.stale` and is
  retried once from the current display, an action that reads the selection (split, join,
  indent, a slash item, paste, block actions) from the selection it was taken at (moved
  through what was shown since; when that cannot be found, nothing is retried and the input
  notice shows; a history step or a block's props ignore the caret)
  while the view shows, and the retry keeps, a selection the user made meanwhile: an
  action on a range (marks, a range replacement, unpredicted typing) is
  retried on that range moved through what was shown since (a non-empty range keeps an
  insertion at either end outside; a change inside it, or a rebuilt block, cancels the
  retry), and a cut's pending copy follows the retried delete. **Journal before publication,
  redefined:** publication is the canonical advance, save scheduling
  (`NativeReplicaSaveScheduler.schedule` only on a journaled `.applied` or commit) or a
  network send; a predicted keystroke on screen is provisional UI, like marked text. A
  failed or refused append rolls the display back to canonical, freezes authoring and
  turns the dropped text (with held keys, even when no prediction was dropped) into an
  `.orphaned` `ProvisionalRecovery` banner entry, and nothing waits to be copied. **The
  composition rule:** while marked text owns the view (`compositionOwnsView`: `isActive ||
  markedTextRange != nil`), the surface's whole `ReplicaDelivery`s queue up unapplied,
  results included, a local storage failure waits too, and nothing reads the view's
  offsets. Return during a composition always commits it. **The commit is a predicted
  command** (option A for IME too): it is shown at once as a prediction, posted with its
  epoch, and the composition stops owning the view there and then (no resolving window);
  while input is held (a barrier, an awaited invalidation, the prediction bound, or held
  keys) it is instead held as an ordinary key behind them and the session's composition
  cancelled; the queue then applies in order through `apply(_:)`
  (rebasing through the commit like any typed key), followed by the failure that waited,
  stale retries and held keys. Its rebuild is stamped as its echo and confirms or repairs
  it. The session maps the begin and the commit exactly like a predicted `.replace`
  (assoc 1; the commit moves the unseen ring through its replacement) and keeps that echo
  out of the ring unless the rebuild folded in changes the composition discarded, so the
  next begin (posted at the pre-commit base) rebases cleanly, and after a folded rebuild comes back orphaned as a
  recovery entry. A commit whose target is gone, or whose begin was never captured, ends
  the epoch like an unrebaseable key (the rollback keeps its text); one from an epoch
  already invalidated is answered orphaned. Cancel posts with nothing to show. While a
  barrier is in flight the commit is recorded as a shown change and its caret as the
  user's selection; the editor's own placements are never taken for the user's. A begin
  carries its epoch: one from an invalidated epoch is not captured. A cut while input is
  held is refused with the busy notice. A begin or cancel that could not be posted (a full
  mailbox) freezes authoring; the session's engine may stay composing, and the read-only
  display of that block stops following peers until the editor is reopened (accepted).
  An echo spelled as a whole-block rebuild settles from that
  snapshot; a predicted block a concurrent change showed as canonical keeps its
  predictions off screen until the invalidation, so later patches are not shifted by them. **Rebase:** the session keeps, per surface, the changes it had not seen
  (`unseen`, every patch but its own predicted echoes, `ringCapacity` 256); a predicted
  command is rebased through them with `TextDelta.rebase(range:assoc:through:blockID:)`
  and they through it (`rebase(_:throughReplacing:length:)`), exactly as the surface
  rebases its pending predictions through a concurrent patch, so both reach the same
  text (a concurrent insertion at the same point lands first). Anything not rebaseable
  (an overlap, a replaced, removed or reset block, a dropped ring entry) invalidates
  the surface's epoch: every command of the old epoch is dropped and the surface rolls
  back into a recovery entry. A selection is posted with an increasing `seq` and
  `baseRevision` (rebased the same way); a delivery's endpoints restore it only when
  they answer the latest `seq`, else the view's range follows the shown deltas. Bounds:
  32 pending predictions per surface (then keys are held), 64 held intents (then
  `native_editor_input_busy`, English only), mailbox 256, ring 256, deliveries 256 per
  surface (then a `.reset` resync, PR08c bullet below). **IME:** begin is posted (a target the session cannot
  capture comes back as an orphaned commit), the surface defers restyles from begin to
  the answer, commit and cancel are barriers, `provisional.json` is written through
  `.writeProvisional`. **Undo:** one `ReplicaHistory` per replica session, grouping
  decided on main (`ReplicaCommand.undoBefore/undoAfter`); `NativeUndoManager` only
  mirrors the stacks (a pending prediction is undoable already). **Menus:** availability
  is asked of the session per (block, structural revision) and cached; the menu offers
  nothing until the answer arrives (prefetched on selection changes); copy, cut and Copy
  block write the pasteboard when the session's payload arrives (a cut only once its
  delete was applied). `NativeEditorSession` is the main-actor view session (no graph):
  it consumes deliveries in order, `settle()` waits for a drain marker and anything held
  (and returns false if work is still in flight after its bound; the harness fails then),
  `close()` returns a `Task` that ends after every message posted before it was
  journaled (a late append's save is handed over then), and `NativeEditorOpen` awaits
  the previous close before an open and rechecks its generation and account after the
  off-main restore. Multi-window stays off; the registry, fan-out and bounded delivery
  are PR08c (bullet below); the live socket is PR09a (bullet below). Tests:
  `ReplicaSessionOrderingTests` (a latching disk gate on `ReplicaStore`'s interrupt hook,
  a mailbox gate on `Hooks.beforeMessage`, fixed client ids: ordering, rebase,
  invalidation, held keys, stale retry, append failure, publication, `onReplicaWork` off
  main plus the grep, bounds, IME, undo, close, timings), `NativeEditorActivationTests`'
  closed-during-restore case, and the host UI test
  `testRapidTypingUnderSlowDiskSurvivesRelaunch` (`--native-slow-disk`, 60 ms per
  append, with an in-flight readout). Native suites drive the session through
  `harness.settle()`/`run`/`engine`/`history`/`replicaDoc` (`NativeEditingTestCase`).

- **PR08c `NativeSessionRegistry`, fan-out and bounded delivery.**
  `NativeSessionRegistry` (`@MainActor`, `Features/Editor/Native/`) keeps one
  `DocumentReplicaSession` per `ReplicaScope`. `AuthenticatedHomeContainer` (`RootView.swift`)
  owns one and injects it into the environment; `EditorView` hands it to its
  `NativeEditorOpen` before opening (a host without one keeps the open's private
  registry). **Rules:** `open(store:scope:)` leases a new surface (`NativeEditorSession`,
  whose `release` the registry sets) on the scope's replica, restoring it off main when
  none is open; opens that arrive during a restore share it. Closing a leased surface
  posts `.detach` (its stream ends after everything posted before it); the replica
  closes after its last surface and its last pending open. A scope's next restore
  waits for its previous replica's close, so two replica sessions never journal into
  one scope. Each scope has one journal (`setWritable`, posted once; nil makes every
  surface read-only: the session refuses every write without a journal, an IME commit
  included, so nothing mutates unjournaled; a predicted key or commit in flight rolls back
  into a recovery entry, and each view stops taking input once a delivery says it is no
  longer writable) and one
  `NativeReplicaSaveScheduler` (`scheduler(for:make:)`; a capture failure freezes every
  surface of the scope; a leased surface only flushes it when it ends). `drainAll()`
  (scene `.background`, beside `EditorView`'s own flush) flushes every scheduler at
  once, then again after each surface's drain marker; `closeAll(where:)` (sign-out, and
  every `SessionStore.signInGeneration` change, when mounted native editors reopen
  anyway) closes matching surfaces and replicas, and an open still waiting returns nil
  (a replica closed before any attach starts its loop in `waitUntilClosed` to handle the close).
  **Fan-out:** every surface gets every change; a result goes only to the surface whose
  command it answers. Epochs, unseen rings and selection `seq`s are per surface. The one
  engine selection belongs to the surface that set it last (a select or a command) and
  only its deliveries carry it; other surfaces follow their shown deltas. The one engine
  composition belongs to the surface whose begin was captured: another surface's begin
  is not captured, its commit comes back invalidated (a recovery entry), its cancel
  touches nothing, and detaching the owner cancels the composition. **Bounded
  delivery:** each surface's stream holds `DocumentReplicaSession.deliveryBound` (256)
  plus one slot for a `.requested` marker; once 256 wait, the session keeps only what
  answers something (results, drain markers, payloads, availability:
  `ReplicaDelivery.withoutPatches`) until the surface asks with `.resync`, then sends
  those followed by one delivery whose `.reset` patch is the canonical projection, under
  a new epoch (`Resync.reset(epoch:)`). Deliveries queued behind marked text count too:
  256 there and the coordinator asks itself. **The resync rule, in one sentence:** from
  the ask until its reset is applied, the surface applies nothing, drops the patches of
  what arrives, holds every key (a commit included), and then applies the answers, the
  reset and the held keys in that order, so every key posted before the ask is answered
  before the reset and none is lost (a prediction still unanswered at the reset becomes
  a recovery entry). Multi-window stays off (no new scene UI); in one window at most one
  editor of a document is visible, so fan-out mostly covers a push that opens the same
  document before the previous editor closed. Tests: `NativeSessionRegistryTests` (shared
  replica and fan-out, racing opens, refcounted close, a reopen waiting for the previous
  close under a slow disk, per-surface epochs, one composition, `drainAll` with the
  shared scheduler, `closeAll(where:)` with an open in flight, sign-out during a pending
  append then reopen, the stream bound and the marked-text bound).

- **PR09a `NativeCollaborationBinding`, native live content over the same replica.**
  One binding per `ReplicaScope`, kept by `NativeSessionRegistry` beside the scope's journal
  and scheduler (`liveBinding(for:)`) and stopped when the replica closes. **The gate, in one
  sentence:** a native document goes live only when the native switch, the Live
  collaboration preference, a Docs 6 server advertising its collaboration socket
  (`ServerConfig.supportsNativeLiveCollaboration`, same org as the scope) and the document's
  `abilities.update` all hold, on a session that types (`nativeLiveCollaborationEligible`;
  `NativeEditorOpen.startLive` after the open's server-state integration or seed). It never
  reads `ServerConfig.yWebSocketLiveCollaborationEnabled` (A5's switch for the current
  editor), and a reader never opens a socket. **The ability is the server's:** the
  navigation row can be stale (an account switch reuses the screen, a cached row predates a
  permission change), so an online open asks `documents/{id}/` (`serverSaysReader`). Only an
  explicit `update: false` answer fails closed: the seeded route asks beside the state fetch
  (inside its deadline) and stays read-only; the owned route types from the row at once
  (offline-first) and, on that answer, its integration calls `setWritable(nil)` for the
  scope before any socket (a key typed meanwhile becomes a recovery entry). A failed request
  (offline, a 5xx, a timeout, a captive portal) keeps the row's ability, and the server still
  refuses a real reader's save; a row that says reader is never asked.
  `DocumentCollaborationManager.nativeTransport` only dials (origin-pinned URL, the config's
  framing: y-websocket for Docs 6, Hocuspocus before; nil while suspended or working
  offline) and tracks nothing; the binding owns a plain `DocumentCollaborationSession`
  (awareness since PR10a, bullet below), told a step2 from an update (`onSync`). The binding reads the
  replica's state vector before it dials (a full mailbox answers nil: nothing is dialed,
  never an empty-vector handshake), and dials and sends content only while `isCurrent`
  holds (the open, and the remembered signed-in user owning the scope, which a cookie
  handover clears). **Inbound:** every step2/update goes to the replica as `.integrate`
  (journaled as remote before any surface shows it, never in the outbox); a duplicate or
  empty frame is not journaled (`YUpdate.addsNothing(to:)`), and after 64 remote entries the
  session compacts from its live state, so a document that is only read stays small. At
  most `inboundBound` (64) frames wait in the mailbox, so a burst never takes the slots a
  keystroke needs; past it the frame is skipped. `integrate` refuses an update whose run
  starts past the store's clock, carries a skip, or names an origin, parent or deletion
  neither the store nor the update holds (`YUpdate.missesDependencies(in:)`), untouched
  (`NativeLiveError.missingDependencies`). A skipped frame, a dropped post or an update
  refused after the socket's step2 makes the binding **redial** once the in-flight frames are
  answered (a fresh handshake's step2 is the server's whole diff, whether or not the server
  answers a later SyncStep1), at most `redialLimit` (3) times in a row (a socket whose step2
  integrates starts the count again; a redial ignores answers still due from the old
  socket); a refused step2
  stops live (every handshake would repeat it). **A remote frame never freezes authoring:** an
  update that fails inside integration (after the checks) may have half-mutated the graph,
  so the session rebuilds doc, engine and history from the journal, which never held it,
  and every surface gets a `.reset` under a new epoch (keys in flight become recovery
  entries; undo starts over). Only a failed append (ours) freezes. Any integrate failure
  but a gap stops the binding; HTTP keeps saving. Decoding refuses a delete range whose end
  overflows `UInt` (`YWireError.clockOutOfRange`), never a trap. **Outbound, journal before
  publication:** the scope's journal closure (`installTyping`) appends, then calls
  `binding.outbox.publish`; a peer's SyncStep1 is answered by the replica in mailbox order
  (`.liveSync`) into the same `Outbox` stream, so frames leave in journal order, once, and at
  most one such answer waits in the mailbox (a later vector supersedes it). `.liveSync`
  answers nothing for a reader (`setWritable(nil)`) or a frozen replica (its graph may hold
  an unjournaled mutation), and a session built read-only sends no step2 or update at all.
  The HTTP save path is unchanged and still owns acknowledgment: the server takes the same
  update from both idempotently, and the handshake offers unsent outbox edits through the
  step2. Remote format cleanup deletions stay unjournaled and unpublished (every replica,
  the server's included, derives them). Reconnect, background, permission changes and the
  Live switch mid-session are PR09b (bullet below). **Known limits:** after three recoveries
  in a row with no step2 between them, or `recoveryBudget` in one open, live stays off until
  the document is reopened; an offline open, or one whose abilities request fails, trusts
  the navigation row's ability; the outbox is unbounded
  while a socket's send stalls (it grows only with local typing); a dial that races the
  cookie write itself, before the handover clears the account, is caught only at the next
  send.
  Tests: `NativeLiveSyncTests` (a fake y-websocket relay with its own replica: two and three
  clients, a web peer's format, duplicate and out-of-order frames recovered by a redial from
  a server that ignores a later SyncStep1, a frame overtaking the first step2, the inbound
  bound, a failed append publishing nothing, offline edits offered in the handshake, a
  read-only replica sending nothing, the dependency check, and the hostile frames: an
  overflowing delete range, a frame failing mid-integration, duplicates and compaction, a
  SyncStep1 burst, a refused step2, an open that stopped being current, a full mailbox at
  dial), `NativeEditorActivationTests`' gate matrix and stale-row check, `YWebSocketTests`'
  native transport, `DocumentCollaborationSessionTests`' reader sends and
  `LiveCollaborationAvailabilityTests`.

- **PR09b Reconnect, background and mid-session changes.** One small state machine in
  `NativeCollaborationBinding`, no new queue. **A drop** (`CollaborationDisconnect.transient`,
  reported by the session's `onDisconnect`) dials again after `Backoff.delay(attempt)`:
  1 s doubled per attempt up to 30 s; the attempts count again once a socket stayed up for
  `stableAfter` (30 s, measured from its step2), on foreground and when the path returns, so
  a server that accepts the handshake and then closes is retried at most every 30 s. A dial
  the manager refuses (suspended, working offline) backs off too; one the open refuses (not
  `isCurrent`, as during a cookie handover) waits for the next resume. **Background:**
  `DocumentCollaborationManager` keeps weak `CollaborationLifecycleObserver`s
  (`addLifecycleObserver`, registered by `startLive`); `suspend` closes every native socket
  and nothing dials, `resume` and `reconnect` (the path's return) replace the socket (one that
  looks live may be dead after a path change) and dial at once from a fresh backoff. Edits
  typed meanwhile are journaled and offered by the next handshake's step2,
  deletion-only ones included. **Access is asked again after every gap:** a drop, a 1000
  close (the server's permission reset, also how a server rejects a writer), background and
  the path's return set `needsAbilityCheck`, and the next dial asks `documents/{id}/`
  (`Dialer.isReader`) inside the dial itself, so no suspend, resume or close can drop the
  answer (one GET per redial, paced by the backoff). A reader answer
  runs `NativeEditorOpen.becomeReader`, the first production caller of
  `NativeSessionRegistry.setWritable(nil)` (every surface of the scope stops writing; a key
  typed meanwhile becomes a recovery entry; what is journaled stays for HTTP) and
  `disconnect`s live; any other answer, a failed request included, dials. `startLive`
  always hands the binding its dialer, so a same-document push (a second editor opening
  before the first closes) takes over `isCurrent` and live never sticks on a closed
  surface's. A state vector the full mailbox could not read backs off and is tried again.
  **The Live preference** is followed while open (`EditorView`'s
  `@AppStorage(LiveCollaborationPreference.key)` → `NativeEditorOpen.liveSettingChanged`):
  off `disconnect`s (no socket, nothing dials, typing and HTTP saving unchanged), on runs the
  reconnect refresh, which rechecks the whole gate. **Budget:** refused-frame redials also
  back off and stop live past `redialLimit` (3) in a row or `recoveryBudget` (10) in one open,
  so a peer that keeps sending refused updates cannot drive reconnects forever. **401:** a
  socket refused for an expired session drops like any other and backs off; the re-login
  sheet comes from the REST 401s (the 1000-close ability check, saves), a cookie handover
  stops dials through `isCurrent`, and the sign-in change reopens the route with a fresh
  binding, whose handshake delivers what was typed meanwhile. Nothing here acknowledges the
  outbox: HTTP still does, and a server that already applied an update (live, or an HTTP save
  whose answer was lost) takes it again idempotently. **Known limits:** a downgraded reader
  stops receiving live updates until it reopens (a reader open is PR01's snapshot view); the
  socket's own HTTP 401 is not read, so the sheet waits for a REST request; a socket refused
  for good backs off forever at the 30 s cap while the document stays open. Tests:
  `NativeLiveSyncTests` (a drop with typing meanwhile, background with a deletion-only edit,
  cold relaunch, an edit applied but unacknowledged, a 1000 close as writer then reader,
  dials held during re-authentication, the per-open budget) and `NativeEditorActivationTests`
  (a permission reset to reader through `setWritable(nil)`, Live off and on while open).

- **PR10a Awareness and relative cursors.** Awareness rides the binding's one socket: each
  `NativeCollaborationBinding` owns a `NativeAwarenessController` (`@MainActor`), its
  session announces `LocalAwarenessState` (read from `DocumentCollaborationManager
  .localAwarenessState` **at each dial**, never snapshotted at open; nil joins as an
  observer) and hands every decoded batch to it (`onAwareness`, which replaces the session's
  own unbounded `peers` fold); a socket that ends (drop, background, Live off, stop) clears
  every peer. A `signInGeneration` change calls `forgetLocalAwareness` (RootView), which also
  drops a `refreshLocalAwareness` answer still in flight for the previous account. Every
  awareness frame (announce, renewal, query reply, cursor) checks the binding's `isCurrent`,
  like content.
  **Inbound is untrusted:** a state over `maxStateBytes` (8 KiB) is ignored; y-protocols'
  clock rule (only a higher clock, or `null` at the same clock; an equal clock does not
  renew); `null` or an unparseable user removes the peer; a malformed `cursor` hides only the
  cursor (`AwarenessCursor.parse`); at most `maxPeers` (64; an unknown id at the cap, or a
  `null` for an unknown id, is refused before any JSON is parsed); a peer not renewed for 30 s
  expires (`sweep`). Peer colors come from the name (`avatarColorHex`), never the peer's
  string. **Resolution** is a mailbox message (`.resolveCursors`, at most one in flight, asked
  again at once after a peer change and at most every 100 ms after delivered patches, since
  each resolve walks the positions' left siblings) answered by `DocumentEngine.peerPlace`: a
  root `tname` that is not already in `doc.share` is never resolved (stricter than "existing
  or schema-owned": a missing `document-store` has nothing to point into), a throw or a
  missing id is nil (never `nativeWriteFailed`), a deleted type is nil, a position in a
  block's own `XmlText` (or between its content element's children) is `.text`, anything
  else inside an indexed block (inline nodes, table cell, column, leaf) is `.block(id)`.
  Nothing writes the replica; awareness is never journaled, persisted or undone. A peer
  whose cursor cannot resolve stays in `peers`. **Painting:** `NativeCursorOverlay`
  (a non-interactive subview of `NativeTextView`, laid out after `layoutControls` in every
  layout pass, so scroll, rotation, folding and edits re-place it) draws only what lies in
  TextKit's viewport: a caret with the name and the selection's visible part, or, for a
  folded block (badge on the nearest shown ancestor), an opaque/preview block or `.block`,
  a badge on the owner until it is opened. Per pass it reads `hiddenRanges` once and tints at
  most `maxHighlights` (16) selections; a peer's name is one truncated, clipped caption line
  at most `maxLabelWidth` (160 pt) wide. The overlay uses the last resolution even when
  the display moved on (a predicted keystroke) and clamps; it never forces layout outside
  the viewport. **Outbound:** after every message the replica reports the engine's
  selection as its captured relative positions (`awarenessCursor`, direction kept) to the
  `.watchCursor` sink when it changed; a replica without a journal reports nil, and a
  session built for a reader (`canUpdate` false) has no local state, so readers publish
  nothing (they open no socket anyway). The controller publishes at most every 100 ms (the
  latest wins) through `DocumentCollaborationSession.updateLocalCursor`, which sends a frame
  with a higher clock once announced and carries the cursor in every renewal and
  query-awareness reply. `NativeEditorView` shows `PresenceBar` from `awareness.peers`
  (hidden offline). **Known limits:** a cursor is published while the view keeps a selection
  even after it resigned first responder; a resolution can lag one delivery behind the
  display (a peer caret in a block being typed into shifts by the predicted characters until
  the echo); an overlong selection highlight across folded content is not drawn (the caret
  is); peers in a document whose replica freezes keep their last places. Navigation is
  PR10b (bullet below). Tests:
  `NativeAwarenessTests` (direction and affinity through edits, malformed/oversized payloads
  and replica fingerprints, unknown root names, deletion with two peers, stale clocks,
  expiry and disconnect, the peer bound, viewport-only painting across scroll and width,
  folded/math/image badges, throttled directed publication, no reader publication, the
  binding's single socket; the PR #276 review fixes: no session peer table under an owner,
  identity read per dial, a stale identity answer dropped, frames stop when not current, the
  highlight bound, the name pill bound, the resolve cadence) and the host UI test
  `testPeerCursorsPaintVisibleGeometryAndBadgeFoldedContent` (`--native-peer`).

- **PR10b Native outline, find and continue reading.** `NativeDocumentNavigation` (one per
  `NativeEditorSession`, `session.navigation`) offers the native blocks to the classic pure
  rules (`buildOutline`, `findMatchingBlockIDs`, `ReadingPositionSession`/`Store`) and the
  classic `DocumentOutlineSheet` (through `DocumentOutlinePresentation`: a toolbar button
  `nativeEditor.outline` and Command-F) as `EditorBlock`s with an id stable for the open:
  headings carry their literal text backslash-escaped (the classic rules read markdown, so
  `**` stays text), everything else is `.unknown` (verbatim). The entries come from the replica
  session (`.navigation`, a projection stamped with the engine index's generation) or, for
  the one-shot reader, its fixed surface; they are refreshed when the sheet opens and, **only
  while it is presented** (`isOutlinePresented`), at most every 500 ms after delivered patches:
  with the sheet closed nothing is projected for navigation while anyone types (the "a
  keystroke projects no block" rule). **A jump is generation-safe:** the entry's
  `NativeBlockHandle` is checked on the replica (`.locate`: same index generation, same
  container item, not deleted), so a block re-created since it was read (a move, a rebuilt
  replica) does not jump until the next refresh; it then `reveal`s the toggles above its
  target (view state) and scrolls with `NativeTextView.scroll(toBlock:surface:)`, which
  relocates TextKit's viewport rather than laying out the document. A jump never writes the
  replica or moves the selection. Closing the sheet with a caret in an early paragraph does not
  scroll the jump back to the caret (UIKit hands focus back without a selection change);
  `testAJumpSurvivesClosingTheSheetWithACaretAbove` pins that, so nothing resigns focus. **Continue reading** is the classic session keyed by the
  route's `documentID` (`NativeEditorView.documentID`, from `EditorView`): restored once after
  the first refresh when the view has a size (every block counts as laid out; one in a fold is
  unfolded), **never while the text view is first responder** (a reader who tapped to type
  before the first reply, or before the view had a size, keeps their place), persisted from the
  top visible fragment's block on disappear and when the scene leaves `.active` (built from
  `surface.blocks` at that moment, not the outline's copy), Back to top (`nativeEditor.backToTop`) over the text, dismissed by a user
  scroll (`NativeTextView.onLayout`). The fingerprint is of the native text, so a position
  saved by the classic editor (markdown text) is not found by the native one.
  **VoiceOver over collaborators:** carets read "name, cursor" or "name, selection", badges
  "name, collaborator in folded content" (or "name, cursor" on a preview), and the overlay
  groups them (`shouldGroupAccessibilityChildren`); the overlay itself is never an element, so
  it does not cover the text. **Known limits:** a heading moved while the sheet is open needs
  the sheet to refresh (reopen) before it jumps; the outline is at most 500 ms behind typing;
  find matches block text only (a preview's name or caption is not searched; PR12c reads inside
  familiar column groups); restore needs one
  round trip to the replica after open; the overlay's elements still sit in the text view's
  element order (grouped, not removed). Tests: `NativeNavigationTests` (literal headings and
  find, a heading jump that changes no content, journal or selection, a find jump into a fold,
  a stale handle, the outline following edits, restore at 390 and 1024 pt with Back to top,
  leaving at the top, collaborator labels and grouping; the PR #277 fixes: no reprojection with
  the sheet closed, persist from the surface, no restore while typing, a pending restore dropped
  once typing starts) and the host UI tests `testOutlineFindsInTheNativeEditorWithoutChangingText`
  and `testAJumpSurvivesClosingTheSheetWithACaretAbove` (`--native-readout`: the top block,
  polled on the main actor; a `TimelineView` closure can run off main and trapped there).

- **PR11a Native tables: the grid, preservation and cell text.** The staging plan (11a here; 11b
  structure commands and concurrency; 11c rectangular selection, clipboard, VoiceOver grid and
  scale) lives outside the repo. **The grid** (`Core/Yjs/TableGridModel.swift`, `TableGrid.read`)
  is BlockNote 0.56's `table → tableRow → tableCell|tableHeader → tableParagraph+`: cell
  attributes as stored (unknown keys kept), `colwidth` (one entry per spanned column), the slot
  grid prosemirror-tables' `TableMap` makes (first free slot, `colspan × rowspan`), Tab order
  (cells in row order) and the cell below (`nextCell(…, "vert", 1)`). **Familiar or not:** only the
  four node kinds, readable attributes, a rectangular grid without overlap or a span past the edge,
  paragraphs of marked text (readable links) or a `hardBreak`, and at most `maxCells` (1,000) cells
  is familiar. Anything else (a mention or inline math in a cell, the shapes `fixTables` rewrites
  on the web) is unfamiliar: the native projection keeps it opaque (`table: <reason>`), the
  document has no shadow (read-only), `openTable` refuses it and move/duplicate refuse it, so its
  bytes stay as authored; the viewer still shows its readable text. **The document types:** under
  `nativeMarks` a familiar table is `.modeled` (the classic projection keeps it opaque, so classic
  callers and golden bytes are unchanged) and `markdownShadow` spells a root table without
  children with `NativeExportMarkdown.table`, a port of 0.56's `htmlToMarkdown.serializeTable`:
  covered slots empty, each cell `serializeInlineContent` + JS `trim()` + `|` → `\|`, columns
  padded to `max(10, longest)` UTF-16 units, a header line only when BlockNote's JSON has header
  rows or columns (else an empty one; PR11b). A cell is spelled from BlockNote's reading of it
  (`NativeExportMarkdown.blockNoteRuns`, PR11b): equal-styled paragraphs join with "\n", others
  concatenate, a hard break is "\n" on the item before it, and marks close around each break. A
  nested table has no shadow. A familiar table is moved and
  duplicated like any modeled block (the writer's snapshot copies every cell attribute).
  **Cell text is the document's own machinery.** `DocumentEngine.openTable/closeTable` index an
  open table's paragraphs in `BlockIndex` under **cell paragraph ids**
  (`TableGrid.paragraphID`: `<tableID>\u{1}<client>.<clock>` of the paragraph item; never a
  BlockNote id) as root-level text entries outside `order`; `blockID(for:)` resolves a change in
  one to it. `replaceText`, composition, selection, relative positions (an empty paragraph anchors
  on its element) and undo address them like any block (`BlockNoteWriter.tableParagraphTarget`);
  `.marks` within one paragraph is `prepareCellMarks`; every structural command refuses them
  (`structuralTarget` knows no `tableParagraph` schema), and a newline is never typed into one.
  PatchBuilder gives an open paragraph's text the `.text` fast path and its element changes a
  `.replaceBlock`; any other change inside an open table (rows, cells, spans, paragraphs) is the
  table's `.replaceBlock` plus a diff of its paragraph list (`PatchBuilder.diff`: removes, then
  inserts anchored after the previous kept paragraph); a tree change or rebuild re-reads every open
  table. Snapshots are plain root paragraphs (`node: "paragraph"`, no props) whose runs read a
  `hardBreak` as "\n"; any "\n" in a block's runs is displayed as U+2028 (one TextKit paragraph, as
  code lines were), and a prose block holding one is never predicted (shown, not typed into).
  **Surfaces have a scope** (`DocumentReplicaSession.attach(surfaceID:table:)`): a document
  surface never sees a cell paragraph id; a table surface sees only its table's paragraphs and the
  table's own changes (which `NativeTextSurface` ignores and the editor reads as a structure
  signal), and a `.reset` re-expressed as its table's paragraphs. Epochs, unseen rings, selection
  `seq`, prediction and the composition rule are per surface, unchanged. While a table is open the
  document's preview is not re-rendered per keystroke; closing the last table surface sends the
  document surfaces one `.replaceBlock(table)`. A rebuilt replica (remote fault) reopens every open
  table. **The editor** (`TableEditorViewController`, presented full screen by `NativeEditorView`
  from a tap or VoiceOver activation of the table card, `NativeBlockControls.onOpenTable`) lays the
  grid out from `colwidth` (else 120 pt, BlockNote's `EMPTY_CELL_WIDTH`), spans, header cells (bold,
  tinted), BlockNote cell colours and alignment, rows as tall as their tallest cell, and puts the
  **table surface's own `NativeTextView`** (`NativeEditorSession.openTable`, leased by detaching,
  no recovery entries, typing while the document types) over the active cell, never inside it.
  That surface holds every paragraph of the table; `NativeInputCoordinator.showCell` focuses one
  cell (`NativeTextSurface.setFocus`: every other paragraph is left out of layout exactly like
  folded content, so the folded-content rule refuses a range or mark command reaching another
  cell) and selects its text as `goToNextCell` does (a caret at the end of a multi-paragraph
  cell). Moving is view state: the text view stays first responder and held keys keep flowing.
  Keys (`tableMove`): Tab / Shift-Tab next / previous cell (nothing at either end, no new row),
  Return the cell below (nothing on the last row), Backspace at a paragraph start nothing, Escape
  (`UIKeyCommand.inputEscape`) and Done close the editor and put the caret at the start of the block
  after the table. A structure change re-reads the grid (`.tableGrid` message) and keeps the
  active cell by item, else the first. An unfamiliar table, a reader (`inspect` keeps its
  `TableGrid.tables`) or a read-only document gets the same grid with no text view.
  **Review fixes (PR #278).** The slots a table's spans claim are bounded (at most `maxCells`)
  before any is allocated (`large table`), so a crafted span layout cannot exhaust memory on
  open. A structure change re-shows the active cell in place (`activate(_:selecting: false)`)
  and keeps the caret; only a move between cells selects the cell's text. **A table stays a
  childless root block and a merged cell unstyled**, because only those keep the shadow (the
  open-time `canType` is not re-checked after edits): Tab under a table or of a table, a move
  that would put a table in a sibling's children, and a paste that lands a table below the root
  or with children are refused before arming (PR11b lifted the merged-cell mark refusal: the
  shadow spells styled merged cells). A block id holding
  U+0001 makes the index non-canonical (input refused, every patch a `.reset`, no open table
  re-indexed), and paragraph-ness is decided by membership in the open table
  (`BlockIndex.isTableParagraph`), never by the spelling; the session's filter may read the
  spelling because only canonical indices deliver per-block changes. A cell is trimmed with JS
  `trim()`'s set (U+FEFF trimmed, U+0085 kept). Done before the table surface attached closes
  it at once.
  **Known limits:** on CI's iOS 26.5 simulator XCUITest's synthesized Shift-Tab never reached the
  cell (run 43116995469; the host UI test therefore moves with Tab and a tap, and Shift-Tab is
  unit-tested only), so Shift-Tab on an iOS 26 hardware keyboard is unconfirmed until a device
  check; (PR11c lifted: the active cell's alignment, peer cursors in the table editor, a mixed
  text-and-colour transaction, IME recovery for a cell); a table
  over 1,000 cells (PR11c: viewable, not editable), a nested
  table and the 72ebe1bb test document (math, columns, media and a diagram have no shadow yet) stay
  read-only; pasting another unshadowable block (math, media, an unfamiliar table) still stops
  saves at the next capture (the pre-existing PR06d class: the capture failure freezes authoring
  with the storage notice). Tests: `BlockNoteTableOracleTests` (`BlockNoteTableCaptures`, from the installed 0.56
  through the S3 harness: every fixture familiar with its export as the shadow, the grid's spans,
  widths and colours, typing in a cell, into an empty cell and bold over part of one equal to the
  web's XML, the hard break, structural refusals, the real `.review/` table when present),
  `TableGridTests` (every unfamiliar shape, the bound, a mention kept readable) and
  `TableEditorTests` (predicted and journaled cell typing never shown to the document, the preview
  on close, marks and a pending mark, an IME commit, Tab/Shift-Tab/Return/Escape writing nothing,
  layout, undo and redo, a peer edit rebased in the active cell, a peer deleting the active row,
  relaunch, a hard-break cell, an unfamiliar table preserved and read-only, the reader's viewer,
  the card, duplicating a table; the review fixes: the caret kept across a peer's structure
  change, no marks in a merged cell, no command nesting a table, a block id spelling a cell
  paragraph refused) and the host UI test `testTypingInATableCellSurvivesRelaunch`
  (`--native-open --native-table`: a web-shaped 2 × 2 table).

- **PR11b Table structure, hard breaks and concurrency.** `Core/Yjs/BlockNoteTableCommands.swift`:
  `BlockNoteTableCommand` (slot coordinates) is one `NativeEditCommand.Kind.table` on the table
  block through `applyStructural`, prepared whole before arming (`BlockNoteWriter.prepareTable`,
  so `canApplyStructural` is the menus' availability) and written in one transaction. Each is a
  port of what BlockNote 0.56's menus run on the web: prosemirror-tables 1.8.5's `addRow`
  (`addRowBefore/After` on the row of the cell at (row, 0): a cell spanning across grows, every
  other slot a new cell of the reference row's type), `addColumn`, `removeRow` (a cell spanning
  down moves, as a copy, to the next row) and `removeColumn` (refused when they would empty the
  table), `mergeCells` on the two cells' rectangle (refused when a cell crosses its edge; the
  others' non-empty paragraphs move in, the spans and `colwidth` grow), `splitCell` (new cells of
  its type with its attributes and their column's width), `columnResizing`'s `updateColumnWidth`,
  and the `updateBlock` round trip of the header, colour and alignment menus (`nodeToBlock` →
  `tableContentToNodes`: header rows and columns counted from the cells, each cell's attributes
  exactly its props and its column's width, its content one paragraph of BlockNote's reading, a
  merged cell flattened as the web flattens it). After every command a row left empty takes a cell
  (prosemirror's content fitting) and `fixTables` runs (`TableModel.fixTable`: overlong spans,
  collisions, missing slots, column-width agreement), as the web's appendTransaction does. The
  model (`TableModel`) keeps every row, cell and paragraph item it can, so a peer's concurrent text
  in an untouched paragraph lands (a round trip keeps a paragraph whose shape does not change);
  content a deleted or retyped cell held is copied before anything is deleted. **Hard breaks:**
  `.lineBreak(offset:)` (Shift-Return in a cell, `NativeTextView`'s key command) is
  `BlockNoteWriter.insertHardBreak`: the text split around one `hardBreak` element, as
  y-prosemirror writes `a<hardBreak/>b`. A cell paragraph of several parts takes typing (barriers:
  never predicted, its patches are `.replaceBlock`), marks and IME; `RelativeEditorPosition`
  anchors in the text part holding the offset, else between parts, and resolves a position in a
  text that a break split since. **The menus:** the table editor shows Row (insert above/below,
  delete, header row, row colour), Column (insert left/right, delete, header column, wider/narrower
  by 40 pt from BlockNote's 35 pt floor, column colour), Cell (merge right, merge down, split,
  text and background colour, alignment) and Format (bold, italic, underline, strikethrough,
  inline code), each built when it opens for the active cell (`UIDeferredMenuElement`), unavailable
  items disabled; a command is `NativeInputCoordinator.applyTable`, a barrier keeping the caret's
  paragraph offsets, and the grid is re-read when the table's own change arrives (the active cell
  kept by item, its caret not re-selected). **Web widths** may be floats (a drag), `0` or
  `undefined` (the round trip's spanned columns): all familiar. **Concurrency:** a peer's
  structure change merges in Yjs; one that leaves the grid ragged (a row and a column added at
  once) is unfamiliar, read-only and addresses no cell until a web client's `fixTables` writes the
  repair, and meanwhile the shadow spells the repaired grid (`TableModel.fixedGrid`), so a save
  does not fail. **Review fixes (PR #279).** `fixTable` builds every fix from the cell as its
  pass found it (prosemirror's `table.nodeAt(prob.pos)`, the last write wins), so several
  collisions on one spanning cell no longer pile up into a span below 1; a span below 1 is
  refused by `map()` and `fixTable` (no repaired grid, so no shadow, never a trap). Pinned against
  prosemirror's own `fixTables` (`BlockNoteTableFixCaptures`: piled collisions, a collision, an
  overlong rowspan, missing cells, disagreeing widths). `prepareTable` refuses a command whose
  result exceeds `TableGrid.maxCells` cells or slots (the menu item shows disabled), so no native
  add makes a table unfamiliar. The table editor hides its menus while the grid is uneven, and the
  Column menu never indexes past the widths. **A native repair is not written** (owner question
  in the review): the web writes `fixTables`' repair only when someone next edits the document
  (its ProseMirror view holds the repaired table meanwhile), so a native client that repaired on
  receipt would repair alongside a web client in the common web-and-native case, and two
  repairs of missing cells insert twice (Yjs keeps both inserts), which no rule makes idempotent.
  **Known limits:** an uneven grid stays read-only (with a shadow of the repaired grid, so saves
  continue) until a web client edits the document: after any offline window with structure
  changes on two devices, overlapping merges, or deleting a row while a merge-down lands, two
  native devices with no web client leave it read-only; Shift-Return over a selection, or while another barrier is in
  flight, does nothing; the row and column colour menus colour the cells starting in that row or
  column (the web's handle may include a cell spanning into it); the repaired-grid shadow is not
  pinned against the server (rectangular selection came in PR11c).
  Tests: `BlockNoteTableCommandOracleTests` (`BlockNoteTableOperationCaptures`: 84 web operations
  on four tables, the 76 the web applies equal to its XML with the shadow equal to its Markdown,
  the 8 it refuses refused natively; styled merges and hard breaks), `TableEditorTests` (the menus
  durably through a relaunch, undo and redo of a column with a peer's edit kept, a colour change
  keeping a peer's concurrent typing, concurrent structure changes, merged-cell marks, a
  hard-break cell typed into, Shift-Return, IME after a break), `TableGridTests` (web widths) and
  the host UI test `testTheRowMenuInsertsARowThatSurvivesRelaunch`.

- **PR11c CellSelection, clipboard, VoiceOver, scale.** **Commands** (`BlockNoteTableCommands`):
  `.clear(from:to:)` is prosemirror-tables 1.8.5's `deleteCellSelection` (each cell of
  `cellsInRect` emptied to one paragraph, attributes kept; also cut's delete) and
  `.paste(cells:anchor:head:)` its `handlePaste`: `ensureRectangular`, then into a CellSelection
  `clipCells` (repeat or cut to its size, prosemirror's own `removeColSpan(attrs, colspan, n)`
  and `max(1, newHeight - rowspan)` arithmetic kept), else from the active cell; `insertCells`
  (`growTable` with the last row's/cell's kinds, `isolateHorizontal`/`isolateVertical` at the
  four edges, each row's target cells replaced), then `fixTables`. Growth is bounded
  (`maxCells` slots) before any cell is allocated. Merging a selection is the existing `.merge`
  on its corners. `TableModel.content(from:to:)` is `CellSelection.content()` (edge cells
  clipped, emptied when they start outside). **Clipboard** (`Core/Yjs/BlockNoteTableClipboard
  .swift`): a copy (`DocumentEngine.tableCopy`, mailbox `.tableCopy`, read in mailbox order)
  writes `public.html` as BlockNote's external HTML (every cell a `td`, props as `data-*`,
  `colwidth` only on spanning cells from the first row's widths, marks in schema rank through
  prosemirror's `DOMSerializer` rule, closed around a break, BlockNote's palette for colour
  spans), plain text as its Markdown (`NativeExportMarkdown.table`, every cell a `td`, so an
  empty header line), and a one-table `BlockNoteSubtreePayload` (a paste outside the editor
  inserts a table). Paste reads, like the web, the payload as BlockNote reads its own
  `blocknote/html` (nodes and spans kept, content flattened by `parseTableContent`, `colwidth`
  through `parseInt`, an unset width `NaN`), else `public.html` through BlockNote's parse
  (`tryParseHTMLToBlocks` + `blocksToFullHTML`: header rows/columns counted, widths from the
  first row, `data-*` props or a palette colour name in `style`), else (only into a
  CellSelection) plain text as one cell, a line break a hard break. **Untrusted:** `HTMLNode` is
  a bounded tolerant parser (2 MiB, 200,000 nodes, depth 256, raw-text elements skipped, implied
  end tags), anything but one table is not cells, spans and cells are bounded, a link
  `sanitizedLinkURL` would not write unchanged loses its mark. **Editor**
  (`TableEditorViewController`, `TableGridView`): the CellSelection is two slots (kept across a
  structure change where they still fit; a paste selects what it pasted; a merge activates the
  merged cell); a long press and drag (the grid's pan is cancelled), a pointer drag, Shift-click
  and Shift-arrows past the cell's edge (`shiftArrow`: `atEndOfCell` by offsets, caret-line
  geometry for up/down) select; plain arrows at the edge move (`arrow`: Left/Right to the
  neighbour in row order with the caret at its end/start, Up/Down `TableMap.nextCell`);
  Backspace/Delete clear, ⌘C/⌘X/⌘V and the Cell menu (Merge cells, Copy cells, Cut cells, Paste
  into cells, Clear cells, colours and alignment on every selected cell) act on it, Escape
  drops it first, typing drops it and types in the active cell, ⌘Return is Done. Keys reach the
  editor through `NativeInputCoordinator.tableKey` (`NativeTextView.pressesBegan` for arrows,
  `deleteBackward`, `insertText`, `copy`/`cut`/`paste`); the table surface shares the document's
  pasteboard. **Virtualised grid:** only the cells in the scroll view's bounds plus half a screen
  are realised (`TableCellView`, recycled); rows start at 44 pt and are measured (cached per
  text and width) as their cells are realised, a spanning cell growing its last row, the content
  offset kept when a row above grows; the active cell is measured with the text view's insets,
  not its layout. **VoiceOver:** `TableGridView` is a `UIAccessibilityContainerDataTable` with
  elements made on demand (row/column ranges with spans, header row/column cells as headers,
  `.selected`, a collaborator in the value), the active cell's element being the table surface's
  text view (`NativeTextView.tableCellRanges`); focusing an element scrolls to it. **Large
  tables:** the editing bound stays `TableGrid.maxCells` (1,000): measured in a debug simulator,
  the table surface lays out its hidden paragraphs on each key (~40 µs each: 999 cells ≈ 50 ms a
  key, 30,000 cells ≈ 24 s to open and 1.2 s a key), so a larger table is read whole for the
  viewer (`TableGrid.read(limit: maxViewerCells)`, 50,000, still unfamiliar "large table": no
  shadow, the document read-only); 10,000 × 3 opens in ~0.5 s with scroll steps p99 ~1.4 ms
  (debug simulator). **The 11a limits:** a table paragraph's snapshot carries its cell's
  `textAlignment` (`PatchBuilder.paragraphSnapshot`), and a cell's attribute change re-projects
  its paragraphs, so the active cell edits in its alignment; the table surface paints the
  document's awareness (`showAwareness`: a caret in the active cell) and the editor badges a
  collaborator's cell; a cell composition's recovery entries are handed to the document's
  composition (`NativeCompositionSession.forward`/`adopt`: written with its list, shown by it,
  restored with it); a peer's transaction typing in one cell and colouring another already
  re-read the grid on main (the 11a limit was stale; a test now pins it). **Known limits:** editing a table over 1,000 cells needs a table surface that
  holds only the active cell (a later PR); a paste whose rectangle cuts a rowspan cell at its top
  or bottom edge splits that cell as intended, where prosemirror-tables 1.8.5's
  `isolateHorizontal` inserts the split cell at a table-relative offset used as a document
  position (no `+ start`) and garbles the web's grid (pinned structurally, not by XML); typing over a CellSelection clears it and types into
  the active cell (the web replaces the first cell's content and empties the rest); plain text
  is not read as Markdown (the web pastes `**x**` bold and a Markdown table as cells), a CSS
  colour other than a palette name is not read (the web keeps any CSS string, which it does not
  show), HTML with anything beside one table pastes as text, uncommon named entities stay
  literal; a colour span outside the palette and link-inside-colour nesting in copied HTML are
  not pinned; the Row and Column menus act on the active cell, not the selection; a drag cannot
  start in the active cell (its text view takes the touch); a row grows when a taller cell
  scrolled in from the side is realised; a collaborator's selection in another cell is a badge;
  table key commands have no discoverability titles; Dynamic Type/RTL grid layout and mentions
  or inline math in cells are not done. Tests: `BlockNoteTableClipboardOracleTests`
  (`BlockNoteTableClipboardCaptures`, clip2.mjs: 11 copies' HTML and Markdown, 21 pastes —
  the web's HTML into a selection and at a caret, growing, tiling, ragged rows, spans clipped and
  isolated at each edge,
  headers, breaks, marks, entities, whitespace, `data-*` props, Schrift's own copy as the web's
  `blocknote/html`, plain text — and 6 clears, cuts and merges, each the web's XML with the
  shadow its Markdown; hostile HTML and payloads; a paste past the bound), `TableSelectionTests`
  (Shift-arrows and Backspace, typing over a selection, arrows across edges and ⌘Return, copy
  through the text view and the paste of it, cut, web HTML at a caret, plain text, merging a
  selection, a merge across a span disabled, a hostile paste, the data table),
  `TableScaleTests` (the fixture gate: 10,000 × 3 viewer realises < 150 cells, scrolls, a jump
  recycles, VoiceOver reaches row 9,999; 999 editable cells realise only the screen),
  `TableEditorTests` (alignment, a mixed transaction, a collaborator, a dropped cell
  composition) and the host UI test `testDraggingAcrossCellsSelectsThemAndTheCellMenuMergesThem`.

- **PR12a Native columns: the group, preservation and column editing.** The staging plan (12a
  here; 12b group/column structure, widths, boundary moves, concurrency and awareness; 12c
  side-by-side presentation, scale, VoiceOver, find/outline) lives outside the repo. **The group**
  (`Core/Yjs/ColumnGroupModel.swift`, `ColumnGroup.read`) is `@blocknote/xl-multi-column` 0.56's
  shape: a `columnList` **directly in a `blockGroup`** with its own `id`, holding `column`
  elements (attributes `id`, `width`, BlockNote's default 1) that hold `blockContainer`s
  **directly** (no `blockGroup`). **Familiar** = at least two columns (the schema's `min: 2`), each
  with a readable id, readable attributes and a width absent or positive, each holding at least
  one container with a readable non-empty id unique in the group, no group inside a column, no
  deeper than `NativeBlockProjection.maxDepth`, at most `maxColumns` (16) columns and `maxBlocks`
  (2,000) blocks, counted before any per-block allocation. Anything else (an empty column, a group
  of one: the shapes `fixLayoutBlocks` repairs on the web) is unfamiliar: opaque, preserved, never
  addressed. lib0 stores a width float32 holds exactly (1.5, 0.75) as **float32**, so
  `TableGrid.number` reads float32 too (a web table width such as 120.5 used to read as unset).
  **The index:** a `columnList` is a canonical atomic entry of its group (`BlockIndex.containers`,
  `isCanonical(group:)`; before, a document with columns was non-canonical: every transaction a
  `.reset`, all input refused), its own element, no text; a change inside a closed group resolves
  to it (`blockID(for:)`), so a peer's edit there is the group's `.replaceBlock` (its preview).
  `DocumentEngine.openColumns/closeColumns` index every block of every column (`openGroups`,
  `columnOrders`, `columnOf`; depth and parent relative to the column, top-level blocks depth 0
  with no parent) as entries outside `order`; a document id reused inside the group refuses the
  open. The engine's order rules (join, range, marks, moves, `requireMovable`, `movesTable`) use
  the block's own list (`BlockIndex.list(of:)`, `listPosition(of:)`, `sameList`), so a column's
  blocks never meet another column's or the document's: Backspace at a column's first block, a
  range or mark command across columns, a move past a column's edge and Shift-Tab at a column's
  top are refused before arming. A column keeps a block (delete of its only block refused, the
  existing `siblings.count > 1` rule). The group's own move and duplicate are refused
  (`requireMovable`: `isColumnGroup`), its delete and copy have no lossless payload
  (`BlockNoteSubtreePayload.validate` takes containers only), and nothing indents under it;
  inserting a block above or below it works. **Review fixes (PR #281):** Move up/down of a block
  whose neighbour is a group is refused (the web's `getMovePlacement`/`getInsertionPos` moves it
  into the group's first or last column: PR12b), two columns sharing an id make the group
  unfamiliar (`duplicate column id`), and the presenter (`NativeEditorView`) owns the
  `ColumnEditorModel` (made when the card is tapped; `ColumnEditorScreen` only loads it, once,
  and never closes it on disappear), so a screen `.task` that runs again (a table editor's cover
  dismissed over it) cannot attach every column a second time. On the iOS 26 simulator the
  cover's dismissal did not re-run the task (the host UI test passed without the fix);
  `testTheScreenAttachesEachColumnOnceWhenItReappears` forces a re-run by removing and re-adding
  the hosted screen. A caret placed below a table that ends a column is the table's, which takes no
  text (as after a trailing table in the document). **The writer** (`find`) descends into
  `columnList`/`column`, `resolve` accepts a `column` as the parent list
  (`BlockNoteWriter.isBlockList`), and `liftListItem` lifts into a column; split, join, marks,
  type changes and indent were already parent-agnostic. **Patches:** a change inside an open group
  is its block's patch (the `.text` fast path included); a `column`/`columnList` child-list change
  in an open group is a tree change, and after the rebuild each column's list is diffed like the
  document's (`PatchBuilder.diff`; a block that changed container, depth or parent is a
  `.replaceBlock`). Every column-scope change is tagged in the patch (`BlockPatch.columns`: block id
  → column id; `removedColumns` for removals, by the column the block was in), so the session
  routes by tag, never by spelling (column blocks have real ids). **Surfaces** gain a column scope
  (`DocumentReplicaSession.attach(surfaceID:group:column:)`): a document surface never sees a
  tagged change; a column surface sees only its column's and its group's own changes (a structure
  signal its surface ignores), and a `.reset` re-expressed as its column's blocks
  (`engine.columnBlocks`); a table surface keeps its table's changes even when the table is a
  column's block. Closing the last column surface sends the document one `.replaceBlock(group)`;
  a rebuilt replica reopens open groups (before tables: a column's table is one of their blocks).
  **The shadow** spells a root familiar group as the export does: `htmlToMarkdown` prints the
  column frames transparently, so it is each column's blocks spelled as root blocks
  (`NativeBlockProjection.spell`, the same classic/table/export-chunk rules), column after column,
  each column its own segment (lists restart, as the export's `1. two\n\n1. three`). Its classic
  spellings differ from the export only where they do at the root (`- `, `_x_`, dropped empty
  paragraphs; `syncCanonicalMarkdown` equal). Under `nativeMarks` a familiar group whose every
  block the native projection models is `.modeled` (`columnFidelity`; else `columnList: <reason>`
  or `columnList: unmodeled block`), so the document types; the classic projection keeps it opaque.
  A group below the root has no shadow. **The editor** (`ColumnEditorViewController.swift`:
  `ColumnEditorModel`, `ColumnEditorScreen`, `ColumnTextContainer`), presented full screen by
  `NativeEditorView` from a tap or VoiceOver activation of the group's card
  (`NativeBlockControls.onOpenColumns`), leases **one surface per column**, all attached at open
  (`NativeEditorSession.openColumn`: the document's journal, scheduler and pasteboard, its
  composition recovery forwarded to the document's, the document's awareness painted), and shows
  one at a time behind a segmented picker (`nativeEditor.columns.picker`; each text view
  `nativeEditor.column.<index>`). Switching hands first responder to the next text view before the
  shown one hides, so the keyboard stays up; no focus set is needed (Return would have to keep
  growing one). The document's formatting bar, slash menu and link sheet
  (`nativeLinkEditing`) act on the shown column's input; a table card in a column opens the table
  editor over that column's surface. Escape (`NativeInputCoordinator.onExit`) and Done close every
  column surface and put the document's caret after the group. A reader (`inspect` keeps
  `ColumnGroup.groups`) gets read-only columns without input; an unfamiliar group does not open.
  **Known limits:** the web's boundary moves (Backspace at a column's first block moves it into the
  previous column or above the group, the block after the group moves into its last column, Delete
  at a column's end pulls the next column's first block in) write nothing natively; a column a peer
  adds while the editor is open shows when it is reopened; a group that turns unfamiliar while
  open empties its columns without closing the editor; a group below the root, or holding math or
  a diagram (the 72ebe1bb test document; its media are modeled since PR13a), keeps the document
  read-only; Shift-Tab of a
  nested block with following siblings lifts it with them as their parent (the existing PR06a
  `liftToOuterList`), where this harness's web run leaves it nested and nests the siblings under
  it, at the root as in a column; a frozen save (`freezeAuthoring`, below) now also stops the table
  and column surfaces the document opened (they share its journal; before, a table surface kept
  journaling). Edge whitespace inside a column takes the same shadow rules as at the root (see
  "Edge whitespace in the save shadow").
  Tests: `BlockNoteColumnOracleTests` (`BlockNoteColumnCaptures`,
  cols.mjs: seven web fixtures familiar with their export as the shadow, widths, column blocks;
  typing, Return, Return in an empty column block (`emptyChildEnter: "stay"`), an empty nested
  Return, list Return, join, Tab, Shift-Tab, bold, a type change, a range delete and a cell of a
  column's table equal to the web's XML and Markdown; the web's boundary moves refused, moves past the group included; duplicate column ids; a closed
  group's blocks not targets; the real `.review/` group preserved), `ColumnEditorTests` (typing
  predicted and journaled and never shown to the document, the preview on close, Return/Backspace
  in the column, Tab, IME, undo and redo, relaunch, peers in two columns, a peer's new block, the
  picker keeping first responder, a column's table, the reader, an unfamiliar group, the document
  typing around a group, a frozen document freezing its columns) and the host UI tests
  `testTypingInBothColumnsSurvivesRelaunch` and `testTypingAfterAColumnsTableSurvivesRelaunch`
  (`--native-column-table`)
  (`--native-open --native-columns`).
- **PR12b Column structure, moves across a column's edge, the group as a block.** Every command
  produces the web's XML (`BlockNoteColumnStructureCaptures`, cols2.mjs: 33 web operations).
  **Column commands** (`Core/Yjs/BlockNoteColumnCommands.swift`, `BlockNoteColumnCommand`, one
  `NativeEditCommand.Kind.columns` on the group's id, `DocumentEngine.prepareColumnCommand`,
  validated before arming, open or closed group): `add` (a column of one empty paragraph, width 1,
  the others' widths first normalised to an average of 1 when it is outside 0.99...1.01, as the
  column drop handler's `updateBlock` does, JS arithmetic kept: `1.7999999999999998`), `remove`
  (`removeBlocks([column])`; a group of two dissolves into the other column's blocks, copied in
  place of the group, `fixLayoutBlock`), `move` (the column cloned to its new place) and `resize`
  (the handle's two `width` attributes, each at least `minimumWidth` 0.5,
  `ColumnResizeExtension`'s floor). Widths are written as lib0's `writeAny` keeps a number
  (`BlockNoteWriter.number`: an int within 31 bits, a float32 when exact, else a float64). New ids
  must be unused by any block, column or group (`isUnused`, `ColumnGroup.columnIDs`). **Insertion**
  (`.insertColumns(count:ids:removing:)`, the slash menu's `twoColumnsSlashItem`/
  `threeColumnsSlashItem`, native only, `SlashMenuAction.columns`): `insertColumnList`'s
  `insertOrUpdateBlockForSlashMenu` — a root paragraph left empty once the "/query" goes becomes
  the group (keeping its id; one of the `2n + 1` ids is then spare), one with text gets the group
  after it, and from a column the group goes after its group; a nested paragraph is refused (a
  group below the root has no shadow). **Moves across a column's edge** (`DocumentEngine.crossing`,
  the web's `getInsertionPos`), for Move up/down and Backspace (`.join` at a block start, which the
  web turns into the same move): a block next to a group goes in (Move down: the top of its first
  column; Move up and Backspace: the end of its last column); a column's first block moving up goes
  to the end of the previous column, or above the group from the first column; a column's last
  block moving down to the top of the next column, or below the group from the last. A column the
  move empties keeps one empty paragraph (`moveAcross`'s `padID`, `DocumentEngine.newBlockID`):
  the web keeps the empty column, refilled by ProseMirror. Delete at the end of the block before a
  group (a `.range` to the group's offset 0) pulls its first column's first block out after it
  (`pullFirstBlock`). **The group as a block:** the document's block menu on its card moves it
  among plain root blocks (never past a block with children or a group: it would nest), duplicates
  it with fresh ids for the group, its columns and its blocks (the engine's own ids:
  `BlockNoteWriter.Copy.idCount`, `replacingIDs` renames lists and columns too), copies it
  (`BlockNoteSubtreePayload.validate` takes a root `columnList` of 2...16 columns of containers;
  its ids count as blocks) and deletes it; a pasted group lands at the root only. **The editor
  follows the group** (`ColumnEditorModel.reconcile`): the group's own change (its
  `.replaceBlock`, a `.reset`, or its removal, which column surfaces now receive as a signal)
  re-reads it; a column a peer or a command added gets a surface, a removed one loses its own, the
  order follows the group's, the shown column stays shown by id (else the nearest), and a group
  that dissolved, went or turned unfamiliar closes the editor. **The Column menu** (toolbar,
  `nativeEditor.columns.menu`; `ColumnAction`: insert left/right, move left/right, wider,
  narrower, delete, each disabled when unavailable) acts on the shown column; Wider/Narrower move
  the handle beside it (its right one; the last column's left one) by a quarter column, clamped as
  the web clamps. Awareness per column: a peer's position in a column's block resolves to that
  block while the group is open (its column paints it) and to the group's card while closed.
  **Known limits:** Delete at a column's end (the web pulls the next column's first block in) is
  refused: a column surface holds only its column; a resize is a menu step, not a drag, and is an
  undo step (the web's resize is not in its history); the column editor is not opened by itself
  after the slash menu makes a group, and the caret does not follow a block moved into another
  column; a moved or reordered column and a dissolved group's blocks are clones (a peer's
  concurrent edit in them lands in the deleted original, as for every native move, PR06d);
  a group never moves past a block with children or another group. Tests:
  `BlockNoteColumnStructureOracleTests` (every capture, refusals, the group moved, duplicated and
  copied), `ColumnStructureTests` (the menu end to end through a dissolve, a peer's new, deleted and
  dissolved column, a group turning unfamiliar, a block moved out by a peer, a block moved to the
  next column, the slash item, the block menu on the card, awareness per column) and the host UI
  test `testTheColumnMenuInsertsAColumnThatSurvivesRelaunch`. The PR12a bullet's refusals of these
  moves are superseded. (PR12c: the caret now follows a block moved into another column.)
  **Review fixes (PR #284).** A column command carries the column ids its indices address
  (`.columns(_:expecting:)`, the editor's group when the menu was used) and is refused once a peer
  changed the columns, never retargeted. Insert column refuses widths whose normalisation would
  not stay positive and finite (1e308s sum to infinity and divide to 0: an unfamiliar, unsaveable
  group), and a pasted group's widths must be absent or positive and finite (`validate`), for the
  same reason. New-id checks collect the replica's ids once per command (`usedIDs`,
  `idCollections`), not one document walk per id (a 2,000-block Duplicate). `ColumnTextContainer.show`
  removes a removed column's text view (it sat on top and took every touch) and sets every view's
  visibility each pass. A reconcile closed while it attaches ends every surface it attached
  (`beforeAttach` is the test seam), so the group closes and its card updates again. Tests:
  `BlockNoteColumnStructureOracleTests` (stale column ids, huge widths, pasted widths, one id walk)
  and `ColumnStructureTests` (deleting the shown column, closing during an attach).
- **PR12c Column presentation, scale, VoiceOver, find into columns.** **Layout**
  (`ColumnTextContainer`, a `UIScrollView`, one scroll for the whole editor): side by side at the
  group's relative widths (`width`, unset 1; a hairline between) when the horizontal size class is
  regular and the narrowest column gets `minimumColumnWidth` (220 pt, scaled by the host's Dynamic
  Type `contentSizeCategory`), else stacked (a hairline above each column after the first). Every
  column is shown; `active` (the picker's selection, the Column menu's target) follows first
  responder (`NativeTextView.onFocus` → `onActivate`), and a column made active by the picker takes
  first responder when the previous one had it and is scrolled to its caret. **Viewports, not
  full layout:** each column's text view sits in a `ColumnFrameView` framed to the part of its
  column on screen (`viewport`: the visible clip; off screen, at most a screen of it at the edge
  nearest the screen) with its `contentOffset` set to match, so TextKit lays out only what is
  visible. Its own pan, scroll indicator, scroll-to-top and safe-area insets are off; this view
  scrolls. Heights are the text views' (estimated) `contentSize`; a text view that has not laid
  out stands for a screen. After each of its layout passes (`NativeTextView.onGeometry`) a height
  change lays the columns out again, and a self-scroll (UIKit keeping its caret visible) or a moved
  caret of the first responder is shown by scrolling this view (`reveal`, after the next layout:
  place, lay out, place again, at most three times, because an off-screen caret is TextKit's
  estimate); a user's scroll changes no selection, so it is never pulled back. **Transitions**
  (rotation, split view, Stage Manager, a Dynamic Type change, a column added) only move frames: no
  view leaves the hierarchy or resigns, so focus, the selection, marked text and an unconfirmed
  prediction stay. **VoiceOver:** each `ColumnFrameView` is a `.semanticGroup` labelled
  `NativeEditorLabels.column` ("Column 2 of 3", `native_editor_column`), the container's
  `accessibilityElements` are the columns in order, and a custom Columns rotor
  (`native_editor_columns_rotor`, 11 languages) moves between their text views; the document's
  group card (a button) has the value "Column 1 of 2, <first lines>; Column 2 of 2, …".
  **Find and outline into columns:** `DocumentEngine.navigationEntries` lists each familiar root
  group's blocks after its card, column after column, each entry carrying the group's handle
  (`NativeNavigationEntry.group`); `.locate(handle, group:)` answers the block's column id only
  while the group and that block item are still the ones read (`locateColumn`, O(group)), so a
  block a move re-created does not jump. A jump to one calls `NativeDocumentNavigation.onOpenColumn`:
  `NativeEditorView` closes the outline (a cover cannot present over the sheet) and, in its
  `onDismiss`, opens `ColumnEditorModel(target:)`, which makes that column active with the caret at
  the block's start (`NativeInputCoordinator.focus(at:)`: the selection only). The reading position
  restores and persists over the document's blocks only (`documentBlocks`). **The 12b caret limit:**
  a Move up/down whose block left the column (`.remapping` finds no entry) reports it
  (`onBlockLeft`), and the model makes the column that shows it active with the caret at the same
  offset (`follow`, checked after every column delivery). **Scale** (fixture gate, debug iPhone 17
  Pro simulator, iOS 27): a 2,000-block group (two columns of 1,000, the `maxBlocks` bound) loads in
  ~80–85 ms, shows its first frame in ~30–140 ms, realises < 60 blocks per column, scrolls at p99
  ~3.2–3.4 ms a step, and a key far down the second column (insert plus the container's layout) takes
  p50 ~11–12 ms, p95 ~16–21 ms (four runs): over the provisional 8.3 ms typing budget in a debug build, to be
  measured on TestFlight. **Known limits:** stacked heights are TextKit estimates until a column is
  laid out, so a long column above the screen can shift the ones below by its estimate's error (no
  anchor correction, as in the document); a block moved out of the group into the document is not
  followed (the document is behind the editor) and the column editor still does not open by itself
  after the slash menu makes a group; the one-shot reader's find does not search inside columns;
  layout follows the size class, so a compact-width window wide enough for the columns (iPhone
  landscape) still stacks; Next/Previous onto a match in a column closes the outline (the editor
  opens there), so stepping through matches stops at it. Tests: `ColumnLayoutTests` (side by side at the widths, stacked, a change of layout keeping
  first responder, selection, marked text and a pending key, Dynamic Type without clipping, the
  2,000-block gate, typing scrolling to the caret, the containers and rotor, the card's value, find
  and outline into columns with an unchanged document, a stale column handle, the caret following a
  moved block), the updated `ColumnEditorTests`/`ColumnStructureTests` (every column shown) and the
  host UI tests `testAFindMatchInAColumnOpensTheColumnEditorThere` and (iPad only)
  `testColumnsSitSideBySideOnIPadAndKeepTypingThroughRotation`.
  **Review fixes (PR #285).** F1: the find field's query-following jump (`DocumentOutlineSheet
  .onQueryMatch`, `jump(to:deliberate: false)`) only scrolls the document to the group's card; only
  a tap, Next or Previous opens the column editor, once until it closes
  (`NativeDocumentNavigation.isOpeningColumn`/`columnEditorClosed`, and the view drops a reply while
  an editor is up or pending), and an editor opened at a result does not take first responder
  (`ColumnTextContainer.takesFocusOnOpen`), so the rest of a query is never typed into a column.
  F2: keys held while a move is in flight go with the block (`BlockLeft.keys`, adopted by the
  column that shows it, `NativeInputCoordinator.adopt`), never replayed in the column it left; when
  no column shows it (it left the group, or another column's delivery came first) they become the
  document's recovery entry. F3: Backspace at a column's first block (a `.join` whose `.caret` block
  is no longer on the surface) reports the block too. F4: only moves and joins report
  (`Barrier.movesBlock`; a column or table command's `.remapping` never does), and a wait ends at
  another column's delivery or at close. F5: a target or followed block inside a collapsed toggle is
  revealed (`surface.reveal`) before the caret goes there, the reader too. Tests (each fails without
  its fix): `testTypingAQueryNeverOpensTheColumnEditorAndADeliberateJumpOpensItOnce`,
  `testAnEditorOpenedAtAResultDoesNotTakeTheKeyboard`, `testAKeyHeldDuringAMoveIsTypedWhereTheBlockWent`,
  `testBackspaceAcrossAColumnEdgeTakesTheCaretWithTheBlock`,
  `testDeletingAndRestoringAColumnDoesNotPullTheCaretLater` (fails only with both F4 guards removed)
  and `testAResultInsideACollapsedToggleIsRevealed`; the host UI test now types the whole query, sees
  no editor, and opens it with Next.
- **PR13a Native media: model, export shadow, props, insertion, online upload.** The staging plan
  (13a here; 13b the native offline queue, headless commits and drag/drop; 13c mentions and page
  links) lives outside the repo. **The model** (`Core/Yjs/BlockNoteMediaCommands.swift`,
  `MediaBlock`): BlockNote 0.56's `image`, `video`, `audio`, `file` and Docs' `pdf` and
  `uploadLoader`, props in schema order (`MediaBlock.schemas`, the order y-prosemirror sets a new
  element's attributes; `pdf`/`uploadLoader` are Docs' **server** specs,
  `docs/src/frontend/servers/y-provider/src/blockSpecs`). Under `nativeMarks` a block with no
  content and every known prop of a readable type is `.modeled` (`unfamiliarReason`; unknown props
  are preserved and never written); the classic projection, its default-props image rule and every
  golden are unchanged. **The shadow** (`NativeExportMarkdown.media`, a port of each block's
  `toExternalHTML` and `htmlToMarkdown`'s media serializers, media.mjs captures): a shown image or
  video without a caption is `![name](url)` (nothing escaped; a video's name is the export
  layer's `data-name`), with a caption a raw `<figure>` (attributes and text HTML-escaped, the
  caption JS-trimmed, the image alt dropped when empty or equal to the caption, no name on a
  video figure); audio is `<audio src controls></audio>`, in a figure with a caption; a hidden
  preview and a file are `formatLink(name || url)` then the caption as its own untrimmed
  paragraph; a pdf preview is an iframe, which prints **nothing** (its caption paragraph stays), a
  hidden one the link, and a pdf url Docs' `isSafePdfUrl` would refuse (the server prints a span
  glued to the next block) has no shadow; an empty url prints an empty block (blank lines the
  shadow drops, canonical-equal like empty paragraphs) and `uploadLoader` nothing. Only a root or
  column-root media block without children gets the chunk; below the root or with children only
  the classic projection's modeled image line spells one, anything else has no shadow.
  **Commands** (`NativeEditCommand.Kind`): `.mediaProps(props, expecting:)` (`prepareMediaProps`,
  validated per kind by `MediaBlock.isValidEdit`: name ≤ 1,024 and caption ≤ 4,096 UTF-16 without
  control characters, url empty or `isAuthoredURL` — absolute http(s) with a host, no userinfo,
  whitespace or controls, ≤ 2,048 —, `previewWidth` 1…10,000 or unset, `textAlignment` of the four,
  `showPreview` bool, only keys the kind's schema has) writes like y-prosemirror's
  `updateYFragment`: changed props set (an absent default included) and every schema prop whose
  value is `undefined` **removed** (the web's `!= null`: an edited block loses its stored
  `previewWidth="undefined"`); unknown props stay (the web would drop them). The writer resolves
  media through `mediaTarget` (never a text target). `expecting` is an upload's `MediaBlock.Slot`
  (kind + url when it started): a block whose kind or url changed refuses. `.insertMedia(node:ids:
  removing:)` is `insertOrUpdateBlockForSlashMenu`: the "/query" removed, the emptied paragraph
  becomes the block in place (element replaced, container and id kept, shared props carried), else
  a new container after it; then, when no later sibling takes text
  (`needsTrailingParagraph`, walking past `MediaBlock.contentless`), an empty paragraph after the
  **document's last root block**, even from a column, as `setSelectionToNextContentEditableBlock`
  does; one transaction; root or column-root paragraphs without children only (a nested media
  block has no shadow). The engine's table rules now cover media (`rootOnlyNodes`): nothing indents
  under one, none indents or moves below the root, a paste never nests one. **Uploads** (`Native/NativeMediaUploads.swift`): one at a
  time per document (the view owns it, the column editor shares it), the classic pipeline
  (`preparedJPEGData`, `loadPickedAttachmentFile`, `DocsAPIClient.mediaUploader` =
  `uploadAttachment` + `readyMediaURLString`) to the document id captured at start; the answered
  URL must parse as this server's attachment for **that** document (`parseAttachmentLink`, document
  UUID compared) and pass `isAuthoredURL`, else nothing is written. The commit is
  `.mediaProps([name, url], expecting: slot)` through the **starting session's** input, held weakly
  (a busy input is retried every 100 ms, up to 50 times; a block gone from the surface, a closed
  session — Done, sign-out, another account — drops it, never retargeting another session).
  Offline, a local document or no uploader refuses with `native_editor_media_upload_offline`; the
  card shows "Uploading…" (`NativeBlockControls.uploadingBlock`, presentation only). **Never** put a
  local path, `schrift-attachment://` placeholder or the picked name the server did not store into
  Yjs, and **never write `uploadLoader`**: it makes every editable web client poll and replace the
  block. A peer's `uploadLoader` is modeled (the document types), shown as
  `native_editor_upload_elsewhere`, saved as nothing, and never polled, replaced or edited.
  **Review fixes (PR #286).** F1: the inspector's name and caption are a `NativeMediaTextDraft`: each
  field remembers the stored value it last synced to, an untouched field follows the block on every
  delivery (an upload's name, a peer's caption) and Done writes only the fields the user changed
  (before, Done wiped an upload's name and reverted peers' edits). S1/A1: the width a peer stored is
  shown only through `MediaBlock.displayWidth` (in 1…10,000, else unset); `Int(1e20)` trapped. A2: a
  file picked for an **image** block is re-encoded by `preparedJPEGData` like a photo (name
  `<stem>.jpg`), so its EXIF/GPS never uploads; a file block's bytes still go as picked. S2: a pasted
  media block must be `MediaBlock.isPastable` (familiar, every editable prop `isValidEdit`,
  `backgroundColor` a bounded string; `BlockNoteSubtreePayload.validateMedia`, paste only: copy and
  delete keep any block), so a payload cannot store `javascript:`/`data:`/relative urls, unbounded
  text, an out-of-range width or a pdf the shadow cannot spell. A3: after preparation, before the
  request, an upload whose starting session closed (Done, sign-out, another account's reopen) sends
  nothing; `NativeEditorView` makes one `NativeMediaUploads` per session. S3: Open opens only an
  `isAuthoredURL` URL (no userinfo to disguise the host) and shows its host on its own line
  (`NativeMediaInspector.openTarget`). S4: names, captions and URLs are displayed through
  `MediaBlock.clipped` (300 scalars, never characters: one character can carry a million combining
  marks), and a stored name or caption over its limit is read-only. S5: `isAuthoredURL` accepts only
  RFC 3986 characters with `%` as a hex escape, checked on the raw string before `URLComponents`
  (Foundation may percent-encode what it would otherwise refuse; a non-ASCII host must be punycode).
  **Round 2.** V1: an upload is bound to the sign-in generation it started in, checked when the
  request is built, not only before the await: `SessionStore.generationClock`
  (`SignInGenerationClock`, a `Mutex`, set at every `signInGeneration` bump; since PR13b read by the
  coordinator through `signInIsCurrent`, no longer an environment entry) gives an `isCurrent()` closure that
  `DocsAPIClient.mediaUploader(isCurrent:)` threads to `uploadAttachment`/`send`/`performRequest`,
  which asks it synchronously after building the request and before handing it to the session
  (false: `CancellationError`, nothing sent). V2: a pdf url must also be one the export spells
  (`NativeExportMarkdown.isSafePDFURL`, for native edits and pastes), and a pasted media block must
  have its export chunk before insertion. V3: a pasted url is canonicalised first
  (`MediaBlock.pastedURL`: a web IRI such as `https://images.example/été.png` or a non-ASCII host is
  percent-encoded and punycoded by `URL(string:encodingInvalidCharacters:)`, then must pass
  `isAuthoredURL`; whitespace and controls are refused before), so a cut web image pastes back;
  `BlockNoteSubtreePayload.validatingMedia` returns the canonical copies. V4: a submitted name or
  caption becomes that field's synced value at once (`NativeMediaTextDraft.committed`), so a
  delivery bringing a peer's later rename with ours is followed, not overwritten by Done.
  **Round 3.** W1: the clock moves **before** a web login writes cookies: `WebLoginView`'s
  `onCookiesWillChange` (called on the main actor just before `captureCookies`; the three login
  views pass their view model's `cookiesWillChange`) calls `SessionStore.noteSessionCookiesWillChange`,
  which `beginSwitch`es the clock: every earlier `isCurrent` closure is false from then on, and one
  made while switching stays false; the next `signInGeneration` bump `advance`s it and ends the
  switch. W2: the paste check that keeps tables and media at the top level (`nestsTable`) now walks a
  pasted column group's columns (their blocks at the column's top level), so a pdf nested under a
  paragraph in a pasted group is refused instead of leaving a document without a shadow. W3: a
  submitted name or caption is **pending** (`NativeMediaTextDraft.pendingName`/`pendingCaption`),
  the field dirty, until a delivery shows it stored or a peer's later change of that field supersedes
  it (`setMediaProps` returning true only means posted: a command and its retry can both go stale),
  so Done writes a lost submit again.
  **UI:** slash items Image/Video/Audio/File/PDF (`mediaSlashItems`, `SlashMenuAction.media`,
  native only) and the formatting bar's Attach menu (Photo, File, Video, Audio, PDF —
  `NativeAttachChoice` → `insertMediaBlock(node:)`, the same path with no "/query" to consume;
  Photo and File stand in for the image and file blocks, whose inspector holds the photo picker
  and the file importer) insert and set `requestedMedia`, which opens the inspector. A media card tap or
  VoiceOver activation is routed by `NativeMediaTap.route` (pure; `NativeMediaPlaybackTests`): video
  and audio play, image, file and PDF preview (`NativeMediaPresenter`: `AVPlayerViewController`,
  `QLPreviewController`), from a queued upload's bytes, this server's upload through
  `AttachmentLoader` (video and audio streamed to disk, capped), an image through `ImageLoader`, or
  any other https file on the tap (offline: a notice; a document: the browser; video and audio:
  downloaded cookie-free by `RemoteMediaClient` and played from the staged file, since the player
  must never get a remote URL); a block with no url, an `uploadLoader`, a non-https other-site URL,
  a playlist or a type QuickLook must not render (`attachmentExtensionIsPreviewable`) opens the
  inspector instead. `NativeMediaPresenter.start` plays only in a still-presented player, with
  `forbidAll` reference restrictions; `endSession` (from `SessionStore.forgetSignedInIdentity`)
  stops it and deletes `tmp/SchriftMediaPreview`. Another site's audio, file or PDF card shows its
  host as the detail line. The
  card's Options button (`mediaOptionButtons`, editing only) and the block menu's Options
  (`mediaOptionsTarget` → `requestedMedia`) call `NativeBlockControls.onOpenMedia`, which opens
  `NativeMediaInspector` (a sheet,
  `nativeMedia.*` identifiers): name and caption (one command on submit or Done), Show preview,
  Width (Original or 240–640 pt, plus the block's own), Alignment, Upload photo (image), Upload file
  (types by kind), Link (`isAuthoredURL`; the name becomes its last path segment, the web's
  `filenameFromURL`), Open (a same-origin attachment through `AttachmentCardView`, its loader's
  rules; any other `isAuthoredURL` URL only on a tap, in the browser, its host shown) and Delete; read-only for a document
  that cannot type and for `uploadLoader`. The inspector reads `session.revision` so it re-renders
  after each delivery (the surface is not observable). An empty media card says
  `native_editor_media_empty`. **Known limits:** no native offline queue and an upload finishing
  after the editor closed is dropped (both lifted by PR13b, bullet below), no drag/drop or paste of files, no poster frames, unknown props survive an edit where the
  web drops them, a nested media block authored on the web keeps its document read-only unless it
  is a plain image, Width offers presets (any web width is kept and shown), and 72ebe1bb stays
  read-only (interlink: 13c; math, diagram: PR14). Tests: `BlockNoteMediaOracleTests`
  (`BlockNoteMediaCaptures`: 70 web fixtures modeled with the export as their shadow, byte for byte
  except empty blocks and classic list spellings; 56 web edits — caption, name, commit, replace,
  width, fraction, alignment, preview, slash insertion in every shape, delete — equal to the web's
  XML and Markdown; refusals; the nested captioned image; `uploadLoader`; an unknown prop; the
  `.review/` capture), `NativeMediaTests` (slash items, inspector commands, a peer's caption, the
  upload pipeline incl. other documents' and other origins' URLs, a block deleted or filled during
  the upload, offline/local/concurrent refusal, a closed editor, a too-large file) and the host UI
  test `testAMediaCaptionEditedInTheInspectorSurvivesRelaunch` (`--native-open --native-media-edit`).
- **PR13b Native media: offline queue and headless commits.** (13b2, later: drag and drop or paste
  of files into the text view, poster frames, an image's height refreshed when its ratio arrives.)
  **One path, record first:** `NativeMediaUploads.start` prepares the bytes as PR13a did, then
  `DocumentSaveCoordinator.queueNativeAttachment(scope:target:data:)` writes bytes, then a
  `PendingAttachment` whose optional `native: NativeMediaTarget` (org, block id, the
  `MediaBlock.Slot` the upload started from, file name, content type) stands in for the Markdown
  placeholder; the record's scope is derived (`nativeScope`: origin, owner, org, document), so
  `migrateCreatedDocument`'s re-key carries it (a native editor never types a local document, so
  none is minted for one). Online or offline the same record; the queue refuses another account's
  or server's scope and an unreadable store. **The run** (`runNativeAttachment`, kicked at queue time
  and by `runAttachmentPass` for each native record whose owner is the `/users/me/` answer; one
  runner per record, `nativeRuns`): the slot checked headlessly first (block gone, retyped or filled →
  record and bytes dropped, nothing sent), the upload (`client.mediaUploader`, its `isCurrent` the
  sign-in generation captured when the run started — `signInIsCurrent`, set by `RootView` from the
  clock), the stored bytes no larger than the picker's limit (`nativeAttachmentByteLimit`, checked
  on the file size before reading; over → failed), the answered URL this server's attachment for
  **this** document and `isAuthoredURL` (`isDocumentMediaURL`, else failed), the URL
  **checkpointed** on the record, the URL checked again right before the commit (a checkpoint read
  back from disk included), then the headless commit; `.committed` or
  `.gone` removes the record. Transient failures (offline, 5xx, an expired session, a refused
  switch) wait for the next pass; a rejection sets `failedAt`. The classic pass `continue`s past
  native records: no Markdown names them, so its collection would delete them; the pass runs the
  native records after every classic one, so a blocked commit's retries (about 5 s) never delay a
  classic photo. An editor that starts typing (`installTyping`) runs its scope's waiting records
  (`replayNativeAttachments`). Lookups are account-scoped (`nativeAttachment(scope:blockID:)`,
  `nativeAttachments(scope:)`; `NativeMediaUploads` holds the scope), so a card never shows,
  retries or discards another account's record. **Saves are bound to the sign-in generation**
  (review X1, every route): `start` captures `signInIsCurrent` and runs the save under the
  task-local `DocsAPIClient.saveIsCurrent`, which `performRequest` asks right before each request
  (body, title, config, identity); a refusal throws `CancellationError`, which `finish` treats as
  `.pendingSync`, so a cookie handover after `/users/me/` or between PATCHes sends nothing more
  and the draft and journal wait for the right account. **The headless lease**
  (`NativeSessionRegistry.commitMedia`, the coordinator's `weak nativeSessions`): no replica on disk →
  `.gone`, an unreadable one → `.unavailable`; `open` a surface (an open editor's replica, else one
  restored for this), the block found in mailbox order (`ReplicaMessage.mediaLocation`,
  `DocumentEngine.mediaLocation`: the index first (an indexed container with no content element is
  undecided), then a walk of the whole document's **block structure** only (`blockGroup`,
  `blockContainer`, `columnList`, `column`, never inline content), counting block levels up to
  `NativeBlockProjection.maxDepth`, and every structural step (a group in a group, a column group in
  a column, crafted or not) counting toward `MediaSearch.maxLevel` (4 × maxDepth), so a crafted
  nesting is cut, never walked without bound on the replica actor; a cut branch marks the search
  but never stops it, and a
  block found but not addressable (outside a column, a column or group without an id, past the
  depth, no content element) is undecided; only an id absent from the whole document is nil, and
  undecided means `.unavailable` (the record waits). So a block moved into a column or another
  group after it was picked, or a web-authored one nested under a column's paragraph, is found and its
  column is opened before the commit; `.some(nil)` only when no block of the document has the id,
  nil when nothing answered), the session's `canType` required, then the journal (`installJournal`,
  shared with `installTyping`) installed only when this is the scope's only surface **and**
  `mayWrite` holds — the coordinator's async `nativeMayWrite`, the editor open's typing gate: the
  native switch (`nativeEditorEnabled`), no pending create or delete, no live owner, no classic
  draft, and `abilities.update` asked of the server once (`documents/{id}/`, under the run's
  sign-in generation, so a document opened from a folder or a deep link commits too); a reader
  answer, or an editor's (`becomeReader` → `noteNativeReader`), is remembered per scope
  (persisted, `nativeMediaReaderScopes`) and only the server saying update again lifts it; with no
  answer (offline, a 5xx, an expired session) a remembered reader is no, else only the account's
  own Home lists decide (unknown is no: the record waits; the subpage cache is neither account- nor
  origin-scoped and never decides); a 403, an API 404 and an answer naming another document id are
  denials remembered like a reader answer, while a missing route (an HTML 404 from a proxy during a
  rollout), an unreadable body, a timeout, a 408, a 5xx, offline and an expired session are no
  answer at all (`DocumentAbilityAnswer`, one classifier shared with the editor open), so a rollout
  never makes a writer a reader; a no is final even if an editor made the scope writable during the
  question; the gate runs before **every**
  commit, an editor's writable entry or not (an editor writable on its row's ability never carries
  a commit the gate refuses), and a denial (`noteNativeReader`) also ends the scope's shared
  writability (`setWritable(nil)`, live disconnected), as an editor's own reader answer does, and
  `NativeEditorOpen.startLive` refuses a scope the coordinator remembers as a reader
  (`isNativeReader`) and a surface that is not writable (`NativeSessionRegistry.isWritable`), so
  lifting a denial never dials a socket for a read-only surface (it recovers on reopen); the
  editor's own ability check (`serverAbility`) reads the same answers as reader, and its writer
  answer clears a remembered denial (`clearNativeReader`) on every route, the unowned one included;
  the
  registry re-reads the entry after that await — else
  `.unavailable` and the record waits (an open editor that does not write stays so); the save goes
  through the scope's scheduler when an editor installed one, else a private one that is never
  registered, so an editor opened later keeps its own save rules (review X7);
  one `.mediaProps([name, url], expecting: slot)` barrier posted from the surface
  (`NativeEditorSession.post`, a surface without input, answered by its result, posted with the
  surface's current epoch, which a resync's reset or an invalidation moves) after a settle,
  `.stale` and a same-slot refusal (a composition) retried `nativeCommitAttempts` × interval, then
  `schedule` + `flush`. A refused commit re-reads the slot: changed → `.gone`, same → `.unavailable`.
  Visible editors get the change by fan-out. The headless save (`enqueueNativeReplica`) is
  `installTyping`'s without a view model; the title is the cached server title or the draft's,
  never guessed (none known: the journal waits for the next open). **Kill and relaunch:** before
  the checkpoint the record uploads again (no idempotency key; the old upload is an orphan on the
  server), after it only commits, and a commit that landed before the record went is refused by
  its own slot (url no longer ""), so a block never gets two photos and no photo is lost.
  **UI:** a file-style card (an empty block, a file, audio, a hidden preview) says "Uploading…" for
  every block with a live record or being prepared (`NativeBlockControls.uploadingBlocks`) and
  "Upload failed · tap to retry" for a failed one (`failedUploads`), "Waiting to upload" for one a
  run left for a later pass (offline, the gate, a busy block: `nativeWaiting`, `waitingUploads`;
  the inspector says the same); an image or video card showing
  its picture shows no state (the inspector does); the inspector shows the same, "Uploads when you're back online." offline, and
  Retry upload / Discard upload for a failed record (`nativeMedia.retryUpload`/`discardUpload`);
  Delete also discards the block's record; uploads no longer refuse offline (only a local document
  says `native_editor_media_upload_offline`, now "Uploading needs a document saved to the
  server."); one upload per block.
  Document delete and keep-server drop the signed-in account's records on this server only
  (`discardPendingAttachments`; another account's, or any with the account unknown, are kept). **Known limits:**
  no local thumbnail while a photo waits; a document that stops being typable keeps its record
  waiting (retried each pass); a commit blocked past its retries by a composition waits for the
  next pass; offline, a document in no cached list waits for the server or its editor. Tests:
  `NativeMediaQueueTests` (`MockURLProtocol`, a real registry, `ReplicaStore` and attachment store:
  the web's `imageCommit` XML with no editor open, the inspector's upload reaching an open editor,
  an upload finishing after its editor closed, offline then the next pass, kill/relaunch before and
  after the checkpoint and after the commit, a column's block, a block moved into a column, the
  typing gate (reader, unknown, switch off), a restored checkpoint re-checked, bytes over the limit,
  the headless scheduler never the editor's, a headless post after a resync, a reader answer
  winning over the cache and remembered across a relaunch, an editor's reader answer, a document
  outside the caches asking the server (waiting meanwhile), a 403/404 as a denial, a missing route
  or unreadable answer not a denial, the subpage
  cache never deciding, another document's answer, a reader answer through an editor opened
  meanwhile (and a second replay before it closes), a remembered denial through a writable editor,
  a nested image in a closed column (and `DocumentEngineMediaLocationTests`: a crafted 2,000-level nesting undecided, block-level depth, a cut
  branch, found-but-unaddressable, absent; `NativeEditorActivationTests`: 403/404/mismatch as reader,
  a missing route, an unreadable body and a timeout as no answer, a writer answer on the unowned
  route lifting a remembered denial, a lifted denial never dialing for a read-only open, a
  remembered denial keeping the open off the socket), a delete keeping another account's
  records, a deleted block (nothing sent), a
  block filled during the upload, a rejection then Retry and Discard, another document's URL,
  another account's record, a sign-in switch, the classic pass, document delete, JPEG preparation,
  a close during preparation, too large and local); PR13a's upload cases moved there, and
  `testAMediaCaptionEditedInTheInspectorSurvivesRelaunch` now expects Upload file offered offline.
  `RootView` sets `nativeSessions` and `signInIsCurrent`; a host without them queues and waits.
  `ReplicaSaveAdapterTests` pins the save binding (a switch after `/users/me/`: no PATCH, pending,
  then sent once current; a switch during the body: no title; a classic save during a switch).
- **PR13b2 Native media drop, paste, video posters & aspect-ratio refresh (`NativeMediaDropPaste`, `VideoPosterLoader`, `NativeMediaUploads`).**
  **Aspect-ratio & posters:** `NativeBlockAttachment` (`NativeAttachmentView`) notifies
  `NativeBlockControls.noteMediaAspectRatioLoaded` on decoded image/video-poster arrival, coalescing
  `NativeTextSurface.refreshAttachmentGeometry()` for changed URLs/titles without touching Yjs,
  offset indices, or IME compositions while preserving scroll position across above-viewport loads and
  approved external URLs across restyles. `NativeBlockPreview` projects shown non-empty `video` blocks
  as `.video(url:label:previewWidth:)` with a play-badge thumbnail card sizing like `.image` under
  key `"video-poster:<url>"`. `VideoPosterLoader` extracts JPEG thumbnails off-main via
  `AVAssetImageGenerator` (concurrency capped at 2) exclusively from local files (`AttachmentCacheStore`
  fast hit or bounded 20 MB `ImageTransport` fetch, same-origin cookies only, post-await account-scope
  recheck before disk/memory caching, `ImageLoadPolicy` offline/external consent gates), never passing
  remote URLs to `AVURLAsset`; same-origin `"video"` uploads seed `AttachmentCacheStore` at upload
  time.
  **Batch insertion & uploads:** `DocumentEngine.prepareInsertMediaBatch` (`BlockNoteWriter.insertMediaBatch`,
  `.insertMediaBatch`) inserts `1..N` empty media blocks in one Yjs transaction (replacing an empty
  `depth == 0` paragraph or inserting `.before`/`.after`, walking `depth > 0` targets up to root or
  column-root, and appending a trailing empty paragraph at the end of root `blockGroup` when no sibling
  after the insertion target in `group` takes text); `NativeMediaUploads.preparing`
  is `Set<String>` with serialized off-main preparation and `ColumnTextHost` forwards upload states.
  **Drop & paste (`NativeMediaDropPaste`):** Classifies `NSItemProvider` types into `"pdf"`, `"image"`
  (raster only; `.svg` routes to `"file"`), `"video"`, `"audio"`, or `"file"` (excluding bare
  directories and non-file web URLs); enforces text-before-media clipboard precedence (`HTML`/`RTF`
  with fallback PNG or plain URL stays text, Files `public.file-url` + filename routes as media),
  `maxItemsPerOperation = 10` (`native_editor_media_drop_limit`), and `attachmentImportByteLimit`
  (50 MB) checked before reading bytes. `NativeMediaDropController` (`UIDropInteractionDelegate` +
  `UITextDropDelegate`) on `NativeTextView` synchronously initiates non-backed-up `MediaDropStaging`
  file/data staging before `performDrop` returns, shows a 2 pt `brandFill` horizontal line or rounded
  replace border on root/column surfaces (activating the dropped-on column), refuses readers, table
  cells, source editors, and local unsaved documents (`native_editor_media_upload_offline` on paste),
  and routes every upload exclusively through `NativeMediaUploads.start` ->
  `DocumentSaveCoordinator.queueNativeAttachment` (EXIF GPS stripped on images).
  Tests: `NativeAttachmentLayoutTests`, `VideoPosterTests` (poster extraction, EXIF orientation, disk
  cache, off-origin cookie isolation, post-fetch/post-extraction scope switches), `NativeMediaTests`,
  `NativeMediaQueueTests`, `ColumnEditorTests`, and `NativeMediaDropPasteTests`.
- **PR13c1 Native inline objects: mentions & page links (read/edit/clipboard/navigation).**
  **Model:** `NativeInlineObject` adds `.interlink(docID:blockID:title:disabled:trigger:)`,
  `.mention(userID:fullName:)`, and `.mentionSearch(disabled:trigger:)` on `InlineRun.inlineObject`
  for BlockNote's `interlinkingLinkInline`, `userMentionInline`, and `mentionSearchInline` Yjs
  elements (malformed shapes fail closed so classic/preserved fallback still triggers). Projected as
  `\u{FFFC}` (`NSTextAttachment`) with `NativeInlineChipAttachment` and `.nativeInlineObject`
  attributes, rendered via `NativeInlineChipImageCache` (light/dark, `AppTheme`, Dynamic Type) and
  read-only cached title lookup (`NativeEditorView.documentTitle` ->
  `EditorViewModel.cachedDocumentTitle(for:)`) without touching Yjs.
  **Shadow:** `NativeBlockProjection.markdownShadow(_:interlinkingOrigin:)` and
  `NativeExportMarkdown` export enabled interlinks with non-empty `docId` via
  `formatLink(label, "<origin>/docs/<encodeURIComponent(docId)>/")` (where `label` is `title` if
  non-empty else `docId`) when `interlinkingOrigin` (`ReplicaScope.serverOrigin`) is set, or `nil`
  otherwise; disabled/empty-`docId` interlinks, `.mention`, and `.mentionSearch` all export as `""`.
  `TableGrid.read` keeps tables holding inline objects `.familiar` while marking those paragraphs
  `TableGrid.Paragraph.isSimpleText == false` (disabling only the `.text` fast path in `PatchBuilder`).
  **Editing rules:** `AttributedDocumentProjection` inserts mark barriers around each `\u{FFFC}`
  so adjacent typing never bleeds marks; `NativeInputCoordinator` and `BlockNoteWriter` move/delete
  each chip as one atomic unit (`insertInlineObject`, `joinBlocks`, `mergeIntoParent` coalesce
  adjacent `YXmlText`), skip/split range formatting across chips, gate off link-sheet editing when
  touching an inline object, and preserve IME composition across peer chip updates.
  **Clipboard:** `NativeClipboard` (`inlineSlices`, `plainText`, `touchesInlineObject`) and
  `BlockNoteInlinePayload` / `BlockNoteWriter.insertInlineSlice` preserve `.interlink` and
  `.mention` slices across paragraphs and tables, strip `\u{FFFC}` to visible plain text in code
  blocks and external pasteboards (`strippingObjectReplacementCharacters`), and convert pasted
  same-origin doc URLs (`NativeInlineObject.interlink(fromURLString:serverOrigin:)`) into enabled
  interlink chips.
  **Navigation:** `DocumentLink.documentLinkAction(forDocumentID:currentDocumentID:)` treats self
  links as `.alreadyOpen` no-ops and external links as `.openInApp(UUID)`. `NativeTextView.chipTapRecognizer`
  (with `NativeBlockControls` as `UIGestureRecognizerDelegate`, isolated from superview taps and
  suppressed during drags/long-press/IME composition) hit-tests TextKit 2 glyph segments
  (`inlineChipFrame(atUTF16:)`, `navigableInterlink(at:)`) so tapping an enabled `.interlink` chip
  invokes `onOpenDocument` across document, `ColumnEditorScreen`/`ColumnEditorModel`, and
  `TableEditorViewController` active cell surfaces without moving caret placement or writing Yjs;
  tapping mentions, `mentionSearch`, or disabled/empty interlinks does nothing. VoiceOver adds
  `"Open link"` (`NativeEditorLabels.openLink`) when selection touches an enabled interlink.
  `NativeEditorView` (`NativeDocumentLinkCoordinator`) resolves via
  `EditorViewModel.openLinkedDocument(_:)` and dismisses open table/column/media/outline covers
  before pushing. `NativeDocumentNavigation` expands inline objects in outline/find summaries.
  **Known limits:** Tapping `@mention` does nothing in PR13c1; `/` and `@` autocomplete pickers,
  `blockID` scroll-on-open landing, and localized `L10nKey` for `"Open link"` are PR13c2. A table
  command (header toggle, cell prop) or table copy joins a cell's paragraphs across a chip with no
  break, as the web does (BlockNote 0.56 `nodeToBlock`).
  **Tests:** `BlockNoteInlineOracleTests` (11 tests covering captured Yjs oracle parity, shadows,
  fail-closed parsing, URL parsing, native edits matching web XML, selection boundaries, inline
  clipboard slices, and collaborative undo/redo) and `NativeInlineObjectTests` (19 tests covering
  layout parity, Dynamic Type clamping, chip cache, cached title updates, accessibility labels and
  `"Open link"`, table/column/outline expansion, mark barriers, atomic delete, IME composition,
  clipboard degradation, same-origin URL paste, TextKit 2 chip tap hit-testing across surfaces, and
  cover dismissal).
- **PR13c2 Native inline-object pickers (`[[`, `@`, slash "Link a page").**
  **Triggers & zero-zombie model:** `NativeInlinePicker` (`nativeInlineTrigger`, `NativeInlineTrigger`,
  `InlineTriggerKey`, `NativeInlinePickerSource`, `NativeInlinePickerPresentation`) detects `[[`,
  `@` (capped at 64 UTF-16 units, valid only at block offset 0 or after whitespace / `\u{FFFC}`,
  rejecting leading whitespace so emails like `user@example.com` and `"@ 5pm"` stay prose), and
  slash `"Link a page"` (`SlashMenuAction.linkPage` / `linkPageSlashItem(title:)`, ignored by
  classic `EditorViewModel.applySlashSelection`) across editable inline blocks (`paragraph`,
  `heading`, `bulletListItem`, `numberedListItem`, `checkListItem`, `quote`, `callout`,
  `toggleListItem`, `tableParagraph`). `\u{FFFC}`, `"code"`, `"link"`, and line breaks act as hard
  barriers; multi-word prose auto-closes when matches are empty and not loading. Native never
  creates or writes `mentionSearchInline` to Yjs: `[[` and `@` stay ordinary text until commit,
  `/link` consumes the slash token into an ephemeral `slashPageLinkSession` (rebased across remote
  patches via `adjustSlashPageLinkSession`), and Escape (`dismissedInlineTrigger`), empty-session
  Backspace (`cancelEmptySlashPageLinkOnBackspace`), caret move, ranged selection, blur, or IME
  `hasMarkedText` dismisses with zero Yjs writes.
  **Permissions, loading & account scope:** `DocumentAbilities.mention` (default `false`) and
  `DocumentAccess.maxRole` (`(maxRole ?? role) != .reader`) gate `@` mention eligibility via
  `NativeEditorOpen.canMention` and `NativeMentionAccessLoader` (scoped to `(serverOrigin,
  ownerUserID, documentID, signInGeneration)` over `DocsAPIClient.listAccesses(documentID:)`;
  suppressed when `!canMention`, `isLocalDocument`, or `isOffline` before first load; coalesces
  in-flight fetches, caches in memory for the open session, and fails silently per
  `InlineTriggerKey`). `[[` and slash `"Link a page"` are gated by non-empty `serverOrigin` and read
  offline account-scoped candidates from `EditorViewModel.nativePageLinkCandidates()` and
  `recordedNativeDocumentTitles` (keyed by `signedInUser.userID`).
  **Commit, surfaces & localization:** Selecting a candidate dispatches one `.insertInlineObject`
  command replacing `anchor..<caret>` (`interlinkingLinkInline` with `blockId: ""`,
  `disabled: false`, `trigger: "/"` and omitted `title`, immediately priming `documentTitles`;
  `userMentionInline` with `userID` and `fullName`). `NativeMentionPickerView` /
  `NativeInlinePickerCard` / `NativeInlinePickerHost` share Liquid Glass bottom-docked placement
  with `PageLinkPickerView` across `NativeEditorView`, `ColumnEditorScreen` (`ColumnEditorModel`),
  and `TableEditorViewController` (`TableInlinePickerOverlay` above `keyboardLayoutGuide`);
  `NativeTextView` (`keyCommands`, `pressesBegan`, `canPerformAction`) routes `Escape`, `Up`/`Down`,
  and `Return` ahead of slash, table cell navigation/exit, and column exit. Adds 5 localized keys
  (including `.native_editor_open_link` replacing hardcoded `"Open link"`) across all 11
  `Strings+<lang>.swift` tables.
  **Known limits:** Native `@` mention picks do not trigger notification emails (`POST
  /api/v1.0/documents/{id}/mention/` is not called and UI strings make no notification promise);
  `[[` and slash `"Link a page"` rank device-known cached pages only (no live `/documents/` search);
  `@` mention requires at least one online `listAccesses` fetch during the open session (access
  rosters are not persisted across launches); pickers author whole-document interlinks (`blockId:
  ""`) only; and XCUITest synthesized `Escape` does not reliably reach `NativeTextView`, so
  Escape-dismissal precedence is covered in unit tests while simulator UI tests verify tap-outside
  and Backspace dismissal.
  **Tests:** `NativeInlinePickerTests` (13 tests), `NativeInlinePickerCoordinatorTests` (10 tests),
  `NativeEditorInlinePickerViewTests` (7 tests), `NativeInlineObjectTests` (24 tests), and
  `NativeEditorUITests` (6 `--native-inline-objects` tests), alongside PR13c2 additions in
  `NativeMentionAccessLoaderTests`, `ColumnEditorTests`, `TableEditorTests`, `SlashMenuTests`,
  `BlockNoteInlineOracleTests`, `DocumentDecodingTests`, and `ShareModelsTests`.
- **PR14 Native math & diagram blocks + inline math (read/edit/preview/clipboard/recovery).**
  **Model & Yjs:** `SourceBlock` (`mathBlock`, `diagram`) and `SourceTarget` (`block(id:)`,
  `inlineMath(blockID:itemID:)`, synthetic surface id `"\(ownerID)\u{2}\(client).\(clock)"`) in
  `BlockNoteSourceCommands.swift`, plus `NativeInlineObject.math(source:)` (BlockNote `<math>`
  element with zero props and zero/one plain unmarked `YXmlText` child). Familiar `mathBlock`,
  `diagram`, and `<math>` shapes project `.modeled`; unfamiliar shapes fail closed to `.opaque` and
  drop `markdownShadow` (`nil`). Classic projection keeps all three opaque. `BlockNoteSubtreePayload`
  and `BlockNoteInlinePayload` validate plain unmarked content, preserve `<math>` text on copy/paste,
  and reject newlines/control chars/`U+FFFC` inside `<math>`.
  **Auxiliary broadcast root (`doc-<UUID>`):** Docs' `useBroadcastStore.tsx` writes a top-level `Y.Array` named `doc-<UUID>` holding string items (`"broadcast: doc-<UUID>"`); `NativeBlockProjection` (`isKnownAuxiliaryRoot`) preserves it untouched while ignoring it in `canType`, `markdownShadow`, and `firstUnsupportedReason`, and still refuses any other unknown root (`"unsupported root"`).
  **Shadow:** `NativeBlockProjection.markdownShadow(_:interlinkingOrigin:)` and
  `NativeExportMarkdown` match Docs' `y-provider` (which omits `@blocknote/math-block` and
  `@blocknote/diagram-block`), dropping familiar `mathBlock`/`diagram` subtrees (including nested
  descendants) and exporting `.math` as `""` while preserving surrounding prose, marks, and table cells.
  **Engine & Replica:** `DocumentEngine`, `BlockIndex`, `PatchBuilder`, `EngineSelection`,
  `DocumentReplicaSession`, and `NativeEditorSession` add scoped `openSource(_:)` surfaces bound to
  the source element's `YXmlText` (top-level, nested, column, or table cell), projecting it as a
  single plain `codeBlock` (`mathBlock`/`diagram`) or `"paragraph"` (`inlineMath`) surface while keeping outer block previews refreshed and isolating outer
  blocks from text deltas. Awareness (`peerPlace`, `RelativeEditorPosition`) and shared `ReplicaHistory`
  undo/redo adapt between closed and open source views; peer delete/replacement/unfamiliar edits drop
  the scoped surface, auto-dismiss `NativeSourceEditorViewController`, and orphan active IME
  composition into `provisional.json`.
  **Previews, Input & Focused UI:** `NativeSourcePreview` formats exact source previews (preserving
  indentation, blank lines, and empty-source labels) with explicit `"Math source"` / `"Diagram source"`
  headers and Dynamic Type scaling without claiming syntax validation. `NativeSourceEditorViewController`
  / `NativeSourceEditorScreen` (presented from `NativeEditorView`, `ColumnEditorModel`/`ColumnEditorScreen`,
  and `TableEditorViewController`) edits live with Done / `Escape` / `⌘Return`, Return = newline in
  `mathBlock`/`diagram` and exit-after-chip in `.inlineMath`, slash/formatting/link/indent gating in
  `NativeInputCoordinator` (including plain-text paste fallback inside source buffers and newline
  rejection in `.inlineMath`), and IME `provisional.json` recovery. The sheet's text view starts
  below the navigation bar with the code block's header row inside it (a `mathBlock`/`diagram`
  source is a code block, whose header row is drawn above the first line), and a source surface
  shows no code-language control: `mathBlock`/`diagram` are their own block types with no
  language prop (the web's `@blocknote/diagram-block` fixes mermaid), so there is nothing to
  pick. `sourceSlashItems` adds
  `mathBlock` and `inlineMath` (both auto-opening `NativeSourceEditor`), and `diagram` (seeding
  `SourceBlock.defaultDiagramSource`).
  **Tests:** `BlockNoteSourceOracleTests` (13 tests), `DocumentEngineSourceTests` (10 tests),
  `ReplicaSessionSourceTests` (4 tests), `NativeSourcePreviewTests` (7 tests), `NativeSourceEditorTests`
  (21 tests), and `DocumentEngineBoundaryTests.testCoreYjsAndNativeSourceFilesRespectLayerBoundaries`
  (4 tests total in `DocumentEngineBoundaryTests`).
- **PR15 Native shell integration, Reading↔Editing mode handoff, local-create migration, diagnostics, and acceptance suite (PR15a + PR15b).**
  **Shell & Mode Handoff (PR15a):** `NativeEditorPreference.key` (`"schrift.nativeEditor"`) stays `false`
  by default. `EditorView` routes `.loading`, `.native`, and `.preservedUnavailable` through
  `NativeDocumentShellView`, sharing `EditorLoadingPlaceholder`, `EditorBannerStack`, `EditorDocumentHeader`,
  `PagesTreeDrawer` + edge pan, `Share`, `OptionsSheetView`, `OutlinePresentationGate` /
  `OutlineHeldNavigation`, `ConflictSheetView`, `pendingDeleteNotice`, `subpagesSection`, and
  `noteEditorAppeared()` with classic while `NativeTextView` stays the sole vertical `UIScrollView`
  (`headerAccessoryView` via `contentInset.top`, `footerAccessoryView` via `contentInset.bottom`).
  Read-only `.native` routes show `NativeEditUnavailableNotice` (`nativeEditor.editUnavailableNotice`)
  under the header with a localized `NativeEditUnavailableReason` (plus a sanitized, 48-char
  ASCII-bounded `Details:` line for `.unfamiliarContent`, recomputed on `refresh`/`integrateServerState`).
  Existing documents open in Reading mode (`isEditable = false`) over one `NativeEditorSession` &
  `NativeTextSurface`, entering Editing via toolbar `Edit`, text tap, writable card/source tap, or
  new-document `entryIntent` (one-shot header title focus), and exiting via `Done` or `⌘Return`
  after committing marked text and flushing pending saves. A writable page with no blocks mounts the
  canvas in Reading mode too, its first line carrying the grey hint `native.editor.empty_hint`
  (the text view's accessibility value, never a separate element) instead of the empty card; the card
  stays for read-only pages and the preserved root. A tap on the line, or VoiceOver's "Start writing"
  action, enters Editing and focuses the body, which seeds the first empty paragraph — nothing is
  written before that. Only the root document surface (`NativeTextView.isRootDocumentSurface`) shows
  the hint, never a table, column or source surface. Authoritative `title`
  on `EditorViewModel`
  drives native header title saves (`NativeReplicaSaveScheduler` → `enqueueReplica`, `ReplicaSaveAdapter.prepare`
  `batch == nil` title-only path); native conflict resolution wires "Keep my version"
  (`flushPendingSave()` + `resolveConflictKeepingLocal`) and "Keep the server version"
  (`close()` + `resolveConflictKeepingServer` + `reopen()`).
  **Checklists, Shortcuts, Divider & Accessibility (PR15a):** `NativeTextSurface.setChecklistPresentation`
  hides checked items and deeper descendants presentation-only in Reading mode without Yjs writes,
  pairing `ChecklistReadingControls` and `ChecklistSettlingStore` (450 ms settle, 0 ms under Reduce
  Motion) with next-survivor scroll restoration and the all-hidden empty state. `NativeTextView` adds
  `⌘B`/`⌘I`/`⌘U`/`⇧⌘X`/`⌘E`/`⌘K` + Edit-menu formatting actions (disabled in `mathBlock`/`diagram`/`inlineMath`
  source buffers), `NativeInputCoordinator` / `DocumentEngine` add `/divider` and `---`/`***`/`___` + Return
  (`insertDivider`), `NativeEditorView` attaches the localized `BackToTop` accessibility action, and
  `NativeTextView.orderAuxiliarySubviews()` orders header, controls, attachments, footer, `NativeCursorOverlay`,
  and `NativeInlineChipAccessibilityOverlay` deterministically top-to-bottom without disturbing TextKit's
  text element or `headingRotor`.
  **Migration, Offline Guard & Sign-Out Cleanup (PR15a):** `ServerConfigEndpoints` persists Docs 6 capability
  per origin; when the switch is on and Docs 6 org is known, `createLocalDocument` seeds a `localScope`
  native replica, `enqueueReplica` holds saves under `pendingCreates` without sending `localID` over HTTP/WS,
  and `migrateNativeCreatedDocument` verifies `ownerUserID`, copies `localScope` → `serverScope` before
  removing the local draft/replica, and re-keys child creates and `PendingAttachment`s. Offline unmigrated
  Docs-6 Markdown caches keep `canStartEditing == false` (`isNativeLimitedOfflineRead`) when the switch is on,
  and delayed `formattedContent` responses never overwrite an active native route. `RootView.onSignOut` calls
  `purgeCleanNativeReplicasOnSignOut(ownerUserID:)` → `ReplicaStore.purgeCleanReplicas` to remove clean
  synced replicas while retaining dirty, provisional, conflicted, and unreadable ones (`isExcludedFromBackup`
  is `true` while clean and `false` before local appends/provisionals).
  **Diagnostics & Acceptance Suite (PR15b):** `NativeEditorDiagnosticsStore` (`Logger(subsystem: "dev.llun.Schrift", category: "NativeEditor")`
  + `OSSignposter`) records 13 pipeline stages, `ReplicaWorkloadMetrics`, `SurfaceWorkCounters`, and Mach
  `phys_footprint` in a bounded 256-sample / 32-session in-memory ring (active only when both
  `NativeEditorPreference` and the separate default-off `NativeEditorDiagnosticsPreference`
  ("Collect native editor diagnostics" in Profile, shown only when the native editor is on) are enabled,
  cached in memory via an atomic flag, or forced in `NativeEditorTestHostApp` via `setForcedCollection(true)`;
  strictly zero PII, document text, titles, IDs, or hosts; cleared on every account change / `signInGeneration`
  with a `minSessionSeq` floor; copyable as sanitized JSON from Profile when native mode is enabled).
  **Tests & Docs:** `NativeEditorAcceptanceTests` (11 tests: whole-family `72ebe1bb` round-trip, real `state.bin`
  capture, switch-off rollback/retained drafts, classic non-regression, new-doc/subpage & offline local-create
  migration, stale-cache/Docs-6 guard, Reading↔Editing & all-hidden checklist settling, 10-cycle memory
  reclamation & clean-replica sign-out, bounded work counters on 5,000-block & S2 mixed fixtures,
  diagnostics zero-PII/bounded-ring/opt-in/floor invariants, and `timeToEdit` first-responder gating),
  `NativeEditorUITests` shell/diagnostics/S2 `CADisplayLink` `--native-scroll-sampler` tests, and
  [`docs/native-editor-acceptance.md`](../native-editor-acceptance.md).
- **Layers.** `EditorSurface` (model → UI: `applyPatch(BlockPatch)`) sits above
  `DocumentEngine` (confined to its creating domain, PR08a), which borrows the replica and resolves
  intents through `BlockNoteWriter` inside one `.localUser` transaction. Below
  it: `BlockIndex` (block id ↔ container / content element / text children),
  `PatchBuilder` (change signal → patch), and `HeadlessSurface` (an in-memory
  surface, so a test can assert the surface converges to the projection).
  `BlockPatch` changes are `.text(blockID, [TextDelta])`, `.props`,
  `.insert(after:, [BlockSnapshot])`, `.remove([blockID])`,
  `.replaceBlock(blockID, BlockSnapshot)` and `.reset([BlockSnapshot])` (the
  whole surface list, for a root-group replacement, a fragment that was empty
  when the engine attached, a container `id` changed in place, and every
  transaction while the replica is not index-shaped — see the `.text` bullet). Every patch carries a `BlockPatchOrigin`
  (`.localUser`, `.remote`, `.other`) normally taken from the transaction;
  authoritative composition rebuilds always use `.other` and must be applied.
- **Selection is relative.** `setSelection(EditorSelection?)` captures directed
  anchor/head endpoints (`EditorPosition`: block id, UTF-16 offset, `assoc`);
  `currentSelection()` resolves them against the current replica after any
  transaction, including while the surface is deferred. Negative affinity (the
  default) stays with the character before a boundary; non-negative affinity
  follows the character after it. Captures require a canonical index and a
  projectable single-text block, or a simple text-capable element with no
  countable children at offset 0. Empty captures name the element, not a newly
  authored XmlText: left affinity stays at 0 when text appears; non-negative
  affinity follows the end of its sole XmlText. Invalid offsets, including one
  inside a surrogate pair, throw without replacing the previous selection.
  A deleted/replaced/non-addressable text or empty element returns nil, never
  a position in another text under the same block id. These are local captures,
  not an entry point for peer-supplied relative positions.
- **Composition deferral lives in the engine.** `compositionBegan(blockID:at:assoc:)`
  captures an insertion anchor, using the current selection head when `at` is
  omitted; `compositionBegan(blockID:replacing:)` captures both endpoints of a
  same-block replacement range (the native IME path; a peer insertion at either
  boundary stays outside the replaced span, and a peer deletion of the whole span
  collapses it to an insertion). `compositionCommitted(text:)`
  inserts the composed string at the resolved anchor through the writer in one
  `.localUser` transaction and returns update bytes; the durable
  `compositionCommitted(text:commandID:persist:)` holds delivery until `persist`
  journals the `NativeEditCommand` (that id, the current revision, the resolved range)
  and returns `.committed(Data)` or `.orphaned` (the target was deleted or
  replaced: no write, never redirected into a new text under the same block id).
  The commit stamps `nativeCommand`, so its own echo is deduplicated and the durable
  owner's unjournaled-transaction guard does not fire. `compositionCancelled()`
  performs no write and returns the caret to the resolved start of the replaced span.
  `isComposing` reports an active composition. Remote data is accepted **during** a
  composition (`durablyIntegrateRemote` no longer refuses): the queue defers the
  composing block and the surface buffers the rest. The engine signals
  `EditorSurface.setCompositionDeferred(true/false)` (recorded by `HeadlessSurface`).
  While active, changes to that block from every origin, including the commit's
  own write, are discarded from delivery; other blocks keep updating. Commit or
  cancel sends exactly one `.replaceBlock` rebuilt from the current projection,
  never replays stale deltas, then clears deferral. A `.reset` or list operation
  removing/reinserting the composing block defers the whole list and all later
  patches until a fresh `.reset` at completion. If the original text disappears,
  is replaced, or becomes non-addressable, commit drops its write (empty update)
  and still rebuilds. A successful commit collapses selection after the inserted
  UTF-16 text, captured inside the write transaction before observers run; capture
  errors propagate through the error/rebuild path rather than becoming a silent
  nil selection (transactions have no rollback). A new composition can begin from
  the relative selection after commit/cancel inside `applyPatch`: deferral stays continuous
  and generation-tagged completion events cannot end a newer composition.
  All three composition APIs throw `.insideTransaction` before changing anything
  when `doc.transaction` is non-nil or `transactionCleanups` is non-empty. Do not
  call them from transaction bodies or observer/cleanup hooks. Calls from
  `applyPatch` remain supported: the cleanup list is cleared before
  `afterAllTransactions` starts delivery.
  Input offsets are always replica coordinates, not frozen-surface coordinates.
  `setSelection` endpoints and local `replaceText`/`formatRange`/`splitBlock`/
  `joinBlocks`/`setBlockType` targeting a deferred block throw `.composingBlock`
  without mutating the replica (joins check the destination/outer block too).
  Block locks remain through pending rebuild delivery until the final
  `setCompositionDeferred(false)`; a chained restart retains earlier locks.
  When the composition queue requires a whole-list reset, **all blocks** reject
  offset-based input with `.composingBlock`. That global lock is latched through
  logical composition end, pending reset delivery and chained restarts, and clears
  only with the final deferral-complete signal. Ordinary composition keeps the
  per-block lock, allowing input on independently updated blocks.
  Explicit-offset restarts into locked blocks are rejected. Restarts from an
  existing relative selection, without `at:`, remain supported. Queries and
  clearing selection remain allowed. A commit's write is `.localUser`, but its
  rebuild is `.other` so optimistic surfaces always apply discarded peer changes.
  Detach drops deferral without rebuilding, clears selection, and
  rejects all later composition/selection intents as `.detached`. Surface equality
  with projection is intentionally suspended for deferred content, and restored
  on commit/cancel. The engine stays headless; the native IME surface is the
  PR03 composition session above.
- **The engine borrows the replica; it never owns it.** `DocumentCollaborationManager`
  (classic) and `DocumentReplicaSession` (native, PR08b) keep the one-owner rule. `YDoc.onDestroy` fires at the start of `destroy()`
  and the engine detaches there — hooks cleared, buffered patches dropped (even
  mid-delivery, if a surface destroys the replica from `applyPatch`), and every
  later intent throws `DocumentEngineError.detached`. Releasing the engine
  detaches it too (a plain `deinit`, run in the domain that owns engine and replica), so a closed editor leaves no hook on a
  replica that lingers. A replica destroyed by a fail-safe or a suspend teardown must
  never be touched again, and this is the hook that makes that true.
- **Buffer in `afterTransaction`, deliver at `afterAllTransactions`.** A text
  delta is valid only inside the observer phase, and the store there is still
  pre-gc/pre-merge, so the engine only *buffers*. `YDoc.afterAllTransactions`
  (yjs's `'afterAllTransactions'`) fires once the outermost cleanup is done and
  `doc.transaction` is nil; that is where patches reach the surface. A surface
  that opens a transaction from `applyPatch` is queued and drained by the same
  `transact` call, as in yjs. Never deliver from inside `afterTransaction`.
- **Local intents emit patches too.** The engine does not suppress the patch for
  the edit it just made: the same transaction may also carry a format cleanup or
  a split's new block. A patch describes a *transition* from the pre-transaction
  state, so a surface that already applied the keystroke itself (a UIKit text
  view mutates synchronously) must **reconcile**. The rule is the patch's
  `origin`, not content inspection — a displayed `"a"` plus a delete of `0..<1`
  cannot tell "already applied" from "not yet applied". A surface that applied a
  local intent optimistically **skips `.localUser` patches for that edit** (phase
  2 may refine this with command ids); it applies every `.remote` and `.other`
  patch. `.replaceBlock`/`.props`/`.reset` are assignments and idempotent either
  way; `.insert`/`.remove` skip ids already present/absent. `HeadlessSurface`
  never mutates on its own, so it applies every patch regardless of origin and
  equals the projection after each step. The engine has no optimistic overlay (plan
  §2.3); the native surface's PR08b predictions live in `NativeTextSurface`, outside
  the engine, and are confirmed by their stamped echo.
- **`.text` has exactly one shape.** A block, at any depth, gets `.text` only when
  (a) its container holds its content element and at most one nested `blockGroup`,
  (b) its content element has exactly
  one child, an `XmlText`, with no inline nodes — so the projection's runs *are*
  that text — and (c) the only change to it in this transaction is that text (no
  attribute, structural or container change). Everything else touched in a block
  escalates to `.replaceBlock` of that block, rebuilt from its projection:
  several `XmlText` children (no sibling-offset math), a container replaced in place
  under the same id or moved to another depth or parent (the index tracks the
  container `YItem`, not just the id), or
  props and text changed together. `.text` and `.props` also need the block to
  have projected as-is *before* the transaction and after it (readable props, a
  text of strings and marks with readable links; `BlockIndex.Entry.isProjectable`),
  because an opaque block's surface copy came from a `.replaceBlock`. Any group's
  membership change produces `.insert`/`.remove` from the preorder diff (PR06a); a
  reorder is a `.remove` + `.insert` of the moved span (the surface holds an ordered
  list). A change to the
  fragment root, or a root group that is not the one the index recorded, a
  container's `id` changed in place, or any transaction while
  `BlockIndex.isCanonical` is false, is a `.reset` of the projected document.
- **Patch building is O(touched blocks) for text and prop changes.** Classification
  reads `transaction.changed` (the types whose *direct* children changed), so a
  keystroke visits one `XmlText`, folds that one text to check its deltas against
  the index's cached runs (`TextDelta.apply`), re-folds it when the entry
  refreshes, and projects no block. The index holds one cached run list per
  simple block, a second copy of the document's text. The emit loop iterates
  only the touched ids, ordered by the index's position map — never
  `index.order`. A tree change (any group's membership, a container's children:
  split/join/move) rebuilds the index
  — O(document), reading each block's text for `isProjectable` — and projects
  the touched blocks, one at a time (`NativeBlockProjection.projectBlock`); any
  other change only refreshes its own entry. A replica the id-keyed index cannot
  mirror (`BlockIndex.isCanonical` false: several root children, an id-less or
  non-container group child, a repeated id) resets on every transaction until
  it is canonical again. `DocumentEnginePatchCostTests` and
  `DocumentEngineNarrowedRuleTests.testTextTransactionVisitsOnlyTouchedEntries`
  pin the counters and what they measure. A delta that both rewrites text and
  re-marks it escalates to `.replaceBlock` rather than guessing; a format range
  whose marks are not uniform is one `.text` delta per uniform run.
- **`TextDelta.marks` is never `nil` from the builder.** `nil` means *inherit*
  the marks in force at the insertion point (the surface's convenience form for
  a local keystroke). The builder always sends the complete set, including `[]`
  for "no marks in force", in the projection's format-item order — never
  `Dictionary` order.
- **No UIKit, no `NSRange`, in `Engine/`.** The model speaks block-relative
  `Range<Int>` UTF-16 offsets only; `BlockNoteWriter` carries `Range<Int>`
  overloads so the engine never spells `NSRange`. Grep the folder for
  `NSRange`/`NSText*`/`UIView`/`UITextView`/`UndoManager` and expect zero hits.
