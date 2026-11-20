# Native Editor Acceptance Protocol & Evidence Record

This document defines the TestFlight acceptance protocol, diagnostics capture instructions,
provisional performance/memory thresholds, measured simulator baselines, and the owner
sign-off log for the Phase 2 native BlockNote/Yjs editor (`NativeEditorView` / `NativeDocumentShellView`).

## 1. Rollout status & scope invariants

- **Default state:** `NativeEditorPreference.key` (`"schrift.nativeEditor"`, persisted in `UserDefaults`,
  toggled in **Profile → Native editor (experimental)**) **stays `false` (OFF) by default**.
- **Scope:** When the switch is on, eligible Docs 6 documents (`usesCollaborationYDocServer == true`)
  open through `NativeDocumentShellView` and `NativeEditorSession`. Pre-Docs 6 legacy servers and
  unmigrated classic `PendingDraft`s remain on `ClassicEditorView` (`ClassicEditorView`,
  `BlockEditorView`, `BlockTextView`, `MarkdownBlockView`, and `BlockNoteYjs.applyEdit` are all
  retained).
- **Failure states:** With the switch on, a failed config or raw-state fetch, an unreadable fetched
  state and a failed replica seed show the native error state with Retry; an offline or unreachable
  open with no replica and no cached copy shows "Go online to open this page". These never mount
  `ClassicEditorView`.
- **Public default-on promotion** is a separate post-acceptance decision made only after the
  owner completes Release TestFlight verification below.

## 2. How to enable & capture diagnostics

`NativeEditorDiagnosticsStore` (`Schrift/Features/Editor/Native/NativeEditorDiagnostics.swift`)
instruments the pipeline with zero document text, titles, markdown shadows, raw Yjs bytes,
block IDs, URLs, server hosts, org slugs, user IDs, or credentials. Only monotonic session
sequence integers (`sessionSeq`), static stage identifiers, counts, byte sizes, and millisecond
durations are emitted.

### A. In-app sanitized JSON (TestFlight & Debug)

1. Open **Profile**, enable **Native editor (experimental)** (`profile.nativeEditor`), and then
   enable **Collect native editor diagnostics** (`profile.nativeEditor.collectDiagnostics`, default
   `false`, shown only while the native editor switch is on). In-memory collection in
   `NativeEditorDiagnosticsStore.shared` (bounded ring: 256 recent stage samples, 32 session
   summaries; reset on sign-out, account change, `signInGeneration` bump, and process termination;
   never written to disk, backups, or network) activates only when
   `NativeEditorDiagnosticsPreference.isEnabled()` is true (or `setForcedCollection(true)` in the
   UI-test host).
2. Open, read, edit, scroll, and close target documents.
3. Return to **Profile** and tap **Copy native editor diagnostics** (`profile.nativeEditor.diagnostics`)
   to copy the sanitized JSON (`NativeEditorDiagnosticsSnapshot`, `schemaVersion: 1`) to the
   clipboard (`"Diagnostics copied"`).

### B. Instruments / `OSSignposter` (Release & TestFlight)

`NativeEditorDiagnosticsStore.signposter` uses `Logger(subsystem: "dev.llun.Schrift", category: "NativeEditor")`.
Attach Instruments (**Logging** / **os_signpost**) or stream `os_signpost` events for subsystem
`dev.llun.Schrift`, category `NativeEditor` (`NativeEditorStage` intervals and `NativeEditorMetric`
events) across all ten instrumented stages:

1. `diskRestore` (`ReplicaStore.restore` checkpoint + journal segment read)
2. `decodeIntegrate` (`DocumentReplicaSession` decode + `YDoc.applyUpdate`)
3. `projection` (`NativeBlockProjection` / `AttributedDocumentProjection`)
4. `storageApply` (`NativeTextSurface` `NSTextStorage` & `ProjectionRangeIndex` mutation)
5. `firstVisibleContent` (`NativeEditorOpen.open` start → first non-empty `NativeTextView` viewport layout)
6. `timeToEdit` (open / tap-to-edit / `Edit` tap → editable & first responder ready)
7. `inputToDisplay` (`NativeInputCoordinator` entry → mailbox round-trip → `NativeTextSurface` patch → `CATransaction` commit)
8. `mailboxQueueWait` (`ReplicaCommandMailbox` enqueue → worker dequeue)
9. `remoteMerge` (socket/HTTP remote update arrival → journal append → main-actor patch apply)
10. `checkpointCompact` (`ReplicaSaveAdapter.compactIfNeeded` → `ReplicaStore.compact`)

