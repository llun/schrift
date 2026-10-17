import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelFreshnessTests: HomeViewModelTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func stubLists(_ recorder: RequestRecorder) {
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }
    }

    func testPassiveReloadInsideTheWindowSkipsTheFetchButPullToRefreshStillFetches() async {
        let recorder = RequestRecorder()
        stubLists(recorder)
        let viewModel = makeViewModel(now: { [unowned self] in self.clock })

        await viewModel.loadIfStale()
        let afterFirst = recorder.count(ofMethod: "GET", urlContaining: "documents/")
        XCTAssertGreaterThan(afterFirst, 0)

        clock = clock.addingTimeInterval(10)
        await viewModel.loadIfStale()
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "documents/"), afterFirst)

        await viewModel.refresh()
        XCTAssertGreaterThan(recorder.count(ofMethod: "GET", urlContaining: "documents/"), afterFirst)
    }

    func testMarkingTheListStaleMakesTheNextPassiveReloadFetchInsideTheWindow() async {
        let recorder = RequestRecorder()
        stubLists(recorder)
        let viewModel = makeViewModel(now: { [unowned self] in self.clock })

        await viewModel.loadIfStale()
        let afterFirst = recorder.count(ofMethod: "GET", urlContaining: "documents/")

        clock = clock.addingTimeInterval(5)
        viewModel.markListStale()
        await viewModel.loadIfStale()
        let afterStale = recorder.count(ofMethod: "GET", urlContaining: "documents/")
        XCTAssertGreaterThan(afterStale, afterFirst)

        // The fetch it triggered is fresh again, so a second passive call is skipped.
        await viewModel.loadIfStale()
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "documents/"), afterStale)
    }

    func testPassiveReloadAfterTheWindowFetchesAgain() async {
        let recorder = RequestRecorder()
        stubLists(recorder)
        let viewModel = makeViewModel(now: { [unowned self] in self.clock })

        await viewModel.loadIfStale()
        let afterFirst = recorder.count(ofMethod: "GET", urlContaining: "documents/")

        clock = clock.addingTimeInterval(31)
        await viewModel.loadIfStale()

        XCTAssertGreaterThan(recorder.count(ofMethod: "GET", urlContaining: "documents/"), afterFirst)
    }
}
