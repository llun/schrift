import Foundation

// MARK: - Type

/// A Yjs shared type — yjs `AbstractType` (@5045).
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

    /// The owning document. `weak` deliberately: yjs relies on a tracing GC and
    /// wires `doc → share → type → doc` into a cycle, which ARC would leak.
    weak var doc: YDoc?

    init(typeRef: YTypeRef? = nil) {
        self.typeRef = typeRef
    }

    /// yjs `_integrate(y, item)` (@5155).
    func integrate(doc: YDoc, item: YItem?) {
        self.doc = doc
        self.item = item
    }

    /// yjs `ContentType.delete` (@9445) — delete every child, recursively.
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
        transaction.changed.removeValue(forKey: ObjectIdentifier(self))
    }
}

/// yjs `ArraySearchMarker` (@4966). Never constructed in this milestone — see
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
/// Deliberately **not** modelled: observers/events (`ObservableV2`), subdocuments
/// (Schrift's BlockNote schema is a single `document-store` XmlFragment with no
/// nested docs), and undo/redo. The roadmap adds the `YDocument` facade
/// (`applyUpdate`/`encodeStateVector`/`encodeStateAsUpdate`) in B3 on top of this.
final class YDoc {
    /// Garbage collection. **Off for this milestone** — `Item.gc`/`tryGcDeleteSet`
    /// land in B4, and the oracle fixtures here are captured from
    /// `new Y.Doc({ gc: false })` to match.
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

    init(clientID: UInt, gc: Bool = false) {
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

    /// yjs `findRootTypeKey` (@5027) — the `share` key a root type is filed under.
    /// Needed by B3's serializer; here it keeps `YType` from having to store a
    /// back-pointer that could disagree with `share`.
    func findRootTypeKey(_ type: YType) throws -> String {
        for (key, value) in share where value === type { return key }
        throw YIntegrationError.unexpectedCase
    }
}