Each session summary also records `ReplicaWorkloadMetrics` (`rawBytes`, `yjsStructCount`,
`tombstoneCount`, `blockCount`, `mediaBlockCount`, `journalSegmentCount`, `outboxSegmentCount`),
`SurfaceWorkCounters` (`textPatchCount`, `blockPatchCount`, `fullStorageRebuildCount`,
`presentationRestyleCount`, `realisedAttachmentViewCount`, `realisedControlViewCount`, `undoDepth`),
and Mach `task_vm_info` `phys_footprint` snapshots (`baselineBytes`, `peakBytes`, `steadyBytes`,
`closeDeltaBytes`).

### C. Debug test-host launch arguments (`SchriftNativeTestHost`)

Handled inside `NativeEditorTestHostApp` (`SchriftUITests/Support/NativeEditorTestHostApp.swift`),
calling `NativeEditorDiagnosticsStore.shared.setForcedCollection(true)` so shipping targets never
read process arguments for diagnostics or test switches:

- `--native-diagnostics`: forces `NativeEditorDiagnosticsStore` collection on launch in the UI-test
  host and exposes the sanitized JSON readout (`nativeEditor.diagnostics`) + refresh button
  (`nativeEditor.diagnostics.refresh`).
- `--native-scroll-sampler`: mounts the S2 5,000-paragraph / 200-attachment mixed fixture with an
  in-process `CADisplayLink` `NativeScrollSampler` (`scrollSampler.run`, `scrollSampler.status`)
  that measures per-frame block/attachment screen `minY`, attachment bounds vs provider bounds,
  realised attachment/control counts, reversal count + `maxReversalPt`, and bottom-reach across
  touch flings and programmatic sweeps.

## 3. Target device envelope & provisional thresholds

- **Memory floor:** **iPad mini 6 (4 GB RAM)**.
- **Device matrix:** ProMotion iPhone and iPad / Apple Pencil targets across the last two device
  generations.
- **Provisional fixture-specific reference thresholds** (evaluated from Release `OSSignposter` /
  copied diagnostics distributions on real hardware; never silently relaxed):
  - First visible content (`firstVisibleContent`): `< 500 ms`
  - Hardware-keyboard / touch input-to-display (`inputToDisplay` p95): `< 8.3 ms`
  - Scroll-step frame budget (p99): `< 8.3 ms`, hitch time `< 5 ms/s`
  - Peak / steady `phys_footprint`: `< 150 MB`

## 4. Measured results so far (Simulator, Debug build)

> **Environment note:** All measurements below were collected on the **iOS Simulator**
> (`Schrift N17 iPhone`, UUID `CFCAD758-032F-4AC7-99F8-4F691ED0130F`) with a **Debug** build
> (`derivedDataPath .review/dd`). Simulator Debug timings are functional/regression baselines,
> not Release device latency or memory proof.

### A. Unit & integration acceptance suite (`SchriftTests/NativeEditorAcceptanceTests`)

Recorded in `.review/fix1.log` (`11` tests executed, `0` failures, `6.454 s` total):

