import Foundation

// MARK: - Errors

/// Errors raised by the live Yjs document model (the struct store and YATA
/// integration). Each mirrors a specific yjs failure:
///
/// - `unexpectedCase` is yjs's `error.unexpectedCase()` — a state the algorithm
///   proves cannot arise for well-formed input. yjs throws there; so do we.
/// - `methodUnimplemented` is yjs's `error.methodUnimplemented()` — a content
///   kind that cannot be split (`ContentBinary`, `ContentEmbed`, …). Reaching it
///   means an update claimed a split inside single-unit content.
///
/// Both are *malformed-input* signals, not bugs to recover from: the caller
/// (`YDocument.applyUpdate`, later PRs) turns them into the roadmap's `failSafe`
/// state, which permanently forbids snapshot PATCHes from that replica.
enum YIntegrationError: Error, Equatable {
    case unexpectedCase
    case methodUnimplemented
}

// MARK: - Live content model

/// The live, **mutable** counterpart of `YContentRecord` (`YUpdateDecoder.swift`).
///
/// `YContentRecord` is the immutable *wire* record — it exists so a decoded
/// update re-encodes byte-identically, and it is deliberately not mutated. This
/// type is what an integrated `YItem` actually holds: it splits (`splice`) and
/// concatenates (`mergeWith`) as the store splits and merges items around it.
/// The two are kept apart so B1's identity round-trip cannot be perturbed by
/// store work; `init(record:)` is the one-way bridge into the live model.
///
/// A faithful transliteration of yjs's `AbstractContent` subclasses
/// (`ContentDeleted`/`JSON`/`Binary`/`String`/`Embed`/`Format`/`Type`/`Any`/`Doc`,
/// yjs.cjs @8557–9470). Content that is really JSON text on the wire
/// (embed/format value/doc options) stays a **raw string**, exactly as in
/// `YContentRecord`, so nothing hinges on JSON canonicalization.
///
/// Pure value code: no concurrency annotations, callable from any isolation
/// domain (`CLAUDE.md`, "Pure logic layers").
enum YContent {
    case deleted(len: UInt)  // 1  ContentDeleted
    case json([String])  // 2  ContentJSON — raw per-item strings ("undefined" kept literal)
    case binary(Data)  // 3  ContentBinary
    /// 4 ContentString. Stored as **UTF-16 code units**, not a `String`, because a
    /// JS string *is* a code-unit sequence and `splice` transiently produces a
    /// lone surrogate that no Swift `String` can represent — see `splice(_:)`.
    case string([UInt16])
    case embed(json: String)  // 5  ContentEmbed — raw JSON text
    case format(key: String, valueJSON: String)  // 6  ContentFormat — raw JSON value text
    case type(YType)  // 7  ContentType
    case any([YAnyValue])  // 8  ContentAny
    case doc(guid: String, options: YAnyValue)  // 9  ContentDoc

    // MARK: Wire identity

    /// Content ref id (low 5 bits of an item's info byte) — yjs `getRef()`.
    ///
    /// Each yjs content class has a unique ref, so comparing refs is exactly
    /// yjs's `this.content.constructor === right.content.constructor` test.
    var ref: UInt8 {
        switch self {
        case .deleted: return 1
        case .json: return 2
        case .binary: return 3
        case .string: return 4
        case .embed: return 5
        case .format: return 6
        case .type: return 7
        case .any: return 8
        case .doc: return 9
        }
    }

    /// yjs `getLength()` — how far this content advances the client's clock.
    /// Strings count UTF-16 code units (JS `String.length`); list contents count
    /// their items; everything else is a single unit.
    var length: UInt {
        switch self {
        case .deleted(let len): return len
        case .string(let units): return UInt(units.count)
        case .json(let items): return UInt(items.count)
        case .any(let values): return UInt(values.count)
        case .binary, .embed, .format, .type, .doc: return 1
        }
    }

    /// yjs `isCountable()` — whether this content contributes to its parent
    /// type's `_length`. **Only `ContentDeleted` and `ContentFormat` are not
    /// countable**; every other kind is (yjs.cjs: ContentDeleted @8644,
    /// ContentFormat @8970). This drives `YItem.info` bit 2 at construction.
    var isCountable: Bool {
        switch self {
        case .deleted, .format: return false
        case .json, .binary, .string, .embed, .type, .any, .doc: return true
        }
    }

    // MARK: Splitting

    /// yjs `splice(offset)`: truncate `self` to its first `offset` units and
    /// return the remainder as new content.
    ///
    /// Kinds whose length is always 1 cannot be split — yjs throws
    /// `methodUnimplemented()` and so do we.
    mutating func splice(_ offset: UInt) throws -> YContent {
        switch self {
        case .deleted(let len):
            // ContentDeleted @8684. yjs does not range-check; a bogus offset would
            // make `len - offset` negative (harmless in JS, a trap in Swift), so
            // guard it as the malformed input it is.
            guard offset <= len else { throw YIntegrationError.unexpectedCase }
            self = .deleted(len: offset)
            return .deleted(len: len - offset)

        case .json(let items):
            // ContentJSON @9112
            let o = try sliceIndex(offset, count: items.count)
            self = .json(Array(items[..<o]))
            return .json(Array(items[o...]))

        case .any(let values):
            // ContentAny @9227
            let o = try sliceIndex(offset, count: values.count)
            self = .any(Array(values[..<o]))
            return .any(Array(values[o...]))

        case .string(let units):
            // ContentString @9335 — see spliceString for the surrogate repair.
            let o = try sliceIndex(offset, count: units.count)
            let (left, right) = Self.spliceString(units, at: o)
            self = .string(left)
            return .string(right)

        case .binary, .embed, .format, .type, .doc:
            // ContentBinary @8809, ContentEmbed @8918, ContentFormat @9466,
            // ContentType @9466, ContentDoc @8597 — all `methodUnimplemented()`.
            throw YIntegrationError.methodUnimplemented
        }
    }

