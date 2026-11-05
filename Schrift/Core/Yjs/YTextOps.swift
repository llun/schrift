import Foundation

// MARK: - Attribute maps

/// yjs's attribute *value object* — the thing `===` compares in
/// `cleanupFormattingGap` (@6627).
///
/// yjs stores the caller's value object in `currentAttributes` and hands that
/// **same object** to every `ContentFormat` it mints from it, so two format items
/// can be `===` even though they are different items. Deriving identity from the
/// owning item loses that: a restored attribute looked new and survived a cleanup
/// yjs performs. So the value carries an explicit token instead:
///
/// - a value minted from caller JSON gets a **fresh** token;
/// - a value re-used from `currentAttributes` or an existing format (the restore,
///   negation and minimize paths) **keeps the source's** token;
/// - an item decoded from the wire gets its own token on first use, so the remote
///   path keeps yjs's post-round-trip behaviour (the encoder writes the JSON
///   twice and the decoder builds two objects).
///
/// The token is never encoded.
final class YAttributeIdentity {}

/// One attribute value in force at a text position — yjs's `Map<string, any>`
/// entry, kept as the raw JSON text plus the identity token of the value object.
///
/// Two different comparisons are needed over the same map, and yjs gets both from
/// the one parsed value object it stores:
///
/// - the **ops** path (`insertAttributes` @6462, `minimizeAttributeChanges` @6440,
///   `formatText` @6526) uses `equalAttrs` (@6282), which compares two objects
///   by identity first, then by flat enumerable keys (lib0 `equalFlat`);
/// - the **cleanup** path (`cleanupFormattingGap` @6604) uses `===`, which
///   compares two objects by *identity* — so `identity` is what matters.
struct YTextAttributeValue {
    /// The value's raw JSON text (`JSON.stringify(value)` off the wire). `"null"`
    /// is JSON null, which `updateCurrentAttributes` treats as "delete the key".
    let json: String
    /// The value object's identity — see `YAttributeIdentity`.
    let identity: YAttributeIdentity
}

/// An **ordered** attribute map — yjs's `Object<string, any>` (a caller's
/// `TextAttributes`) and `Map<string, any>` (`currentAttributes`).
///
/// Order is load-bearing: `insertAttributes` mints one `ContentFormat` item per
/// changed key in iteration order, so the order decides the clock order of those
/// items and therefore the update bytes. A Swift `Dictionary` has no order, so
/// this keeps one. `ExpressibleByDictionaryLiteral` preserves the literal's
/// source order, which is JS object-literal order for the non-integer keys every
/// schema uses (JS would hoist integer-like keys first; no attribute key is one).
struct YTextAttributes: ExpressibleByDictionaryLiteral {
    typealias Key = String
    typealias Value = String

    private(set) var keys: [String] = []
    private var values: [String: YTextAttributeValue] = [:]

    init() {}

    /// A caller's attributes: raw JSON text per key, in literal order.
    init(dictionaryLiteral elements: (String, String)...) {
        for (key, value) in elements {
            self[key] = YTextAttributeValue(json: value, identity: YAttributeIdentity())
        }
    }