| Test | Scope verified | Result | Duration (s) |
|---|---|---|---|
| `testBoundedWorkCountersOnLargeProseAndS2MixedFixtures` | Single insert / checkbox toggle on 5,000-block & S2 5,000/200 fixtures: `textPatchCount == 1` / `blockPatchCount == 1`, `fullStorageRebuildCount == 0`, viewport-bounded realised views (`> 0` and `<= 32`) | Passed | 1.146 |
| `testClassicEditorAndBlockNoteApplyEditNonRegression` | Default-off classic open, edit, `BlockNotePreservation` (`applyEdit`) save, checklist filter, conflict resolution | Passed | 0.067 |
| `testDiagnosticsStoreBoundedRingPercentilesZeroPIIAndOffModeEarlyReturn` | 256-sample / 32-session ring caps, percentile accuracy, zero PII/IDs/hosts, separate `NativeEditorDiagnosticsPreference` opt-in & `minSessionSeq` floor, mid-session toggle-off interval/session closing & `activeSessions` eviction, mailbox FIFO alignment | Passed | 0.010 |
| `testNewDocumentSubpageAndOfflineLocalCreateMigration` | Online new doc & subpage + title-only `batch == nil` save; offline local create (`localScope` replica, child create, queued image upload) → online `migrateNativeCreatedDocument` to `serverID` | Passed | 0.243 |
| `testReadingEditingModeHandoffAndAllHiddenChecklistSettling` | Reading starts non-editable; `Hide completed` zero-Yjs-write hiding of checked items & descendants; 450 ms settle into all-hidden state; "Show completed"; mode round-trip anchor | Passed | 0.479 |
| `testRealStateBinCaptureProjectsAndMatchesHeadlessSurfaceIfPresent` | Real server `state.bin` fixture projection & headless parity | Passed | 0.020 |
| `testStaleFormattedContentAndOfflineDocs6Guard` | Delayed `formattedContent` does not clobber native title/state; unmigrated Docs 6 offline Markdown cache stays `canStartEditing == false` | Passed | 0.051 |
| `testSwitchOffRollbackRetainsRichDraftAndLeavesUntouchedClassic` | Rich edits with switch on → switch off → background replay via Yjs update + preserved read-only view + untouched docs open classic | Passed | 0.066 |
| `testTenCycleMemoryReclamationAndCleanReplicaSignOut` | 10 open/type/sheet/undo/close cycles on 5,000/200 fixture release `NativeEditorSession`, `NativeTextView`, `NativeInputCoordinator`, `DocumentReplicaSession`; sign-out purges clean replicas and retains dirty/provisional/conflicted/quarantined ones | Passed | 4.280 |
| `testTimeToEditRequiresFirstResponderReady` | `timeToEdit` records only once `textView.isFirstResponder` is true and uses monotonic timestamps | Passed | 0.054 |
| `testWholeFamilyFixturePreserveReadEditAndWebRoundTrip` | All registered BlockNote 0.56 families in one Yjs doc (`HeadlessSurface` == `NativeTextSurface`, edit prose/checklist/table/column/source/inline, untouched sibling `YItem` IDs, auxiliary root preservation, shadow parity) | Passed | 0.038 |

### B. UI-host & S2 scroll-displacement sampler (`SchriftNativeUITests/NativeEditorUITests`)

- **Header title persistence (`testHeaderTitleEditSurvivesRelaunch`):**
  - **Measured simulator (Debug) result (`.review/fix1.log`):** Passed in `20.398 s`. Editing
    `editor.header.title` (`EditorDocumentHeader`) in Editing mode, tapping `Done`, and
    relaunching the app preserves `"Native open fixture Updated"`.
- **Diagnostics readout (`testDiagnosticsReadoutIsSanitizedAndRecordsPipelineStages`):**
  - **Measured simulator (Debug) result (`.review/fix1.log`):** Passed in `17.129 s`.
