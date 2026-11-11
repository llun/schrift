import Foundation
import Observation
import UIKit

/// One block as navigation sees it (PR10b): its generation-safe handle (nil
/// for the one-shot reader, whose surface never changes), id, heading level
/// and plain text.
struct NativeNavigationEntry: Equatable, Sendable {
    var handle: NativeBlockHandle?
    var blockID: String
    var level: Int?
    var text: String

    init(_ block: BlockSnapshot, handle: NativeBlockHandle?) {
        self.handle = handle
        blockID = block.id
        text = block.runs.map(\.text).joined()
        if block.node == "heading", case .int(let level)? = block.props.first(where: { $0.key == "level" })?.value {
            self.level = level
        }
    }
}

/// Outline, find and "continue reading" for the native editor (PR10b), over
/// the classic pure rules (`DocumentOutline.swift`, `ReadingPositionStore`)
/// and the classic sheet: each native block is offered to them as an
/// `EditorBlock` whose id is stable for this open. A jump goes through the
/// block's `NativeBlockHandle`, checked on the replica session (`.locate`):
/// a block replaced since the outline was read (a move, a rebuilt replica)
/// does not jump. A jump unfolds the toggles above its target (view state)
/// and scrolls; it never writes the replica or moves the selection.
@MainActor @Observable
final class NativeDocumentNavigation {
    /// The blocks the outline, find and reading position read.
    private(set) var blocks: [EditorBlock] = []
    @ObservationIgnored private(set) var entries: [UUID: NativeNavigationEntry] = [:]
    /// Block id → its id for this open, so a refresh keeps the sheet's state.
    @ObservationIgnored private var ids: [String: UUID] = [:]
    private(set) var reading: ReadingPositionSession?
    @ObservationIgnored private let replica: DocumentReplicaSession?
    @ObservationIgnored private weak var surface: NativeTextSurface?
    @ObservationIgnored private weak var textView: NativeTextView?
    @ObservationIgnored private let refreshDelay: Duration
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var restorePending = false
    @ObservationIgnored var voiceOverEnabled: () -> Bool = { UIAccessibility.isVoiceOverRunning }

    init(
        replica: DocumentReplicaSession?, surface: NativeTextSurface, textView: NativeTextView,
        refreshDelay: Duration = .milliseconds(500)
    ) {
        self.replica = replica
        self.surface = surface
        self.textView = textView
        self.refreshDelay = refreshDelay
    }

    // MARK: - Entries

    /// Reads every block's handle and text from the replica (off main), or
    /// the reader's fixed surface.
    func refresh() async {
        let read: [NativeNavigationEntry]
        if let replica {
            read = await withCheckedContinuation { done in
                replica.mailbox.post(.navigation(reply: { done.resume(returning: $0) }))
            }
        } else {
            read = surface?.blocks.map { NativeNavigationEntry($0, handle: nil) } ?? []
        }
        var seen: Set<String> = []
        var next: [UUID: NativeNavigationEntry] = [:]
        var built: [EditorBlock] = []
        for entry in read {
            // A repeated id is shown but not addressable: it gets an id of its own.
            let id = seen.insert(entry.blockID).inserted ? ids[entry.blockID, default: UUID()] : UUID()
            if ids[entry.blockID] == nil { ids[entry.blockID] = id }
            next[id] = entry
            built.append(Self.editorBlock(entry, id: id))
        }
        entries = next
        if built != blocks { blocks = built }
    }

