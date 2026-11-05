import Foundation

// MARK: - Type

/// A Yjs shared type — yjs `AbstractType` (@5048).
///
/// **One class covers every type ref.** yjs subclasses `AbstractType` into
/// `YArray`/`YMap`/`YText`/`YXmlElement`/… because each exposes a different
/// public API; the *store* treats them identically — nothing in `Item.integrate`,
/// `splitItem`, or the delete-set application branches on the subclass. Schrift's
/// store is deliberately type-agnostic (the roadmap's "store is type-agnostic;
/// lossiness lives only in projection"), so the type ref is carried as data and
/// the projection layer (B5) interprets it.
final class YType {
    /// The item whose `ContentType` holds this type; nil for a root type reached
    /// through `YDoc.share`.
    var item: YItem?
    /// parentSub → the *rightmost* item for that key (the current value).
    var map: [String: YItem] = [:]
    /// Head of the child list.
    var start: YItem?
    /// Count of countable, undeleted units among the children.
    var length: UInt = 0
    /// The type ref this was instantiated from (`YTypeRef`), or nil for a root
    /// type created by `YDoc.get(_:)` — yjs's roots are bare `AbstractType`s and
    /// are referenced by name on the wire, never by a type ref.
    var typeRef: YTypeRef?

    /// yjs `_searchMarker`: an index cache that `YArray`/`YText` maintain for fast
    /// positional lookup. Nothing here creates markers, so this is always nil —
    /// it exists because `ContentFormat.integrate` and `Item.mergeWith` both
    /// explicitly clear/consult it, and dropping it would make those two diverge
    /// from the source they transliterate.
    var _searchMarker: [YArraySearchMarker]?

    /// yjs `_hasFormatting`: set when a `ContentFormat` is integrated. Unused in
    /// this milestone; it is what B4's `cleanupYTextAfterTransaction` keys off.
    var _hasFormatting = false

    /// Whether this type is a text — yjs's `YText` or `YXmlText`, the two classes
    /// that share `YTextEvent` and are therefore the only ones whose events carry
    /// a `delta`.
    ///
    /// A nested type knows from its `typeRef`. A root has none (a root is named on
    /// the wire, never referenced by a type ref), so its kind is whatever its
    /// creator declared: `YDoc.getText(_:)` marks it text, and a root created by
    /// `YDoc.get(_:)` is not. yjs instead re-casts the bare root into the concrete
    /// class; with one `YType` class the cast is this flag.
    var isText: Bool

    /// The owning document. `weak` deliberately: yjs relies on a tracing GC and
    /// wires `doc → share → type → doc` into a cycle, which ARC would leak.
    weak var doc: YDoc?

    init(typeRef: YTypeRef? = nil) {
        self.typeRef = typeRef
        self.isText = typeRef == .text || typeRef == .xmlText
    }

    /// yjs `_integrate(y, item)` (@5158).
    func integrate(doc: YDoc, item: YItem?) {
        self.doc = doc
        self.item = item
    }

    /// yjs `ContentType.delete` (@9448) — delete every child, recursively.
    ///
    /// Deleted children whose clock predates the transaction are pushed onto
    /// `mergeStructs` instead: they are already deleted so there is nothing to
    /// mark, but they may now be mergeable and nothing else would notice, since
    /// they never enter `transaction.deleteSet`.
    func deleteChildren(_ transaction: YTransaction) {
        var item = start
        while let current = item {
            if !current.deleted {
                current.delete(transaction)
            } else if current.id.clock < (transaction.beforeState[current.id.client] ?? 0) {
                transaction.mergeStructs.append(current)
            }
            item = current.right
        }
        for (_, current) in map {
            if !current.deleted {
                current.delete(transaction)
            } else if current.id.clock < (transaction.beforeState[current.id.client] ?? 0) {
                transaction.mergeStructs.append(current)
            }
        }
        transaction.removeChangedType(self)
    }
}

