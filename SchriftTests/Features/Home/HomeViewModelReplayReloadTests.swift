import XCTest

@testable import Schrift

/// Home's reload after a reconnect replay lands. The reconnect `load()` races the replay's
/// PATCHes and usually re-caches the pre-push list, so the push landing must trigger another.
@MainActor
final class HomeViewModelReplayReloadTests: HomeViewModelTestCase {
    private let documentID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!

    private func stubServer(log: RequestRecorder, savesSucceed: Bool) {
        let id = documentID.uuidString.lowercased()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.contains("formatted-content") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "\(id)", "title": "Old title", "content": "old body",
                         "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
                        """.utf8), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(
                    statusCode: savesSucceed ? 200 : 500, headers: [:], body: Data("{}".utf8), error: nil)
            }
            if url.contains("documents/?") {
                return .init(statusCode: 200, headers: [:], body: Self.emptyFixture, error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
    }

    func testAReplayedDraftPushLandingReloadsTheList() async {
        let log = RequestRecorder()
        let viewModel = makeViewModel(signedInUser: makeSignedInUser())

        // An offline edit: the PATCH fails retryably, leaving a draft and `.pendingSync`.
        stubServer(log: log, savesSucceed: false)
        viewModel.saveCoordinator.enqueue(documentID: documentID, title: "New title", markdown: "new body")
        await waitUntil { viewModel.saveCoordinator.state(for: self.documentID) == .pendingSync }

        // Reconnect: the replay pushes it.
        stubServer(log: log, savesSucceed: true)
        let listGetsBefore = log.count(ofMethod: "GET", urlContaining: "documents/?")
        await viewModel.syncPendingDrafts()
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/content/") > 0 }

        await waitUntil { log.count(ofMethod: "GET", urlContaining: "documents/?") > listGetsBefore }
    }

    func testASyncPassWithNothingToReplayDoesNotReloadTheList() async {
        let log = RequestRecorder()
        let viewModel = makeViewModel(signedInUser: makeSignedInUser())
        stubServer(log: log, savesSucceed: true)

        await viewModel.syncPendingDrafts()

        await waitAndConfirmNever(timeout: 0.8) { log.count(ofMethod: "GET", urlContaining: "documents/?") > 0 }
    }

    func testAnOrdinarySaveDoesNotReloadTheList() async {
        let log = RequestRecorder()
        let viewModel = makeViewModel(signedInUser: makeSignedInUser())
        stubServer(log: log, savesSucceed: true)

        viewModel.saveCoordinator.enqueue(documentID: documentID, title: "Typed", markdown: "typed")
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/content/") > 0 }

        await waitAndConfirmNever(timeout: 0.8) { log.count(ofMethod: "GET", urlContaining: "documents/?") > 0 }
    }
}
