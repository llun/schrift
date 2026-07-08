# Remote document edits never reach the app (only the title does)

Date: 2026-07-08
Status: Implemented

## The report

> When a document is updated remotely from the web, it doesn't update in the
> app even on pull-to-refresh. Only the title is updated, not the content.

## Investigation

The server was cleared first, so the bug had to be on the client:

- `GET /documents/{id}/formatted-content/?content_format=markdown` for the
  reported document returned a **fresh title and a fresh body** in the same
  response. Nothing server-side was lagging: the backend's `formatted_content`
  action reads `document.content` straight from object storage on every request
  (`core/api/viewsets.py`), and the title comes from the same row.
- **HTTP caching was ruled out by experiment**, not by assumption. The server
  sends no `Cache-Control`, `Expires`, `ETag`, or `Last-Modified` on this
  endpoint, so a stale `URLCache` hit was the obvious suspect. Three sequential
  `URLSession.shared` GETs against a header-less local endpoint returned three
  distinct bodies — no reuse. `DocsAPIClient` needs no cache-policy change.

That left exactly one code path capable of the reported asymmetry. Enumerating
every branch of `EditorViewModel.apply(formatted:)`, only **one** updates the
title without touching `blocks`/`rawMarkdown`:

| Branch | title | body |
|---|---|---|
| early return (`pendingSave != nil \|\| isDirty`) | — | — |
| `.pendingSave` | — | — |
| `.draft`, within clock tolerance | — | — |
| `.draft`, server newer | ✅ | ✅ |
| `.none` | ✅ | ✅ |
| **`.clean`, body changed, passive load** | **✅** | **❌ (stashed)** |

## Root causes

**1. A clean body was never applied on a passive revalidation.**
`reconcileClean` applied a changed server title *silently and immediately*, but
put the changed server **body** behind the opt-in "Updated" banner
(`pendingFreshContent` + `updateAvailable`) unless `applyDirectly` was set — and
only `refresh()` set it. Since `load()` runs on open *and* on every `.task`
re-fire, a clean document that had been edited on the web rendered its cached
body indefinitely while proudly showing the new title. That is the reported
symptom, verbatim.

The banner protected nothing here: `apply` already returns early when the
document is dirty or has a save pending, so the `.clean` branch only ever runs
when there is **no local work to lose**.

**2. `displaySource` stayed pinned at `.pendingSave` forever.**
`restoreLocalContent()` sets `.pendingSave` when the screen is opened while a
save is in flight for that document (e.g. tap back and reopen a doc you just
finished editing). Once the save landed, `apply`'s early return no longer
triggered — so control reached `case .pendingSave: break`, which did *nothing*,
for the rest of the screen's life. Every later revalidation **and every explicit
pull-to-refresh** silently no-oped: no content, no title, no `lastSyncedAt`, no
error. This is the "even pull to refresh" half of the report.

Reaching that branch actually *proves* the save is no longer pending, so it was
precisely the moment to reconcile, not to give up.

## The fix

- `reconcileClean` installs the fetched body whenever the copy on screen is
  clean. The banner is kept for the destructive case — a revalidation landing
  while an **editing session** holds the caret — and surfaces once editing ends.
  When the fetched body matches what's on screen, any stale stash is now cleared
  unconditionally.
- `apply` loses its `userInitiated` parameter: passive `load()` and explicit
  `refresh()` apply identical content rules. `refresh()` keeps its one real
  difference — it surfaces failures instead of swallowing them.
- The `.pendingSave` branch reclassifies instead of no-oping.
- The `.draft` logic moves into a `reconcileDraft` helper, shared by both entry
  points, with the server-wins-beyond-tolerance rule unchanged.
- `install(...)` clears `focusedBlockID`/`cursorRequest`/`selection`: every
  content swap re-identifies the blocks, and `reconcileDraft`'s server-wins
  install can land mid-edit.

## What review caught (and the first draft got wrong)

Removing the blanket "never swap clean content" rule removed the only thing
protecting two states that had been riding on it. Two independent reviewers
found the same class of bug; both were reproduced as failing tests before being
fixed.

