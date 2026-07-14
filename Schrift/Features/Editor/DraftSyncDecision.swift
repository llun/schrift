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
struct DraftBaseline: Codable, Equatable, Sendable {
    let serverUpdatedAt: Date?
    let markdown: String
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
    /// Replay the draft over the server (full-overwrite save), and *why* that is safe.
    case push(PushEvidence)
    /// The server changed under the draft — surface it and ask the user; never
    /// silently pick a winner.
    case conflict
    /// A legacy, baseline-less draft the server has already moved past — the server
    /// wins and the draft is dropped (today's tolerance-rule behavior).
    case discardServerWins
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
func draftSyncDecision(
    baseline: DraftBaseline?,
    lastPushedMarkdown: String?,
    localMarkdown: String,
    draftUpdatedAt: Date,
    serverUpdatedAt: Date,
    serverMarkdown: String,
    tolerance: TimeInterval = pendingDraftClockTolerance
) -> DraftSyncDecision {
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