    /// A delivered patch: the outline follows, at most every `refreshDelay`.
    func documentChanged() {
        guard refreshTask == nil else { return }
        let delay = refreshDelay
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
            await self?.refresh()
        }
    }

    /// The classic rules read markdown: a heading's literal text is escaped so
    /// `**` or `#` stay text; anything else is taken verbatim (`.unknown`).
    private static func editorBlock(_ entry: NativeNavigationEntry, id: UUID) -> EditorBlock {
        guard let level = entry.level else { return EditorBlock(id: id, kind: .unknown, text: entry.text) }
        let escaped = entry.text.map { "\\`*_{}[]()#+-.!~>|".contains($0) ? "\\\($0)" : String($0) }.joined()
        return EditorBlock(id: id, kind: .heading(level: level), text: escaped)
    }

    // MARK: - Jumps

    /// Scrolls to `target` (the outline's title, a heading or a find match).
    /// False when the target is gone or was replaced since it was read.
    @discardableResult
    func jump(to target: EditorScrollTarget) async -> Bool {
        guard let textView, let surface else { return false }
        switch target {
        case .header:
            textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
            return true
        case .trailer:
            return surface.blocks.last.map { textView.scroll(toBlock: $0.id, surface: surface) } ?? false
        case .block(let id):
            guard let entry = entries[id], let blockID = await locate(entry), self.surface === surface else {
                return false
            }
            surface.reveal(blockID)
            return textView.scroll(toBlock: blockID, surface: surface)
        }
    }

    private func locate(_ entry: NativeNavigationEntry) async -> String? {
        guard let replica, let handle = entry.handle else { return entry.blockID }
        return await withCheckedContinuation { done in
            replica.mailbox.post(.locate(handle, reply: { done.resume(returning: $0) }))
        }
    }

    // MARK: - Continue reading

    /// Remembers where this document is read (the view's document id).
    func enableReadingPosition(
        store: ReadingPositionStore = ReadingPositionStore(), serverOrigin: String, documentID: UUID
    ) {
        guard reading == nil else { return }
        reading = ReadingPositionSession(store: store, serverOrigin: serverOrigin, documentID: documentID)
    }

    /// Decides the restore once per open, and scrolls once the view has a size.
    func restore() {
        guard let reading, let textView else { return }
        let scrolled = textView.contentOffset.y + textView.adjustedContentInset.top > 8
        if reading.beginRestore(blocks: blocks, userHasScrolled: scrolled) != nil { restorePending = true }
        layoutPassed()
    }

    /// Called after each layout pass of the text view.
    func layoutPassed() {
        guard let textView, let reading else { return }
        if textView.isTracking || textView.isDecelerating {
            reading.dismissBackToTop()
            reading.cancelPendingRestore()
            restorePending = false
        }
        guard restorePending, textView.bounds.height > 0 else { return }
        restorePending = false
        // TextKit lays out any block on demand: every block counts as laid out,
        // and one in a folded toggle is unfolded by the jump.
        let all = Set(blocks.map(\.id))
        guard
            let target = reading.takeRestoreScroll(
                presentedBlockIDs: all, laidOutBlockIDs: all, voiceOverEnabled: voiceOverEnabled())
        else { return }
        Task { await jump(to: .block(target)) }
    }

    /// The outline jumped: the reader chose where to be.
    func noteDeliberateJump() { reading?.noteDeliberateJump(blocks: blocks) }

    func backToTop() {
        reading?.dismissBackToTop()
        guard let textView else { return }
        textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
    }

    /// Records the block at the top of the screen (leaving, background).
    func persist() {
        guard let reading, let textView else { return }
        reading.persist(blocks: blocks, topVisibleBlockID: textView.topVisibleBlockID().flatMap { ids[$0] })
    }

    isolated deinit { refreshTask?.cancel() }
}

extension NativeTextView {
    /// Puts `blockID`'s first line at the top of the view (clamped at the
    /// end), relocating TextKit's viewport instead of laying out the
    /// document above it. Storage and the selection are untouched.
    @discardableResult
    func scroll(toBlock blockID: String, surface: NativeTextSurface) -> Bool {
        guard let entry = surface.rangeIndex.entry(for: blockID), !surface.isHidden(blockID: blockID),
            let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: entry.range.location)
        else { return false }
        // Estimated heights settle as the viewport lays out: place, then re-place.
        for _ in 0..<3 {
            layout.textViewportLayoutController.relocateViewport(to: location)
            layout.textViewportLayoutController.layoutViewport()
            guard let fragment = layout.textLayoutFragment(for: location) else { return false }
            let top = -adjustedContentInset.top
            let bottom = max(top, contentSize.height - bounds.height + adjustedContentInset.bottom)
            let y = min(max(fragment.layoutFragmentFrame.minY + textContainerInset.top + top, top), bottom)
            if abs(contentOffset.y - y) < 0.5 { break }
            setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
            layoutIfNeeded()
        }
        return true
    }

    /// The block whose fragment is at the top edge of the visible text.
    func topVisibleBlockID() -> String? {
        guard let layout = textLayoutManager else { return nil }
        let y = max(0, contentOffset.y + adjustedContentInset.top - textContainerInset.top + 1)
        return (layout.textLayoutFragment(for: CGPoint(x: 0, y: y)) as? NativeBlockFragment)?.blockID
    }
}
