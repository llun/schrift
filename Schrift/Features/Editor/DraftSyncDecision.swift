import Foundation

/// The server state a queued offline edit descends from. Carried on `PendingDraft`
/// so the draft-replay path can tell "the server moved on while I was offline" (a
/// real conflict) from "the server only looks different because my own earlier
/// save landed" (not a conflict).
///
/// `serverUpdatedAt` is the server's own `updated_at`, so comparisons against it
/// are server-clock-to-server-clock and — unlike `pendingDraftClockTolerance` —
/// need no slack. It is nil after a void save (the save PATCHes return no server
/// timestamp) or when the baseline was restored from a cache entry written before
/// that field existed; the `markdown` still anchors a content comparison in either
/// case.
///
/// `title` is the server's title at that same moment. A save PATCHes content **and**
/// title, so without it a replay pushes whatever title the draft was made with and
/// silently reverts a co-author's rename — a rename leaves the body untouched, which is
/// precisely rule 2's body-equality `.push`. It is optional for the same reason
/// `serverUpdatedAt` is: drafts and cache entries written before this field existed decode
/// as nil, and a nil title simply means "unknown", which keeps the title rule inert and the
/// legacy behavior exactly as it was.
struct DraftBaseline: Codable, Equatable, Sendable {
    let serverUpdatedAt: Date?
    let markdown: String
    let title: String?

    init(serverUpdatedAt: Date?, markdown: String, title: String? = nil) {
        self.serverUpdatedAt = serverUpdatedAt
        self.markdown = markdown
        self.title = title
    }
}

/// *Why* a replay is safe. The distinction is load-bearing: three of the four rules prove
/// something about **content** (the server holds our body, or ours descends from it), but rule
/// 3 proves nothing at all — it only says the draft's *client* clock is within tolerance of the
/// server's `updated_at`. Releasing an already-surfaced conflict on that basis pushed a full
/// overwrite over the co-author with no prompt, because the user typing *after* the conflict
/// landed bumps the draft's clock past the server's and rule 3 then starts answering `.push`.
enum PushEvidence: Equatable, Sendable {
    /// Rule 0: the server body already **equals our local body** — a push overwrites nothing.
    case serverHoldsOurBody
    /// Rule 1: the server body is what **we last pushed** — its most recent writer was us.
    case serverHoldsOurLastPush
    /// Rule 2: the draft still **descends from the server** (baseline evidence).
    case descendsFromBaseline
    /// Rule 3: **no content evidence at all** — only the legacy client-vs-server clock
    /// tolerance, for a baseline-less draft. Never sufficient to release a standing conflict.
    case clockToleranceOnly
}

/// What to do with a queued draft when reconciling it against the current server copy.
enum DraftSyncDecision: Equatable {
    /// Replay the draft over the server (full-overwrite save), PATCHing `title`, and *why*
    /// that replay is safe (`evidence`).
    ///
    /// The title is part of the decision — not the caller's to choose — because a save
    /// writes the title too: it is the draft's own, or the **server's** when a remote
    /// rename must be adopted (see `draftTitleOutcome`). Every replay site takes it from
    /// here, so none of them can push a stale title. `evidence` says which rule proved the
    /// push safe; a standing conflict may be released only on *content* evidence
    /// (`PushEvidence` / the editor's `releaseConflictIfProven`).
    case push(title: String, evidence: PushEvidence)
    /// The server changed under the draft — surface it and ask the user; never
    /// silently pick a winner.
    case conflict
    /// A legacy, baseline-less draft the server has already moved past — the server
    /// wins and the draft is dropped (today's tolerance-rule behavior).
    case discardServerWins
}

/// Which title a replay must carry once the body rules have said `.push`. Private: the only
/// sanctioned way to ask is `draftSyncDecision`, which returns the title *with* the push it
/// belongs to — a caller that could take one without the other could push a title the
/// decision never sanctioned.
private enum DraftTitleOutcome: Equatable {
    /// Push the draft's own title (nothing to merge, or nothing known to merge against).
    case keepDraft
    /// A co-author renamed the document and the user did not — take their title.
    case adoptServer(String)
    /// Both renamed, differently: the user has to pick.
    case conflict
}

