import Observation
import UIKit

/// Ordinary input is intercepted before UIKit changes storage. Canonical
/// engine echoes update storage after persistence; returning false prevents
/// UIKit from applying the same edit a second time.
@MainActor @Observable
final class NativeInputCoordinator: NSObject, UITextViewDelegate {
    private let engine: DocumentEngine
    private let surface: NativeTextSurface
    private weak var view: NativeTextView?
    private let persist: (NativeEditCommand, Data) throws -> Void
    private(set) var noticeKey: L10nKey?

    init(
        engine: DocumentEngine, surface: NativeTextSurface, view: NativeTextView,
        persist: @escaping (NativeEditCommand, Data) throws -> Void
    ) {
        self.engine = engine
        self.surface = surface
        self.view = view
        self.persist = persist
        super.init()
        view.delegate = self
        view.inputCoordinator = self
        view.isEditable = true
        view.allowsEditingTextAttributes = false
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        _ = replace(range: range, with: text)
        return false
    }

    /// iOS 26 can supply disjoint ranges. Its fallback passes their union to
    /// the older delegate, which would incorrectly delete intervening text.
    func textView(_ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String)
        -> Bool
    {
        guard ranges.count == 1, let range = ranges.first?.rangeValue else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        _ = replace(range: range, with: text)
        return false
    }

    @discardableResult
    func replace(range: NSRange, with text: String) -> Bool {
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached else { return false }
        guard range.length != 0 || !text.isEmpty else { return false }
        guard view.markedTextRange == nil else {
            refuseMarkedText()
            return false
        }
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

    func stopAfterStorageFailure() {
        view?.isEditable = false
        view?.resignFirstResponder()
        noticeKey = .native_editor_storage_failed
    }

    /// Called by `setMarkedText` before invoking UIKit's implementation. There
    /// is never marked/provisional text in native storage in PR02a.
    func refuseMarkedText() {
        noticeKey = .native_editor_marked_unavailable
        view?.isEditable = false
        view?.resignFirstResponder()
    }
}
