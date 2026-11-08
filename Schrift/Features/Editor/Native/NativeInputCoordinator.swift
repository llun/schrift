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
    private(set) var noticeKey: L10nKey?

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
        super.init()
        view.delegate = self
        view.inputCoordinator = self
        view.isEditable = true
        view.allowsEditingTextAttributes = false
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
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
        guard let language = view.textInputMode?.primaryLanguage,
            ["ja", "zh", "yue", "ko"].contains(where: { language.hasPrefix($0) })
        else { return false }
        return range == view.selectedRange && text.utf16.count == 1
            && !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0.value == 0xfffc })
    }

    /// Our overrides never let UIKit write storage outside marked text. A
    /// change that still arrives here bypassed the journal: restore the
    /// projection rather than let storage drift from the replica.
    func textViewDidChange(_ textView: UITextView) {
        guard let view, !view.isApplyingMarkedText, !composition.isActive else { return }
        surface.restoreStorage()
        noticeKey = .native_editor_input_unavailable
    }

    /// iOS 26 can supply disjoint ranges. Its fallback passes their union to
    /// the older delegate, which would incorrectly delete intervening text.
    func textView(_ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String)
        -> Bool
    {
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
        guard composition.isActive else { return }
        view?.dropMarkedText()
        composition.interrupt()
    }

    @discardableResult
    func replace(range: NSRange, with text: String) -> Bool {
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached else { return false }
        guard range.length != 0 || !text.isEmpty else { return false }
        // The composition owns input until it reconciles: UIKit's offsets are
        // stale and a second command would race the commit.
        guard view.markedTextRange == nil, !composition.isActive else { return false }
        // Subtraction, rather than NSMaxRange, also rejects overflowing ranges.
        guard range.location >= 0, range.length >= 0, range.location <= surface.storage.length,
            range.length <= surface.storage.length - range.location,
            let entry = surface.rangeIndex.entry(atUTF16: range.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            range.location <= NSMaxRange(entry.textRange),
            range.length <= NSMaxRange(entry.textRange) - range.location,
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position]),
            !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0.value == 0xfffc })
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
            view.selectedRange = NSRange(location: range.location + text.utf16.count, length: 0)
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

    /// The end-of-document boundary has no owner, so it is never a block start.
    func isBlockStart(_ location: Int) -> Bool {
        surface.rangeIndex.entry(atUTF16: location)?.range.location == location
    }

    // MARK: - Marked text

    /// Called by `setMarkedText` before UIKit applies the marked range.
    func beginComposition(markedText: String) -> Bool {
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached else { return false }
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
        UIPasteboard.general.string = recovery.text
        composition.resolveRecovery(recovery)
    }

    func discardRecovery(_ recovery: ProvisionalRecovery) {
        composition.resolveRecovery(recovery)
    }

    func stopAfterStorageFailure() {
        view?.isEditable = false
        view?.resignFirstResponder()
        noticeKey = .native_editor_storage_failed
    }

    /// A composition this editor cannot support (a multi-block selection, an
    /// opaque target): keep the preserved read-only refusal and never let
    /// provisional text become committed content.
    func refuseComposition() {
        noticeKey = .native_editor_marked_unavailable
        view?.isEditable = false
        view?.resignFirstResponder()
    }
}
