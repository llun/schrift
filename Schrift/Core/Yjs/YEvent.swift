import Foundation

// MARK: - Path

/// One step of a `YEvent` path — yjs's `Array<string|number>`: a map key for a
/// map child, the child's index among its **visible** siblings for a list child.
///
/// The literal conformances let a test spell a path exactly as the yjs oracle
/// records it (`[0, 0, 0]`, `["id"]`).
enum YPathComponent: Equatable, Hashable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case index(UInt)
    case key(String)

    init(integerLiteral value: UInt) { self = .index(value) }
    init(stringLiteral value: String) { self = .key(value) }
}

// MARK: - Delta

/// One `insert` value in a text delta — yjs's `{ insert: string | object |
/// AbstractType }`.
enum YDeltaInsert: Equatable {
    /// `ContentString` text. A string-valued `ContentEmbed` lands here too: yjs
    /// cannot tell the two apart once the value is a string.
    case text(String)
    /// `ContentEmbed` — its raw JSON text. yjs carries the parsed value; the
    /// delta's insert is the same JSON value either way.
    case embed(json: String)
    /// `ContentType` — an embedded shared type (an `XmlElement` inside an
    /// `XmlText`). Compared by identity, as yjs's `===` would.
    case type(YType)

    static func == (lhs: YDeltaInsert, rhs: YDeltaInsert) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): return a == b
        case (.embed(let a), .embed(let b)): return a == b
        case (.type(let a), .type(let b)): return a === b
        default: return false
        }
    }
}

/// One attribute value in a delta op — the `ContentFormat` value's raw JSON text,
/// or JSON `null` (a `retain` that removes the attribute).
enum YDeltaAttribute: Equatable, ExpressibleByStringLiteral {
    case json(String)
    case null

    init(stringLiteral value: String) { self = .json(value) }

    /// The raw JSON text, or nil for JSON `null` — the shape `equalAttrs` takes.
    var jsonText: String? {
        switch self {
        case .json(let text): return text
        case .null: return nil
        }
    }
}

/// One operation of a text delta — yjs's `{ insert }` / `{ retain, attributes? }`
/// / `{ delete }`.
struct YDeltaOp: Equatable {
    enum Kind: Equatable {
        case insert(YDeltaInsert)
        case retain(UInt)
        case delete(UInt)
    }

    var kind: Kind
    /// Absent (`nil`) when yjs omits the key — an insert with no attributes in
    /// force, a retain that changes none. Never `[:]`.
    var attributes: [String: YDeltaAttribute]?

    static func insert(_ text: String, attributes: [String: YDeltaAttribute]? = nil) -> YDeltaOp {
        YDeltaOp(kind: .insert(.text(text)), attributes: attributes)
    }

    static func insert(_ value: YDeltaInsert, attributes: [String: YDeltaAttribute]? = nil) -> YDeltaOp {
        YDeltaOp(kind: .insert(value), attributes: attributes)
    }

    static func retain(_ length: UInt, attributes: [String: YDeltaAttribute]? = nil) -> YDeltaOp {
        YDeltaOp(kind: .retain(length), attributes: attributes)
    }

    static func delete(_ length: UInt) -> YDeltaOp {
        YDeltaOp(kind: .delete(length), attributes: nil)
    }
}

// MARK: - Event

/// One change event — yjs `YEvent` (@4546), with `YTextEvent`'s delta folded in.
///
/// yjs splits the two classes because `YTextEvent` adds `childListChanged`,
/// `keysChanged` and `changes`; the only subclass state the change signal needs
/// is `delta`, which is nil for a non-text target, so one class covers both.
final class YEvent {
    /// The type the event was raised on — yjs `YEvent.target`.
    let target: YType
    /// The transaction that raised it — yjs `YEvent.transaction`.
    let transaction: YTransaction

    private var _path: [YPathComponent]?
    private var _delta: [YDeltaOp]?

    init(target: YType, transaction: YTransaction) {
        self.target = target
        self.transaction = transaction
    }

    /// yjs `getPathTo` (@4786) — the path from the root type to `target`: a map
    /// key for a map child, the child's index among its **visible** siblings for
    /// a list child.
    ///
    /// yjs's `YEvent.path` is relative to `currentTarget`, which only
    /// `observeDeep` changes; Schrift has no `observeDeep`, so the path is always
    /// from the root — the value yjs's `getPathTo(root, target)` produces.
    var path: [YPathComponent] {
        if let cached = _path { return cached }
        var path: [YPathComponent] = []
        var child = target
        while let item = child.item {
            if let parentSub = item.parentSub {
                path.insert(.key(parentSub), at: 0)
            } else {
                var index: UInt = 0
                var sibling = item.parentType?.start
                while let current = sibling, current !== item {
                    if !current.deleted && current.countable { index += current.length }
                    sibling = current.right
                }
                path.insert(.index(index), at: 0)
            }
            guard let parent = item.parentType else { break }
            child = parent
        }
        _path = path
        return path
    }

