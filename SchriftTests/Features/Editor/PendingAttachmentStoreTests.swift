import XCTest

@testable import Schrift

/// The queued-photo store: records in UserDefaults, bytes as backup-included files, and the
/// quarantine discipline that keeps a schema slip from destroying photos nothing else holds.
final class PendingAttachmentStoreTests: XCTestCase {
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherDocumentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let localID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let otherLocalID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let owner = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let origin = "https://docs.example.org"

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "PendingAttachmentStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingAttachments-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> PendingAttachmentStore {
        PendingAttachmentStore(userDefaults: defaults, directory: directory)
    }

    private func makeAttachment(
        localID: UUID? = nil,
        documentID: UUID? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_750_000_000),
        ownerUserID: UUID? = nil
    ) -> PendingAttachment {
        PendingAttachment(
            localID: localID ?? self.localID,
            documentID: documentID ?? self.documentID,
            createdAt: createdAt,
            serverOrigin: origin,
            ownerUserID: ownerUserID ?? owner)
    }

    // MARK: - Placeholder URLs

    func testPlaceholderURLRoundTripsThroughTheParser() {
        let url = pendingAttachmentPlaceholderURL(for: localID)
        XCTAssertEqual(url, "schrift-attachment://\(localID.uuidString.lowercased())")
        XCTAssertEqual(pendingAttachmentID(fromPlaceholderURL: url), localID)
    }

    func testPlaceholderParsingRejectsAnythingElse() {
        for candidate in [
            "https://docs.example.org/media/a.png",
            "schrift-attachment://not-a-uuid",
            "schrift-attachment://",
            // A near-miss scheme must not pass: the render branch and the save hold both key
            // off this, so a loose match would hold a document's saves over a plain link.
            "schrift-attachments://\(localID.uuidString)",
            "xschrift-attachment://\(localID.uuidString)",
            "schrift-attachment:\(localID.uuidString)",
            "schrift-attachment://\(localID.uuidString)/extra",
        ] {
            XCTAssertNil(pendingAttachmentID(fromPlaceholderURL: candidate), "should not parse: \(candidate)")
        }
    }

    func testPlaceholderParsingToleratesATrailingSlashAndUppercase() {
        XCTAssertEqual(
            pendingAttachmentID(fromPlaceholderURL: "schrift-attachment://\(localID.uuidString.uppercased())"),
            localID)
        XCTAssertEqual(
            pendingAttachmentID(fromPlaceholderURL: "schrift-attachment://\(localID.uuidString.lowercased())/"),
            localID)
    }

    // MARK: - Records

    func testSavingAndReadingBackARecord() {
        let store = makeStore()
        store.save(makeAttachment())

        let stored = store.attachment(for: localID)
        XCTAssertEqual(stored?.localID, localID)
        XCTAssertEqual(stored?.documentID, documentID)
        XCTAssertEqual(stored?.serverOrigin, origin)
        XCTAssertEqual(stored?.ownerUserID, owner)
        XCTAssertNil(stored?.uploadedURLString)
        XCTAssertNil(stored?.failedAt)
    }

    func testACheckpointAndAFailureStampSurviveARoundTrip() {
        let store = makeStore()
        var attachment = makeAttachment()
        attachment.uploadedURLString = "https://docs.example.org/media/key.jpg"
        attachment.failedAt = Date(timeIntervalSince1970: 1_750_000_500)
        store.save(attachment)

        XCTAssertEqual(store.attachment(for: localID)?.uploadedURLString, "https://docs.example.org/media/key.jpg")
        XCTAssertEqual(
            store.attachment(for: localID)?.failedAt,
            Date(timeIntervalSince1970: 1_750_000_500))
    }

    func testAttachmentsForADocumentAreFilteredAndOldestFirst() {
        let store = makeStore()
        store.save(makeAttachment(localID: otherLocalID, createdAt: Date(timeIntervalSince1970: 1_750_000_100)))
        store.save(makeAttachment(createdAt: Date(timeIntervalSince1970: 1_750_000_000)))
        store.save(
            makeAttachment(
                localID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
                documentID: otherDocumentID))

        XCTAssertEqual(store.attachments(forDocumentID: documentID).map(\.localID), [localID, otherLocalID])
        XCTAssertEqual(store.attachments(forDocumentID: otherDocumentID).count, 1)
    }

    func testEqualTimestampsOrderDeterministicallyByLocalID() {
        let store = makeStore()
        let instant = Date(timeIntervalSince1970: 1_750_000_000)
        store.save(makeAttachment(localID: otherLocalID, createdAt: instant))
        store.save(makeAttachment(createdAt: instant))

        // Sorted by localID string, not by insertion — `values` has no defined order and
        // Swift's `sorted` is not stable, so without the tie-break this would vary per run.
        XCTAssertEqual(store.allAttachments().map(\.localID), [localID, otherLocalID])
    }

    func testRemovingARecordAlsoRemovesItsBytes() {
        let store = makeStore()
        XCTAssertTrue(store.saveData(Data([0xFF, 0xD8, 0xFF]), for: localID))
        store.save(makeAttachment())

        store.remove(localID: localID)

        XCTAssertNil(store.attachment(for: localID))
        XCTAssertNil(store.data(for: localID), "bytes outliving their record would be uncollectable")
    }

    func testRemovingAllForADocumentLeavesOtherDocumentsAlone() {
        let store = makeStore()
        store.save(makeAttachment())
        store.save(makeAttachment(localID: otherLocalID))
        let keeper = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        store.save(makeAttachment(localID: keeper, documentID: otherDocumentID))

        store.removeAll(forDocumentID: documentID)

        XCTAssertTrue(store.attachments(forDocumentID: documentID).isEmpty)
        XCTAssertEqual(store.attachments(forDocumentID: otherDocumentID).map(\.localID), [keeper])
    }

    // MARK: - Bytes

    func testBytesRoundTrip() {
        let store = makeStore()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        XCTAssertTrue(store.saveData(jpeg, for: localID))
        XCTAssertEqual(store.data(for: localID), jpeg)
    }

    func testSaveDataReportsFailureRatherThanPretendingItWrote() throws {
        // A file where the directory should be: `ensureDirectory` sees something at the path
        // and skips creation, so the write fails. The caller must treat false as "not queued" —
        // a record whose bytes do not exist is a placeholder that can never resolve.
        try Data().write(to: directory)
        let store = makeStore()

        XCTAssertFalse(store.saveData(Data([0xFF, 0xD8]), for: localID))
        XCTAssertNil(store.data(for: localID))
    }

    func testPendingBytesAreNotExcludedFromBackup() throws {
        // The one deliberate divergence from the `DocumentContentCacheStore` template it
        // otherwise copies. That cache is excluded because it is re-downloadable; these bytes
        // are the only copy of a photo until the upload lands, exactly like the draft text
        // beside them — so restoring a backup must bring them back.
        let store = makeStore()
        XCTAssertTrue(store.saveData(Data([0xFF, 0xD8]), for: localID))

        let excluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertNotEqual(excluded, true)
    }

    // MARK: - Corruption

    func testRecordsAddedLaterDecodeWhenOlderFieldsAreAbsent() throws {
        // Optional-on-decode discipline: the store decodes the whole blob in one `try?`, so a
        // record written by an older build missing today's fields must not drop every record.
        let json = """
            {"\(localID.uuidString)":{"localID":"\(localID.uuidString)",\
            "documentID":"\(documentID.uuidString)","createdAt":1750000000000,\
            "serverOrigin":"\(origin)"}}
            """
        defaults.set(Data(json.utf8), forKey: "dev.llun.Schrift.pendingAttachments")

        let store = makeStore()
        XCTAssertFalse(store.holdsUnreadableData)
        XCTAssertEqual(store.attachment(for: localID)?.localID, localID)
        XCTAssertNil(store.attachment(for: localID)?.ownerUserID)
    }

    func testUndecodableDataReadsAsUnknownRatherThanEmpty() {
        defaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.pendingAttachments")
        let store = makeStore()

        XCTAssertTrue(store.holdsUnreadableData)
        XCTAssertTrue(store.allAttachments().isEmpty)
    }

    func testTheFirstWriteQuarantinesUndecodableDataInsteadOfOverwritingIt() {
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "dev.llun.Schrift.pendingAttachments")
        let store = makeStore()

        store.save(makeAttachment())

        XCTAssertEqual(defaults.data(forKey: "dev.llun.Schrift.pendingAttachments.unreadable"), corrupt)
        XCTAssertEqual(store.attachment(for: localID)?.localID, localID)
    }

    func testUnreadabilityIsStickyWhileAQuarantineSurvives() {
        defaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.pendingAttachments")
        let store = makeStore()
        store.save(makeAttachment())

        // The live key is healthy again, but the quarantined records are still unaccounted
        // for. A non-sticky flag would let the next launch resume collecting — and every
        // surviving placeholder naming one of those records would become record-less, holding
        // its document's saves with nothing left to explain why.
        XCTAssertTrue(store.holdsUnreadableData)
        XCTAssertTrue(makeStore().holdsUnreadableData, "a freshly constructed store must agree")
    }

    func testASecondCorruptionDoesNotOverwriteTheFirstQuarantine() {
        let first = Data("first corruption".utf8)
        defaults.set(first, forKey: "dev.llun.Schrift.pendingAttachments")
        makeStore().save(makeAttachment())

        defaults.set(Data("second corruption".utf8), forKey: "dev.llun.Schrift.pendingAttachments")
        makeStore().save(makeAttachment(localID: otherLocalID))

        // First corruption wins: a second means the store was already rebuilt after the first,
        // so the earlier blob is the one still holding records nothing else has.
        XCTAssertEqual(defaults.data(forKey: "dev.llun.Schrift.pendingAttachments.unreadable"), first)
    }
}