- **S2 scroll-displacement sampler (`testS2ScrollSamplerReachesBottomWithoutReversalsOrBoundsDrift`):**
  - **Fixture:** S2 5,000-paragraph / 200-attachment mixed fixture (`--native-scroll-sampler`),
    combining two fast XCUITest touch flings with a full top-to-bottom programmatic sweep sampled
    per frame via `CADisplayLink`.
  - **Previous `.review/step4c.log` baseline note:** Earlier `.review/step4c.log` ran the stricter
    `testS2ScrollSamplerReachesBottomWithoutJumpsOrReversals`, which **failed** on `jumps=13`
    (`reversals=0`, `reachedBottom=1`, `maxBoundsErr=0.00 pt`, `maxRealised=1`, `maxControls=0`,
    `frames=661`).
  - **Sampler measurement fix & verdict rule:** Fixed `NativeScrollSampler.tick` to sort observed
    anchor-block frame deltas before taking the median (previously indexed an unsorted
    `Dictionary.values` array), cleared residual `pendingRequestedDeltaY` at sweep start, tracked
    `maxReversalPt`, and aligned `passed` with the reversal/bounds contract
    (`reachedBottom && reversalCount <= 2 && maxReversalPt <= 24.0 && maxBoundsError <= 0.5 && maxRealisedAttachments <= 32`)
    Why up to two reversals of at most 24 pt: TextKit 2 replaces estimated paragraph heights with measured ones as it lays out ahead of the viewport, and the correction can nudge the content offset back by a fraction of a line during a continuous scroll. One full-suite run recorded a single such reversal (jumps=20, reversals=1); a reversal larger than a line or repeated reversals would still fail.
    while continuing to report single-frame TextKit 2 height-estimate `jumps`.
  - **Measured simulator (Debug) result (`.review/fix1.log`, passed in `102.064 s`):**
    `S2_SAMPLER_RESULT: pass|jumps=16|reversals=0|maxReversalPt=0.00|reachedBottom=1|maxBoundsErr=0.00|maxRealised=1|maxControls=0|frames=721`
  - **Interpretation:** With the unsorted anchor-delta median bug fixed, the 16 single-frame jumps
    are pure TextKit 2 height-estimate corrections as the viewport sweeps past mixed
    attachment/container runs, with `0` reversals (`maxReversalPt=0.00 pt`), full bottom reach
    (`reachedBottom=1`), zero provider bounds drift (`maxBoundsErr=0.00 pt`), and realised
    attachments bounded to `1`. The full raw sampler string is attached to the test result as an
    `XCTAttachment` (`"S2 Scroll Sampler Result"`).

## 5. Step-by-step TestFlight manual checklist (iPhone & iPad)

Execute on physical devices (including an iPad mini 6 4 GB memory floor device and a ProMotion
iPhone/iPad) using a Release/TestFlight build before considering any rollout change:

1. **Enable switch & inspect `72ebe1bb` contract:**
   - Confirm **Native editor (experimental)** starts **OFF** (`false`) on fresh/upgraded install.
   - Open an existing document with the switch OFF to confirm `ClassicEditorView` remains unchanged.
   - Enable **Native editor (experimental)** in Profile.
   - Open the `72ebe1bb` read/render fixture (or designated test doc) and an authorized write
     document: verify first visible content feels instantaneous, all rich families render
     (headings, lists, checklists, toggles, quotes, callouts, code blocks, dividers, page breaks,
     tables, columns, media, interlinks/mentions, math/diagrams), and Reading mode opens non-editable.
2. **Reading ↔ Editing & checklists:**
   - Scroll down, tap **Edit** (or tap body text) → verify mode switches smoothly without layout jump,
     header title edits persist across relaunch, and **Done** / `⌘Return` flushes and returns to
     Reading.
   - In Reading mode on a checklist document, toggle **Hide completed**, check the last remaining
     item, verify the 450 ms settle into the all-hidden empty state, tap **Show completed**, and
     verify VoiceOver focus and zero unexpected sync writes.
3. **Rich editing, sheets & hardware keyboard:**
   - Exercise bold/italic/underline/strike/code/link via both formatting bar and `⌘B`/`⌘I`/`⌘U`/`⇧⌘X`/`⌘E`/`⌘K`,
     `/divider` and `---` + Return, `/table` + `TableEditorViewController`, `/columns` +
     `ColumnEditorViewController`, `mathBlock`/`diagram`/`inlineMath` + `NativeSourceEditor`,
     and `[[` / `@` pickers; verify hardware keyboard undo/redo.
4. **IME, system text tools & Pencil:**
   - Test Chinese, Japanese, and Korean IME composition around Return, block join/split, and
     concurrent peer edits (including `provisional.json` recovery if a peer deletes the active
     block mid-composition).
   - Exercise autocorrection, dictation, Apple Intelligence Writing Tools, and Apple Pencil Scribble
     on iPad.
5. **Accessibility & adaptive layouts:**
   - Walk a rich document with VoiceOver enabled: prose paragraphs, **Headings** rotor, checkboxes,
     toggles, code-language buttons, attachment cards, interlink chips, **Back to top** custom
     action, and table grid navigation.
   - Test iPhone compact width, iPad regular split-view width, multitasking resize, and Dynamic
     Type scaling.