    /// Splits a UTF-16 code-unit sequence, repairing a surrogate pair broken by
    /// the split — a literal transliteration of yjs `ContentString.splice`
    /// (yjs.cjs @9335, yjs issue #248).
    ///
    /// When the split lands *between* a high and a low surrogate, both halves
    /// would otherwise end/begin with a lone surrogate — an ill-formed string
    /// that cannot be encoded. yjs replaces each orphan with U+FFFD, which is why
    /// this operates on `[UInt16]`: the intermediate lone surrogate is
    /// unrepresentable in a Swift `String`, so a `String`-based splice could not
    /// mirror this at all.
    ///
    /// **Both halves keep their length** (one orphan out, one U+FFFD in), which
    /// the store depends on — an item's clock range must not move when it splits.
    static func spliceString(_ units: [UInt16], at offset: Int) -> (left: [UInt16], right: [UInt16]) {
        var left = Array(units[..<offset])
        var right = Array(units[offset...])
        // yjs reads `this.str.charCodeAt(offset - 1)` *after* truncating to the left
        // half, i.e. the left half's last unit. At offset 0 JS yields NaN, which
        // fails every comparison below — hence the `offset > 0` guard, which is the
        // same behavior rather than an added rule.
        if offset > 0, (0xD800...0xDBFF).contains(left[offset - 1]) {
            // `str.slice(0, offset - 1) + '\u{FFFD}'` and `'\u{FFFD}' + str.slice(1)`,
            // transliterated literally — including the empty-right case, where JS
            // yields a 1-unit "\u{FFFD}" rather than an empty string.
            left = Array(left[..<(offset - 1)]) + [0xFFFD]
            right = [0xFFFD] + right.dropFirst()
        }
        return (left, right)
    }

    /// Bounds-checks a JS `slice(offset)` split point. yjs relies on callers never
    /// passing an out-of-range offset (`splitItem` is only ever called with
    /// `0 < diff < length`); a malformed update could still claim one, and JS
    /// would silently produce empty slices where Swift would trap.
    private func sliceIndex(_ offset: UInt, count: Int) throws -> Int {
        guard let o = Int(exactly: offset), o >= 0, o <= count else {
            throw YIntegrationError.unexpectedCase
        }
        return o
    }

    // MARK: Merging

    /// yjs `mergeWith(right)`: absorb `right` into `self`, reporting whether it
    /// merged. Only the four splittable list-ish kinds merge; the rest return
    /// false unconditionally.
    ///
    /// The caller (`YItem.mergeWith`) has already established that both sides are
    /// the same content kind, but this re-checks — as yjs's own class-per-kind
    /// dispatch does implicitly — so a mismatched pair can never silently merge.
    mutating func mergeWith(_ right: YContent) -> Bool {
        switch (self, right) {
        case (.deleted(let l), .deleted(let r)):
            self = .deleted(len: l + r)
            return true
        case (.json(let l), .json(let r)):
            self = .json(l + r)
            return true
        case (.any(let l), .any(let r)):
            self = .any(l + r)
            return true
        case (.string(let l), .string(let r)):
            self = .string(l + r)
            return true
        default:
            // Binary/Embed/Format/Type/Doc return false unconditionally in yjs —
            // they are single-unit content with nothing to concatenate. A
            // mismatched pair lands here too, which `YItem.mergeWith` has already
            // excluded via its ref check.
            return false
        }
    }

    // MARK: Integration hooks

    /// yjs `integrate(transaction, item)` — the per-kind hook fired once the item
    /// is spliced into its parent. Only three kinds do anything.
    func integrate(_ transaction: YTransaction, item: YItem) {
        switch self {
        case .deleted(let len):
            // ContentDeleted @8700: the item arrives already-deleted, so its range
            // joins the transaction's delete set and the item is marked immediately.
            transaction.deleteSet.add(client: item.id.client, clock: item.id.clock, length: len)
            item.markDeleted()
        case .type(let type):
            // ContentType @9438
            type.integrate(doc: transaction.doc, item: item)
        case .format:
            // ContentFormat @8988. Search markers are unsupported for rich text, so
            // yjs drops the parent's marker cache and flags it as formatted. We keep
            // no markers (see YType._searchMarker), so only the flag is meaningful —
            // it is what B4's `cleanupYTextAfterTransaction` will key off.
            // yjs casts `item.parent` to YText unconditionally here: integrate only
            // ever runs once the parent is resolved to a type.
            item.parentType?._searchMarker = nil
            item.parentType?._hasFormatting = true
        case .json, .binary, .string, .embed, .any, .doc:
            break  // no-ops in yjs
        }
    }

    /// yjs `delete(transaction)` — fired when the owning item is deleted.
    ///
    /// Only `ContentType` does anything: it recursively deletes the sub-tree.
    /// `ContentDoc.delete` manages `transaction.subdocs*`, which this milestone
    /// does not model (Schrift's document has no subdocuments — the BlockNote
    /// schema is a single `document-store` XmlFragment).
    func delete(_ transaction: YTransaction) {
        guard case .type(let type) = self else { return }
        type.deleteChildren(transaction)
    }
}
