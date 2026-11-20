import XCTest

@testable import Schrift

/// `DocumentReplicaSession.validateInstallable` is the gate the keep-server
/// conflict path runs before it discards the local replica: it must accept
/// exactly what a fresh durable restore would accept, and reject anything
/// `build` would throw on.
final class DocumentReplicaSessionValidationTests: XCTestCase {
    private func fullState() -> Data {
        BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph", props: [], runs: [InlineRun("Hello")], id: "b1"),
                BlockNoteBlock(
                    node: "paragraph", props: [], runs: [InlineRun("World")], id: "b2"),
            ],
            clientID: 1)
    }

    func testValidateInstallableAcceptsAFullState() throws {
        try DocumentReplicaSession.validateInstallable(state: fullState())
    }

    func testValidateInstallableRejectsGarbageBytes() throws {
        do {
            try DocumentReplicaSession.validateInstallable(state: Data([0xff]))
            XCTFail("garbage bytes must not validate")
        } catch {}
    }

    func testValidateInstallableRejectsTruncatedBytes() throws {
        let state = fullState()
        do {
            try DocumentReplicaSession.validateInstallable(state: state.prefix(state.count / 2))
            XCTFail("a truncated update must not validate")
        } catch {}
    }

    func testValidateInstallableRejectsAPartialUpdateWithPendingStructs() throws {
        // An update whose origin names a struct that never arrived: it stashes
        // and stays in `pendingStructs`, so a fresh restore would throw.
        let pending = Data(hex: "01010200840100017900")
        do {
            try DocumentReplicaSession.validateInstallable(state: pending)
            XCTFail("an update with pending structs must not validate")
        } catch {}
    }
}
