import Foundation

// MARK: - Format attribute value (JS `===` semantics over raw JSON)

/// A `ContentFormat` value, compared with JS `===`.
///
/// yjs stores the parsed value and compares attribute values with `===`; Schrift
/// keeps the raw `valueJSON` (see `YContent.format`), so this reproduces the same
/// decision without parsing: **primitives compare by JSON text, objects/arrays by
/// owning-item identity** (two separate `ContentFormat.value` objects are never
/// `===`, even when structurally equal). JSON `null` is never stored — yjs's
/// `updateCurrentAttributes` *deletes* the key on a null value — so an absent key
/// represents `null`, which means `Optional<YFormatAttrValue>` equality *is* JS
/// `===`: `nil == nil` ⇔ `null === null`, `nil == .some` ⇔ `null === obj` (false),
/// and `.some == .some` by the cases.
enum YFormatAttrValue: Equatable {
    /// JSON text of a scalar (bool / number / string) — compared by text.
    case primitive(String)
    /// An object/array value — identity of the owning item; never `==` another item's.
    case object(ObjectIdentifier)

    /// The value of `item`'s `ContentFormat`, or nil when it is JSON `null` (which
    /// `updateCurrentAttributes` treats as "delete the key"). `nil` for a non-format
    /// item (never reached — callers gate on `.format`).
    static func of(_ item: YItem) -> YFormatAttrValue? {
        guard case .format(_, let valueJSON) = item.content else { return nil }
        if valueJSON == "null" { return nil }
        // `valueJSON` is `JSON.stringify(value)` off the wire — compact, no leading
        // whitespace — so the first byte distinguishes an object/array from a scalar.
        let first = valueJSON.first
        if first == "{" || first == "[" { return .object(ObjectIdentifier(item)) }
        return .primitive(valueJSON)
    }
}

// MARK: - Struct iteration over the delete set

extension YStructStore {
    /// yjs `iterateDeletedStructs` (yjs.cjs @121) — call `f` on every struct
    /// named by `ds`. Uses the **original** transaction for splits (so a boundary
    /// split lands on `transaction.mergeStructs`, merged in that transaction's own
    /// finally), exactly as yjs.
    static func iterateDeletedStructs(
        _ transaction: YTransaction, _ ds: YDeleteSet, _ f: (YStruct) throws -> Void
    ) throws {
        // yjs `Map` insertion order. This routing is NOT confluent across clients: a
        // format-owning client processed first adds its parent to `needFullCleanup`,
        // which suppresses every later client's *contextless* cleanup on that type.
        // Ascending order diverges from yjs (differential fuzz seed-174); insertion
        // order reproduces it, and it is deterministic where a raw `Dictionary` is not.
        for client in ds.orderedClients {
            let deletes = ds.clients[client]!
            guard let list = transaction.doc.store.clients[client], let last = list.structs.last
            else { continue }
            let clockState = last.id.clock + last.length
            var i = 0
            while i < deletes.count {
                let del = deletes[i]
                if del.clock >= clockState { break }
                try iterateStructs(transaction, list, clockStart: del.clock, len: del.len, f)
                i += 1
            }
        }
    }
}

// MARK: - Formatting cleanup

/// yjs's YText formatting-cleanup pass — transliterated from `types/YText.js`.
///
/// In yjs these are private helpers on the YText module. Schrift's store is
/// type-agnostic (one `YType`), so a "formatted text" is any `YType` with
/// `_hasFormatting` — which only ever holds for text types, since `ContentFormat`
/// exists only inside text. The trigger fires on a *remote* transaction; see
/// `YTransaction.cleanupTransactions`'s observer phase.
enum YTextCleanup {
    /// yjs `updateCurrentAttributes` (yjs.cjs @6421) — a null value deletes the key.
    static func updateCurrentAttributes(_ current: inout [String: YFormatAttrValue], _ item: YItem) {
        guard case .format(let key, _) = item.content else { return }
        if let value = YFormatAttrValue.of(item) {
            current[key] = value
        } else {
            current.removeValue(forKey: key)
        }
    }

    /// yjs `cleanupContextlessFormattingGap` (yjs.cjs @6657) — around a deleted, non-format
    /// item, delete duplicate-key formats in the surrounding uncountable/deleted gap.
    static func cleanupContextlessFormattingGap(_ transaction: YTransaction, _ item: YItem) {
        // Iterate until item.right is null or countable-undeleted content.
        var current: YItem? = item
        while let c = current, let r = c.right, r.deleted || !r.countable {
            current = c.right
        }
        var attrs = Set<String>()
        // Iterate back until a content item is found, deleting repeated format keys.
        while let c = current, c.deleted || !c.countable {
            if !c.deleted, case .format(let key, _) = c.content {
                if attrs.contains(key) { c.delete(transaction) } else { attrs.insert(key) }
            }
            current = c.left
        }
    }

