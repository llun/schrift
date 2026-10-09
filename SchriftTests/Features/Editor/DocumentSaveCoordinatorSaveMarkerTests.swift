import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorSaveMarkerTests: DocumentSaveCoordinatorTestCase {
    // MARK: - Save markers (raced-revalidation detection)

    func testSaveMarkerWithNoSaveActivityDoesNotPredate() {
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker))
    }

    func testSaveMarkerTakenWhileASaveIsInFlightPredates() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, saveDelay: 0.2)
        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")

        let marker = coordinator.saveMarker(documentID: documentID)

        XCTAssertTrue(coordinator.mayPredateSave(marker), "in flight when the marker was taken")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertTrue(coordinator.mayPredateSave(marker), "still true once it lands")
    }

    /// The case a "was a save pending?" boolean alone would miss: no save existed
    /// when the fetch was issued, but one started *and settled* while it awaited.
    func testSaveMarkerPredatesASaveThatStartedAndSettledAfterIt() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log)
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker))

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(coordinator.mayPredateSave(marker))
    }

    func testSaveMarkerPredatesAFailedSaveToo() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, contentStatus: 400)
        let marker = coordinator.saveMarker(documentID: documentID)

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertTrue(
            coordinator.mayPredateSave(marker),
            "a failed content PATCH may still have been applied server-side before it errored")
    }

    func testSaveMarkerIsPerDocument() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        let otherID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        stubSavePipeline(log: log)
        let marker = coordinator.saveMarker(documentID: otherID)

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertFalse(coordinator.mayPredateSave(marker), "another document's save is irrelevant")
    }
}
