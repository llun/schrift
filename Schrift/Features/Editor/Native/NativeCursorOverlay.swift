import UIKit

/// Collaborators' cursors over the native text view (PR10): a caret with the
/// peer's name, their selection, or, where no caret can be drawn (folded or
/// structured content), a badge on the block that owns it until it is opened.
///
/// Painting only: it never takes touches, focus or the selection, and it
/// only places what lies in TextKit's laid-out viewport, so scrolling a long
/// document costs no more than the screen it shows. It follows the view's
/// layout pass, so scrolling, rotation, folding and peer edits re-place it.
@MainActor
final class NativeCursorOverlay: UIView {
    weak var awareness: NativeAwarenessController?
    weak var surface: NativeTextSurface?
    private var carets: [UInt: UIView] = [:]
    private var badges: [UInt: UIView] = [:]
    private var highlights: [UInt: [UIView]] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "nativeEditor.cursorOverlay"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What a resolved endpoint is drawn as on this surface.
    private enum Mark: Equatable {
        case caret(Int)
        case badge(String)
    }

    /// Re-places every visible cursor; called from the text view's layout.
    func layout(in textView: NativeTextView) {
        // The visible region, in the scroll view's content coordinates.
        frame = textView.bounds
        textView.bringSubviewToFront(self)
        var shownCarets = Set<UInt>()
        var shownBadges = Set<UInt>()
        var shownHighlights = Set<UInt>()
        defer {
            for (id, view) in carets where !shownCarets.contains(id) {
                view.removeFromSuperview()
                carets[id] = nil
            }
            for (id, view) in badges where !shownBadges.contains(id) {
                view.removeFromSuperview()
                badges[id] = nil
            }
            for (id, views) in highlights where !shownHighlights.contains(id) {
                views.forEach { $0.removeFromSuperview() }
                highlights[id] = nil
            }
        }
        guard let awareness, let surface, !awareness.places.isEmpty, let visible = visibleRange(textView)
        else { return }
        var badgesPerBlock: [String: Int] = [:]
        for peer in awareness.peers {
            guard let places = awareness.places[peer.clientID], let head = places.head.flatMap({ mark($0, surface) })
            else { continue }
            let color = UIColor(rgb: avatarColorHex(for: peer.name))
            switch head {
            case .caret(let offset):
                guard visible.contains(offset) || offset == NSMaxRange(visible),
                    let rect = caretRect(offset, in: textView)
                else { continue }
                shownCarets.insert(peer.clientID)
                place(caret: peer, color: color, at: rect, origin: textView.bounds.origin)
                if case .caret(let anchor)? = places.anchor.flatMap({ mark($0, surface) }), anchor != offset {
                    let range = NSRange(location: min(anchor, offset), length: abs(anchor - offset))
                    if highlight(peer.clientID, range: range, visible: visible, color: color, in: textView) {
                        shownHighlights.insert(peer.clientID)
                    }
                }
            case .badge(let blockID):
                guard let entry = surface.rangeIndex.entry(for: blockID), visible.contains(entry.range.location),
                    let rect = caretRect(entry.range.location, in: textView)
                else { continue }
                shownBadges.insert(peer.clientID)
                let index = badgesPerBlock[blockID, default: 0]
                badgesPerBlock[blockID] = index + 1
                place(badge: peer, color: color, line: rect, index: index, in: textView)
            }
        }
    }

    /// A caret at a text offset of a shown block, else a badge on the
    /// nearest shown block that owns the place (a folded toggle, a preview).
    private func mark(_ place: PeerCursorPlace, _ surface: NativeTextSurface) -> Mark? {
        var id = place.blockID
        guard var position = surface.rangeIndex.position(for: id) else { return nil }
        var folded = false
        while surface.isHidden(position: position) {
            guard let parent = surface.blocks[position].parentID, let next = surface.rangeIndex.position(for: parent)
            else { return nil }
            id = parent
            position = next
            folded = true
        }
        let block = surface.blocks[position]
        guard !folded, case .text(let caret) = place, !block.isOpaque, block.preview == nil,
            let range = surface.rangeIndex.documentRange(blockID: id, textRange: caret.offset..<caret.offset)
        else { return .badge(id) }
        return .caret(range.location)
    }