    /// The same, from pairs built at runtime — the order is the array's.
    init(_ pairs: [(String, String)]) {
        for (key, value) in pairs {
            self[key] = YTextAttributeValue(json: value, identity: YAttributeIdentity())
        }
    }

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    /// `nil` reads as absent (JS `undefined`); writing `nil` deletes the key.
    /// Re-setting an existing key keeps its position, as a JS `Map.set` does.
    subscript(key: String) -> YTextAttributeValue? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else if values[key] != nil {
                values.removeValue(forKey: key)
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Iterate in insertion order.
    func forEach(_ body: (String, YTextAttributeValue) throws -> Void) rethrows {
        for key in keys {
            guard let value = values[key] else { continue }
            try body(key, value)
        }
    }
}

// MARK: - Insert value

/// What `insertText` inserts — yjs's `string | object | AbstractType<any>`.
enum YTextInsertValue {
    /// `ContentString`.
    case text(String)
    /// `ContentEmbed`, as its raw JSON text.
    case embed(json: String)
    /// `ContentType` — an embedded shared type.
    case type(YType)
}

// MARK: - Text operations

/// Format-aware operations on a text type — yjs's `YText` (`types/YText.js`),
/// transliterated from yjs 13.6.33. `YXmlText` shares every one of these in yjs
/// (it extends `YText`), and Schrift has one `YType`, so both use this file.
///
/// **Out-of-range indices are yjs's, not the editor's.** yjs does not clamp:
/// `findPosition` (@6367) walks until the child list ends, so an insert past the
/// end appends, a delete past the end stops at the end, and a format past the end
/// pads the text with `'\n'` (Quill's trailing-newline convention, @6584). Range
/// clamping for editor safety is the caller's job (B5's BlockNote writer), not
/// this layer's — clamping here would change the bytes a real yjs client produces.
///
/// **No search markers.** `YType._searchMarker` is always nil in this store, so
/// `findMarker` is not ported and `findPosition` always takes yjs's
/// `useSearchMarker === false` branch (@6374-6377). Every `updateMarkerChanges`
/// call is likewise a no-op and is dropped.
///
/// Pure value code with no concurrency annotations, but it **mutates** the live
/// replica graph, so it must run inside an open transaction owned by the replica's
/// single owner (`YDoc.transact`). See `AGENTS.md`, "The Yjs CRDT core".
enum YTextOps {

    // MARK: - Position

    /// yjs `ItemTextListPosition` (@6284) — a cursor over a text's child list that
    /// carries the visible index and the attributes in force at that point.
    final class ItemTextListPosition {
        var left: YItem?
        var right: YItem?
        var index: UInt
        var currentAttributes: YTextAttributes

        init(left: YItem?, right: YItem?, index: UInt, currentAttributes: YTextAttributes) {
            self.left = left
            self.right = right
            self.index = index
            self.currentAttributes = currentAttributes
        }

        /// yjs `forward()` (@6300) — step over `right`, folding a format into
        /// `currentAttributes` and any other content into `index`.
        ///
        /// Only call this when `right` is defined; yjs throws `unexpectedCase`
        /// otherwise, and so do we.
        func forward() throws {
            guard let right else { throw YIntegrationError.unexpectedCase }
            if case .format = right.content {
                if !right.deleted { YTextOps.updateCurrentAttributes(&currentAttributes, right) }
            } else if !right.deleted {
                index += right.length
            }
            left = right
            self.right = right.right
        }
    }

    /// yjs `findNextPosition` (@6331) — advance `pos` by `count` visible units,
    /// splitting the item the count lands inside so the cursor sits on a boundary.
    @discardableResult
    static func findNextPosition(
        _ transaction: YTransaction, _ pos: ItemTextListPosition, _ count: UInt
    ) throws -> ItemTextListPosition {
        var count = count
        while let right = pos.right, count > 0 {
            if case .format = right.content {
                if !right.deleted { updateCurrentAttributes(&pos.currentAttributes, right) }
            } else if !right.deleted {
                if count < right.length {
                    // Split `right` at the boundary; it is truncated in place to the
                    // left half, so the two lines below consume exactly `count`.
                    _ = try YStructStore.getItemCleanStart(
                        transaction, YID(client: right.id.client, clock: right.id.clock + count))
                }
                pos.index += right.length
                count -= min(count, right.length)  // yjs `count -= right.length`
            }
            pos.left = right
            pos.right = right.right
        }
        return pos
    }

    /// yjs `findPosition` (@6367) — the cursor for visible `index`, with the
    /// attributes in force there. Always the no-marker branch (see `YTextOps`).
    static func findPosition(
        _ transaction: YTransaction, _ parent: YType, index: UInt
    ) throws -> ItemTextListPosition {
        let pos = ItemTextListPosition(
            left: nil, right: parent.start, index: 0, currentAttributes: YTextAttributes())
        return try findNextPosition(transaction, pos, index)
    }

