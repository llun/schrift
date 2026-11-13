import Foundation
import Synchronization

struct ReplicaInlineSlice: Equatable, Sendable {
    let blockID: String
    let range: Range<Int>
}

/// One command a surface sends its replica session (PR08b).
///
/// `predicted` is option A's optimistic typing: the surface already shows it
/// (same-block typing only). The session rebases it through changes the
/// surface had not seen when it predicted (`TextDelta.rebase`, the same
/// function the surface uses) or, when that is impossible, invalidates the
/// surface's epoch. Everything else is a barrier: the surface shows it when
/// the result arrives, and a barrier that meets an unseen change is `.stale`
/// (the surface retries it once).
struct ReplicaCommand: Sendable {
    let surfaceID: UUID
    let epoch: UInt64
    let predicted: Bool
    /// `baseRevision` is the revision the surface's canonical display showed
    /// when it sent this; the session re-stamps it with its own revision.
    let command: NativeEditCommand
    /// The undo grouping the surface decided: a step boundary before and/or
    /// after the command (`ReplicaHistory.stopCapturing`).
    let undoBefore: Bool
    let undoAfter: Bool
}

/// A block-menu action the surface would apply, and the command it would
/// send for it (nil for Copy, which needs a lossless payload instead).
struct ReplicaAvailabilityCandidate: Sendable {
    let action: NativeBlockAction
    let kind: NativeEditCommand.Kind?
}

/// Main → session, in order. Every message is handled synchronously on the
/// session: no await between the engine call, the journal append and the
/// delivery yield.
enum ReplicaMessage: Sendable {
    case command(ReplicaCommand)
    /// The surface's selection, `seq` increasing per surface, in display
    /// coordinates at `baseRevision`.
    case select(surfaceID: UUID, seq: UInt64, baseRevision: UInt64, EditorSelection?)
    /// `epoch`: a begin from an epoch the session already invalidated is not
    /// captured (its offsets may count dropped predictions); the commit is orphaned.
    case compositionBegin(surfaceID: UUID, epoch: UInt64, baseRevision: UInt64, blockID: String, range: Range<Int>)
    /// A predicted command (PR08b): the surface already shows `text`.
    case compositionCommit(surfaceID: UUID, epoch: UInt64, commandID: UUID, text: String)
    case compositionCancel(surfaceID: UUID)
    /// The surface's IME recovery entries, written to `provisional.json`.
    case writeProvisional([ProvisionalRecovery])
    /// Server state merged into the replica: journaled before its patches
    /// are delivered.
    case integrate(Data, reply: (@Sendable (Result<Void, any Error>) -> Void)?)
    /// Live sync (PR09a), answered in mailbox order: the replica's state vector
    /// and, for a peer's SyncStep1 vector, the update it lacks (nil for a
    /// reader, a frozen replica or a vector that cannot be read).
    /// A message that cannot be handled answers nil for both.
    case liveSync(peerVector: Data?, reply: @Sendable (_ stateVector: Data?, _ missing: Data?) -> Void)
    /// Awareness (PR10): `sink` hears the engine's selection as relative
    /// positions after every message that changed it (nil for a reader).
    case watchCursor(@Sendable (AwarenessCursor?) -> Void)
    /// Awareness (PR10): peers' published cursors, by client id, resolved
    /// against the replica now. Never writes it.
    case resolveCursors([UInt: AwarenessCursor], reply: @Sendable ([UInt: PeerCursorPlaces]) -> Void)
    /// Navigation (PR10b): every block with its handle, in document order.
    case navigation(reply: @Sendable ([NativeNavigationEntry]) -> Void)
    /// Navigation (PR10b): the block `handle` names if it is still that
    /// block in this replica (same generation and item), else nil. A block
    /// in column group `group` (PR12c) answers its column's id instead.
    case locate(NativeBlockHandle, group: NativeBlockHandle? = nil, reply: @Sendable (String?) -> Void)
    /// Tables (PR11a): the grid of table `blockID` now (nil when it is not a table).
    /// `full` (PR11c) reads a table past the editing bound, for the viewer.
    case tableGrid(blockID: String, full: Bool = false, reply: @Sendable (TableGrid?) -> Void)
    /// Tables (PR11c): the clipboard of the CellSelection `from`...`to`.
    case tableCopy(blockID: String, from: TableSlot, to: TableSlot, reply: @Sendable (TableCopy?) -> Void)
    /// Column groups (PR12a): group `blockID` as the replica holds it now.
    case columnGroup(blockID: String, reply: @Sendable (ColumnGroup?) -> Void)
    /// Media (PR13b): where block `blockID` is now, anywhere in the document
    /// (a closed column group's included), `.some(nil)` when no such block
    /// exists; nil when the message could not be handled (nothing decided).
    case mediaLocation(blockID: String, reply: @Sendable (MediaLocation??) -> Void)
    case requestAvailability(surfaceID: UUID, blockID: String, candidates: [ReplicaAvailabilityCandidate])
    case copyPayload(surfaceID: UUID, requestID: UUID, blockIDs: [String])
    case copyInlinePayload(surfaceID: UUID, requestID: UUID, slices: [ReplicaInlineSlice])
    /// Installs the journal (nil makes the session read-only) and the shared
    /// history.
    case setWritable(DocumentReplicaSession.Journal?)
    /// A marker delivered back to the surface once everything before it was
    /// handled (tests' `settle`, a close's flush).
    case drain(surfaceID: UUID, token: UUID)
    /// The surface read its resync marker (or marked text held too many
    /// deliveries): send what was held and a `.reset` under a new epoch (PR08c).
    case resync(surfaceID: UUID)
    /// The surface leaves; the session stays for the others (PR08c).
    case detach(surfaceID: UUID)
    case close
    /// Tests only: runs on the session in mailbox order, with the live graph
    /// (nil once the session closed).
    case inspect(@Sendable (DocumentEngine?, YDoc?, ReplicaHistory?) -> Void)

