import Foundation

// MARK: - Yjs replica projection (B5 of the live-editing roadmap)

/// A single projected block property: a key and a typed value decoded from the
/// Yjs replica. Properties are sorted by key for determinism in the projected
/// document and write-back path.
struct ProjectedProp: Equatable, Sendable {
    /// The property name (e.g. "level" for a heading, "url" for an image).
    var key: String
    /// The property value, one of the scalar/object/array cases from yjs's wire
    /// format. The value's type and presence drive fidelity classification.
    var value: YAnyValue
}

/// A single block projected from the Yjs replica: its BlockNote id, node type,
/// and decoded properties and inline runs. The id is the container map's "id"
/// field and serves as C1's identity map key for the live-write projection path.
/// Props are sorted by key for determinism.
struct ProjectedBlock: Equatable {
    /// The BlockNote block id from the replica's container-map "id" field.
    /// This is the key used to track the block identity across live edits (C1).
    var id: String
    /// The node type string: "paragraph", "heading", "bulletListItem", etc.,
    /// drawn from the content element in the blockContainer.
    var node: String
    /// The block's properties, sorted by key. Ordered attributes of the content
    /// element: heading level, list type, image url, etc.
    var props: [ProjectedProp]
    /// The block's inline content — text runs with their marks. Empty for leaf
    /// nodes like divider. Built from the xmlText child's content.
    var runs: [InlineRun]
    /// The fidelity classification of this block: whether it can be rendered,
    /// written back, or neither.
    var fidelity: ProjectionFidelity
}

/// The fidelity of a projected block: whether it can be faithfully rendered,
/// written back to the server, or neither.
enum ProjectionFidelity: Equatable, Sendable {
    /// The block is fully modeled and can be rendered and written back without
    /// data loss. This is the normal case for blocks built from the schema the
    /// app understands.
    case modeled
    /// The block can be rendered as markdown with visual fidelity equal to what
    /// the server would export, but writing it back would lose information. This
    /// happens when a block carries properties or structure the app's editor
    /// does not model (e.g. an unknown property on a heading, or a custom block
    /// type the app doesn't define). The block is frozen in the UI and cannot be
    /// edited.
    case lossy(reasons: [String])
    /// The block cannot be rendered as markdown at all — it requires server-side
    /// interpretation or carries a type or structure the app cannot display. The
    /// document containing this block cannot be edited, and the block appears as
    /// a placeholder or read-only element.
    case opaque(reason: String)
}

/// The projection of a Yjs replica into BlockNote blocks: a sequence of
/// projected blocks with metadata about whether they can be rendered and
/// written back. Not `Sendable` because it contains `ProjectedBlock`, which
/// cannot be `Sendable` due to `InlineRun`'s tuple marks (C1 stays on the
/// main actor — nothing crosses isolation domains in Phase B).
struct ProjectedDocument: Equatable {
    /// The blocks of the document in order, each projected from the replica's
    /// blockGroup and blockContainer tree.
    var blocks: [ProjectedBlock]
    /// True if every block has .modeled or .lossy fidelity (no .opaque blocks)
    /// and the document's root shape is the canonical blockGroup + blockContainer
    /// structure. Fully renderable documents can be displayed and edited if all
    /// blocks are .modeled; lossy blocks are display-only. Non-fully-renderable
    /// documents cannot be rendered at all.
    var isFullyRenderable: Bool
    /// True if isFullyRenderable is true AND every block has .modeled fidelity
    /// (no .lossy blocks). Only fully modeled documents can be written back to
    /// the server without data loss.
    var isFullyModeled: Bool
}