/// yjs `ArraySearchMarker` (@4969). Never constructed in this milestone — see
/// `YType._searchMarker`. Declared so the two call sites that consult markers can
/// be transliterated as written rather than silently dropped.
final class YArraySearchMarker {
    var p: YItem
    var index: UInt

    init(p: YItem, index: UInt) {
        self.p = p
        self.index = index
    }
}

// MARK: - Document

/// A Yjs document replica — yjs `Doc` (@455), reduced to what the struct store
/// needs.
///
/// Deliberately **not** modelled: the `ObservableV2` observer tree (`observe`/
/// `observeDeep` and their listener sets) beyond the two hooks the live replica
/// needs — `onUpdate` and `afterTransaction` — subdocuments (Schrift's BlockNote
/// schema is a single `document-store` XmlFragment with no nested docs), and
/// undo/redo. The roadmap adds the `YDocument` facade
/// (`applyUpdate`/`encodeStateVector`/`encodeStateAsUpdate`) in B3 on top of this.
final class YDoc {
    /// Garbage collection. **On by default** (B4) — matching a real yjs client
    /// (`new Y.Doc()` defaults `gc: true`) and the live write path (C2). When on,
    /// `tryGcDeleteSet` sweeps the replica's *own* deleted items each transaction:
    /// their content becomes a `ContentDeleted` tombstone and a deleted type's
    /// children become `GC` structs (`Item.gc`). Still overridable to `false` — the
    /// gc-off golden fixtures pin that mode. Note GC *structs* occur regardless of
    /// this flag: they arrive on the wire from peers that collect, and `Item.integrate`
    /// mints one for a parentless item.
    let gc: Bool
    /// This replica's client id. The roadmap requires a fresh random id per
    /// session, never persisted — a reused id means duplicate `(client, clock)`
    /// pairs, i.e. silent corruption.
    var clientID: UInt
    let store = YStructStore()
    /// Root types by name (`document-store` for BlockNote).
    var share: [String: YType] = [:]

    var transaction: YTransaction?
    var transactionCleanups: [YTransaction] = []
    /// Test seam: origin of the most recently cleaned transaction, including nested cleanup transactions.
    var lastTransactionOrigin: YTransactionOrigin?

    /// yjs `Doc`'s `'update'` event (@3388-3392), reduced to the one listener the
    /// live replica needs: fired once per cleaned transaction with that transaction's
    /// origin and an `encode` closure returning its v1 update bytes
    /// (`writeUpdateMessageFromTransaction`, the same `YTransactionEncoder.encodeUpdate`
    /// the local-edit path uses), or nil when it has no content.
    ///
    /// yjs emits from `cleanupTransactions`'s `finally` block, after gc/merge and the
    /// client-id re-roll, before the next queued cleanup. That is what makes the
    /// formatting-cleanup transaction (origin `null`) visible to a provider, which
    /// broadcasts every update whose origin is not itself.
    ///
    /// Unlike yjs, encoding is lazy: the listener calls `encode` only for origins it
    /// wants, so the hot paths (a whole-document sync step 2, every keystroke) pay
    /// nothing. `encode` is valid only during the call. A nil hook runs nothing. An
    /// encode refusal (a store holding pending structs/deletes) is swallowed as nil,
    /// never thrown out of cleanup or trapped.
    var onUpdate: ((_ origin: YTransactionOrigin?, _ encode: () -> Data?) -> Void)?

    /// yjs `Doc`'s `'afterTransaction'` event (@3337) — the **change signal**.
    ///
    /// Fired once per cleaned transaction from the observer phase, after every
    /// changed type's `_callObserver` has populated `transaction.changedParentTypes`
    /// and **before** the formatting cleanup and gc/merge. That ordering is the
    /// point: a run of typing that the merge will coalesce into one struct still
    /// reads as separate inserts, and a deleted item is still a `delete` rather
    /// than a tombstone.
    ///
    /// The transaction's `changedParentTypes` is complete when the hook runs, and
    /// each text event's `delta` is valid **only** during the call (see
    /// `YEvent.delta`). A nil hook runs nothing, and then no events are built at
    /// all: `changedParentTypes` is populated only while a hook is set, because
    /// this hook is its only consumer. The B4 formatting-cleanup arming does not
    /// depend on it and still runs.
    ///
    /// A `transact` opened from inside the hook behaves as in yjs: the current
    /// transaction is already off `doc.transaction`, so the new one is queued and
    /// drained after the current one's gc/merge, never mid-cleanup.
    var afterTransaction: ((YTransaction) -> Void)?

