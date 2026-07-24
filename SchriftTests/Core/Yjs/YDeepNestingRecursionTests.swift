import XCTest

@testable import Schrift

/// The delete and gc cascades (`YItem.delete → ContentType.delete →
/// YType.deleteChildren → YItem.delete`, and the `YItem.gc` twin) recurse once
/// per nested `ContentType` level. That depth is fully attacker-controlled by a
/// single inbound update, and unbounded it overruns the native stack — an
/// uncatchable `EXC_BAD_ACCESS` that slips past the collaboration manager's
/// fail-safe `catch`. `YTransaction.maxTypeNestingDepth` bounds both cascades and
/// refuses a too-deep replica with a thrown `.recursionLimitExceeded`, matching
/// what yjs does (a catchable `RangeError`) instead of crashing.
///
/// **Crash-signature caveat:** these tests are meaningful only against the
/// *patched* code. Run against unpatched code, the deep cases don't fail as
/// assertions — they stack-overflow and take the whole test process down
/// (`Restarting after unexpected exit, crash, or test timeout`), which can
/// mis-blame an unrelated test. They assert the post-fix *throw*, never try to
/// "catch" the pre-fix crash.
final class YDeepNestingRecursionTests: XCTestCase {

    // MARK: - Applying a crafted chain

    private func applyChain(depth: Int, gc: Bool, deleteRoot: Bool, innermostFirst: Bool = false) throws {
        let doc = YDoc(clientID: 1, gc: gc)
        defer { doc.destroy() }
        try doc.applyUpdate(
            YUpdateDecoder.decode(
                DeepNestingFixtures.nestedTypeChain(
                    depth: depth, deleteRoot: deleteRoot, innermostFirst: innermostFirst)))
    }

    private func assertRefuses(depth: Int, gc: Bool, innermostFirst: Bool = false) {
        do {
            try applyChain(depth: depth, gc: gc, deleteRoot: true, innermostFirst: innermostFirst)
            XCTFail("expected recursionLimitExceeded at depth \(depth) (gc: \(gc))")
        } catch let error as YIntegrationError {
            XCTAssertEqual(error, .recursionLimitExceeded)
        } catch {
            XCTFail("expected YIntegrationError.recursionLimitExceeded, got \(error)")
        }
    }

    // MARK: - The regression (a hostile update must throw, not crash)

    func testDeepOutermostDeleteThrowsInsteadOfCrashing_gcOff() {
        assertRefuses(depth: YTransaction.maxTypeNestingDepth * 2, gc: false)
    }

    func testDeepOutermostDeleteThrowsInsteadOfCrashing_gcOn() {
        assertRefuses(depth: YTransaction.maxTypeNestingDepth * 2, gc: true)
    }

    func testDeepInnermostFirstDeleteSetRefusesViaGCGuard() {
        // Innermost-clock-first ordering keeps every per-item delete cascade
        // shallow, slipping past the delete-side counter — so the depth lands in
        // tryGcDeleteSet, and the gc-side guard must catch it. gc on.
        assertRefuses(depth: YTransaction.maxTypeNestingDepth * 2, gc: true, innermostFirst: true)
    }

    func testDeepIntegrateWithoutDeleteDoesNotCrash() throws {
        // Integration alone is iterative — a deep chain that is never deleted must
        // integrate fine (capping integrate would be stricter than yjs).
        try applyChain(depth: YTransaction.maxTypeNestingDepth * 2, gc: false, deleteRoot: false)
    }

    // MARK: - Boundary (read the cap, don't hard-code it)

    func testDepthAtTheCapSucceeds() throws {
        // A chain exactly `maxTypeNestingDepth` deep deletes + gcs without refusal.
        try applyChain(depth: YTransaction.maxTypeNestingDepth, gc: true, deleteRoot: true)
    }

    func testDepthOnePastTheCapRefuses() {
        assertRefuses(depth: YTransaction.maxTypeNestingDepth + 1, gc: true)
    }

    // MARK: - Below the cap is a provable no-op

    func testShallowDepthDeletesAndGCsCleanly() throws {
        try applyChain(depth: 500, gc: true, deleteRoot: true)
        try applyChain(depth: 500, gc: false, deleteRoot: true)
    }

    func testWideShallowDeleteDoesNotRefuse() throws {
        // ~10,000 sibling list children at nesting depth 1, all deleted at once:
        // the counter tracks nesting, not sibling count, so this must not refuse.
        func varUInt(_ value: UInt) -> [UInt8] {
            var v = value
            var out: [UInt8] = []
            while v >= 0x80 {
                out.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            out.append(UInt8(v))
            return out
        }
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        var out: [UInt8] = []
        out += varUInt(1)  // 1 client block
        let count = 10_000
        out += varUInt(UInt(count))  // numStructs
        out += varUInt(42)  // client
        out += varUInt(0)  // first clock
        // struct 0: ContentString "a" under named root "t".
        out += [0x04, 0x01, 0x01, 0x74, 0x01, 0x61]
        // structs 1..<count: ContentString "a", left-origin id(42, i-1) (a run of
        // siblings in one flat list, depth 1).
        for i in 1..<count {
            out += [0x84]  // info: ContentString + origin bit
            out += varUInt(42)
            out += varUInt(UInt(i - 1))
            out += [0x01, 0x61]
        }
        out += varUInt(1)  // delete set: 1 client
        out += varUInt(42)
        out += varUInt(1)  // 1 range
        out += varUInt(0)  // clock 0
        out += varUInt(UInt(count))  // length = all siblings
        try doc.applyUpdate(YUpdateDecoder.decode(Data(out)))
    }
}
