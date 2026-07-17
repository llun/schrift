import XCTest

@testable import Schrift

/// Unit tests for the struct store's primitives (`YStructStore.swift`) and its
/// delete set (`YDeleteSet.swift`) — the pieces `YIntegrationTests` exercises only
/// indirectly, through whole updates.
final class YStructStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(client: UInt = 1, lengths: [UInt]) -> YStructStore {
        let store = YStructStore()
        var clock: UInt = 0
        let list = YStructList()
        for length in lengths {
            list.structs.append(YGC(id: YID(client: client, clock: clock), length: length))
            clock += length
        }
        store.clients[client] = list
        return store
    }

    private func item(client: UInt, clock: UInt, text: String) -> YItem {
        YItem(
            id: YID(client: client, clock: clock), left: nil, origin: nil, right: nil,
            rightOrigin: nil, parent: .type(YType()), parentSub: nil,
            content: .string(Array(text.utf16)))
    }

    // MARK: - getState

    func testGetStateIsTheNextUnusedClock() {
        let store = makeStore(lengths: [3, 2, 5])
        XCTAssertEqual(store.getState(1), 10)
        XCTAssertEqual(store.getState(99), 0, "an unknown client starts at clock 0")
    }

    // MARK: - addStruct

    func testAddStructRejectsANonContiguousStruct() {
        // A client's structs must tile its clock range exactly. yjs throws
        // `unexpectedCase` on a gap or overlap, because every later binary search
        // assumes the invariant.
        let store = makeStore(lengths: [3])
        XCTAssertThrowsErrorOfType(.unexpectedCase) {
            try store.addStruct(YGC(id: YID(client: 1, clock: 5), length: 1))  // gap: 3 → 5
        }
        XCTAssertThrowsErrorOfType(.unexpectedCase) {
            try store.addStruct(YGC(id: YID(client: 1, clock: 2), length: 1))  // overlap
        }
    }

    func testAddStructAppendsAContiguousStruct() throws {
        let store = makeStore(lengths: [3])
        try store.addStruct(YGC(id: YID(client: 1, clock: 3), length: 2))
        XCTAssertEqual(store.getState(1), 5)
    }

    func testAddStructStartsANewClientAtAnyClock() throws {
        // yjs checks contiguity only against an *existing* last struct, so the first
        // struct for a client is unchecked. The driver's `offset < 0` guard is what
        // keeps a non-zero first clock from ever reaching here.
        let store = YStructStore()
        try store.addStruct(YGC(id: YID(client: 7, clock: 0), length: 1))
        XCTAssertEqual(store.getState(7), 1)
    }

    // MARK: - findIndexSS

    func testFindIndexSSFindsTheStructContainingAClock() throws {
        let store = makeStore(lengths: [3, 2, 5])  // clocks 0..2, 3..4, 5..9
        let structs = store.clients[1]!.structs
        for (clock, expected) in [(UInt(0), 0), (2, 0), (3, 1), (4, 1), (5, 2), (9, 2)] {
            XCTAssertEqual(
                try YStructStore.findIndexSS(structs, clock), expected,
                "clock \(clock) should be in struct \(expected)")
        }
    }

    func testFindIndexSSThrowsForAClockPastTheEnd() {
        // yjs: "Always check state before looking for a struct in StructStore.
        // Therefore the case of not finding a struct is unexpected."
        let store = makeStore(lengths: [3])
        XCTAssertThrowsErrorOfType(.unexpectedCase) {
            _ = try YStructStore.findIndexSS(store.clients[1]!.structs, 99)
        }
    }

    func testFindIndexSSThrowsOnAnEmptyList() {
        XCTAssertThrowsErrorOfType(.unexpectedCase) { _ = try YStructStore.findIndexSS([], 0) }
    }

    func testFindIndexSSHandlesManyStructs() throws {
        // The pivot only picks a starting probe; the search must still be correct for
        // every clock in a long, uneven list.
        let lengths: [UInt] = (1...200).map { UInt($0 % 7 + 1) }
        let store = makeStore(lengths: lengths)
        let structs = store.clients[1]!.structs
        var clock: UInt = 0
        for (expected, length) in lengths.enumerated() {
            for offset in 0..<length {
                XCTAssertEqual(try YStructStore.findIndexSS(structs, clock + offset), expected)
            }
            clock += length
        }
    }

    func testPivotIndexStaysInRangeForDegenerateDenominators() {
        // yjs computes the pivot as `floor((clock / (midclock + len - 1)) * right)` in
        // floating point. A single struct at clock 0 length 1 makes the denominator 0
        // → Infinity/NaN → `structs[NaN]` throws in JS. Swift would trap converting
        // that to Int, so the pivot clamps instead and lets the search decide.
        XCTAssertEqual(YStructStore.pivotIndex(clock: 5, midclock: 0, midLength: 1, right: 0), 0)
        XCTAssertEqual(YStructStore.pivotIndex(clock: 0, midclock: 0, midLength: 1, right: 0), 0)
        // A huge wire clock must not overflow the Int conversion.
        XCTAssertEqual(
            YStructStore.pivotIndex(clock: UInt.max, midclock: 0, midLength: 2, right: 3), 3)
        // A normal proportional probe.
        XCTAssertEqual(YStructStore.pivotIndex(clock: 50, midclock: 90, midLength: 10, right: 10), 5)
    }

    // MARK: - splitItem

    func testSplitItemWiresTheRightHalfIntoTheList() throws {
        let doc = YDoc(clientID: 9, gc: false)
        let transaction = YTransaction(doc: doc, local: false)
        let left = item(client: 1, clock: 0, text: "hello")
        let right = try YStructStore.splitItem(transaction, leftItem: left, diff: 2)

        XCTAssertEqual(left.length, 2)
        XCTAssertEqual(left.content, .string(Array("he".utf16)))
        XCTAssertEqual(right.id, YID(client: 1, clock: 2))
        XCTAssertEqual(right.length, 3)
        XCTAssertEqual(right.content, .string(Array("llo".utf16)))
        XCTAssertEqual(right.origin, YID(client: 1, clock: 1), "origin is the left half's lastId")
        XCTAssertTrue(left.right === right)
        XCTAssertTrue(right.left === left)
        XCTAssertTrue(
            transaction.mergeStructs.contains { $0 === right },
            "the right half is a merge candidate for cleanup")
    }

    func testSplitItemDoesNotSetTheLeftHalfsRightOrigin() throws {
        // yjs is explicit: "do not set leftItem.rightOrigin as it will lead to
        // problems when syncing". It is also what lets the two halves merge back.
        let doc = YDoc(clientID: 9, gc: false)
        let transaction = YTransaction(doc: doc, local: false)
        let left = item(client: 1, clock: 0, text: "hello")
        left.rightOrigin = nil
        _ = try YStructStore.splitItem(transaction, leftItem: left, diff: 2)
        XCTAssertNil(left.rightOrigin)
    }

    func testSplitItemCarriesTheDeletedFlagToTheRightHalf() throws {
        let doc = YDoc(clientID: 9, gc: false)
        let transaction = YTransaction(doc: doc, local: false)
        let left = item(client: 1, clock: 0, text: "hello")
        left.markDeleted()
        let right = try YStructStore.splitItem(transaction, leftItem: left, diff: 2)
        XCTAssertTrue(right.deleted, "half of a deleted item is still deleted")
    }

    // MARK: - Delete set

    func testSortAndMergeCoalescesOverlappingAndAdjacentRanges() {
        var ds = YDeleteSet()
        ds.add(client: 1, clock: 5, length: 2)  // 5..6
        ds.add(client: 1, clock: 0, length: 3)  // 0..2
        ds.add(client: 1, clock: 3, length: 2)  // 3..4 — adjacent to both
        ds.sortAndMerge()
        XCTAssertEqual(ds.clients[1], [YDeleteItem(clock: 0, len: 7)])
    }

    func testSortAndMergeKeepsDisjointRangesApart() {
        var ds = YDeleteSet()
        ds.add(client: 1, clock: 10, length: 1)
        ds.add(client: 1, clock: 0, length: 2)
        ds.sortAndMerge()
        XCTAssertEqual(ds.clients[1], [YDeleteItem(clock: 0, len: 2), YDeleteItem(clock: 10, len: 1)])
    }

    func testSortAndMergeKeepsTheLongerRangeWhenOneContainsAnother() {
        // `max(left.len, right.clock + right.len - left.clock)` — a nested range must
        // not shorten the one containing it.
        var ds = YDeleteSet()
        ds.add(client: 1, clock: 0, length: 10)
        ds.add(client: 1, clock: 2, length: 3)
        ds.sortAndMerge()
        XCTAssertEqual(ds.clients[1], [YDeleteItem(clock: 0, len: 10)])
    }

    func testFindIndexDSReturnsNilForAClockOutsideEveryRange() {
        let ranges = [YDeleteItem(clock: 0, len: 2), YDeleteItem(clock: 10, len: 1)]
        XCTAssertEqual(YDeleteSet.findIndex(ranges, 0), 0)
        XCTAssertEqual(YDeleteSet.findIndex(ranges, 10), 1)
        // Unlike findIndexSS, a miss here is legitimate, not `unexpectedCase`.
        XCTAssertNil(YDeleteSet.findIndex(ranges, 5))
        XCTAssertNil(YDeleteSet.findIndex(ranges, 99))
        XCTAssertNil(YDeleteSet.findIndex([], 0))
    }

    func testIsDeletedChecksTheRightClient() {
        var ds = YDeleteSet()
        ds.add(client: 1, clock: 0, length: 3)
        XCTAssertTrue(ds.isDeleted(YID(client: 1, clock: 2)))
        XCTAssertFalse(ds.isDeleted(YID(client: 1, clock: 3)))
        XCTAssertFalse(ds.isDeleted(YID(client: 2, clock: 0)))
    }

    func testDeleteSetFromStoreCoalescesRunsOfDeletedStructs() {
        // Adjacent deleted structs become one range; a live struct breaks the run.
        let store = YStructStore()
        let list = YStructList()
        let a = item(client: 1, clock: 0, text: "ab")
        let b = item(client: 1, clock: 2, text: "cd")
        let c = item(client: 1, clock: 4, text: "ef")
        a.markDeleted()
        b.markDeleted()
        list.structs = [a, b, c]
        store.clients[1] = list

        let ds = YDeleteSet.from(store: store)
        XCTAssertEqual(ds.clients[1], [YDeleteItem(clock: 0, len: 4)])
    }

    func testDeleteSetFromStoreOmitsClientsWithNothingDeleted() {
        let store = YStructStore()
        let list = YStructList()
        list.structs = [item(client: 1, clock: 0, text: "ab")]
        store.clients[1] = list
        XCTAssertTrue(YDeleteSet.from(store: store).clients.isEmpty)
    }
}