    init(clientID: UInt, gc: Bool = true) {
        self.clientID = clientID
        self.gc = gc
    }

    /// yjs `Doc.get(name)` (@531) — the root type for `name`, created on first use.
    ///
    /// yjs additionally re-casts an existing root when it was first created as a
    /// bare `AbstractType` and is later requested as a concrete type. That branch
    /// has no meaning here: `YType` is the one type class (see `YType`), so every
    /// root already has the only shape there is.
    func get(_ name: String) -> YType {
        if let existing = share[name] { return existing }
        let type = YType()
        type.integrate(doc: self, item: nil)
        share[name] = type
        return type
    }

    /// yjs `Doc.getText(name)` (@665) — `get(name, YText)`.
    ///
    /// yjs's `Doc.get` (@614) re-casts a root that was created as a bare
    /// `AbstractType` into the requested concrete class, and throws a plain
    /// `Error` only when the root is already a *different* concrete constructor.
    /// Schrift has one `YType` class, so the cast is `isText = true` and it is
    /// applied unconditionally: a root that was declared as something else is
    /// silently re-marked as text, not returned unchanged and not rejected.
    ///
    /// **Call this only for a text root.** Schrift cannot tell a bare root (which
    /// yjs would re-cast) from a declared non-text root (which yjs would refuse),
    /// because a root's kind is not on the wire and `get(_:)` records none. There
    /// is no production caller; the tests use it to declare their text roots.
    func getText(_ name: String) -> YType {
        let type = get(name)
        type.isText = true
        return type
    }

    /// yjs `findRootTypeKey` (@5030) — the `share` key a root type is filed under.
    /// Needed by B3's serializer; here it keeps `YType` from having to store a
    /// back-pointer that could disagree with `share`.
    func findRootTypeKey(_ type: YType) throws -> String {
        for (key, value) in share where value === type { return key }
        throw YIntegrationError.unexpectedCase
    }

    /// Breaks the document graph's reference cycles so ARC can reclaim it.
    ///
    /// **Releasing a `YDoc` frees nothing without this.** yjs relies on a tracing
    /// collector and wires cycles freely: `item.left ⇄ item.right`, and
    /// `type.start`/`type.map` ⇄ `item.parent`. ARC cannot collect any of it, so
    /// every replica would leak its entire item graph for the process's lifetime —
    /// and a live session opens one replica per document.
    ///
    /// Making an edge `unowned` instead is not an option: the algorithm reads
    /// `left`/`right`/`parent` in both directions throughout, and there is no edge
    /// whose target provably outlives its source.
    ///
    /// Idempotent, and safe to call on a partially built store. The owner (the
    /// collaboration session, C1) must call it when it drops a replica; `deinit` is
    /// no use here, since the cycles are exactly what keeps `deinit` from running.
    func destroy() {
        for (_, list) in store.clients {
            for s in list.structs {
                guard let item = s as? YItem else { continue }
                item.left = nil
                item.right = nil
                item.parent = nil
                if case .type(let type) = item.content {
                    type.start = nil
                    type.map = [:]
                    type.item = nil
                }
            }
            list.structs = []
        }
        store.clients = [:]
        store.pendingStructs = nil
        store.pendingDs = nil
        for (_, type) in share {
            type.start = nil
            type.map = [:]
            type.item = nil
        }
        share = [:]
        transaction = nil
        transactionCleanups = []
    }
}
