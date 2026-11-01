import CoreGraphics
import XCTest

@testable import Schrift

/// The pure pieces of "continue reading": the fingerprint, the capped store, the restore
/// decision and the top-of-screen lookup. The scrolling itself needs a device.
final class ReadingPositionTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!
    private let origin = "https://docs.example.org"

    override func setUp() {
        super.setUp()
        suiteName = "ReadingPositionTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func paragraphs(_ count: Int) -> [EditorBlock] {
        (0..<count).map { EditorBlock(kind: .paragraph, text: "Paragraph number \($0)") }
    }

    private func position(for block: EditorBlock, index: Int, id: UUID? = nil) -> ReadingPosition {
        ReadingPosition(
            blockID: id ?? block.id, fingerprint: readingPositionFingerprint(of: block), blockIndex: index,
            savedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Fingerprint

    func testFingerprintIgnoresCaseAndWhitespaceRuns() {
        let a = EditorBlock(kind: .paragraph, text: "  Hello   World \n")
        let b = EditorBlock(kind: .paragraph, text: "hello world")
        XCTAssertEqual(readingPositionFingerprint(of: a), readingPositionFingerprint(of: b))
        XCTAssertFalse(readingPositionFingerprint(of: a).isEmpty)
    }

    func testFingerprintDiffersForDifferentText() {
        let a = EditorBlock(kind: .paragraph, text: "First")
        let b = EditorBlock(kind: .paragraph, text: "Second")
        XCTAssertNotEqual(readingPositionFingerprint(of: a), readingPositionFingerprint(of: b))
    }

    func testFingerprintIsStableAcrossCalls() {
        // A known value pins the hash: it must not be the per-process `Hashable` seed.
        let block = EditorBlock(kind: .paragraph, text: "a")
        XCTAssertEqual(readingPositionFingerprint(of: block), "af63dc4c8601ec8c")
    }

    func testFingerprintOnlyCoversThePrefixOfLongText() {
        let prefix = String(repeating: "word ", count: 60)
        let a = EditorBlock(kind: .paragraph, text: prefix + "tail one")
        let b = EditorBlock(kind: .paragraph, text: prefix + "tail two")
        XCTAssertEqual(readingPositionFingerprint(of: a), readingPositionFingerprint(of: b))
    }

    func testFingerprintIsEmptyWhenNothingCanNameTheBlock() {
        XCTAssertEqual(readingPositionFingerprint(of: EditorBlock(kind: .divider)), "")
        XCTAssertEqual(readingPositionFingerprint(of: EditorBlock(kind: .paragraph, text: "  \n ")), "")
    }

    func testMediaBlocksAreFingerprintedByURL() {
        let a = EditorBlock(kind: .image(alt: "", url: "https://docs.example.org/media/a.png"))
        let b = EditorBlock(kind: .image(alt: "", url: "https://docs.example.org/media/b.png"))
        XCTAssertFalse(readingPositionFingerprint(of: a).isEmpty)
        XCTAssertNotEqual(readingPositionFingerprint(of: a), readingPositionFingerprint(of: b))
    }

    // MARK: - Key

    func testKeyIsScopedByServerAndDocument() {
        let id = UUID()
        let a = readingPositionKey(serverOrigin: "https://a.example.org", documentID: id)
        let b = readingPositionKey(serverOrigin: "https://b.example.org", documentID: id)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, readingPositionKey(serverOrigin: "https://a.example.org", documentID: UUID()))
    }

    func testKeyNormalisesCaseAndTrailingSlashOfTheOrigin() {
        let id = UUID()
        XCTAssertEqual(
            readingPositionKey(serverOrigin: "https://Docs.Example.org/", documentID: id),
            readingPositionKey(serverOrigin: "https://docs.example.org", documentID: id))
    }

    // MARK: - Capped recording

    func testRecordingKeepsTheMostRecentlySavedEntries() {
        var entries: [String: ReadingPosition] = [:]
        for index in 0..<5 {
            let block = EditorBlock(kind: .paragraph, text: "p\(index)")
            var saved = position(for: block, index: index)
            saved.savedAt = Date(timeIntervalSince1970: Double(index))
            entries = recordingReadingPosition(saved, forKey: "k\(index)", in: entries, limit: 3)
        }
        XCTAssertEqual(Set(entries.keys), ["k2", "k3", "k4"])
    }

    func testRecordingNeverEvictsTheEntryBeingRecorded() {
        let block = EditorBlock(kind: .paragraph, text: "p")
        var newer = position(for: block, index: 0)
        newer.savedAt = Date(timeIntervalSince1970: 100)
        var older = position(for: block, index: 0)
        older.savedAt = Date(timeIntervalSince1970: 1)
        let entries = recordingReadingPosition(older, forKey: "new", in: ["a": newer], limit: 1)
        XCTAssertEqual(Set(entries.keys), ["new"])
    }

    func testRecordingTheSameKeyReplacesItWithoutGrowing() {
        let block = EditorBlock(kind: .paragraph, text: "p")
        var entries = recordingReadingPosition(position(for: block, index: 3), forKey: "k", in: [:], limit: 2)
        entries = recordingReadingPosition(position(for: block, index: 9), forKey: "k", in: entries, limit: 2)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries["k"]?.blockIndex, 9)
    }

    // MARK: - Store

    func testStoreRoundTripsAPosition() {
        let store = ReadingPositionStore(userDefaults: userDefaults, now: { Date(timeIntervalSince1970: 1234.567) })
        let id = UUID()
        let blockID = UUID()
        store.save(blockID: blockID, fingerprint: "abc", blockIndex: 7, serverOrigin: origin, documentID: id)

        let loaded = ReadingPositionStore(userDefaults: userDefaults).position(serverOrigin: origin, documentID: id)
        XCTAssertEqual(loaded?.blockID, blockID)
        XCTAssertEqual(loaded?.fingerprint, "abc")
        XCTAssertEqual(loaded?.blockIndex, 7)
        // Millisecond precision survives the round trip.
        XCTAssertEqual(loaded?.savedAt.timeIntervalSince1970 ?? 0, 1234.567, accuracy: 0.0005)
    }

    func testStoreScopesPositionsByServer() {
        let store = ReadingPositionStore(userDefaults: userDefaults)
        let id = UUID()
        store.save(blockID: UUID(), fingerprint: "abc", blockIndex: 4, serverOrigin: origin, documentID: id)

        XCTAssertNil(store.position(serverOrigin: "https://other.example.org", documentID: id))
        XCTAssertNotNil(store.position(serverOrigin: origin, documentID: id))
    }

    func testStoreCapsEntriesLeastRecentlySavedFirst() {
        var clock = 0.0
        let store = ReadingPositionStore(
            userDefaults: userDefaults, limit: 2,
            now: {
                clock += 1
                return Date(timeIntervalSince1970: clock)
            })
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            store.save(blockID: UUID(), fingerprint: "f", blockIndex: 5, serverOrigin: origin, documentID: id)
        }

        XCTAssertNil(store.position(serverOrigin: origin, documentID: ids[0]))
        XCTAssertNotNil(store.position(serverOrigin: origin, documentID: ids[1]))
        XCTAssertNotNil(store.position(serverOrigin: origin, documentID: ids[2]))
    }

    func testRemoveDropsOnlyThatDocument() {
        let store = ReadingPositionStore(userDefaults: userDefaults)
        let first = UUID()
        let second = UUID()
        store.save(blockID: UUID(), fingerprint: "f", blockIndex: 5, serverOrigin: origin, documentID: first)
        store.save(blockID: UUID(), fingerprint: "f", blockIndex: 5, serverOrigin: origin, documentID: second)

        store.remove(serverOrigin: origin, documentID: first)

        XCTAssertNil(store.position(serverOrigin: origin, documentID: first))
        XCTAssertNotNil(store.position(serverOrigin: origin, documentID: second))
    }

    func testRemovingAnAbsentPositionWritesNothing() {
        let store = ReadingPositionStore(userDefaults: userDefaults)
        store.remove(serverOrigin: origin, documentID: UUID())
        XCTAssertNil(userDefaults.data(forKey: "dev.llun.Schrift.readingPositions"))
    }

    func testRemoveAllClearsEverything() {
        let store = ReadingPositionStore(userDefaults: userDefaults)
        let id = UUID()
        store.save(blockID: UUID(), fingerprint: "f", blockIndex: 5, serverOrigin: origin, documentID: id)
        store.removeAll()
        XCTAssertNil(store.position(serverOrigin: origin, documentID: id))
    }

    func testAnUnreadableBlobReadsAsEmptyAndIsReplacedBySaving() {
        userDefaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.readingPositions")
        let store = ReadingPositionStore(userDefaults: userDefaults)
        let id = UUID()
        XCTAssertNil(store.position(serverOrigin: origin, documentID: id))

        store.save(blockID: UUID(), fingerprint: "f", blockIndex: 5, serverOrigin: origin, documentID: id)
        XCTAssertNotNil(store.position(serverOrigin: origin, documentID: id))
    }

    // MARK: - Restore decision

    func testNothingSavedMeansNothingToRestore() {
        XCTAssertEqual(readingPositionRestore(saved: nil, blocks: paragraphs(10)), .none)
    }

    func testAnEmptyDocumentIsNotRestored() {
        let saved = position(for: EditorBlock(kind: .paragraph, text: "x"), index: 5)
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: []), .none)
    }

    func testRestoresByIDWhenTheBlockIsStillThere() {
        let blocks = paragraphs(10)
        let saved = position(for: blocks[6], index: 6)
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: blocks), .restore(blockID: blocks[6].id))
    }

    func testIDMatchWinsOverAFingerprintMatchElsewhere() {
        var blocks = paragraphs(10)
        blocks[8] = EditorBlock(kind: .paragraph, text: blocks[6].text)
        let saved = position(for: blocks[6], index: 6)
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: blocks), .restore(blockID: blocks[6].id))
    }

    func testFallsBackToTheFingerprintWhenIDsChanged() {
        // A relaunch re-parses the document: every id is new.
        let old = paragraphs(10)
        let saved = position(for: old[6], index: 6)
        let reparsed = old.map { EditorBlock(kind: $0.kind, text: $0.text) }
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: reparsed), .restore(blockID: reparsed[6].id))
    }

    func testFingerprintStillFindsTheBlockAfterContentWasAddedAbove() {
        let old = paragraphs(10)
        let saved = position(for: old[6], index: 6)
        let edited =
            [EditorBlock(kind: .paragraph, text: "New intro"), EditorBlock(kind: .paragraph, text: "Another")]
            + old.map { EditorBlock(kind: $0.kind, text: $0.text) }
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: edited), .restore(blockID: edited[8].id))
    }

    func testDuplicateFingerprintsPickTheOneNearestTheOldIndex() {
        var blocks = paragraphs(12)
        blocks[3] = EditorBlock(kind: .paragraph, text: "Same line")
        blocks[9] = EditorBlock(kind: .paragraph, text: "Same line")
        let saved = ReadingPosition(
            blockID: UUID(), fingerprint: readingPositionFingerprint(of: blocks[9]), blockIndex: 8,
            savedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: blocks), .restore(blockID: blocks[9].id))
    }

    func testNoMatchMeansNoRestore() {
        let saved = position(for: EditorBlock(kind: .paragraph, text: "Gone"), index: 6, id: UUID())
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: paragraphs(10)), .none)
    }

    func testAnEmptyFingerprintNeverMatchesByFingerprint() {
        var blocks = paragraphs(10)
        blocks[5] = EditorBlock(kind: .divider)
        let saved = position(for: EditorBlock(kind: .divider), index: 5, id: UUID())
        XCTAssertEqual(saved.fingerprint, "")
        XCTAssertEqual(readingPositionRestore(saved: saved, blocks: blocks), .none)
    }

    func testABlockNearTheTopIsNotWorthRestoring() {
        let blocks = paragraphs(10)
        XCTAssertEqual(readingPositionRestore(saved: position(for: blocks[0], index: 0), blocks: blocks), .none)
        XCTAssertEqual(readingPositionRestore(saved: position(for: blocks[1], index: 1), blocks: blocks), .none)
        XCTAssertEqual(
            readingPositionRestore(saved: position(for: blocks[2], index: 2), blocks: blocks),
            .restore(blockID: blocks[2].id))
    }

    // MARK: - Update decision

    func testUpdateKeepsTheStoredPositionWhenNothingIsKnown() {
        XCTAssertEqual(readingPositionUpdate(topVisibleBlockID: nil, blocks: paragraphs(10)), .keep)
        XCTAssertEqual(readingPositionUpdate(topVisibleBlockID: UUID(), blocks: paragraphs(10)), .keep)
    }

    func testUpdateClearsWhenTheReaderIsNearTheTop() {
        let blocks = paragraphs(10)
        XCTAssertEqual(readingPositionUpdate(topVisibleBlockID: blocks[1].id, blocks: blocks), .clear)
    }

    func testUpdateSavesBlockFingerprintAndIndex() {
        let blocks = paragraphs(10)
        XCTAssertEqual(
            readingPositionUpdate(topVisibleBlockID: blocks[4].id, blocks: blocks),
            .save(blockID: blocks[4].id, fingerprint: readingPositionFingerprint(of: blocks[4]), blockIndex: 4))
    }

    // MARK: - Top visible block

    func testTopVisibleIsTheFirstBlockStillOnScreen() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 0, y: -300, width: 300, height: 100),
            b: CGRect(x: 0, y: -20, width: 300, height: 100),
            c: CGRect(x: 0, y: 100, width: 300, height: 100),
        ]
        XCTAssertEqual(topVisibleBlockID(in: frames), b)
    }

    func testTopVisibleIsNilWithoutFramesOrWhenEverythingIsAbove() {
        XCTAssertNil(topVisibleBlockID(in: [:]))
        XCTAssertNil(topVisibleBlockID(in: [UUID(): CGRect(x: 0, y: -200, width: 300, height: 100)]))
    }

    @MainActor func testAnchorStoreKeepsTheLastKnownTopBlockThroughAnEmptyReport() {
        let store = EditorScrollAnchorStore()
        let id = UUID()
        store.noteBlockFrames([id: CGRect(x: 0, y: 10, width: 300, height: 100)])
        store.noteBlockFrames([:])
        XCTAssertEqual(store.lastTopVisibleBlockID, id)
    }

    // MARK: - Session

    @MainActor private func makeSession(
        duration: Duration = .seconds(60), documentID: UUID = UUID()
    ) -> (ReadingPositionSession, ReadingPositionStore, UUID) {
        let store = ReadingPositionStore(userDefaults: userDefaults)
        let session = ReadingPositionSession(
            store: store, serverOrigin: origin, documentID: documentID, offerDuration: duration)
        return (session, store, documentID)
    }

    @MainActor func testSessionRestoresOnceAndOffersBackToTop() {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession()
        store.save(
            blockID: UUID(), fingerprint: readingPositionFingerprint(of: blocks[6]), blockIndex: 6,
            serverOrigin: origin, documentID: id)

        XCTAssertEqual(session.beginRestore(blocks: blocks, userHasScrolled: false), blocks[6].id)
        XCTAssertTrue(session.offersBackToTop)
        XCTAssertNil(session.beginRestore(blocks: blocks, userHasScrolled: false))
    }

    @MainActor func testSessionDoesNotSpendItsDecisionOnAnEmptyDocument() {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession()
        store.save(
            blockID: UUID(), fingerprint: readingPositionFingerprint(of: blocks[6]), blockIndex: 6,
            serverOrigin: origin, documentID: id)

        XCTAssertNil(session.beginRestore(blocks: [], userHasScrolled: false))
        XCTAssertEqual(session.beginRestore(blocks: blocks, userHasScrolled: false), blocks[6].id)
    }

    @MainActor func testSessionDoesNotRestoreOnceTheReaderHasScrolled() {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession()
        store.save(
            blockID: UUID(), fingerprint: readingPositionFingerprint(of: blocks[6]), blockIndex: 6,
            serverOrigin: origin, documentID: id)

        XCTAssertNil(session.beginRestore(blocks: blocks, userHasScrolled: true))
        XCTAssertFalse(session.offersBackToTop)
        XCTAssertNil(session.beginRestore(blocks: blocks, userHasScrolled: false))
    }

    @MainActor func testSessionWithNothingSavedOffersNothing() {
        let (session, _, _) = makeSession()
        XCTAssertNil(session.beginRestore(blocks: paragraphs(10), userHasScrolled: false))
        XCTAssertFalse(session.offersBackToTop)
    }

    @MainActor func testDismissEndsTheOffer() {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession()
        store.save(
            blockID: UUID(), fingerprint: readingPositionFingerprint(of: blocks[6]), blockIndex: 6,
            serverOrigin: origin, documentID: id)
        _ = session.beginRestore(blocks: blocks, userHasScrolled: false)

        session.dismissBackToTop()

        XCTAssertFalse(session.offersBackToTop)
    }

    @MainActor func testTheOfferDismissesItself() async {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession(duration: .milliseconds(20))
        store.save(
            blockID: UUID(), fingerprint: readingPositionFingerprint(of: blocks[6]), blockIndex: 6,
            serverOrigin: origin, documentID: id)
        _ = session.beginRestore(blocks: blocks, userHasScrolled: false)
        XCTAssertTrue(session.offersBackToTop)

        for _ in 0..<200 where session.offersBackToTop {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(session.offersBackToTop)
    }

    func testTheOfferAutoDismissesOnlyWithoutVoiceOver() {
        XCTAssertTrue(backToTopAutoDismisses(voiceOverEnabled: false))
        XCTAssertFalse(backToTopAutoDismisses(voiceOverEnabled: true))
    }

    @MainActor func testTheOfferStaysWhileVoiceOverIsRunning() async {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession(duration: .milliseconds(20))
        store.save(
            blockID: UUID(), fingerprint: readingPositionFingerprint(of: blocks[6]), blockIndex: 6,
            serverOrigin: origin, documentID: id)
        XCTAssertEqual(
            session.beginRestore(blocks: blocks, userHasScrolled: false, voiceOverEnabled: true), blocks[6].id)

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(session.offersBackToTop)

        session.dismissBackToTop()
        XCTAssertFalse(session.offersBackToTop)
    }

    @MainActor func testPersistIsIgnoredUntilTheRestoreWasDecided() {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession()

        session.persist(blocks: blocks, topVisibleBlockID: blocks[5].id)

        XCTAssertNil(store.position(serverOrigin: origin, documentID: id))
    }

    @MainActor func testPersistSavesThenClearsWhenTheReaderIsBackAtTheTop() {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession()
        _ = session.beginRestore(blocks: blocks, userHasScrolled: false)

        session.persist(blocks: blocks, topVisibleBlockID: blocks[5].id)
        XCTAssertEqual(store.position(serverOrigin: origin, documentID: id)?.blockIndex, 5)

        session.persist(blocks: blocks, topVisibleBlockID: blocks[0].id)
        XCTAssertNil(store.position(serverOrigin: origin, documentID: id))
    }

    @MainActor func testPersistWithoutAKnownBlockLeavesTheStoredPositionAlone() {
        let blocks = paragraphs(10)
        let (session, store, id) = makeSession()
        store.save(blockID: UUID(), fingerprint: "zzz", blockIndex: 5, serverOrigin: origin, documentID: id)
        _ = session.beginRestore(blocks: blocks, userHasScrolled: false)

        session.persist(blocks: blocks, topVisibleBlockID: nil)

        XCTAssertNotNil(store.position(serverOrigin: origin, documentID: id))
    }
}