    // MARK: - Attributes

    /// yjs `updateCurrentAttributes` (@6424) — a null value deletes the key.
    ///
    /// The `[String: YFormatAttrValue]` overload in `YTextCleanup` is the cleanup
    /// pass's `===` view; this one keeps the raw JSON the ops path compares
    /// structurally.
    static func updateCurrentAttributes(_ current: inout YTextAttributes, _ item: YItem) {
        guard case .format(let key, let valueJSON) = item.content else { return }
        if valueJSON == "null" {
            current[key] = nil
        } else {
            current[key] = YTextAttributeValue(json: valueJSON, identity: item.resolvedFormatIdentity())
        }
    }

    /// yjs `insertNegatedAttributes` (@6390) — after inserting content, re-apply
    /// the attributes the insert had to negate, skipping formats already in place.
    static func insertNegatedAttributes(
        _ transaction: YTransaction, _ parent: YType, _ currPos: ItemTextListPosition,
        _ negatedAttributes: inout YTextAttributes
    ) throws {
        // Skip deleted items and formats that already carry the negated value.
        while let right = currPos.right,
            right.deleted
                || (isFormat(right) && equalAttrs(negatedAttributes[formatKey(right)], right))
        {
            if !right.deleted { negatedAttributes[formatKey(right)] = nil }
            try currPos.forward()
        }
        let doc = transaction.doc
        let ownClientId = doc.clientID
        // yjs iterates the `Map` in insertion order; `YTextAttributes` keeps it.
        var minted: [(String, YTextAttributeValue)] = []
        negatedAttributes.forEach { key, value in minted.append((key, value)) }
        for (key, value) in minted {
            let left = currPos.left
            let right = currPos.right
            let nextFormat = YItem(
                id: YID(client: ownClientId, clock: doc.store.getState(ownClientId)),
                left: left,
                origin: left?.lastId,  // yjs `left && left.lastId`
                right: right,
                rightOrigin: right?.id,  // yjs `right && right.id`
                parent: .type(parent),
                parentSub: nil,
                content: .format(key: key, valueJSON: value.json))
            // yjs passes the value object it took from `currentAttributes`, so the
            // restored format stays `===` to the one it restores.
            nextFormat.formatIdentity = value.identity
            try nextFormat.integrate(transaction, offset: 0)
            currPos.right = nextFormat
            try currPos.forward()
        }
    }

    /// yjs `minimizeAttributeChanges` (@6440) — step over deleted items and
    /// formats that already hold the requested value, so the insert does not mint
    /// a redundant format.
    static func minimizeAttributeChanges(
        _ currPos: ItemTextListPosition, _ attributes: YTextAttributes
    ) throws {
        while let right = currPos.right {
            let matches =
                right.deleted
                || (isFormat(right)
                    && equalAttrs(attributes[formatKey(right)], right, absentIsNull: true))
            guard matches else { break }
            try currPos.forward()
        }
    }

