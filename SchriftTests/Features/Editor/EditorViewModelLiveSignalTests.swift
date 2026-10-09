import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelLiveSignalTests: EditorViewModelTestCase {
    // MARK: - live-collaboration change signal

    func testRemoteChangeSignalRevalidatesAndAppliesTheNewBody() async {
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# First")
        await viewModel.load()
        XCTAssertEqual(viewModel.rawMarkdown, "# First")

        // A peer signals a change: a debounced silent revalidation adopts the new
        // clean body (the same rule as pull-to-refresh / on-open revalidation).
        stubLoad(content: "# Second")
        viewModel.noteRemoteChange()
        await waitUntil { viewModel.rawMarkdown == "# Second" }
        XCTAssertFalse(viewModel.updateAvailable, "a clean copy adopts the body directly, no banner")
    }

    func testRemoteChangeSignalBeforeLoadIsANoOp() async {
        let recorder = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# Body", log: recorder)

        // No load() yet — nothing on screen, so the signal must not fetch.
        viewModel.noteRemoteChange()
        await waitAndConfirmNever { recorder.count(ofMethod: "GET", urlContaining: "content") > 0 }
    }

    func testRapidRemoteChangeSignalsCoalesceIntoOneRevalidation() async {
        let recorder = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(80))
        stubLoad(content: "# First", log: recorder)
        await viewModel.load()
        let afterLoad = recorder.count(ofMethod: "GET", urlContaining: "content")

        // Three signals inside one debounce window collapse to a single re-fetch.
        viewModel.noteRemoteChange()
        viewModel.noteRemoteChange()
        viewModel.noteRemoteChange()
        await waitUntil { recorder.count(ofMethod: "GET", urlContaining: "content") == afterLoad + 1 }
        await waitAndConfirmNever { recorder.count(ofMethod: "GET", urlContaining: "content") > afterLoad + 1 }
    }

    func testRemoteChangeSignal404WhileEditingDoesNotTearDown() async {
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# Body")
        await viewModel.load()
        viewModel.startEditing()

        // A peer's edit prompts a revalidation that 404s (a transient hiccup, or a
        // co-author's own permission flap). A background prompt must never eject an
        // active editing session — unlike an on-open / pull-to-refresh 404.
        stubStatus(404)
        viewModel.noteRemoteChange()
        await waitAndConfirmNever { viewModel.isUnavailable }
        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertEqual(viewModel.rawMarkdown, "# Body")
    }

    func testRemoteChangeSignalAfterDeleteIssuesNoFetch() async {
        let recorder = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# Body", log: recorder)
        await viewModel.load()
        let afterLoad = recorder.count(ofMethod: "GET", urlContaining: "content")

        // A late signal after the document is deleted must not fetch (the task is
        // cancelled and `revalidateFromRemoteChange` re-checks `isDocumentDiscarded`).
        viewModel.handleDidDelete()
        viewModel.noteRemoteChange()
        await waitAndConfirmNever { recorder.count(ofMethod: "GET", urlContaining: "content") > afterLoad }
    }
}
