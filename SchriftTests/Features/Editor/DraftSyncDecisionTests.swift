import XCTest

@testable import Schrift

final class DraftSyncDecisionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Rule 1: server body still equals our last push

    func testServerMatchingLastPushedMarkdownPushes() {
        // Even when the baseline would otherwise read as a conflict (server newer,
        // different baseline body), a server body equal to our own last push means
        // the server's most recent writer was us — replay is safe.
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Old"),
            lastPushedMarkdown: "# Mine",
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
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(10_000),
            serverMarkdown: "- a\n- b"
        )
        XCTAssertEqual(decision, .push)
    }

    // MARK: - Rule 2: baseline present

    func testServerNotNewerThanBaselinePushes() {
        let decision = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: base, markdown: "# Base"),
            lastPushedMarkdown: nil,
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
            draftUpdatedAt: base,
            serverUpdatedAt: base.addingTimeInterval(3600),
            serverMarkdown: "# Base"
        )
        XCTAssertEqual(matching, .push)

        let diverged = draftSyncDecision(
            baseline: DraftBaseline(serverUpdatedAt: nil, markdown: "# Base"),
            lastPushedMarkdown: nil,
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
    }
}