    /// yjs `insertAttributes` (@6462) — mint a `ContentFormat` for every requested
    /// attribute whose value differs from the one in force, returning the values
    /// they replaced (the "negated" attributes) so the insert can restore them.
    static func insertAttributes(
        _ transaction: YTransaction, _ parent: YType, _ currPos: ItemTextListPosition,
        _ attributes: YTextAttributes
    ) throws -> YTextAttributes {
        let doc = transaction.doc
        let ownClientId = doc.clientID
        var negatedAttributes = YTextAttributes()
        var requested: [(String, YTextAttributeValue)] = []
        attributes.forEach { key, value in requested.append((key, value)) }
        for (key, value) in requested {
            // `currentAttributes.get(key) ?? null` — absent is JSON null here.
            let currentVal = currPos.currentAttributes[key]?.json ?? "null"
            guard
                !YJSONValue.equalAttrs(
                    currentVal, value.json,
                    identityA: currPos.currentAttributes[key]?.identity, identityB: value.identity)
            else { continue }
            // Save the negated attribute (null when it was absent).
            negatedAttributes[key] = YTextAttributeValue(
                json: currentVal,
                identity: currPos.currentAttributes[key]?.identity ?? YAttributeIdentity())
            let left = currPos.left
            let right = currPos.right
            let item = YItem(
                id: YID(client: ownClientId, clock: doc.store.getState(ownClientId)),
                left: left,
                origin: left?.lastId,
                right: right,
                rightOrigin: right?.id,
                parent: .type(parent),
                parentSub: nil,
                content: .format(key: key, valueJSON: value.json))
            // yjs stores the caller's value object in the new format item.
            item.formatIdentity = value.identity
            try item.integrate(transaction, offset: 0)
            currPos.right = item
            try currPos.forward()
        }
        return negatedAttributes
    }

    // MARK: - Insert

    /// yjs `insertText` (@6492) — insert `text` at `currPos`, applying
    /// `attributes` and restoring the attributes it had to negate.
    ///
    /// yjs mutates the caller's `attributes` object (adding a `null` for every
    /// attribute in force that the caller did not mention); the mutation is not
    /// observable to a caller, so this works on a copy.
    static func insertText(
        _ transaction: YTransaction, _ parent: YType, _ currPos: ItemTextListPosition,
        _ text: YTextInsertValue, _ attributes: YTextAttributes
    ) throws {
        var attributes = attributes
        // Every attribute in force that the caller did not mention is negated.
        currPos.currentAttributes.forEach { key, _ in
            if attributes[key] == nil {
                attributes[key] = YTextAttributeValue(json: "null", identity: YAttributeIdentity())
            }
        }
        let doc = transaction.doc
        let ownClientId = doc.clientID
        try minimizeAttributeChanges(currPos, attributes)
        var negatedAttributes = try insertAttributes(transaction, parent, currPos, attributes)
        let content: YContent
        switch text {
        case .text(let string): content = .string(Array(string.utf16))
        case .embed(let json): content = .embed(json: json)
        case .type(let type): content = .type(type)
        }
        let left = currPos.left
        let right = currPos.right
        let index = currPos.index
        let item = YItem(
            id: YID(client: ownClientId, clock: doc.store.getState(ownClientId)),
            left: left,
            origin: left?.lastId,
            right: right,
            rightOrigin: right?.id,
            parent: .type(parent),
            parentSub: nil,
            content: content)
        try item.integrate(transaction, offset: 0)
        currPos.right = item
        currPos.index = index
        try currPos.forward()
        try insertNegatedAttributes(transaction, parent, currPos, &negatedAttributes)
    }

    // MARK: - Format