    /// TextKit's laid-out viewport as document offsets.
    private func visibleRange(_ textView: NativeTextView) -> NSRange? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let viewport = layout.textViewportLayoutController.viewportRange
        else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard start != NSNotFound, end != NSNotFound, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func caretRect(_ offset: Int, in textView: NativeTextView) -> CGRect? {
        guard let position = textView.position(from: textView.beginningOfDocument, offset: offset) else { return nil }
        let rect = textView.caretRect(for: position)
        return rect.isNull || rect.isInfinite ? nil : rect
    }

    private func place(caret peer: CollaborationPeer, color: UIColor, at rect: CGRect, origin: CGPoint) {
        let view = carets[peer.clientID] ?? makeCaret(peer)
        let label = view.subviews.first as? UILabel
        label?.text = String(peer.name.prefix(40))
        label?.backgroundColor = color
        view.subviews.last?.backgroundColor = color
        view.accessibilityLabel = peer.name
        let labelSize = label?.sizeThatFits(CGSize(width: 160, height: 20)) ?? .zero
        let top = max(rect.minY - origin.y - labelSize.height, 0)
        view.frame = CGRect(
            x: rect.minX - origin.x, y: top, width: max(2, labelSize.width + 8),
            height: rect.maxY - origin.y - top)
        label?.frame = CGRect(x: 0, y: 0, width: labelSize.width + 8, height: labelSize.height)
        view.subviews.last?.frame = CGRect(x: 0, y: 0, width: 2, height: view.bounds.height)
    }

    private func makeCaret(_ peer: CollaborationPeer) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "nativeEditor.peerCursor.\(peer.clientID)"
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.cornerRadius = 3
        label.layer.masksToBounds = true
        view.addSubview(label)
        view.addSubview(UIView())
        addSubview(view)
        carets[peer.clientID] = view
        return view
    }

    /// The selection's visible part, tinted. Not drawn across folded content.
    private func highlight(
        _ id: UInt, range: NSRange, visible: NSRange, color: UIColor, in textView: NativeTextView
    ) -> Bool {
        let shown = NSIntersectionRange(range, visible)
        guard shown.length > 0,
            surface?.hiddenRanges.contains(where: { NSIntersectionRange($0, shown).length > 0 }) != true,
            let start = textView.position(from: textView.beginningOfDocument, offset: shown.location),
            let end = textView.position(from: start, offset: shown.length),
            let textRange = textView.textRange(from: start, to: end)
        else { return false }
        let rects = textView.selectionRects(for: textRange).map(\.rect).filter { !$0.isEmpty && !$0.isNull }
        var views = highlights[id] ?? []
        while views.count < rects.count {
            let view = UIView()
            insertSubview(view, at: 0)
            views.append(view)
        }
        while views.count > rects.count { views.removeLast().removeFromSuperview() }
        for (view, rect) in zip(views, rects) {
            view.backgroundColor = color.withAlphaComponent(0.25)
            view.frame = rect.offsetBy(dx: -textView.bounds.minX, dy: -textView.bounds.minY)
        }
        highlights[id] = views
        return !views.isEmpty
    }

    /// A collaborator badge at the owning block's trailing edge, one slot per
    /// peer on that block.
    private func place(badge peer: CollaborationPeer, color: UIColor, line: CGRect, index: Int, in textView: UITextView)
    {
        let size: CGFloat = 20
        let view = (badges[peer.clientID] as? UILabel) ?? makeBadge(peer)
        view.text = avatarInitials(for: peer.name)
        view.backgroundColor = color
        view.accessibilityLabel = peer.name
        let trailing = textView.bounds.width - textView.textContainerInset.right - size
        view.frame = CGRect(
            x: trailing - CGFloat(index) * (size + 2), y: line.midY - textView.bounds.minY - size / 2, width: size,
            height: size)
    }

    private func makeBadge(_ peer: CollaborationPeer) -> UILabel {
        let view = UILabel()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "nativeEditor.peerBadge.\(peer.clientID)"
        view.font = .preferredFont(forTextStyle: .caption2)
        view.textColor = .white
        view.textAlignment = .center
        view.layer.cornerRadius = 10
        view.layer.masksToBounds = true
        addSubview(view)
        badges[peer.clientID] = view
        return view
    }
}

extension UIColor {
    /// A `0xRRGGBB` palette value (never peer-supplied text).
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