/// The baseline a draft descends from once its replay's title has been resolved.
///
/// **Adopting the server's title advances the baseline's title with it.** The draft now
/// descends from *that* server title, and a baseline left on the old one would make the
/// adopted title look like a **local** rename to the next reconcile — so a *second* remote
/// rename would read as "both renamed, differently" and raise a `.conflict` the user never
/// created, holding their body push behind a dialog about a title they never touched.
///
/// Nothing else moves: the body still descends from the same server state, so `markdown`
/// and `serverUpdatedAt` are untouched. A push that keeps the draft's own title advances
/// nothing at all — writing the *user's* rename into the baseline would make the next
/// reconcile see `draftTitle == baselineTitle`, decide the server's (older) title was a
/// rename they never made, and adopt it straight back over their own.
func adoptedBaseline(_ baseline: DraftBaseline?, draftTitle: String, pushingTitle: String) -> DraftBaseline? {
    guard let baseline, pushingTitle != draftTitle else { return baseline }
    return DraftBaseline(
        serverUpdatedAt: baseline.serverUpdatedAt, markdown: baseline.markdown, title: pushingTitle)
}

/// Canonical markdown for equality comparisons: the same normalization the
/// editor's own `serverChanged` uses (parse → serialize), so cosmetic differences
/// between the server's markdown export and ours (`*`→`-`, list renumbering) never
/// read as a change.
func canonicalMarkdown(_ markdown: String) -> String {
    serializeMarkdown(parseEditorBlocks(markdown))
}

/// Decides how to reconcile a queued draft with the server copy fetched at sync time.
///
/// Rules, applied in order (every markdown comparison is canonical-form):
///
/// 0. The server body **already equals our local body** → there is nothing to conflict
///    about: replaying is a content no-op (it still lands the title). This is the backstop
///    for the case rule 1 cannot see — a content PATCH whose *response* was lost. The save
///    threw, so nothing recorded a push, but the server applied it anyway; without this the
///    next reconcile would compare our own text against a stale baseline and raise a
///    **conflict against the user's own writing**. It can never destroy a real conflict:
///    if the bodies are equal there is nothing for a push to overwrite.
/// 1. The server body still equals what we last pushed → the server's most recent
///    writer was us, so replaying is safe. This kills false conflicts right after
///    our own mid-session saves, including across a relaunch: `DocumentSaveCoordinator`
///    persists `lastPushedMarkdown` onto the draft (`enqueue`/`finish`), so a draft
///    written after a confirmed save carries it here even on a fresh process.
/// 2. A baseline is present (the draft was made from a known server state): the
///    draft still descends from the server copy when the server is no newer than
///    the baseline (`serverUpdatedAt <= baseline.serverUpdatedAt`, when the baseline
///    carries a timestamp) **or** its body still equals the baseline body (a web
///    title-only rename bumps `updated_at` without touching content) → `.push`;
///    otherwise the server genuinely moved on → `.conflict`. A baseline-carrying
///    draft is **never** silently discarded.
/// 3. No baseline (a legacy draft written before the field existed): fall back to
///    today's device-vs-server clock tolerance — within the window replay, beyond
///    it the server wins and the draft is dropped.
/// 4. Every `.push` then resolves **which title** it carries (`draftTitleOutcome`):
///    title and body are independent fields, so a one-sided rename is merged, not
///    dialogued — but two different renames escalate the push to a `.conflict`. A
///    `.conflict` or `.discardServerWins` from the body rules is never revisited: a
///    body conflict is a conflict whatever the titles do, and a baseline-less draft
///    has no baseline title to compare against anyway.
func draftSyncDecision(
    baseline: DraftBaseline?,
    lastPushedMarkdown: String?,
    localMarkdown: String,
    draftTitle: String,
    draftUpdatedAt: Date,
    serverTitle: String?,
    serverUpdatedAt: Date,
    serverMarkdown: String,
    tolerance: TimeInterval = pendingDraftClockTolerance
) -> DraftSyncDecision {
    switch draftSyncBodyDecision(
        baseline: baseline,
        lastPushedMarkdown: lastPushedMarkdown,
        localMarkdown: localMarkdown,
        draftUpdatedAt: draftUpdatedAt,
        serverUpdatedAt: serverUpdatedAt,
        serverMarkdown: serverMarkdown,
        tolerance: tolerance)
    {
    case .conflict:
        return .conflict
    case .discardServerWins:
        return .discardServerWins
    case .push(let evidence):
        // The body rules proved the push safe and *why* (`evidence`); the title rule decides
        // which title it carries. The evidence rides through unchanged — it is a fact about
        // the body, and a one-sided rename does not weaken it.
        switch draftTitleOutcome(
            baseline: baseline, draftTitle: draftTitle, serverTitle: serverTitle, serverUpdatedAt: serverUpdatedAt)
        {
        case .keepDraft:
            return .push(title: draftTitle, evidence: evidence)
        case .adoptServer(let serverTitle):
            return .push(title: serverTitle, evidence: evidence)
        case .conflict:
            return .conflict
        }
    }
}