    /// yjs `YTextEvent.delta` (@6893) — the Quill-style delta of this
    /// transaction's change to a text: `insert` (with the attributes in force),
    /// `retain` (with the attributes that changed) and `delete`.
    ///
    /// **Only valid during the `afterTransaction` call that raised this event.**
    /// It is computed from the transaction's before-state and delete set against
    /// the *live* item list, so once `cleanupTransactions` has gc'd and merged,
    /// the same read would describe a different store. yjs has the same rule (its
    /// `changes` throws once the cleanup queue is empty); Schrift documents it
    /// rather than throwing, because a delta is a read and a late read is a
    /// caller bug, not peer data.
    ///
    /// `nil` for a non-text target: plan §5 covers `XmlText` only, and an
    /// element's change is rebuilt from a projection of that block.
    ///
    /// yjs wraps the computation in `transact(...)`, which queues an empty extra
    /// transaction (and lets the getter delete redundant format items). Schrift
    /// does not: reading a delta must not open a transaction, and the redundant
    /// formats are removed by the B4 cleanup that runs immediately after the
    /// hook. The delta's *values* are unaffected — a redundant format contributes
    /// no op either way.
    var delta: [YDeltaOp]? {
        guard target.isText else { return nil }
        if let cached = _delta { return cached }
        let computed = computeDelta()
        _delta = computed
        return computed
    }

    /// yjs `YEvent.adds` (@4690) — whether this transaction minted the struct.
    func adds(_ `struct`: YStruct) -> Bool {
        `struct`.id.clock >= (transaction.beforeState[`struct`.id.client] ?? 0)
    }

    /// yjs `YEvent.deletes` (@4610) — whether this transaction deleted the
    /// struct (including one it added and then deleted).
    func deletes(_ `struct`: YStruct) -> Bool {
        transaction.deleteSet.isDeleted(`struct`.id)
    }

    // MARK: Delta computation

    private enum DeltaAction {
        case insert
        case retain
        case delete
    }

    /// yjs `YTextEvent.delta`'s body (@6893-7075), minus the `transact` wrapper.
    private func computeDelta() -> [YDeltaOp] {
        var delta: [YDeltaOp] = []
        // `currentAttributes` never holds JSON null (`updateCurrentAttributes`
        // deletes the key instead); `oldAttributes` treats absent as null, which
        // is how yjs reads it (`oldAttributes.get(key) ?? null`).
        var currentAttributes: [String: String] = [:]
        var oldAttributes: [String: String] = [:]
        var item = target.start
        var action: DeltaAction?
        var attributes: [String: YDeltaAttribute] = [:]
        var insertText: [UInt16] = []
        var insertValue: YDeltaInsert?
        var retain: UInt = 0
        var deleteLen: UInt = 0

        func insertAttributes() -> [String: YDeltaAttribute]? {
            guard !currentAttributes.isEmpty else { return nil }
            var result: [String: YDeltaAttribute] = [:]
            for (key, text) in currentAttributes { result[key] = .json(text) }
            return result
        }

        func addOp() {
            guard let current = action else { return }
            switch current {
            case .delete:
                if deleteLen > 0 { delta.append(.delete(deleteLen)) }
                deleteLen = 0
            case .insert:
                if let value = insertValue {
                    delta.append(.insert(value, attributes: insertAttributes()))
                } else if !insertText.isEmpty {
                    // Decode once, at the op boundary: a surrogate pair split
                    // across two `ContentString` items is one character in JS.
                    delta.append(
                        .insert(
                            .text(String(decoding: insertText, as: UTF16.self)),
                            attributes: insertAttributes()))
                }
                insertText = []
                insertValue = nil
            case .retain:
                if retain > 0 {
                    delta.append(.retain(retain, attributes: attributes.isEmpty ? nil : attributes))
                }
                retain = 0
            }
            action = nil
        }

        while let current = item {
            switch current.content {
            case .type, .embed:
                if adds(current) {
                    if !deletes(current) {
                        addOp()
                        action = .insert
                        if case .type(let type) = current.content {
                            insertValue = .type(type)
                        } else if case .embed(let json) = current.content {
                            insertValue = .embed(json: json)
                        }
                        addOp()
                    }
                } else if deletes(current) {
                    if action != .delete {
                        addOp()
                        action = .delete
                    }
                    deleteLen += 1
                } else if !current.deleted {
                    if action != .retain {
                        addOp()
                        action = .retain
                    }
                    retain += 1
                }

            case .string(let units):
                if adds(current) {
                    if !deletes(current) {
                        if action != .insert {
                            addOp()
                            action = .insert
                        }
                        insertText += units
                    }
                } else if deletes(current) {
                    if action != .delete {
                        addOp()
                        action = .delete
                    }
                    deleteLen += current.length
                } else if !current.deleted {
                    if action != .retain {
                        addOp()
                        action = .retain
                    }
                    retain += current.length
                }

            case .format(let key, let valueJSON):
                let value: String? = valueJSON == "null" ? nil : valueJSON
                if adds(current) {
                    if !deletes(current) {
                        let curVal = currentAttributes[key]
                        if !YJSONValue.equalAttrs(curVal, value) {
                            if action == .retain { addOp() }
                            if YJSONValue.equalAttrs(value, oldAttributes[key]) {
                                attributes.removeValue(forKey: key)
                            } else {
                                attributes[key] = value.map(YDeltaAttribute.json) ?? .null
                            }
                        } else if value != nil {
                            // yjs deletes the redundant item here, inside the
                            // transaction its delta getter opens. Schrift's delta
                            // is a pure read; the B4 cleanup removes it right
                            // after the hook.
                        }
                    }
                } else if deletes(current) {
                    oldAttributes[key] = value
                    let curVal = currentAttributes[key]
                    if !YJSONValue.equalAttrs(curVal, value) {
                        if action == .retain { addOp() }
                        attributes[key] = curVal.map(YDeltaAttribute.json) ?? .null
                    }
                } else if !current.deleted {
                    oldAttributes[key] = value
                    if let attr = attributes[key] {
                        if !YJSONValue.equalAttrs(attr.jsonText, value) {
                            if action == .retain { addOp() }
                            if let value {
                                attributes[key] = .json(value)
                            } else {
                                attributes.removeValue(forKey: key)
                            }
                        } else if attr != .null {
                            // Redundant; see the `adds` branch above.
                        }
                    }
                }
                if !current.deleted {
                    if action == .insert { addOp() }
                    Self.updateCurrentAttributes(&currentAttributes, current)
                }

            case .deleted, .json, .binary, .any, .doc:
                // yjs's `switch` has no case for these, so they neither emit an
                // op nor break the current run.
                break
            }
            item = current.right
        }
        addOp()
        // yjs drops trailing retains that assign no attributes.
        while let last = delta.last, case .retain = last.kind, last.attributes == nil {
            delta.removeLast()
        }
        return delta
    }

