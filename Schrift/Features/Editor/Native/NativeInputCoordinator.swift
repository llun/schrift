import Observation
import UIKit

/// Ordinary input is intercepted before UIKit changes storage. Canonical
/// engine echoes update storage after persistence; returning false prevents
/// UIKit from applying the same edit a second time.
///
/// Marked text (IME) is different: UIKit owns the provisional range in storage
/// for the whole composition, so `NativeCompositionSession` freezes the surface
/// and commits once. Offset-based commands are refused while it is active,
/// because document-wide UIKit offsets are stale until reconciliation.
@MainActor @Observable
final class NativeInputCoordinator: NSObject, UITextViewDelegate {
    private let engine: DocumentEngine
    private let surface: NativeTextSurface
    private weak var view: NativeTextView?
    private let persist: (NativeEditCommand, Data) throws -> Void
    let composition: NativeCompositionSession
    /// Directed relative selection: published on every UIKit change and
    /// restored after each peer patch or rebuild.
    @ObservationIgnored let selection: NativeSelectionCoordinator
    /// The general pasteboard; tests use a uniquely named one.
    @ObservationIgnored var pasteboard: UIPasteboard = .general
    private(set) var noticeKey: L10nKey?
    /// What the formatting bar shows: the marks every selected character
    /// carries, or at a caret the marks typing there would carry.
    private(set) var activeMarks: [TextMark] = []
    /// The slash command at the caret (the text after "/" in a paragraph that
    /// is only that command), which `NativeEditorView` shows the menu for.
    private(set) var slashMenuQuery: String?
    /// The "/query" token the menu's choice removes: from the paragraph's
    /// start to the caret. Text after the caret is the user's and stays.
    @ObservationIgnored private var slashToken: Range<Int>?
    /// A toggle at a caret (ProseMirror's stored marks): the marks the next
    /// typed text carries. Nothing is written until text is typed, and a
    /// selection change drops it.
    @ObservationIgnored private var pendingTypingMarks: [TextMark]?
    /// The active keyboard's language; a seam so tests can stand in for a
    /// composing keyboard the simulator may not have.
    @ObservationIgnored var inputLanguage: () -> String? = { nil }
    /// A single character a composing keyboard was allowed to write itself.
    /// It either starts marked text, arrives through `insertText`, or is
    /// written straight to storage (space, digits, punctuation), which
    /// `textViewDidChange` turns into an ordinary command.
    @ObservationIgnored private var directInsertion: (range: NSRange, text: String)?

    init(
        engine: DocumentEngine, surface: NativeTextSurface, view: NativeTextView,
        persist: @escaping (NativeEditCommand, Data) throws -> Void,
        recoveryStore: (store: ReplicaStore, scope: ReplicaScope)? = nil
    ) {
        self.engine = engine
        self.surface = surface
        self.view = view
        self.persist = persist
        self.composition = NativeCompositionSession(
            engine: engine, surface: surface, view: view, persist: persist, recoveryStore: recoveryStore)
        self.selection = NativeSelectionCoordinator(engine: engine, surface: surface, view: view)
        super.init()
        surface.onPatchApplied = { [weak self] patch in
            self?.selection.restore(after: patch)
            self?.refreshSelectionMarks()
        }
        inputLanguage = { [weak view] in view?.textInputMode?.primaryLanguage }
        view.delegate = self
        view.inputCoordinator = self
        view.isEditable = true
        view.allowsEditingTextAttributes = false
        refreshSelectionMarks()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Key input reaches `NativeTextView.insertText`, which never asks the
        // delegate; this covers UIKit paths that do, so Return routes once.
        if Self.isNewline(text), view?.isApplyingMarkedText != true {
            // Return over a selection replaces it with a block break.
            _ = range.length == 0 ? insertNewline() : replace(range: range, with: "\n")
            return false
        }
        if allowsUIKitChange(range, text) { return true }
        _ = replace(range: range, with: text)
        return false
    }

