import Foundation

/// One prevalidated ordinary-text command in replica UTF-16 coordinates.
struct NativeEditCommand: Equatable, Sendable {
    let id: UUID
    let baseRevision: UInt64
    let blockID: String
    let range: Range<Int>
    let replacement: String
}

/// One authoritative patch emitted for a command. Cleanup may emit additional
/// patches; origin alone cannot identify an echo or a cleanup repair.
struct NativePatchStamp: Equatable, Sendable {
    let commandID: UUID
    let baseRevision: UInt64
    let emission: Int
}
