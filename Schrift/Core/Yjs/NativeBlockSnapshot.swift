import Foundation

/// A native block's address in one replica: the replica generation (one per
/// engine/index, so a handle never addresses another replica) and the
/// integrated container item's identity. The string id is link metadata,
/// not the sole address: a move is a clone, so the same string id names a
/// new item afterwards.
struct NativeBlockHandle: Equatable, Hashable, Sendable {
    var generation: UUID
    var itemID: YID
    var stringID: String
}

/// One block of the native tree projection, in preorder: the classic
/// per-block projection plus its depth and parent.
struct NativeBlockSnapshot: Equatable, Sendable {
    var handle: NativeBlockHandle
    var block: ProjectedBlock
    var depth: Int
    var parentHandle: NativeBlockHandle?
    /// The bounded preview of a block the surface does not render as text
    /// (PR06e), read with the block; nil for prose.
    var preview: NativeBlockPreview? = nil

    var id: String { block.id }
    var parentID: String? { parentHandle?.stringID }
}
