import Foundation

/// One undo or redo step — yjs `StackItem` (@3475): the ranges a captured
/// transaction (or merged run of them) inserted and deleted.
final class YUndoStackItem {
    var insertions: YDeleteSet
    var deletions: YDeleteSet
    /// yjs `meta`: caller state saved with the step, such as the selection to
    /// restore when it is popped. Never read by the manager.
    var meta: [String: Any] = [:]

    init(deletions: YDeleteSet, insertions: YDeleteSet) {
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// yjs `StackItemEvent` (@3598), without `changedParentTypes`: Schrift drops a
/// transaction's events once its `afterTransaction` phase ends (see
/// `YTransaction.changedParentTypes`), so they cannot outlive the event.
struct YUndoStackEvent {
    enum Kind { case undo, redo }
    let stackItem: YUndoStackItem
    /// Which stack the item belongs to: a captured edit is `.undo`, the step an
    /// undo records is `.redo`, as in yjs.
    let type: Kind
    let origin: YTransactionOrigin?
}

/// yjs `UndoManager` (@3614), transliterated from 13.6.33: undo/redo stacks over
/// a whole `YDoc` or a set of scope types.
///
/// Undo and redo run as **local** transactions whose origin is the manager
/// (`origin`), so they are ordinary replica edits: the encoder and save path see
/// them like any other local change, and the manager captures them (its own
/// origin is always tracked) to fill the opposite stack. Deletions a stack can
/// still restore are marked `keep` (`YItem.keepItem`) so gc leaves their content;
/// `clear()` releases them. `destroy()`, like yjs's, only unsubscribes.
///
/// Deviations: `trackedOrigins` matches origins by value only (yjs also matches an
/// origin's constructor), and events carry no `changedParentTypes`.
final class YUndoManager {
    let doc: YDoc
    /// The types whose changes are captured; nil scopes the whole doc (yjs's
    /// `typeScope` being the `Doc`).
    private(set) var scope: [YType]?
    /// Origins whose transactions are captured. Always contains `origin`.
    var trackedOrigins: Set<YTransactionOrigin?>
    var captureTimeout: Double
    var captureTransaction: (YTransaction) -> Bool
    var deleteFilter: (YItem) -> Bool
    var ignoreRemoteMapChanges: Bool

    private(set) var undoStack: [YUndoStackItem] = []
    private(set) var redoStack: [YUndoStackItem] = []
    private(set) var undoing = false
    private(set) var redoing = false
    /// The popped item while an undo/redo transaction runs.
    private var currStackItem: YUndoStackItem?
    private var lastChange: Double = 0
    private var observer: UUID?

    var onStackItemAdded: ((YUndoStackEvent) -> Void)?
    var onStackItemUpdated: ((YUndoStackEvent) -> Void)?
    var onStackItemPopped: ((YUndoStackEvent) -> Void)?
    var onStackCleared: ((_ undoStackCleared: Bool, _ redoStackCleared: Bool) -> Void)?

    /// The origin of this manager's undo/redo transactions.
    var origin: YTransactionOrigin { .undoManager(ObjectIdentifier(self)) }

    /// yjs `new UndoManager(typeScope, options)` (@3619). `captureTimeout` is in
    /// milliseconds; the defaults are yjs's.
    init(
        doc: YDoc, scope: [YType]? = nil, captureTimeout: Double = 500,
        captureTransaction: @escaping (YTransaction) -> Bool = { _ in true },
        deleteFilter: @escaping (YItem) -> Bool = { _ in true },
        trackedOrigins: Set<YTransactionOrigin?> = [nil],
        ignoreRemoteMapChanges: Bool = false
    ) {
        self.doc = doc
        self.scope = scope
        self.trackedOrigins = trackedOrigins
        self.captureTimeout = captureTimeout
        self.captureTransaction = captureTransaction
        self.deleteFilter = deleteFilter
        self.ignoreRemoteMapChanges = ignoreRemoteMapChanges
        self.trackedOrigins.insert(origin)
        observer = doc.addAfterTransactionObserver { [weak self] in try self?.afterTransaction($0) }
    }

    deinit { destroy() }

    /// yjs `addToScope` (@3732). A no-op for a whole-doc manager.
    func addToScope(_ types: [YType]) {
        for type in types where scope?.contains(where: { $0 === type }) == false {
            scope?.append(type)
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// yjs `stopCapturing` (@3794): the next capture starts a new stack item.
    func stopCapturing() { lastChange = 0 }

    /// yjs `undo` (@3803). Returns the applied step, nil when nothing changed.
    @discardableResult
    func undo() throws -> YUndoStackItem? {
        undoing = true
        defer { undoing = false }
        return try popStackItem(undo: true)
    }

    /// yjs `redo` (@3819).
    @discardableResult
    func redo() throws -> YUndoStackItem? {
        redoing = true
        defer { redoing = false }
        return try popStackItem(undo: false)
    }

    /// yjs `clear` (@3758): empty the stacks and release `keep` on their deletions.
    /// Runs in a transaction with yjs's default (nil) origin.
    func clear(undoStack clearUndo: Bool = true, redoStack clearRedo: Bool = true) throws {
        guard (clearUndo && canUndo) || (clearRedo && canRedo) else { return }
        try doc.transact { transaction in
            if clearUndo {
                for item in undoStack { try clearStackItem(transaction, item) }
                undoStack = []
            }
            if clearRedo {
                for item in redoStack { try clearStackItem(transaction, item) }
                redoStack = []
            }
            onStackCleared?(clearUndo, clearRedo)
        }
    }

    /// yjs `destroy` (@3848): stop capturing. The stacks and their `keep` marks
    /// stay; call `clear()` first to release them.
    func destroy() {
        trackedOrigins.remove(origin)
        if let observer { doc.removeAfterTransactionObserver(observer) }
        observer = nil
    }

    // MARK: - yjs internals

    /// yjs's `scope.some(type => type === doc || isParentOf(type, item))`.
    private func inScope(_ item: YItem) -> Bool {
        scope?.contains { YItem.isParentOf($0, item) } ?? true
    }

    /// yjs `clearUndoManagerStackItem` (@3494).
    private func clearStackItem(_ transaction: YTransaction, _ stackItem: YUndoStackItem) throws {
        try YStructStore.iterateDeletedStructs(transaction, stackItem.deletions) { s in
            if let item = s as? YItem, inScope(item) { YItem.keepItem(item, false) }
        }
    }

    /// yjs `afterTransactionHandler` (@3665).
    private func afterTransaction(_ transaction: YTransaction) throws {
        // Only track certain transactions.
        guard captureTransaction(transaction),
            scope.map({ scope in
                scope.contains { type in transaction.changedParentTypes.contains { $0.type === type } }
            }) ?? true,
            trackedOrigins.contains(transaction.origin)
        else { return }
        let undoing = undoing
        let redoing = redoing
        if undoing {
            stopCapturing()  // the next undo should not be appended to the last stack item
        } else if !redoing {
            try clear(undoStack: false, redoStack: true)  // a new edit drops the redo stack
        }
        var insertions = YDeleteSet()
        // shortcut: ascending clients where yjs walks the store's Map order; it only
        // orders deletions across clients, and the wire delete set sorts clients itself.
        for client in transaction.afterState.keys.sorted() {
            let startClock = transaction.beforeState[client] ?? 0
            let endClock = transaction.afterState[client]!
            if endClock > startClock {
                insertions.add(client: client, clock: startClock, length: endClock - startClock)
            }
        }
        let now = Date().timeIntervalSince1970 * 1000  // yjs `time.getUnixTime()`
        var didAdd = false
        if lastChange > 0, now - lastChange < captureTimeout, !undoing, !redoing, let lastOp = undoStack.last {
            // Append the change to the last stack item.
            lastOp.deletions = YDeleteSet.merge([lastOp.deletions, transaction.deleteSet])
            lastOp.insertions = YDeleteSet.merge([lastOp.insertions, insertions])
        } else {
            let item = YUndoStackItem(deletions: transaction.deleteSet, insertions: insertions)
            if undoing { redoStack.append(item) } else { undoStack.append(item) }
            didAdd = true
        }
        if !undoing, !redoing { lastChange = now }
        // Make sure that deleted structs are not gc'd.
        try YStructStore.iterateDeletedStructs(transaction, transaction.deleteSet) { s in
            if let item = s as? YItem, inScope(item) { YItem.keepItem(item, true) }
        }
        guard let stackItem = (undoing ? redoStack : undoStack).last else { return }
        let event = YUndoStackEvent(stackItem: stackItem, type: undoing ? .redo : .undo, origin: transaction.origin)
        if didAdd { onStackItemAdded?(event) } else { onStackItemUpdated?(event) }
    }

    /// yjs `popStackItem` (@3508): pop items until one changes the document.
    private func popStackItem(undo isUndo: Bool) throws -> YUndoStackItem? {
        try doc.transact(origin: origin) { transaction in
            let store = doc.store
            while currStackItem == nil, let stackItem = isUndo ? undoStack.popLast() : redoStack.popLast() {
                var itemsToRedo: [YItem] = []  // yjs's insertion-ordered `Set<Item>`
                var redoSet = Set<ObjectIdentifier>()
                var itemsToDelete: [YItem] = []
                var performedChange = false
                try YStructStore.iterateDeletedStructs(transaction, stackItem.insertions) { s in
                    guard let inserted = s as? YItem else { return }
                    var s: YStruct = inserted
                    if inserted.redone != nil {
                        let (item, diff) = try YStructStore.followRedone(store, inserted.id)
                        s =
                            diff > 0
                            ? try YStructStore.getItemCleanStart(
                                transaction, YID(client: item.id.client, clock: item.id.clock + diff))
                            : item
                    }
                    if let item = s as? YItem, !item.deleted, inScope(item) { itemsToDelete.append(item) }
                }
                try YStructStore.iterateDeletedStructs(transaction, stackItem.deletions) { s in
                    // Never redo structs in `insertions`: they were created and
                    // deleted in the same capture interval.
                    if let item = s as? YItem, inScope(item), !stackItem.insertions.isDeleted(item.id),
                        redoSet.insert(ObjectIdentifier(item)).inserted
                    {
                        itemsToRedo.append(item)
                    }
                }
                for item in itemsToRedo {
                    performedChange =
                        try YItem.redoItem(
                            transaction, item, redoSet, stackItem.insertions, ignoreRemoteMapChanges, self) != nil
                        || performedChange
                }
                // Delete in reverse so children go before parents, giving the filter
                // more information.
                for item in itemsToDelete.reversed() where deleteFilter(item) {
                    item.delete(transaction)
                    performedChange = true
                }
                currStackItem = performedChange ? stackItem : nil
            }
            // Destroy the search marker if necessary (Schrift keeps none; see `_searchMarker`).
            for (_, entry) in transaction.changed where entry.subs.contains(nil) {
                entry.type._searchMarker?.removeAll()
            }
        }
        guard let result = currStackItem else { return nil }
        onStackItemPopped?(YUndoStackEvent(stackItem: result, type: isUndo ? .undo : .redo, origin: origin))
        currStackItem = nil
        return result
    }
}