    /// yjs `formatText` (@6526) — apply `attributes` over `length` visible units
    /// from `currPos`, deleting the formats it supersedes.
    ///
    /// Formatting past the end **pads the text with `'\n'`** (@6584): Quill assumes
    /// a document always ends with a newline, and yjs only inserts it when a format
    /// runs past the content. That is yjs's behavior, not a bug to clamp.
    static func formatText(
        _ transaction: YTransaction, _ parent: YType, _ currPos: ItemTextListPosition,
        _ length: UInt, _ attributes: YTextAttributes
    ) throws {
        let doc = transaction.doc
        let ownClientId = doc.clientID
        try minimizeAttributeChanges(currPos, attributes)
        var negatedAttributes = try insertAttributes(transaction, parent, currPos, attributes)
        var length = length
        // Iterate until the first non-format or null is found; delete every format
        // whose key the caller set to a different value. Keep going past the range
        // while negated attributes remain, so no redundant negation is inserted.
        iterationLoop: while let right = currPos.right,
            length > 0
                || (!negatedAttributes.isEmpty && (right.deleted || isFormat(right)))
        {
            if !right.deleted {
                if case .format(let key, let valueJSON) = right.content {
                    if let attr = attributes[key] {
                        if equalAttrs(attr, right) {
                            negatedAttributes[key] = nil
                        } else {
                            if length == 0 { break iterationLoop }
                            negatedAttributes[key] = YTextAttributeValue(
                                json: valueJSON, identity: right.resolvedFormatIdentity())
                        }
                        right.delete(transaction)
                    } else {
                        currPos.currentAttributes[key] = YTextAttributeValue(
                            json: valueJSON, identity: right.resolvedFormatIdentity())
                    }
                } else {
                    if length < right.length {
                        _ = try YStructStore.getItemCleanStart(
                            transaction, YID(client: right.id.client, clock: right.id.clock + length))
                    }
                    length -= min(length, right.length)  // yjs `length -= right.length`
                }
            }
            try currPos.forward()
        }
        if length > 0 {
            var newlines = ""
            while length > 0 {
                newlines += "\n"
                length -= 1
            }
            let left = currPos.left
            let right = currPos.right
            let item = YItem(
                id: YID(client: ownClientId, clock: doc.store.getState(ownClientId)),
                left: left,
                origin: left?.lastId,
                right: right,
                rightOrigin: right?.id,
                parent: .type(parent),
                parentSub: nil,
                content: .string(Array(newlines.utf16)))
            try item.integrate(transaction, offset: 0)
            currPos.right = item
            try currPos.forward()
        }
        try insertNegatedAttributes(transaction, parent, currPos, &negatedAttributes)
    }

    // MARK: - Delete

    /// yjs `deleteText` (@6777) — delete `length` visible units from `currPos`,
    /// then clean the formatting gap the deletion opened.
    ///
    /// The gap cleanup is `YTextCleanup.cleanupFormattingGap` (@6604), reused
    /// rather than duplicated. yjs also writes the cleanup's adjusted attributes
    /// back into `currPos.currentAttributes`; `YText.delete` discards the cursor,
    /// so that write-back is unobservable and is not reproduced.
    static func deleteText(
        _ transaction: YTransaction, _ currPos: ItemTextListPosition, _ length: UInt
    ) throws {
        let startAttrs = currPos.currentAttributes
        let start = currPos.right
        var length = length
        while length > 0, let right = currPos.right {
            if !right.deleted {
                switch right.content {
                case .type, .embed, .string:
                    if length < right.length {
                        _ = try YStructStore.getItemCleanStart(
                            transaction, YID(client: right.id.client, clock: right.id.clock + length))
                    }
                    length -= min(length, right.length)  // yjs `length -= right.length`
                    right.delete(transaction)
                case .deleted, .json, .binary, .format, .any, .doc:
                    break
                }
            }
            try currPos.forward()
        }
        if let start {
            var currAttributes = formatAttrValues(currPos.currentAttributes)
            YTextCleanup.cleanupFormattingGap(
                transaction, start: start, curr: currPos.right,
                startAttributes: formatAttrValues(startAttrs), currAttributes: &currAttributes)
        }
        // yjs updates the parent's search markers here; there are none (see `YTextOps`).
    }

    // MARK: - Helpers

    private static func isFormat(_ item: YItem) -> Bool {
        if case .format = item.content { return true }
        return false
    }

    /// The key of a `ContentFormat` item. Only called on one (guarded by
    /// `isFormat`); a non-format yields `""`, which no schema uses.
    private static func formatKey(_ item: YItem) -> String {
        if case .format(let key, _) = item.content { return key }
        return ""
    }

    /// The raw JSON value of a `ContentFormat` item. Only called on one.
    private static func formatValue(_ item: YItem) -> String {
        if case .format(_, let valueJSON) = item.content { return valueJSON }
        return "null"
    }

