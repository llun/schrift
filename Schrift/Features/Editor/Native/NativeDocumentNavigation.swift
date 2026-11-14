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
    /// Inline runs retained only when `hasInlineObjects`, so navigation can
    /// re-resolve cached interlink titles dynamically.
    var runs: [InlineRun]
    /// The column group this block is in (PR12c); nil for a document block.
    var group: NativeBlockHandle?

    init(_ block: BlockSnapshot, handle: NativeBlockHandle?) {
        self.handle = handle
        blockID = block.id
        text = block.clippedVisibleText()
        runs =
            block.hasInlineObjects
            ? block.runs.map { run in
                guard let inline = run.inlineObject else { return run }
                if case .interlink = inline {
                    return InlineRun(inlineObject: inline.clippedForDisplay())
                }
                return InlineRun(inline.clippedVisibleText())
            } : []
        if block.node == "heading", case .int(let level)? = block.props.first(where: { $0.key == "level" })?.value {
            self.level = level
        }
    }

    func resolvedText(titleForDocument: (UUID) -> String?) -> String {
        guard !runs.isEmpty else { return text }
        return runs.map { run in
            if let inline = run.inlineObject {
                return inline.clippedVisibleText(titleForDocument: titleForDocument)
            }
            return run.text
        }.joined()
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
    /// The blocks the outline and find read: the document's, each familiar
    /// column group's blocks after its card (PR12c).
    private(set) var blocks: [EditorBlock] = []
    /// The document's own blocks: what the reading position reads (a column
    /// block is never a place to restore).
    @ObservationIgnored private var documentBlocks: [EditorBlock] = []
    /// A find or outline result in a column (PR12c): the presenter opens the
    /// column editor on group `group`, column `column`, at block `block`.
    @ObservationIgnored var onOpenColumn: ((_ group: String, _ column: String, _ block: String) -> Void)?
    /// A column editor opened from a jump is up (or about to be).
    @ObservationIgnored private(set) var isOpeningColumn = false

    /// The column editor closed: the next result in a column may open one.
    func columnEditorClosed() { isOpeningColumn = false }
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
    /// Cached title resolver for linked documents referenced by interlink chips.
    @ObservationIgnored var documentTitle: (@MainActor (UUID) -> String?)?

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
        refreshCount += 1
        let (next, built) = build(read)
        entries = next
        documentBlocks = built.filter { next[$0.id]?.group == nil }
        if built != blocks { blocks = built }
    }

    /// Replica reads this open asked for (tests read the sheet-only cadence).
    @ObservationIgnored private(set) var refreshCount = 0
    /// While the outline sheet is up it follows edits; otherwise nothing is
    /// projected for navigation while anyone types.
    @ObservationIgnored var isOutlinePresented = false {
        didSet {
            if !isOutlinePresented {
                refreshTask?.cancel()
                refreshTask = nil
            }
        }
    }

    private func build(_ read: [NativeNavigationEntry]) -> ([UUID: NativeNavigationEntry], [EditorBlock]) {
        var seen: Set<String> = []
        var next: [UUID: NativeNavigationEntry] = [:]
        var built: [EditorBlock] = []
        for entry in read {
            // A repeated id is shown but not addressable: it gets an id of its own.
            let id = seen.insert(entry.blockID).inserted ? ids[entry.blockID, default: UUID()] : UUID()
            if ids[entry.blockID] == nil { ids[entry.blockID] = id }
            next[id] = entry
            built.append(editorBlock(entry, id: id))
        }
        return (next, built)
    }

    /// A delivered patch: the open outline follows, at most every `refreshDelay`.
    func documentChanged() {
        guard isOutlinePresented, refreshTask == nil else { return }
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
    private func editorBlock(_ entry: NativeNavigationEntry, id: UUID) -> EditorBlock {
        let displayText = entry.resolvedText(titleForDocument: documentTitle ?? { _ in nil })
        guard let level = entry.level else { return EditorBlock(id: id, kind: .unknown, text: displayText) }
        let escaped = displayText.map { "\\`*_{}[]()#+-.!~>|".contains($0) ? "\\\($0)" : String($0) }.joined()
        return EditorBlock(id: id, kind: .heading(level: level), text: escaped)
    }

    // MARK: - Jumps

    /// Scrolls to `target` (the outline's title, a heading or a find match).
    /// False when the target is gone or was replaced since it was read.
    /// A match in a column opens the column editor only when `deliberate`
    /// (a tap, Next or Previous), once until it closes; following a query
    /// as it is typed only scrolls to the group's card (PR12c review).
    @discardableResult
    func jump(to target: EditorScrollTarget, deliberate: Bool = true) async -> Bool {
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
            if let group = entry.group {
                guard deliberate else { return textView.scroll(toBlock: group.stringID, surface: surface) }
                // `locate` answered the block's column: the column editor opens there,
                // once (a second reply in flight is dropped).
                guard !isOpeningColumn else { return false }
                isOpeningColumn = true
                onOpenColumn?(group.stringID, blockID, entry.blockID)
                return true
            }
            surface.reveal(blockID)
            return textView.scroll(toBlock: blockID, surface: surface)
        }
    }

    private func locate(_ entry: NativeNavigationEntry) async -> String? {
        guard let replica, let handle = entry.handle else { return entry.blockID }
        return await withCheckedContinuation { done in
            replica.mailbox.post(.locate(handle, group: entry.group, reply: { done.resume(returning: $0) }))
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
        // A reader who already scrolled, or tapped to type, keeps their place.
        let scrolled = textView.contentOffset.y + textView.adjustedContentInset.top > 8 || textView.isFirstResponder
        if reading.beginRestore(blocks: documentBlocks, userHasScrolled: scrolled) != nil { restorePending = true }
        layoutPassed()
    }

    /// Called after each layout pass of the text view.
    func layoutPassed() {
        guard let textView, let reading else { return }
        if textView.isTracking || textView.isDecelerating || (restorePending && textView.isFirstResponder) {
            reading.dismissBackToTop()
            reading.cancelPendingRestore()
            restorePending = false
        }
        guard restorePending, textView.bounds.height > 0 else { return }
        restorePending = false
        // TextKit lays out any block on demand: every block counts as laid out,
        // and one in a folded toggle is unfolded by the jump.
        let all = Set(documentBlocks.map(\.id))
        guard
            let target = reading.takeRestoreScroll(
                presentedBlockIDs: all, laidOutBlockIDs: all, voiceOverEnabled: voiceOverEnabled())
        else { return }
        Task { await jump(to: .block(target)) }
    }

    /// The outline jumped: the reader chose where to be.
    func noteDeliberateJump() { reading?.noteDeliberateJump(blocks: documentBlocks) }

    func backToTop() {
        reading?.dismissBackToTop()
        guard let textView else { return }
        textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
    }

    /// Records the block at the top of the screen (leaving, background).
    func persist() {
        guard let reading, let textView, let surface else { return }
        // Built from the surface now (O(blocks), once per leave): the outline's
        // copy is only kept fresh while the sheet is up.
        let current = build(surface.blocks.map { NativeNavigationEntry($0, handle: nil) }).1
        reading.persist(blocks: current, topVisibleBlockID: textView.topVisibleBlockID().flatMap { ids[$0] })
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
