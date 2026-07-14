import XCTest

@testable import Schrift

final class DraftSyncDecisionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

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
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(3600),  // …but the server applied it anyway
            serverMarkdown: "# My text"
        )

        XCTAssertEqual(decision, .push, "the server already holds our body — there is nothing to conflict about")
    }

    /// It must not swallow a *real* conflict: a server body that differs from ours still
    /// conflicts, exactly as before.
    func testRuleZeroDoesNotMaskADivergedServer() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Old server"),
            lastPushedMarkdown: nil,
            localMarkdown: "# My text",
            draftUpdatedAt: base,
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
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Mine"
        )
        XCTAssertEqual(decision, .push)
    }

    func testLastPushedMatchesServerOnlyCosmetically() {
        // Canonical-form comparison: our stored push and the server's export differ
        // only by list-marker normalization.
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: "* a\n* b",
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(10_000),
            serverMarkdown: "- a\n- b"
        )
        XCTAssertEqual(decision, .push)
    }

    func testLastPushedMarkdownNonMatchWithNilBaselineFallsThroughToTolerance() {
        // Rule 1 misses (non-nil, diverged) and there is no baseline, so it falls
        // all the way to rule 3 (tolerance): within → push, beyond → discard.
        let within = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: "# Something else",
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(60),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(within, .push)

        let beyond = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: "# Something else",
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
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
            draftUpdatedAt: base,
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
            draftUpdatedAt: base,
            serverUpdatedAt: base,
            serverMarkdown: "# Whatever"
        )
        XCTAssertEqual(decision, .push)
    }

    func testServerOlderThanBaselinePushes() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(-500),
            serverMarkdown: "# Different"
        )
        XCTAssertEqual(decision, .push)
    }

    func testServerNewerButContentMatchesBaselinePushes() {
        // Web title-only rename: the document's `updated_at` bumps forward but the
        // body is unchanged, so the draft still descends from it.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base body"
        )
        XCTAssertEqual(decision, .push)
    }

    func testServerNewerBodyMatchesBaselineOnlyCosmetically() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "* one"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "- one"
        )
        XCTAssertEqual(decision, .push)
    }

    func testServerMovedOnConflicts() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base body"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
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
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base"
        )
        XCTAssertEqual(matching, .push)

        let diverged = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: nil, markdown: "# Base"),
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
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
                    draftUpdatedAt: base,
                    serverUpdatedAt: base.addingTimeInterval(offset),
                    serverMarkdown: body,
                    tolerance: 120
                )
                XCTAssertNotEqual(
                    decision, .discardServerWins,
                    "baseline-carrying draft discarded at offset \(offset), body \(body)")
                XCTAssertTrue(decision == .push || decision == .conflict)
            }
        }
    }

    // MARK: - Rule 3: legacy (nil) baseline → tolerance

    func testLegacyDraftWithinTolerancePushes() {
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(60),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(decision, .push)
    }

    func testLegacyDraftBeyondToleranceDiscardsServerWins() {
        let decision = draftSyncDecision(
            baseline: nil,
            lastPushedMarkdown: nil,
            localMarkdown: "# Local draft body",
            draftUpdatedAt: base,
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
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(120),
            serverMarkdown: "# Server",
            tolerance: 120
        )
        XCTAssertEqual(decision, .push)
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
