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
  clean. The banner is kept for the single destructive case — a revalidation
  landing while an **editing session** holds the caret — and surfaces once
  editing ends. When the fetched body matches what's on screen, any stale stash
  is now cleared unconditionally.
- `apply(formatted:)` loses its `userInitiated` parameter: passive `load()` and
  explicit `refresh()` apply identical content rules. `refresh()` keeps its one
  real difference — it surfaces failures instead of swallowing them.
- The `.pendingSave` branch reclassifies instead of no-oping: a surviving draft
  (the save failed) means the draft still owns the screen (`.draft`); no draft
  (the save landed) means the screen holds an ordinary clean copy (`.clean`).
- The `.draft` logic moves into a `reconcileDraft` helper, shared by both entry
  points, with the server-wins-beyond-tolerance rule unchanged.

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

Existing banner tests (`testStartEditingClearsPendingUpdate`,
`testApplyPendingUpdateWhileEditingIsANoOp`,
`testApplyPendingUpdateRecomputesRoundTripMode`) were retargeted to reach the
banner through an editing session, which is now the only way to reach it.

## Docs

`CLAUDE.md` and the living spec
[`../specs/2026-07-03-instant-local-doc-content-design.md`](../specs/2026-07-03-instant-local-doc-content-design.md)
were updated in the same change; the spec's "clean content is never swapped out
from under the user on a passive open" rule is withdrawn and recorded as a dated
amendment.