    /// UIKit's own marked-text edits must reach storage: the composition owns
    /// that range and commits it once. A composing keyboard also asks here
    /// before its first keystroke; refusing would turn romaji or pinyin into
    /// committed Latin text, so it proceeds to `setMarkedText` or `insertText`,
    /// both overridden. Every other change takes the command path.
    private func allowsUIKitChange(_ range: NSRange, _ text: String) -> Bool {
        guard let view else { return false }
        if view.isApplyingMarkedText || (composition.isActive && view.markedTextRange != nil) { return true }
        guard let language = inputLanguage(),
            ["ja", "zh", "yue", "ko"].contains(where: { language.hasPrefix($0) }),
            range == view.selectedRange, text.utf16.count == 1,
            !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0.value == 0xfffc }),
            // The same single-block shape the command path accepts: UIKit must
            // never write across a separator or into a placeholder.
            let entry = surface.rangeIndex.entry(atUTF16: range.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            range.location >= entry.textRange.location, NSMaxRange(range) <= NSMaxRange(entry.textRange),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position])
        else { return false }
        directInsertion = (range, text)
        return true
    }

    /// Our overrides never let UIKit write storage outside marked text, except
    /// a composing keyboard's direct character: undo UIKit's write and submit
    /// it as an ordinary durable command. Anything else bypassed the journal:
    /// restore the projection rather than let storage drift from the replica.
    func textViewDidChange(_ textView: UITextView) {
        guard let view, !view.isApplyingMarkedText, !composition.isActive else { return }
        let direct = directInsertion
        directInsertion = nil
        if let direct, let blockID = surface.rangeIndex.entry(atUTF16: direct.range.location)?.blockID,
            surface.storage.length == surface.rangeIndex.length + direct.text.utf16.count - direct.range.length,
            (surface.storage.string as NSString).substring(
                with: NSRange(location: direct.range.location, length: direct.text.utf16.count)) == direct.text
        {
            surface.restoreStorage(blockID: blockID)
            // A refused command must still leave storage equal to the model.
            if !replace(range: direct.range, with: direct.text), !surface.storageMatchesModel {
                surface.restoreStorage()
            }
            return
        }
        // A late notification for marked text this view already cleared and
        // reconciled has nothing to undo.
        guard !surface.storageMatchesModel else { return }
        surface.restoreStorage()
        noticeKey = .native_editor_input_unavailable
    }

    /// iOS 26 can supply disjoint ranges. Its fallback passes their union to
    /// the older delegate, which would incorrectly delete intervening text.
    func textView(_ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String)
        -> Bool
    {
        if Self.isNewline(text), view?.isApplyingMarkedText != true {
            guard ranges.count == 1, let range = ranges.first?.rangeValue else {
                noticeKey = .native_editor_input_unavailable
                return false
            }
            _ = range.length == 0 ? insertNewline() : replace(range: range, with: "\n")
            return false
        }
        if ranges.count == 1, let range = ranges.first?.rangeValue, allowsUIKitChange(range, text) { return true }
        guard ranges.count == 1, let range = ranges.first?.rangeValue else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        _ = replace(range: range, with: text)
        return false
    }

    /// Focus loss normally reaches `unmarkText` first, which commits like
    /// UIKit. A composition still active here was never confirmed: end it
    /// without writing and keep its text as an explicit recovery entry.
    func textViewDidEndEditing(_ textView: UITextView) {
        // An allowance for a keystroke that never arrived ends with editing.
        directInsertion = nil
        guard composition.isActive else { return }
        view?.dropMarkedText()
        composition.interrupt()
    }

    /// UIKit's selection, including hardware Shift-arrows, is published as
    /// directed relative endpoints so it survives peer edits and rebuilds.
    /// Marked text owns storage and its offsets are stale until the
    /// composition reconciles, so publication waits for that.
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let view, !view.isApplyingMarkedText, view.markedTextRange == nil, !composition.isActive else {
            return
        }
        if !surface.isApplyingPatch { pendingTypingMarks = nil }
        selection.selectionDidChange()
        refreshSelectionMarks()
    }

    /// `marks`, when given, is the complete mark set the text carries (a link
    /// edit); otherwise typing takes the marks at the caret.
    @discardableResult
    func replace(range: NSRange, with text: String, marks: [TextMark]? = nil) -> Bool {
        directInsertion = nil
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached else { return false }
        guard range.length != 0 || !text.isEmpty else { return false }
        // The composition owns input until it reconciles: UIKit's offsets are
        // stale and a second command would race the commit.
        guard view.markedTextRange == nil, !composition.isActive else { return false }
        // The software keyboard deletes the separator before a block start
        // through the delegate or UITextInput `replace`, not `deleteBackward`:
        // it is the same boundary Backspace.
        if text.isEmpty, range.length == 1, view.selectedRange == NSRange(location: NSMaxRange(range), length: 0),
            isBlockStart(NSMaxRange(range))
        {
            return deleteBackwardAtBlockStart()
        }
        // Subtraction, rather than NSMaxRange, also rejects overflowing ranges.
        guard range.location >= 0, range.length >= 0, range.location <= surface.storage.length,
            range.length <= surface.storage.length - range.location,
            !text.unicodeScalars.contains(where: { $0.value == 0xfffc })
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        let text = NativeClipboard.normalizingLineBreaks(text)
        // Within one block's text and without a line break: ordinary typing.
        // A code block keeps its line breaks as source. Anything else (a
        // selection across blocks, pasted or dictated lines) is one range command.
        guard let entry = surface.rangeIndex.entry(atUTF16: range.location),
            range.location <= NSMaxRange(entry.textRange),
            range.length <= NSMaxRange(entry.textRange) - range.location,
            !text.contains("\n") || isCode(entry.blockID)
        else { return replaceRange(range, with: text) }
        guard let position = surface.rangeIndex.position(for: entry.blockID),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position])
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        let offset = range.location - entry.textRange.location
        let command = NativeEditCommand(
            id: UUID(), baseRevision: engine.revision, blockID: entry.blockID,
            range: offset..<(offset + range.length), replacement: text,
            marks: text.isEmpty
                ? nil : typingMarks(marks, runs: surface.blocks[position].runs, offset..<(offset + range.length)))
        do {
            try engine.replaceText(command) { try persist(command, $0) }
            pendingTypingMarks = nil
            selection.place(NSRange(location: range.location + text.utf16.count, length: 0))
            noticeKey = nil
            return true
        } catch {
            if engine.nativeWriteFailed {
                stopAfterStorageFailure()
            } else {
                noticeKey = .native_editor_input_unavailable
            }
            return false
        }
    }

    /// One range command replacing a document range that may span blocks.
    /// The end-of-document boundary ends a range (the last block's text end)
    /// but is never a caret. Every block it touches must be typeable: anything
    /// else is refused with a notice before any write.
    private func replaceRange(_ range: NSRange, with text: String) -> Bool {
        let index = surface.rangeIndex
        guard let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: range.length > 0),
            start != end || !text.isEmpty
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        let lines = NativeRangeCommand.lines(of: text)
        let command = NativeRangeCommand(
            startOffset: start.offset, endBlockID: index.entries[end.position].blockID, endOffset: end.offset,
            replacement: text, newBlockIDs: (1..<lines.count).map { _ in UUID().uuidString })
        return applyStructural(
            index.entries[start.position].blockID, .range(command), refusal: .native_editor_range_unavailable)
    }

    /// Return: one durable structural command at the caret, or a range
    /// replacement over a selection. While text is marked, Return commits the
    /// composition (PR03) and never splits it.
    @discardableResult
    func insertNewline() -> Bool {
        directInsertion = nil
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached else { return false }
        if composition.isActive {
            view.dropMarkedText()
            return commitComposition()
        }
        let selection = view.selectedRange
        if selection.length > 0, view.markedTextRange == nil { return replace(range: selection, with: "\n") }
        guard view.markedTextRange == nil, selection.length == 0,
            let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            selection.location <= NSMaxRange(entry.textRange),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position])
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        // BlockNote's Enter in a code block inserts a line break in the block.
        if isCode(entry.blockID) { return replace(range: selection, with: "\n") }
        let offset = selection.location - entry.textRange.location
        return applyStructural(
            entry.blockID, .split(offset: offset, newID: UUID().uuidString), refusal: .native_editor_input_unavailable)
    }

    private func isCode(_ blockID: String) -> Bool {
        surface.rangeIndex.position(for: blockID).map { surface.blocks[$0].node == "codeBlock" } == true
    }

    /// Backspace at a block's start: the engine joins a paragraph into the
    /// block above, or resets a heading or list item to a paragraph. The first
    /// paragraph and a block above that is opaque, a placeholder or not
    /// writable text stay a quiet no-op.
    @discardableResult
    func deleteBackwardAtBlockStart() -> Bool {
        directInsertion = nil
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached,
            view.markedTextRange == nil, !composition.isActive, view.selectedRange.length == 0,
            isBlockStart(view.selectedRange.location),
            let entry = surface.rangeIndex.entry(atUTF16: view.selectedRange.location)
        else { return false }
        return applyStructural(entry.blockID, .join, refusal: nil)
    }

    /// Tab and Shift-Tab, and the bar's Indent/Outdent (BlockNote's
    /// `nestBlock`/`unnestBlock`): one durable tree move of the caret's block,
    /// with its children. A move changes no text, so the selection stays where
    /// it was. Where BlockNote does nothing (a list's first block, a root block,
    /// the depth bound, a selection across blocks) it is a quiet no-op.
    @discardableResult
    func indent() -> Bool { moveBlock(.indent) }

    @discardableResult
    func outdent() -> Bool { moveBlock(.outdent) }

    /// Hardware Tab: two spaces in a code block (BlockNote's
    /// `indentLineWithTab`), else `indent()`.
    @discardableResult
    func insertTab() -> Bool {
        guard let view, let entry = surface.rangeIndex.entry(atUTF16: view.selectedRange.location) else { return false }
        return isCode(entry.blockID) ? replace(range: view.selectedRange, with: "  ") : indent()
    }

    private func moveBlock(_ kind: NativeEditCommand.Kind) -> Bool {
        directInsertion = nil
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached,
            view.markedTextRange == nil, !composition.isActive
        else { return false }
        let selection = view.selectedRange
        guard let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            selection.location <= NSMaxRange(entry.textRange),
            NSMaxRange(selection) <= NSMaxRange(entry.textRange)
        else { return false }
        return applyStructural(entry.blockID, kind, refusal: nil, keeping: selection)
    }

    /// `refusal` is the notice for an unsupported shape; nil keeps it quiet.
    /// `keeping` is a selection to restore instead of the command's caret.
    private func applyStructural(
        _ blockID: String, _ kind: NativeEditCommand.Kind, refusal: L10nKey?, keeping: NSRange? = nil
    ) -> Bool {
        let command = NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: blockID, kind: kind)
        do {
            let caret = try engine.applyStructural(command) { try persist(command, $0) }
            if let keeping {
                selection.place(keeping)
            } else if let entry = surface.rangeIndex.entry(for: caret.blockID) {
                selection.place(
                    NSRange(location: entry.textRange.location + min(caret.offset, entry.textRange.length), length: 0))
            }
            noticeKey = nil
            return true
        } catch {
            if engine.nativeWriteFailed {
                stopAfterStorageFailure()
            } else if error as? DocumentEngineError != .unsupportedNativeInput {
                noticeKey = .native_editor_input_unavailable
            } else if let refusal {
                noticeKey = refusal
            }
            return false
        }
    }

    // MARK: - Marks

    /// Typing's marks: an explicit set, a pending toggle, or ProseMirror's
    /// marks at the caret (or across the replaced range). Nil when that is
    /// what Yjs inherits anyway, so plain typing writes what it always did.
    private func typingMarks(_ explicit: [TextMark]?, runs: [InlineRun], _ range: Range<Int>) -> [TextMark]? {
        let marks =
            explicit ?? pendingTypingMarks
            ?? (range.isEmpty
                ? NativeMarkSelection.typing(runs, at: range.lowerBound)
                : NativeMarkSelection.typing(runs, replacing: range))
        return NativeMarkSelection.same(marks, NativeMarkSelection.inherited(runs, at: range.lowerBound)) ? nil : marks
    }

    private var canFormat: Bool {
        guard let view else { return false }
        return view.isEditable && !engine.nativeWriteFailed && !engine.isDetached && view.markedTextRange == nil
            && !composition.isActive
    }

    /// Republishes `activeMarks` and the caret's typing attributes (what UIKit
    /// shows marked text with), after a selection change or a patch.
    func refreshSelectionMarks() {
        guard let view, view.markedTextRange == nil, !composition.isActive else { return }
        let range = view.selectedRange
        let index = surface.rangeIndex
        var marks: [TextMark] = []
        var block: BlockSnapshot?
        var caretOffset = 0
        if range.length > 0 {
            marks = NativeMarkSelection.common(in: surface.blocks, index: index, range: range) ?? []
        } else if let caret = index.textPosition(atUTF16: range.location),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[caret.position])
        {
            block = surface.blocks[caret.position]
            caretOffset = caret.offset
            marks =
                pendingTypingMarks ?? NativeMarkSelection.typing(surface.blocks[caret.position].runs, at: caret.offset)
        }
        if marks != activeMarks { activeMarks = marks }
        slashToken = block.flatMap { Self.slashToken(in: $0, caret: caretOffset) }
        let query = block.flatMap { block in
            slashToken.map { String(decoding: Array(text(of: block).utf16)[1..<$0.upperBound], as: UTF16.self) }
        }
        if query != slashMenuQuery { slashMenuQuery = query }
        guard range.length == 0, let block else { return }
        var typing = view.typingAttributes
        for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .backgroundColor] { typing[key] = nil }
        typing.merge(AttributedDocumentProjection.markAttributes(block: block, marks: marks, traits: surface.traits)) {
            $1
        }
        typing[.link] = nil
        view.typingAttributes = typing
    }

    /// Bold, italic, underline, strike or code. Over a selection, one durable
    /// command: off when every character has it, otherwise on everywhere (a
    /// mixed run turns all on). At a caret it only changes what typing carries.
    @discardableResult
    func toggleMark(_ key: String) -> Bool {
        let isOn = activeMarks.contains { $0.key == key }
        return setMark(key, value: isOn ? nil : "{}")
    }

    /// A text or background colour by BlockNote name; nil removes it.
    @discardableResult
    func setColor(_ key: String, name: String?) -> Bool {
        setMark(key, value: name.map(NativeMark.colorValue))
    }

    private func setMark(_ key: String, value: String?) -> Bool {
        guard let view, canFormat else { return false }
        let range = view.selectedRange
        guard range.length > 0 else {
            var marks = activeMarks.filter { $0.key != key }
            if let value { marks.append(TextMark(key: key, valueJSON: value)) }
            pendingTypingMarks = marks
            refreshSelectionMarks()
            return true
        }
        return applyMarks([TextMark(key: key, valueJSON: value ?? "null")], over: range)
    }

    private func applyMarks(_ attributes: [TextMark], over range: NSRange) -> Bool {
        let index = surface.rangeIndex
        guard let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true)
        else {
            noticeKey = .native_editor_range_unavailable
            return false
        }
        let command = NativeMarkCommand(
            startOffset: start.offset, endBlockID: index.entries[end.position].blockID, endOffset: end.offset,
            attributes: attributes)
        return applyStructural(
            index.entries[start.position].blockID, .marks(command), refusal: .native_editor_range_unavailable,
            keeping: range)
    }

    /// What the link sheet edits: the selection (its link when the whole
    /// selection is one), or the link around a caret, or a new link at it.
    func linkTarget() -> NativeLinkTarget? {
        guard let view, canFormat else { return nil }
        let range = view.selectedRange
        if range.length > 0 {
            let href = (NativeMarkSelection.common(in: surface.blocks, index: surface.rangeIndex, range: range) ?? [])
                .first { $0.key == NativeMark.link }.flatMap { YBlockProjection.linkHref(from: $0.valueJSON) }
            let label = NativeClipboard.plainText(for: range, surface: surface) ?? ""
            return NativeLinkTarget(range: range, label: label, href: href)
        }
        guard let entry = surface.rangeIndex.entry(atUTF16: range.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position])
        else { return nil }
        let offset = range.location - entry.textRange.location
        guard let link = NativeMarkSelection.linkRange(surface.blocks[position].runs, at: offset) else {
            return NativeLinkTarget(range: range, label: "", href: nil)
        }
        let linkRange = NSRange(location: entry.textRange.location + link.range.lowerBound, length: link.range.count)
        let label = NativeClipboard.plainText(for: linkRange, surface: surface) ?? ""
        return NativeLinkTarget(range: linkRange, label: label, href: link.href)
    }

    /// Saves the sheet with the classic editor's URL rules; false keeps it
    /// open. An unchanged label is one mark command; a new or edited label
    /// is typed with the link (one block only).
    @discardableResult
    func applyLink(label: String, url: String, to target: NativeLinkTarget) -> Bool {
        guard let href = sanitizedLinkURL(url) else { return false }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? href : trimmed
        let mark = TextMark(key: NativeMark.link, valueJSON: NativeMark.linkValue(href))
        if target.range.length > 0, text == target.label.trimmingCharacters(in: .whitespacesAndNewlines) {
            _ = applyMarks([mark], over: target.range)
            return true
        }
        guard let entry = surface.rangeIndex.entry(atUTF16: target.range.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            NSMaxRange(target.range) <= NSMaxRange(entry.textRange)
        else {
            noticeKey = .native_editor_range_unavailable
            return true
        }
        let offset = target.range.location - entry.textRange.location
        let runs = surface.blocks[position].runs
        let around =
            target.range.length == 0
            ? NativeMarkSelection.typing(runs, at: offset)
            : NativeMarkSelection.typing(runs, replacing: offset..<(offset + target.range.length))
        _ = replace(range: target.range, with: text, marks: around.filter { $0.key != NativeMark.link } + [mark])
        return true
    }

    @discardableResult
    func removeLink(_ target: NativeLinkTarget) -> Bool {
        guard canFormat, target.range.length > 0 else { return false }
        return applyMarks([TextMark(key: NativeMark.link, valueJSON: "null")], over: target.range)
    }

    // MARK: - Block props and types

    /// Ticks or unticks a checklist item: one durable `checked` prop command
    /// (BlockNote's `updateBlock`), never a type change. The selection stays.
    @discardableResult
    func toggleCheckbox(blockID: String) -> Bool {
        guard let block = block(blockID), block.node == "checkListItem" else { return false }
        let checked = block.props.contains(ProjectedProp(key: "checked", value: .bool(true)))
        return setProps(blockID, [ProjectedProp(key: "checked", value: .bool(!checked))])
    }

    /// A code block's language, as one prop command.
    @discardableResult
    func setCodeLanguage(blockID: String, language: String) -> Bool {
        guard block(blockID)?.node == "codeBlock" else { return false }
        return setProps(blockID, [ProjectedProp(key: "language", value: .string(language))])
    }

    /// The number a numbered list starts at (its first item's `start`); nil
    /// unsets it, so the list counts from 1.
    @discardableResult
    func setNumberStart(blockID: String, start: Int?) -> Bool {
        guard block(blockID)?.node == "numberedListItem" else { return false }
        return setProps(blockID, [ProjectedProp(key: "start", value: start.map { .int($0) } ?? .undefined)])
    }

    /// A callout's emoji, as one prop command.
    @discardableResult
    func setCalloutEmoji(blockID: String, emoji: String) -> Bool {
        guard block(blockID)?.node == "callout" else { return false }
        return setProps(blockID, [ProjectedProp(key: "emoji", value: .string(emoji))])
    }

    /// The slash menu's choice: the "/query" paragraph becomes that block
    /// type, the query removed, as one durable command. Items the native
    /// editor cannot author yet (divider, photo, file) are not offered.
    @discardableResult
    func applySlashItem(_ item: SlashMenuItem) -> Bool {
        guard let view, canFormat, view.selectedRange.length == 0, let token = slashToken,
            let type = Self.slashType(item.action),
            let entry = surface.rangeIndex.entry(atUTF16: view.selectedRange.location)
        else { return false }
        return applyStructural(
            entry.blockID, .blockType(node: type.node, props: type.props, removing: token),
            refusal: .native_editor_input_unavailable)
    }

    /// A paragraph starting with "/" and the caret after it, with no
    /// whitespace between: that "/query" is the command. Unlike the classic
    /// editor (which clears the whole block), only the token is consumed, as
    /// BlockNote's suggestion menu does, so "/h1Notes" keeps "Notes".
    private static func slashToken(in block: BlockSnapshot, caret: Int) -> Range<Int>? {
        let units = Array(block.runs.map(\.text).joined().utf16)
        guard block.node == "paragraph", caret >= 1, caret <= units.count, units.first == 0x2F,
            !String(decoding: units[1..<caret], as: UTF16.self).contains(where: \.isWhitespace)
        else { return nil }
        return 0..<caret
    }

    /// The slash items this editor can apply, in the classic menu's order.
    static let slashItems = allSlashMenuItems.filter { slashType($0.action) != nil }

    private static func slashType(_ action: SlashMenuAction) -> (node: String, props: [ProjectedProp])? {
        guard case .convert(let kind) = action else { return nil }
        switch kind {
        case .paragraph: return ("paragraph", [])
        case .heading(let level): return ("heading", [ProjectedProp(key: "level", value: .int(level))])
        case .bulletItem: return ("bulletListItem", [])
        case .numberedItem: return ("numberedListItem", [])
        case .checklistItem: return ("checkListItem", [])
        case .quote: return ("quote", [])
        case .codeBlock: return ("codeBlock", [])
        default: return nil
        }
    }

    /// Unchanged values write nothing; anything else is one validated command.
    private func setProps(_ blockID: String, _ props: [ProjectedProp]) -> Bool {
        guard let view, canFormat, let block = block(blockID) else { return false }
        let defaults = BlockNoteWriter.nativePropSchemas[block.node] ?? []
        func current(_ key: String) -> YAnyValue? {
            block.props.last { $0.key == key }?.value ?? defaults.first { $0.key == key }?.value
        }
        guard props.contains(where: { current($0.key) != $0.value }) else { return true }
        return applyStructural(
            blockID, .props(props), refusal: .native_editor_input_unavailable, keeping: view.selectedRange)
    }

    private func block(_ blockID: String) -> BlockSnapshot? {
        surface.rangeIndex.position(for: blockID).map { surface.blocks[$0] }.flatMap {
            AttributedDocumentProjection.isPlaceholder($0) ? nil : $0
        }
    }

    private func text(of block: BlockSnapshot) -> String { block.runs.map(\.text).joined() }

    // MARK: - Clipboard

    /// Copy puts the selection's plain text on the pasteboard, one line per block.
    func copySelection() {
        guard let view, let text = NativeClipboard.plainText(for: view.selectedRange, surface: surface) else {
            return
        }
        pasteboard.string = text
    }

    /// Cut is copy plus one range delete; a refused delete leaves the
    /// pasteboard as it was.
    @discardableResult
    func cutSelection() -> Bool {
        guard let view, let text = NativeClipboard.plainText(for: view.selectedRange, surface: surface),
            replace(range: view.selectedRange, with: "")
        else { return false }
        pasteboard.string = text
        return true
    }

    /// Paste replaces the selection with the pasteboard's plain text (rich
    /// content contributes only that) as one command; newlines split blocks.
    @discardableResult
    func pasteFromPasteboard() -> Bool {
        guard let view, view.isEditable, let text = pasteboard.string, !text.isEmpty else { return false }
        guard !NativeClipboard.isTooLarge(NativeClipboard.normalizingLineBreaks(text)) else {
            noticeKey = .native_editor_paste_too_large
            return false
        }
        return replace(range: view.selectedRange, with: text)
    }

    private static func isNewline(_ text: String) -> Bool {
        text == "\n" || text == "\r"
    }

    /// The end-of-document boundary has no owner, so it is never a block start.
    func isBlockStart(_ location: Int) -> Bool {
        surface.rangeIndex.entry(atUTF16: location)?.range.location == location
    }

    // MARK: - Marked text

    /// Called by `setMarkedText` before UIKit applies the marked range.
    func beginComposition(markedText: String) -> Bool {
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached else { return false }
        directInsertion = nil
        let began = composition.begin(markedText: markedText)
        if began { noticeKey = nil }
        return began
    }

    /// `text` is UIKit's committed string; nil commits the last marked string.
    /// An orphaned commit becomes a pending recovery entry, shown by the view.
    @discardableResult
    func commitComposition(text: String? = nil) -> Bool {
        guard composition.isActive else { return false }
        switch composition.commit(text: text) {
        case .committed, .orphaned:
            noticeKey = nil
        case .failed:
            if engine.nativeWriteFailed {
                stopAfterStorageFailure()
            } else {
                noticeKey = .native_editor_input_unavailable
            }
        }
        return true
    }

    @discardableResult
    func cancelComposition() -> Bool {
        guard composition.isActive else { return false }
        let cancelled = composition.cancel()
        if cancelled { noticeKey = nil }
        return cancelled
    }

    // MARK: - Recovery

    /// Inserts recovered text at the caret through the ordinary durable
    /// command path. A caret the command path refuses keeps the entry.
    @discardableResult
    func insertRecovery(_ recovery: ProvisionalRecovery) -> Bool {
        guard let view, !composition.isActive, replace(range: view.selectedRange, with: recovery.text) else {
            return false
        }
        composition.resolveRecovery(recovery)
        return true
    }

    func copyRecovery(_ recovery: ProvisionalRecovery) {
        pasteboard.string = recovery.text
        composition.resolveRecovery(recovery)
    }

    func discardRecovery(_ recovery: ProvisionalRecovery) {
        composition.resolveRecovery(recovery)
    }

    func stopAfterStorageFailure() {
        directInsertion = nil
        view?.isEditable = false
        view?.resignFirstResponder()
        noticeKey = .native_editor_storage_failed
    }

    /// A composition this editor cannot support (a multi-block selection, an
    /// opaque target): keep the preserved read-only refusal and never let
    /// provisional text become committed content.
    func refuseComposition() {
        directInsertion = nil
        noticeKey = .native_editor_marked_unavailable
        view?.isEditable = false
        view?.resignFirstResponder()
    }
}
