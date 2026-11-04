import Foundation

// MARK: - Encoding one finished transaction (Yjs v1)

/// Encodes only a transaction's new structs and own deletes, without scanning the
/// store for historical tombstones. For live edits; snapshots and peer state-vector
/// replies still use `YStateEncoder.encodeStateAsUpdate` (the full delete set).
/// Transliterates yjs 13.6.31 `writeUpdateMessageFromTransaction` (@3163).
enum YTransactionEncoder {
    /// Call immediately after the outermost `doc.transact` returns successfully,
    /// before another transaction changes the store. Return the transaction from
    /// its closure to retain it without changing `YDoc.transact`'s behavior. Cleanup
    /// must have filled `afterState` and finished gc/merging, as it has when yjs
    /// emits its `update` event (@3389). Nested transact returns do not suffice.
    ///
    /// `duringCleanup` is the one exception, and only `YDoc.onUpdate` passes it:
    /// yjs emits `'update'` from inside `cleanupTransactions` (@3385-3389), where
    /// the queue is still non-empty but *this* transaction's own gc/merge has
    /// finished. Every other caller keeps the stricter "queue must be empty" gate.
    ///
    /// Like `YStateEncoder`, deliberately refuses a replica with pending state.
    /// Returns nil when neither deletes nor changed clocks need to be sent.
    static func encodeUpdate(_ transaction: YTransaction, duringCleanup: Bool = false) throws -> Data? {
        let doc = transaction.doc
        guard doc.transaction == nil, duringCleanup || doc.transactionCleanups.isEmpty,
            doc.store.pendingStructs == nil, doc.store.pendingDs == nil
        else { throw YIntegrationError.unexpectedCase }

        // yjs @3164: an absent beforeState entry differs from every clock,
        // including zero (Map.get returns undefined, not a default zero).
        if transaction.deleteSet.isEmpty,
            !transaction.afterState.contains(where: { client, clock in transaction.beforeState[client] != clock })
        {
            return nil
        }
        transaction.deleteSet.sortAndMerge()  // yjs @3167, sortAndMergeDeleteSet @179
        var e = Lib0Encoder()
        // yjs writeStructsFromTransaction (@1674): the same writeClientsStructs
        // path as state diffs, including offset-origin substitution after merging.
        try YStateEncoder.writeClientsStructs(&e, doc.store, transaction.beforeState)
        // yjs @3169, writeDeleteSet @285: only this transaction, clients descending.
        YUpdateReencoder.encodeDeleteSet(&e, YStateEncoder.deleteBlocks(transaction.deleteSet))
        return e.data
    }
}