    /// yjs `updateCurrentAttributes` (@6424) over raw JSON text — the delta's
    /// attribute maps keep the text they emit, where the cleanup keeps
    /// `YFormatAttrValue` (JS `===`). Same rule: a null value deletes the key.
    private static func updateCurrentAttributes(_ current: inout [String: String], _ item: YItem) {
        guard case .format(let key, let valueJSON) = item.content else { return }
        if valueJSON == "null" {
            current.removeValue(forKey: key)
        } else {
            current[key] = valueJSON
        }
    }

    // MARK: Observer dispatch

    /// yjs `callTypeObservers` (@5030) — record `event` at `type` and at every
    /// ancestor up to the root, then call the type's own listeners (Schrift has
    /// none).
    ///
    /// The same event instance is shared by every ancestor, exactly as in yjs.
    static func callTypeObservers(_ type: YType, _ transaction: YTransaction, _ event: YEvent) {
        var current: YType? = type
        while let changed = current {
            transaction.addChangedParentType(changed, event)
            guard let item = changed.item, let parent = item.parentType else { break }
            current = parent
        }
    }
}

// MARK: - Type observer

extension YType {
    /// yjs `AbstractType._callObserver` (@5146) and its per-class overrides.
    ///
    /// yjs dispatches on the concrete class; Schrift has one `YType`, so the
    /// dispatch is `isText`. A text raises a `YTextEvent` (the one event with a
    /// delta) and arms B4's formatting cleanup; every other type raises a plain
    /// event. `YArray`/`YMap`/`YXmlElement`/`YXmlFragment` all do the same thing
    /// here — one event, no delta — because plan §5 covers `XmlText` deltas only.
    func callObserver(_ transaction: YTransaction, _ parentSubs: Set<String?>) {
        // yjs `AbstractType._callObserver` clears the search-marker cache on a
        // remote change. Schrift keeps no markers (see `_searchMarker`), so that
        // is a no-op.
        let event = YEvent(target: self, transaction: transaction)
        YEvent.callTypeObservers(self, transaction, event)
        // yjs `YText._callObserver` (@7158), shared by `YText` and `YXmlText`.
        //
        // yjs dispatches on the concrete class; Schrift has one `YType`, and a
        // root created by `applyUpdate` is a bare type whose kind the wire does
        // not carry (yjs's caller picks it with `getText`). So the arming keeps
        // the pre-existing reduction: any changed type with `_hasFormatting`
        // arms the cleanup. Only a text can hold a `ContentFormat`, so this is
        // the same set of types in practice.
        if !transaction.local, _hasFormatting {
            transaction.needFormattingCleanup = true
        }
    }
}
