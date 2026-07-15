import XCTest

@testable import Schrift

final class DraftSyncDecisionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// The title a `.push` resolved to, ignoring its `PushEvidence`. The title-rule tests assert
    /// on this — the body evidence is another rule's concern (and its own tests').
    private func pushTitle(_ decision: DraftSyncDecision) -> String? {
        if case .push(let title, _) = decision { return title }
        return nil
    }

    // MARK: - Rule 0: the server already holds our local body

    /// The backstop rule 1 cannot provide. A content PATCH whose *response* was lost leaves
    /// the server holding our text while nothing recorded a push — so `lastPushedMarkdown` is
    /// nil and the baseline is stale, and rules 1-2 would raise a **conflict against the
    /// user's own writing**. If the server body already equals ours there is, by definition,
    /// nothing for a push to overwrite.
    func testServerAlreadyHoldingOurLocalBodyIsNeverAConflict() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Old server"),
            lastPushedMarkdown: nil,  // the save threw: nothing was recorded
            localMarkdown: "# My text",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),  // …but the server applied it anyway
            serverMarkdown: "# My text"
        )

        XCTAssertEqual(
            decision, .push(title: "Doc", evidence: .serverHoldsOurBody),
            "the server already holds our body — there is nothing to conflict about")
    }

    /// It must not swallow a *real* conflict: a server body that differs from ours still
    /// conflicts, exactly as before.
    func testRuleZeroDoesNotMaskADivergedServer() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Old server"),
            lastPushedMarkdown: nil,
            localMarkdown: "# My text",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Co-author text"
        )

        XCTAssertEqual(decision, .conflict)
    }

    // MARK: - Rule 1: server body still equals our last push

    func testServerMatchingLastPushedMarkdownPushes() {
        // Even when the baseline would otherwise read as a conflict (server newer,
        // different baseline body), a server body equal to our own last push means
        // the server's most recent writer was us — replay is safe.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Old"),
            lastPushedMarkdown: "# Mine",
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Mine"
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .serverHoldsOurLastPush))
    }

    func testLastPushedMatchesServerOnlyCosmetically() {
        // Canonical-form comparison: our stored push and the server's export differ
        // only by list-marker normalization.
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: "* a\n* b",
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(10_000),
            serverMarkdown: "- a\n- b"
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .serverHoldsOurLastPush))
    }

    func testLastPushedMarkdownNonMatchWithNilBaselineFallsThroughToTolerance() {
        // Rule 1 misses (non-nil, diverged) and there is no baseline, so it falls
        // all the way to rule 3 (tolerance): within → push, beyond → discard.
        let within = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: "# Something else",
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(60),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(within, .push(title: "Doc", evidence: .clockToleranceOnly))

        let beyond = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: "# Something else",
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(beyond, .discardServerWins)
    }

    func testLastPushedMarkdownNonMatchFallsThroughToBaselineRule() {
        // Rule 1 misses (lastPushedMarkdown is non-nil but diverged from the server
        // body), so the baseline rule decides — here, a conflict. Guards the seam
        // between rules 1 and 2: a mutation dropping rule 1's equality check would
        // wrongly .push and this would fail.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body"),
            lastPushedMarkdown: "# Something we pushed earlier",
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# A co-author's edit"
        )
        XCTAssertEqual(decision, .conflict)
    }

    // MARK: - Rule 2: baseline present

    func testServerNotNewerThanBaselinePushes() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base,
            serverMarkdown: "# Whatever"
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .descendsFromBaseline))
    }

    func testServerOlderThanBaselinePushes() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(-500),
            serverMarkdown: "# Different"
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .descendsFromBaseline))
    }

    func testServerNewerButContentMatchesBaselinePushes() {
        // Web title-only rename: the document's `updated_at` bumps forward but the
        // body is unchanged, so the draft still descends from it.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .descendsFromBaseline))
    }

    func testServerNewerBodyMatchesBaselineOnlyCosmetically() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "* one"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "- one"
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .descendsFromBaseline))
    }

    func testServerMovedOnConflicts() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# A co-author's edit"
        )
        XCTAssertEqual(decision, .conflict)
    }

    func testBaselineWithoutTimestampFallsBackToContent() {
        // Baseline from a void-save cache entry (no server timestamp): the date
        // check is skipped and only content decides.
        let matching = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: nil, markdown: "# Base"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base"
        )
        XCTAssertEqual(matching, .push(title: "Doc", evidence: .descendsFromBaseline))

        let diverged = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: nil, markdown: "# Base"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Server changed"
        )
        XCTAssertEqual(diverged, .conflict)
    }

    func testBaselineCarryingDraftNeverDiscards() {
        // Sweep server states well past the tolerance window with matching and
        // diverged bodies: a baseline-carrying draft may only ever be .push or
        // .conflict — never silently discarded (the invariant this stack protects).
        let offsets: [TimeInterval] = [-3600, 0, 120, 3600, 10 * 24 * 3600]
        let bodies = ["# Base", "# Server changed", "* Base"]  // one matches the baseline cosmetically
        for offset in offsets {
            for body in bodies {
                let decision = draftSyncDecision(
                    baseline: DraftBaseline(serverUpdatedAt: base, markdown: "- Base"),
                    lastPushedMarkdown: nil,
                    localMarkdown: "# Local draft body",
                    draftTitle: "Doc",
                    draftUpdatedAt: base,
                    serverTitle: "Doc",
                    serverUpdatedAt: base.addingTimeInterval(offset),
                    serverMarkdown: body,
                    tolerance: 120
                )
                XCTAssertNotEqual(
                    decision, .discardServerWins,
                    "baseline-carrying draft discarded at offset \(offset), body \(body)")
                switch decision {
                case .push(_, let evidence):
                    XCTAssertNotEqual(
                        evidence, .clockToleranceOnly,
                        "a baseline-carrying draft must never fall to the clock rule — that is rule 3's job")
                case .conflict:
                    break
                case .discardServerWins:
                    XCTFail("unreachable: asserted above")
                }
            }
        }
    }

    // MARK: - Rule 3: legacy (nil) baseline → tolerance

    func testLegacyDraftWithinTolerancePushes() {
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(60),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .clockToleranceOnly))
    }

    func testLegacyDraftBeyondToleranceDiscardsServerWins() {
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(decision, .discardServerWins)
    }

    func testLegacyDraftAtExactToleranceBoundaryPushes() {
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftTitle: "Doc",
            draftUpdatedAt: base,
            serverTitle: "Doc",
            serverUpdatedAt: base.addingTimeInterval(120),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .clockToleranceOnly))
    }

    // MARK: - Rule 4: the title a push must carry

    func testRemoteRenameWithUnchangedBodyAdoptsTheServerTitle() {
        // The whole point of the baseline's title. A web rename leaves the body
        // untouched, so rule 2's body-equality branch pushes — and without this, the
        // replay's title PATCH would quietly revert the co-author's rename.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "Old title",
            draftUpdatedAt: base,
            serverTitle: "Renamed on the web",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(pushTitle(decision), "Renamed on the web")
    }

    func testRemoteRenameIsAdoptedOnRuleOnesPushToo() {
        // Rule 1 (the server's body is our own last push) short-circuits the body
        // rules, but a co-author can still have renamed the document after that push.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Old", title: "Old title"),
            lastPushedMarkdown: "# Mine",
            localMarkdown: "# Local body",
            draftTitle: "Old title",
            draftUpdatedAt: base,
            serverTitle: "Renamed on the web",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Mine"
        )
        XCTAssertEqual(pushTitle(decision), "Renamed on the web")
    }

    func testLocalRenameAgainstAnUnchangedServerTitlePushesTheDraftTitle() {
        // Only the user renamed: their rename is the edit being replayed.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "My new title",
            draftUpdatedAt: base,
            serverTitle: "Old title",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(pushTitle(decision), "My new title")
    }

    func testTitlesAlreadyAgreeingPushTheDraftTitle() {
        // The server's title is already the draft's — our own title PATCH landed (or
        // the co-author renamed it to the same thing). Nothing to merge, no conflict.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "My new title",
            draftUpdatedAt: base,
            serverTitle: "My new title",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(pushTitle(decision), "My new title")
    }

    func testBothRenamedDifferentlyConflicts() {
        // Title and body are independent fields, so a merge is the right answer for a
        // one-sided rename — but two different renames is a genuine conflict, and the
        // user has to pick. The body is untouched on both sides here, so nothing but
        // the title can raise this.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "My new title",
            draftUpdatedAt: base,
            serverTitle: "Their new title",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(decision, .conflict)
    }

    func testServerNoNewerThanTheBaselineKeepsTheDraftTitle() {
        // The date short-circuit, and the reason a "keep mine" answer sticks: the
        // resolution advances the draft's baseline to the server state the user chose
        // to overwrite, so the retry after a failed push sees a server no newer than
        // the baseline and pushes their title instead of re-raising the same conflict
        // forever. A server that has not been written since the baseline cannot have
        // been renamed since it either.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "My new title",
            draftUpdatedAt: base,
            serverTitle: "Their new title",
            serverUpdatedAt: base,
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(pushTitle(decision), "My new title")
    }

    func testTitlelessBaselinePushesTheDraftTitleUnchanged() {
        // A draft written before the baseline carried a title (or restored from a
        // pre-title cache entry): nothing to compare against, so behave exactly as
        // before — push the draft's own title, never a conflict.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "Draft title",
            draftUpdatedAt: base,
            serverTitle: "Renamed on the web",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(pushTitle(decision), "Draft title")
    }

    func testMissingServerTitleKeepsTheDraftTitle() {
        // `FormattedDocumentContent.title` is optional. An absent server title is not
        // evidence of a rename, so nothing is adopted and nothing conflicts.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "Old title",
            draftUpdatedAt: base,
            serverTitle: nil,
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(pushTitle(decision), "Old title")
    }

    func testTitleRuleNeverOverridesABodyConflict() {
        // A body conflict is a conflict whatever the titles do — including a title
        // the rule would otherwise adopt.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "Old title",
            draftUpdatedAt: base,
            serverTitle: "Renamed on the web",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# A co-author's edit"
        )
        XCTAssertEqual(decision, .conflict)
    }

    func testLegacyDraftBeyondToleranceStillDiscardsWhateverTheTitlesDo() {
        // Rule 3's discard is for baseline-less drafts, where there is no baseline
        // title either — the title rule must not resurrect one as a conflict.
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "My new title",
            draftUpdatedAt: base,
            serverTitle: "Their new title",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(decision, .discardServerWins)
    }

    func testTitledBaselineWithNoServerDateStillAdoptsARemoteRename() {
        // A baseline restored from a cache entry written by a void save carries a title but
        // no `serverUpdatedAt`, so the date short-circuit is skipped and only the titles
        // decide. Reachable via `restoreLocalContent`'s cache path.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: nil, markdown: "# Base", title: "Old title"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "Old title",
            draftUpdatedAt: base,
            serverTitle: "Renamed on the web",
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base"
        )
        XCTAssertEqual(pushTitle(decision), "Renamed on the web")
    }

    // MARK: - adoptedBaseline

    func testAdoptingATitleAdvancesTheBaselineTitleWithIt() {
        // The draft now descends from the server's title. A baseline left on the old one
        // would make the adopted title look like a *local* rename to the next reconcile, so
        // a second remote rename would read as "both renamed" and raise a conflict the user
        // never created. Only the title moves — the body still descends from the same state.
        let baseline = DraftBaseline(serverUpdatedAt: base, markdown: "# Base", title: "Old title")

        let advanced = adoptedBaseline(baseline, draftTitle: "Old title", pushingTitle: "Renamed on the web")

        XCTAssertEqual(advanced?.title, "Renamed on the web")
        XCTAssertEqual(advanced?.markdown, "# Base", "the body's baseline is untouched")
        XCTAssertEqual(advanced?.serverUpdatedAt, base, "and so is the server timestamp")
    }

    func testKeepingTheDraftTitleAdvancesNothing() {
        // Writing the *user's* rename into the baseline would make the next reconcile see
        // `draftTitle == baselineTitle`, mistake the server's older title for a rename they
        // never made, and adopt it straight back over their own.
        let baseline = DraftBaseline(serverUpdatedAt: base, markdown: "# Base", title: "Old title")

        let unchanged = adoptedBaseline(baseline, draftTitle: "My title", pushingTitle: "My title")

        XCTAssertEqual(unchanged?.title, "Old title", "the baseline still records what the SERVER held")
    }

    func testASecondRemoteRenameAfterAnAdoptIsNotAConflict() {
        // The regression `adoptedBaseline` exists to prevent, end to end through the decision:
        // after adopting "New1", the draft's title IS "New1" and so is its baseline's, so a
        // further rename to "New2" is still a one-sided rename — adopt it, don't ask.
        let afterAdopting = adoptedBaseline(
            DraftBaseline(serverUpdatedAt: base, markdown: "# Base", title: "Old title"),
            draftTitle: "Old title", pushingTitle: "New1")

        let decision = draftSyncDecision(
            baseline: afterAdopting,
            lastPushedMarkdown: nil,
            localMarkdown: "# Local body",
            draftTitle: "New1",
            draftUpdatedAt: base,
            serverTitle: "New2",
            serverUpdatedAt: base.addingTimeInterval(7200),
            serverMarkdown: "# Base"
        )

        XCTAssertEqual(pushTitle(decision), "New2", "a second remote rename is still a merge, not a dialog")
    }

    // MARK: - DraftBaseline decoding

    func testBaselineDecodesFromJSONWrittenBeforeTheTitleFieldExisted() {
        // Drafts and cache entries persisted by an earlier build carry no `title`
        // key. They must decode (as nil) rather than throw — a baseline that fails to
        // decode takes the whole draft with it, and the draft is unsaved work.
        let json = Data(##"{"serverUpdatedAt":1000000000,"markdown":"# Base"}"##.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let baseline = try? decoder.decode(DraftBaseline.self, from: json)

        XCTAssertEqual(baseline?.markdown, "# Base")
        XCTAssertEqual(baseline?.serverUpdatedAt, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertNil(baseline?.title)
    }

    // MARK: - retryableSaveFailure

    func testRetryableFailures() {
        XCTAssertTrue(retryableSaveFailure(.network("offline")))
        XCTAssertTrue(retryableSaveFailure(.rateLimited(retryAfter: 30)))
        XCTAssertTrue(retryableSaveFailure(.rateLimited(retryAfter: nil)))
        XCTAssertTrue(retryableSaveFailure(.server(statusCode: 500)))
        XCTAssertTrue(retryableSaveFailure(.server(statusCode: 503)))
        XCTAssertTrue(retryableSaveFailure(.server(statusCode: 599)))
    }

    func testNonRetryableFailures() {
        XCTAssertFalse(retryableSaveFailure(.sessionExpired))
        XCTAssertFalse(retryableSaveFailure(.forbidden))
        XCTAssertFalse(retryableSaveFailure(.notFound))
        XCTAssertFalse(retryableSaveFailure(.routeNotFound))
        XCTAssertFalse(retryableSaveFailure(.decoding("bad")))
        XCTAssertFalse(retryableSaveFailure(.server(statusCode: 400)))
        XCTAssertFalse(retryableSaveFailure(.server(statusCode: 404)))
        XCTAssertFalse(retryableSaveFailure(.server(statusCode: 409)))
        XCTAssertFalse(retryableSaveFailure(.server(statusCode: 499)))
        XCTAssertFalse(retryableSaveFailure(.server(statusCode: 600)))  // just past the 5xx range
    }
}
