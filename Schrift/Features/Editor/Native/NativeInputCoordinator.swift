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
        surface.onPatchApplied = { [weak self] in self?.selection.restore(after: $0) }
        inputLanguage = { [weak view] in view?.textInputMode?.primaryLanguage }
        view.delegate = self
        view.inputCoordinator = self
        view.isEditable = true
        view.allowsEditingTextAttributes = false
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
        selection.selectionDidChange()
    }

    @discardableResult
    func replace(range: NSRange, with text: String) -> Bool {
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
        // Anything else (a selection across blocks, pasted or dictated lines)
        // is one range command.
        guard !text.contains("\n"), let entry = surface.rangeIndex.entry(atUTF16: range.location),
            range.location <= NSMaxRange(entry.textRange),
            range.length <= NSMaxRange(entry.textRange) - range.location
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
            range: offset..<(offset + range.length), replacement: text)
        do {
            try engine.replaceText(command) { try persist(command, $0) }
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
        let offset = selection.location - entry.textRange.location
        return applyStructural(
            entry.blockID, .split(offset: offset, newID: UUID().uuidString), refusal: .native_editor_input_unavailable)
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

    /// `refusal` is the notice for an unsupported shape; nil keeps it quiet.
    private func applyStructural(_ blockID: String, _ kind: NativeEditCommand.Kind, refusal: L10nKey?) -> Bool {
        let command = NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: blockID, kind: kind)
        do {
            let caret = try engine.applyStructural(command) { try persist(command, $0) }
            if let entry = surface.rangeIndex.entry(for: caret.blockID) {
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
        guard let view, let text = pasteboard.string, !text.isEmpty else { return false }
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