    /// yjs `equalAttrs` (@6282) over a stored value and a format item's value.
    ///
    /// `nil` is JS `undefined`, which is `===` to nothing — so an absent stored
    /// value never matches. `minimizeAttributeChanges` uses `?? null` instead.
    private static func equalAttrs(_ a: YTextAttributeValue?, _ b: YItem, absentIsNull: Bool = false) -> Bool {
        guard a != nil || absentIsNull else { return false }
        return YJSONValue.equalAttrs(
            a?.json ?? "null", formatValue(b), identityA: a?.identity, identityB: b.resolvedFormatIdentity())
    }

    /// The cleanup pass's `===` view of an attribute map (`YFormatAttrValue`):
    /// primitives by parsed value, objects by their identity token.
    ///
    /// The token is the same one `YFormatAttrValue.of` reads off the item, so a
    /// value carried through `currentAttributes` compares equal to the format item
    /// it came from — which is exactly what yjs's shared value object does.
    private static func formatAttrValues(_ attributes: YTextAttributes) -> [String: YFormatAttrValue] {
        var result: [String: YFormatAttrValue] = [:]
        attributes.forEach { key, value in
            guard value.json != "null" else { return }
            if YJSONValue.isContainer(value.json) {
                result[key] = .object(ObjectIdentifier(value.identity))
            } else {
                result[key] = .primitive(value.json)
            }
        }
        return result
    }
}

// MARK: - Public text API

/// yjs's `YText` public methods (@7362-@7450), shared by `YText` and `YXmlText`.
///
/// Each opens its own transaction with yjs's default origin (`null`), so the
/// formatting cleanup is not armed for a local edit — exactly as in yjs.
extension YType {

    /// yjs `YText.insert` (@7362).
    ///
    /// `attributes == nil` **inherits** the attributes in force at `index`; an
    /// explicit map applies exactly those, and a `"null"` value negates one.
    /// An empty `text` is a no-op, as in yjs.
    func insert(_ index: UInt, _ text: String, _ attributes: YTextAttributes? = nil) throws {
        guard !text.isEmpty else { return }
        guard let doc else { throw YIntegrationError.unexpectedCase }
        try doc.transact { transaction in
            let pos = try YTextOps.findPosition(transaction, self, index: index)
            var attributes = attributes
            if attributes == nil {
                var inherited = YTextAttributes()
                pos.currentAttributes.forEach { key, value in inherited[key] = value }
                attributes = inherited
            }
            try YTextOps.insertText(transaction, self, pos, .text(text), attributes!)
        }
    }

    /// yjs `YText.insertEmbed` (@7392). `embedJSON` is the embed value's raw JSON
    /// text (`ContentEmbed`'s wire form).
    func insertEmbed(_ index: UInt, _ embedJSON: String, _ attributes: YTextAttributes? = nil) throws {
        guard let doc else { throw YIntegrationError.unexpectedCase }
        try doc.transact { transaction in
            let pos = try YTextOps.findPosition(transaction, self, index: index)
            try YTextOps.insertText(
                transaction, self, pos, .embed(json: embedJSON), attributes ?? YTextAttributes())
        }
    }

    /// yjs `YText.delete` (@7412). A zero length is a no-op; a range past the end
    /// stops at the end.
    func delete(_ index: UInt, _ length: UInt) throws {
        guard length != 0 else { return }
        guard let doc else { throw YIntegrationError.unexpectedCase }
        try doc.transact { transaction in
            let pos = try YTextOps.findPosition(transaction, self, index: index)
            try YTextOps.deleteText(transaction, pos, length)
        }
    }

    /// yjs `YText.format` (@7436). A zero length is a no-op; a range past the end
    /// pads the text with `'\n'` (see `YTextOps.formatText`).
    func format(_ index: UInt, _ length: UInt, _ attributes: YTextAttributes) throws {
        guard length != 0 else { return }
        guard let doc else { throw YIntegrationError.unexpectedCase }
        try doc.transact { transaction in
            let pos = try YTextOps.findPosition(transaction, self, index: index)
            if pos.right == nil { return }
            try YTextOps.formatText(transaction, self, pos, length, attributes)
        }
    }
}