    /// A message that carries a reply, answered when it cannot be handled so
    /// no awaiting caller hangs.
    func cancel() {
        switch self {
        case .integrate(_, let reply): reply?(.failure(DocumentEngineError.detached))
        case .liveSync(_, let reply): reply(nil, nil)
        case .resolveCursors(_, let reply): reply([:])
        case .navigation(let reply): reply([])
        case .locate(_, _, let reply): reply(nil)
        case .tableGrid(_, _, let reply): reply(nil)
        case .tableCopy(_, _, _, let reply): reply(nil)
        case .columnGroup(_, let reply): reply(nil)
        case .mediaLocation(_, let reply): reply(nil)
        case .inspect(let body): body(nil, nil, nil)
        default: break
        }
    }
}

/// The session's answer for one command.
enum ReplicaResult: Sendable, Equatable {
    /// Journaled (or, for a history step, `journaled` false when nothing
    /// changed). `caret` is where a structural command puts the caret.
    case applied(commandID: UUID, caret: EditorPosition?, journaled: Bool)
    /// The engine refused it before writing anything.
    case refused(commandID: UUID, DocumentEngineError?)
    /// A barrier met a change its surface had not seen: retry it once.
    case stale(commandID: UUID)
    /// A predicted command could not be rebased (or was refused): every
    /// command of the surface's old epoch is dropped and `epoch` is current.
    case invalidated(epoch: UInt64, commandID: UUID)
    /// The append failed; the engine is frozen.
    case failed(commandID: UUID)
    case composition(commandID: UUID?, CompositionResult)

    enum CompositionResult: Sendable, Equatable {
        case committed, orphaned, cancelled, failed
    }

    /// The command this answers.
    var commandID: UUID? {
        switch self {
        case .applied(let id, _, _), .refused(let id, _), .stale(let id), .invalidated(_, let id), .failed(let id):
            id
        case .composition(let id, _): id
        }
    }
}

/// The selection resolved on the session after a delivery's changes, for the
/// surface's selection `seq`.
struct ReplicaSelection: Sendable, Equatable {
    let seq: UInt64
    let anchor: EditorPosition?
    let head: EditorPosition?
    /// False when the session holds no selection.
    let tracked: Bool
}

/// What the surface mirrors: the shared history's stacks and whether
/// authoring is possible.
struct ReplicaState: Sendable, Equatable {
    var canUndo = false
    var canRedo = false
    var writable = false
    /// A failed append or an unjournaled transaction: authoring stopped.
    var frozen = false
    var detached = false
}

struct ReplicaTimings: Sendable, Equatable {
    /// The engine call, including the journal append.
    let engine: Duration
    /// The journal append alone.
    let journal: Duration
}

/// Session → one surface, in order.
struct ReplicaDelivery: Sendable {
    enum Event: Sendable {
        /// `settled` holds each `.text`/`.props` block's projection right after
        /// the patch (the surface's former `reprojectBlock`).
        case patch(BlockPatch, settled: [String: BlockSnapshot])
        case compositionDeferred(Bool)
    }

    /// The bounded-delivery handshake (PR08c).
    enum Resync: Sendable, Equatable {
        /// The surface reached `DocumentReplicaSession.deliveryBound`: it asks
        /// for its resync and holds its keys until the reset.
        case requested
        /// This delivery's `.reset` patch is the canonical state; commands
        /// carry `epoch` from now on.
        case reset(epoch: UInt64)
    }

    var revision: UInt64
    var events: [Event] = []
    var result: ReplicaResult?
    var selection: ReplicaSelection?
    var state: ReplicaState
    var availability: (blockID: String, revision: UInt64, actions: [NativeBlockAction])?
    var clipboard: (requestID: UUID, payload: Data?)?
    var inlineClipboard: (requestID: UUID, payload: Data?)?
    var drained: UUID?
    var timings: ReplicaTimings?
    var resync: Resync?

    /// This delivery without its patches and selection, for a surface whose
    /// reset is on its way (it shows them); nil when nothing else is left.
    func withoutPatches() -> ReplicaDelivery? {
        var kept = self
        kept.events = []
        kept.selection = nil
        let answers =
            result != nil || drained != nil || clipboard != nil || inlineClipboard != nil || availability != nil
            || resync != nil
        return answers ? kept : nil
    }
}

/// The main → session channel: one ordered, bounded stream. A full mailbox
/// drops the message; the poster freezes authoring rather than lose input
/// silently (`post` returns false). A `.detach` or `.close` always fits (at
/// most one per surface and one per session): dropping one would strand
/// whoever awaits the close, and the scope's next restore behind it.
final class ReplicaCommandMailbox: Sendable {
    static let capacity = 256

    let stream: AsyncStream<ReplicaMessage>
    private let continuation: AsyncStream<ReplicaMessage>.Continuation
    /// Posted and not yet taken by the session (`took`).
    private let queued = Mutex(0)

    init() {
        // Unbounded: `post` keeps the bound, so a detach or close can pass it.
        (stream, continuation) = AsyncStream.makeStream()
    }

    @discardableResult
    func post(_ message: ReplicaMessage) -> Bool {
        let enqueued = queued.withLock { queued in
            let fits =
                switch message {
                case .detach, .close: true
                default: queued < Self.capacity
                }
            guard fits, case .enqueued = continuation.yield(message) else { return false }
            queued += 1
            return true
        }
        if !enqueued { message.cancel() }
        return enqueued
    }

    /// The session took one message off `stream`.
    func took() { queued.withLock { $0 -= 1 } }

    func finish() { continuation.finish() }
}
