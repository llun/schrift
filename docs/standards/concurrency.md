# Concurrency (Swift 6)

- **View models and the save coordinator** are `@MainActor @Observable final
  class`. Use the **Observation framework** (`@Observable`) — never
  `ObservableObject`/`@Published`/Combine.
- **Networking** is a single `actor DocsAPIClient`; every endpoint method is
  `async throws` and runs on the actor.
- **Pure logic layers** (`Core/Yjs`, markdown parser/serializer, design-system
  style resolvers, path/query builders) use **no concurrency annotations** — they
  are synchronous, side-effect-free value code (caseless `enum` namespaces +
  `static`/free functions over `Sendable` value types) callable from any
  isolation domain. Keep the async/`throws` boundary at the networking layer.
  - **The one exception is the Yjs CRDT core's live replica** (`YDoc`, `YType`,
    `YStruct`/`YItem`, `YStructStore`): a mutable object graph of `final class`es,
    because the YATA algorithm wires structs to one another **by identity**
    (`this.left.right = this`, `Set<Item>` membership, `o !== this.right`) and
    value types cannot express that. It keeps the no-concurrency-annotations rule
    and stays synchronous, but it is **not `Sendable`** and must not be made so:
    a replica is mutable shared state, so exactly one owner may touch it — the
    **main actor**, through `DocumentCollaborationManager` (`@MainActor final
    class`, `Schrift/Core/Collaboration/DocumentCollaborationManager.swift`),
    which holds one `YDoc` per document (C1). The opt-in native route instead
    has a separate owner off the main actor, `actor DocumentReplicaSession`
    (PR08b); it never attaches to the manager's replica. Pass updates and
    projections across isolation domains — never the `YDoc`. Its inputs/outputs stay value types
    (`YUpdate`, `YContentRecord`), which is what keeps the boundary honest.
  - **The document engine and its native history are confined, not isolated**
    (PR08a). `DocumentEngine` and `ReplicaHistory` carry no actor annotation (a
    plain `deinit`; `DocumentEngineBoundaryTests` fails on `@MainActor` in
    `Engine/`): each belongs to whichever domain creates it with its replica, the
    main actor today. They are not `Sendable`; their outputs are, compiler-checked
    with no `@unchecked`: `BlockPatch`, `BlockChange`, `TextDelta`, `BlockSnapshot`,
    `BlockPatchOrigin`, `EditorPosition`, `EditorSelection`,
    `CompositionCommitResult`, `InlineRun`, `ProjectedBlock`, `NativeBlockSnapshot`.
  - **The native replica lives on `actor DocumentReplicaSession`** (PR08b), which
    creates the `YDoc`, the `DocumentEngine` and the shared `ReplicaHistory` and is
    the only code that touches them; there is one per `ReplicaScope`, kept by the
    main-actor `NativeSessionRegistry` (PR08c). Only `Sendable` values cross: `ReplicaMessage`
    in, `ReplicaDelivery` out. `DocumentReplicaSession.swift` has no `@unchecked
    Sendable` and no `nonisolated(unsafe)`, and no `@MainActor` file under
    `Features/Editor/Native/` names `YDoc`, `DocumentEngine`, `YUndoManager` or
    `ReplicaHistory` (`ReplicaSessionOrderingTests` greps both; `ReplicaSaveAdapter`'s
    throwaway save-capture decode is exempt by owner decision).
  - **`ReplicaStore`'s journal is serialized by the store, not the main actor.**
    One `Mutex` (`Synchronization`, shared by every instance) guards each
    read/modify/switch, so append, restore, manifest, outbox, acknowledge, compact
    and the provisional file are callable off main. create, remove, repair,
    set-aside and the marker reads stay `@MainActor` (the ownership marker is
    main-actor) and take the same lock. It is not recursive: public entry points
    lock, private helpers assume it is held, no public method calls another, and an `interrupt` hook (which runs under the lock) never calls into any store.
    `interrupt` is `@Sendable`.
- Value types that cross task/actor boundaries adopt `Sendable`; injected
  closures that do are `@Sendable`. Generic containers propagate it via
  constraints (`PaginatedResponse<T: Decodable & Sendable>`).
- Use `async let` for independent concurrent fetches. Reach for an unstructured
  `Task {}` only for work that must **outlive its trigger** and is owned by a
  long-lived object (autosave debounce; the coordinator's in-flight saves).
  Debounce = cancel the previous `Task`, `try? await Task.sleep(for:)`, then
  `guard !Task.isCancelled`.
- SwiftUI `View`s are already `@MainActor`-isolated; do not add explicit
  `@MainActor` to the design-system components.
