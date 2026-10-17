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