**A. A draft left behind by a failed save was clobbered.** After a save fails
mid-session the draft survives in `PendingDraftStore`, but `pendingSave()` is
`nil`, `isDirty` is `false`, and `displaySource` is still `.clean` — so the next
passive revalidation installed the server body straight over the user's only
copy. `saveNow()` would then enqueue `savedMarkdown` (now the server's own body),
making the loss permanent. Fix: `apply` consults `storedDraft(...)` **before**
switching on `displaySource`; only the clock-tolerance rule may replace a draft.
`hasUnsavedLocalContent` was widened to match, so the "Synced X ago" caption no
longer lies about a failed save.

**B. A revalidation racing our own save installed the pre-save body.** Because
`displaySource == .pendingSave` is only set when a save is in flight at `load()`
entry, the GET is necessarily issued while that PATCH is outstanding — and the
server is free to answer it from the pre-save state. Reclassifying to `.clean`
and reconciling *that* response reverted the screen **and the cache** to the body
the save had just replaced; the next full-overwrite save would push it back to
the server. `case .pendingSave: break` had been silently protecting against this.

Fix: `DocumentSaveCoordinator` gained a `SaveMarker`, snapshotted before the
fetch is issued and checked after it lands (`mayPredateSave`). A response that
may predate a local save is neither installed nor cached; only `displaySource` is
unpinned, so the *next* fetch — which postdates the save — reconciles normally. A
boolean "was a save pending?" is not enough: a save can start **and** settle
inside a single await, so the marker carries a monotonic settled-save count.

**C. Fixing A introduced a third loss.** Routing a `.clean`-with-a-draft screen
into `reconcileDraft` handed it to the clock-tolerance rule — whose else-branch
*discards* the draft. `main` never did that. A passive revalidation then deleted
the user's visible content, and since `install()` resets `savedMarkdown`, the
still-visible "Couldn't save" retry button enqueued the *server's* body and
confirmed the loss.

The comparison mixes clocks: `draft.updatedAt` is the device's at `enqueue`,
`formatted.updatedAt` the server's **last write**. A slow device shrinks the
window from the draft's side, so a genuine remote edit — or even the user's own
partially-landed save (content PATCH applied, title PATCH failed) — can read as
"newer than the draft". (An earlier version of this note claimed a slow clock
alone fires the rule for *any* document; that is wrong, and review caught it.
`formatted.updatedAt` is the last write, not the current server time.)

`pendingDraftClockTolerance`'s own doc comment states the opposite intent. That
rule exists for drafts **stranded by an earlier session** — `recoverDrafts()`'
job, at launch, on a document nobody is looking at. A draft whose save failed
*this* session is a retry candidate with its retry affordance on screen. Fix:
`reconcileDraft` returns early on `saveState == .failed`.

The same round also found `hasUnsavedLocalContent` captioning "Couldn't save"
under a document `becomeUnavailable` had torn off the screen (it deliberately
keeps the draft, because a 403 is revoked access, not a deletion) — now gated on
`hasLoadedContent`.

**D. Round 3 found the pin could freeze the document.** `saveNow()` returned early
whenever `isDirty`, even when the flush enqueued nothing — and typing then undoing
after a failed save leaves exactly that state (`isDirty`, content equal to
`savedMarkdown`). The retry was swallowed, and with C's pin in place the document
was stuck behind its failed save for the whole app session: every pull-to-refresh
silently did nothing, and the reading surface has no retry affordance at all.
`saveNow()` now flushes *and* falls through to the retry.

Round 3 also caught three comments that were simply wrong (including the
clock-skew claim above), a `SaveMarker` that silently accepted a mismatched
`documentID` — making `testSaveMarkerIsPerDocument` pass for the wrong reason —
and a performance regression: `hasUnsavedLocalContent` decoded the whole draft
store out of UserDefaults on every render of a 60 s `TimelineView`.

## The test mock took three attempts

Reproducing B required fixing `MockURLProtocol` first, and the first two fixes
were both wrong:

1. **Original.** Every stub was delivered on URLSession's single protocol thread,
   so a `Thread.sleep` meant to hold one request open silently serialized every
   other in-flight request. The B test passed against knowingly-buggy code — the
   stalled GET was blocking the PATCH it was supposed to race.
2. **`Stub.delay` on a private background queue.** The B test now went red as it
   should. But delivering into a `URLSession` from an arbitrary background thread
   hung the *test process* roughly one run in twenty, and the abort was blamed on
   whichever unrelated slow test happened to be running (`signal kill`). Draining
   the queue in `tearDown` didn't fix it.
3. **`Stub.delay` on the main queue.** Main is the thread the tests already run
   on, is certainly alive, and is serial — so `reset()` cancelling a scheduled work
   item is sufficient, with no drain and no lock. `delay: 0` keeps the original
   synchronous path byte-for-byte, so the other ~600 tests are untouched.

The lesson: a mock that defers work has to defer it somewhere the test owns.
`MockURLProtocol.reset()` (not `stubHandler = nil`) is now the tearDown contract,
and it cancels anything still scheduled.

`waitUntil` also now fails the test on timeout rather than returning silently — a
stalled wait was surfacing as a confusing assertion failure further down. That
immediately exposed four `WebLoginCoordinatorTests` using it as a grace period
before a *negative* assertion, the opposite contract; they moved to a new
`waitAndConfirmNever` helper.

A concurrency lesson came out of the first attempt at
`testSecondLoadSupersedesFirstRevalidation`: keying the stub's response off "which
request arrived first" is not the same as "which `load()` bumped the generation
first". Those agreed only ~60% of the time, and the suite failed 2 runs in 5. The
test now gates the second `load()` on the first request reaching the handler.
**Any new test that overlaps two requests must pin their order explicitly** —
`async let` does not.

## Tests

Each new test was confirmed **red against the pre-fix view model** and green
after (`git stash` on `EditorViewModel.swift` alone):

- `testRevalidateAppliesChangedBodyWhenNotEditing` — the reported bug.
- `testSecondLoadAppliesContentChangedSinceTheFirst` — `.task` re-fire on
  pop-back keeps applying remote edits.
- `testRefreshAppliesRemoteContentAfterAnInFlightSaveCompletes` — root cause 2.
- `testRefreshAfterAFailedSaveKeepsTheDraftOnScreen` — unpinning `.pendingSave`
  must not discard unsaved work.
- `testRevalidateWhileEditingStashesBehindBanner`,
  `testRefreshClearsABannerStashedByAnEditingSession` — the banner's remaining,
  narrower job.
- `testRevalidationAfterAFailedSaveNeverClobbersTheSurvivingDraft` — review
  finding A.
- `testRevalidationRacingOurOwnSaveNeverInstallsThePreSaveBody` — review
  finding B.
- `testRevalidationAfterAFailedSaveKeepsTheDraftEvenWhenTheServerLooksNewer` and
  `testStrandedDraftStillLosesToANewerServerCopyOnRefresh` — the two sides of the
  one branch that legitimately destroys local content.
- `testEditingStartedDuringTheFetchStashesTheResponseBehindTheBanner` — the route
  the shipped app actually takes into the banner (the other banner tests drive
  `load()` twice, which the app never does), so the banner can't quietly become
  unreachable UI.
- `DocumentSaveCoordinatorTests`' `SaveMarker` suite, including the
  started-and-settled-during-one-await case a boolean flag would miss.

Existing banner tests (`testStartEditingClearsPendingUpdate`,
`testApplyPendingUpdateWhileEditingIsANoOp`,
`testApplyPendingUpdateRecomputesRoundTripMode`) were retargeted to reach the
banner through an editing session, which is now the only way to reach it.
`testSecondLoadSupersedesFirstRevalidation` was vacuous — both concurrent loads
returned the same body, so it passed with the generation guard deleted. It now
returns distinct bodies and resolves the superseded fetch last; verified red
against a mutation that removes the guard.

## Docs

`CLAUDE.md` and the living spec
[`../specs/2026-07-03-instant-local-doc-content-design.md`](../specs/2026-07-03-instant-local-doc-content-design.md)
were updated in the same change; the spec's "clean content is never swapped out
from under the user on a passive open" rule is withdrawn and recorded as a dated
amendment.