    /// yjs `cleanupFormattingGap` (yjs.cjs @6601) — within `[start, end)` (the gap up to the
    /// next countable content), delete each format that is either overwritten (a
    /// later format for its key exists in the gap) or already the current value.
    /// Returns the number deleted.
    @discardableResult
    static func cleanupFormattingGap(
        _ transaction: YTransaction, start: YItem, curr: YItem?,
        startAttributes: [String: YFormatAttrValue], currAttributes: inout [String: YFormatAttrValue]
    ) -> Int {
        // `endFormats[key]` = the rightmost format for `key` in the gap. yjs stores
        // the ContentFormat object and compares `endFormats.get(key) !== content`;
        // content ↔ item is 1:1, so we key by the owning `YItem` and compare identity.
        var end: YItem? = start
        var endFormats: [String: YItem] = [:]
        while let e = end, !e.countable || e.deleted {
            if !e.deleted, case .format(let key, _) = e.content { endFormats[key] = e }
            end = e.right
        }
        var cleanups = 0
        var reachedCurr = false
        var startVar: YItem? = start
        while startVar !== end {
            let s = startVar!
            if curr === s { reachedCurr = true }
            if !s.deleted, case .format(let key, _) = s.content {
                let value = YFormatAttrValue.of(s)  // nil == JS null
                let startAttrValue = startAttributes[key]  // nil == JS null
                if endFormats[key] !== s || startAttrValue == value {
                    // Either this format is overwritten or it is not necessary because
                    // the attribute already had this value.
                    s.delete(transaction)
                    cleanups += 1
                    if !reachedCurr, currAttributes[key] == value, startAttrValue != value {
                        if startAttrValue == nil {
                            currAttributes.removeValue(forKey: key)
                        } else {
                            currAttributes[key] = startAttrValue
                        }
                    }
                }
                if !reachedCurr, !s.deleted { updateCurrentAttributes(&currAttributes, s) }
            }
            startVar = s.right
        }
        return cleanups
    }

    /// yjs `cleanupYTextFormatting` (yjs.cjs @6689) — iterate the whole type once, cleaning
    /// each gap between countable contents. Opens/joins the surrounding transaction.
    @discardableResult
    static func cleanupYTextFormatting(_ type: YType) throws -> Int {
        guard let doc = type.doc else { return 0 }
        var res = 0
        try doc.transact(local: true) { transaction in
            var start: YItem? = type.start
            var end: YItem? = type.start
            var startAttributes: [String: YFormatAttrValue] = [:]
            var currentAttributes = startAttributes
            while let e = end {
                if !e.deleted {
                    if case .format = e.content {
                        updateCurrentAttributes(&currentAttributes, e)
                    } else {
                        res += cleanupFormattingGap(
                            transaction, start: start!, curr: end,
                            startAttributes: startAttributes, currAttributes: &currentAttributes)
                        startAttributes = currentAttributes
                        start = end
                    }
                }
                end = e.right
            }
        }
        return res
    }

    /// yjs `cleanupYTextAfterTransaction` (yjs.cjs @6721) — the entry point, run in the
    /// original transaction's observer phase when `needFormattingCleanup` is armed.
    ///
    /// First scans the newly-added structs for an inserted `ContentFormat` (its
    /// parent needs a full cleanup). Then, in a **new local** transaction, walks the
    /// original transaction's deleted structs: a deleted `ContentFormat`'s parent
    /// also needs a full cleanup; any other deleted item gets a contextless gap
    /// cleanup. Finally each collected type is fully cleaned. The new transaction is
    /// local, so it never re-arms `needFormattingCleanup` (no recursion).
    static func cleanupYTextAfterTransaction(_ transaction: YTransaction) throws {
        // yjs `needFullCleanup` is a `Set<YText>` in insertion order; we keep the same
        // order (an array with an identity guard) so the final full-cleanup pass is
        // deterministic. Membership is by object identity.
        var needFullCleanup: [YType] = []
        var needFullCleanupIDs = Set<ObjectIdentifier>()
        func markFullCleanup(_ type: YType) {
            if needFullCleanupIDs.insert(ObjectIdentifier(type)).inserted { needFullCleanup.append(type) }
        }
        let doc = transaction.doc
        // Check if another formatting item was inserted. Ascending client order for a
        // stable dump; this loop only collects parents into a set and its per-client
        // scans start/end on struct boundaries (no split), so the order is not
        // outcome-sensitive here (unlike the deleted-struct routing below).
        for client in transaction.afterState.keys.sorted() {
            let afterClock = transaction.afterState[client]!
            let clock = transaction.beforeState[client] ?? 0
            if afterClock == clock { continue }
            guard let list = doc.store.clients[client] else { continue }
            // yjs passes `afterClock` (not afterClock - clock) as `len`; the array-end
            // bound makes it harmless — transliterated literally.
            try YStructStore.iterateStructs(transaction, list, clockStart: clock, len: afterClock) { s in
                guard let item = s as? YItem, !item.deleted, case .format = item.content else { return }
                if let parent = item.parentType { markFullCleanup(parent) }
            }
        }
        // Clean up in a new (local) transaction.
        try doc.transact(local: true) { t in
            try YStructStore.iterateDeletedStructs(transaction, transaction.deleteSet) { s in
                guard let item = s as? YItem else { return }  // a GC struct → skip
                guard let parent = item.parentType, parent._hasFormatting else { return }
                if needFullCleanupIDs.contains(ObjectIdentifier(parent)) { return }
                if case .format = item.content {
                    markFullCleanup(parent)
                } else {
                    // No formatting attribute was inserted or deleted, so a contextless
                    // cleanup suffices for this gap.
                    cleanupContextlessFormattingGap(t, item)
                }
            }
            for yText in needFullCleanup {
                try cleanupYTextFormatting(yText)
            }
        }
    }
}