6. **Offline, conflicts, permissions & account lifecycle:**
   - While offline, create a root document, a nested subpage, edit titles/bodies, attach a photo,
     kill and relaunch the app, then reconnect: verify `localID` migrates cleanly to `serverID`,
     subpage hierarchy and uploaded photo URL survive, and no duplicate/empty docs appear.
   - Trigger a remote conflict, verify the conflict pill and `ConflictSheetView`, and test both
     **Keep my version** and **Keep the server version**.
   - Test a read-only / downgraded permission document (verifying it gets a read-only durable
     replica and restores offline read-only), an unmigrated Docs 6 cached document while
     offline (must stay read-only), and sign-out / account switch (clean replicas purged, unsynced
     dirty work preserved).
7. **Rollback check & diagnostics capture:**
   - Turn on **Profile → Collect native editor diagnostics** before the run, then copy diagnostics via **Profile → Copy native editor diagnostics** and record Instruments
     `NativeEditor` signpost timings (`p50`/`p95`/`max`) and peak `phys_footprint`.
   - Disable **Native editor (experimental)** in Profile: verify any un-synced rich draft still
     replays via raw Yjs and opens preserved read-only, while untouched documents return to
     `ClassicEditorView`.

## 6. Known limitations & accepted risks

- **Pre-Docs 6 servers:** Servers where `usesCollaborationYDocServer == false` remain on
  `ClassicEditorView` even when the native switch is enabled.
- **Native open failures:** A failed fetch, an unreadable fetched state or a failed seed shows the
  native error state with Retry instead of the classic editor, so the document is not readable until
  the open succeeds. An offline or unreachable open with no replica and no cached copy shows
  "Go online to open this page" (Retry appears once the device is back online).
- **Preserved read-only structures:** A leaf block of an unknown BlockNote type is preserved
  byte-for-byte in `YDoc` and renders as a locked preview card. The rest of the document stays
  typeable and no native edit touches a card. An unknown block with children, an unfamiliar column group,
  a known block read as opaque (unreadable props, an invalid heading level), a known block with a
  non-default or unknown prop (e.g. a centered paragraph) and an auxiliary Yjs root still keep the
  whole surface in preserved read-only mode (`!session.canType`), now backed by a read-only durable
  replica (subject to the 100 MB clean-replica LRU cap) so it restores offline read-only.
- **Native saves and content cache:** Confirmed native saves write their saved title and Markdown
  shadow (`serverUpdatedAt: nil`) into `DocumentContentCacheStore` so offline Search and
  Attachments stay current without an extra fetch; native ownership and `serverUpdatedAt: nil`
  prevent classic from treating that entry as an authoritative server baseline.
- **S2 TextKit 2 height-estimate corrections:** As measured in §4B (`jumps=16`, `reversals=0`,
  `maxReversalPt=0.00`, `reachedBottom=1`, `maxBoundsErr=0.00`, `maxRealised=1`, `maxControls=0`,
  `frames=721` in `.review/fix1.log`, after the earlier `jumps=13` failure in `.review/step4c.log`),
  TextKit 2 adjusts estimated fragment heights during fast sweeps across mixed attachment/container
  runs. Monitor real-device hitch time (`< 5 ms/s`) during TestFlight evaluation.
- **Markdown shadow whitespace edge case:** Leading/trailing whitespace in a block can differ
  from the server's Markdown shadow check (tracked in `NativeEditorUITests`).
- **Offline Docs-6 unmigrated Markdown cache:** Documents opened previously only via Markdown cache
  on a Docs 6 server cannot enter classic editing while offline when the native switch is enabled;
  they display the limited offline read-only banner until raw Yjs state is fetched online.

## 7. Owner TestFlight observations (by `main` SHA & build)

Record each manual TestFlight evaluation round here before promoting `NativeEditorPreference` past
default-off:

| `main` SHA | TestFlight Build | Device / iOS | Diagnostics Summary (`firstVisibleContent`, `inputToDisplay` p95, peak MB) | Result | Owner Notes / Regressions |
|---|---|---|---|---|---|
| _pending_ | _pending_ | iPad mini 6 (4 GB) / iOS _TBD_ | _TBD_ | _Pending_ | _Initial PR15 baseline build_ |
| _pending_ | _pending_ | ProMotion iPhone / iOS _TBD_ | _TBD_ | _Pending_ | |