/// Rules 0–3 in isolation: the body half of the decision. It carries the `PushEvidence` but
/// no title — its own type, rather than a `DraftSyncDecision` with a placeholder title, so
/// there is no moment at which a `.push` exists without the title it must actually PATCH.
private enum DraftSyncBodyDecision {
    case push(PushEvidence)
    case conflict
    case discardServerWins
}

private func draftSyncBodyDecision(
    baseline: DraftBaseline?,
    lastPushedMarkdown: String?,
    localMarkdown: String,
    draftUpdatedAt: Date,
    serverUpdatedAt: Date,
    serverMarkdown: String,
    tolerance: TimeInterval
) -> DraftSyncBodyDecision {
    let serverCanonical = canonicalMarkdown(serverMarkdown)

    if canonicalMarkdown(localMarkdown) == serverCanonical {
        return .push(.serverHoldsOurBody)
    }

    if let lastPushedMarkdown, canonicalMarkdown(lastPushedMarkdown) == serverCanonical {
        return .push(.serverHoldsOurLastPush)
    }

    if let baseline {
        if let baselineDate = baseline.serverUpdatedAt, serverUpdatedAt <= baselineDate {
            return .push(.descendsFromBaseline)
        }
        if canonicalMarkdown(baseline.markdown) == serverCanonical {
            return .push(.descendsFromBaseline)
        }
        return .conflict
    }

    if serverUpdatedAt <= draftUpdatedAt.addingTimeInterval(tolerance) {
        return .push(.clockToleranceOnly)
    }
    return .discardServerWins
}

/// Which title a `.push` carries. Titles are independent of the body, so the answer is a
/// **merge** wherever only one side moved — a remote rename must not raise a dialog, and must
/// not be reverted either.
///
/// Let `b` be the baseline's title (the server title the draft descends from), `d` the
/// draft's, `s` the server's now:
///
/// - `b` or `s` unknown → keep `d`. A pre-title draft/cache entry decodes `b` as nil and
///   `FormattedDocumentContent.title` is optional; neither is evidence of a rename, so the
///   rule stays inert and legacy drafts behave exactly as they did.
/// - The server is no newer than the baseline → keep `d`. It cannot have been renamed since a
///   baseline it hasn't been written since. This is also what makes a **"keep mine" answer
///   stick**: that resolution advances the draft's baseline to the server state the user chose
///   to overwrite, so the retry after a failed push lands here rather than re-raising the
///   identical title conflict forever.
/// - `s == d` → keep `d`. The titles already agree (our own title PATCH landed, or the
///   co-author renamed it to the same thing).
/// - `d == b` → **adopt `s`**: only the server renamed, and the user's draft has no claim on
///   the title. Reverting it here is the bug this rule exists to fix.
/// - `s == b` → keep `d`: only the user renamed, and that rename is the edit being replayed.
/// - otherwise → `.conflict`: both renamed, differently.
private func draftTitleOutcome(
    baseline: DraftBaseline?,
    draftTitle: String,
    serverTitle: String?,
    serverUpdatedAt: Date
) -> DraftTitleOutcome {
    guard let baseline, let baselineTitle = baseline.title, let serverTitle else { return .keepDraft }
    if let baselineDate = baseline.serverUpdatedAt, serverUpdatedAt <= baselineDate { return .keepDraft }
    if serverTitle == draftTitle { return .keepDraft }
    if draftTitle == baselineTitle { return .adoptServer(serverTitle) }
    if serverTitle == baselineTitle { return .keepDraft }
    return .conflict
}

/// Whether a failed content save should be **queued for later sync** rather than
/// surfaced as a hard failure. Transient/transport problems are retryable; anything
/// the server rejected on the merits, or an expired session, is not — it would just
/// fail again on every resync trigger, so it stays a visible `.failed`.
///
/// Wired into `DocumentSaveCoordinator.finish()`, which routes a retryable failure
/// to the `.pendingSync` save state.
func retryableSaveFailure(_ error: DocsAPIError) -> Bool {
    switch error {
    case .network, .rateLimited:
        return true
    case .server(let statusCode):
        return (500..<600).contains(statusCode)
    case .sessionExpired, .forbidden, .notFound, .routeNotFound, .decoding:
        return false
    }
}
