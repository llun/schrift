import SwiftUI
import UIKit

/// The native table editor (PR11a): one table's whole grid over the document,
/// laid out from the replica's spans, widths, header cells, colours and
/// alignment, with the **table surface's own text view** over the active
/// cell. That surface (`NativeEditorSession.openTable`) holds every paragraph
/// of the table; `NativeInputCoordinator.showCell` leaves all but the active
/// cell's out of layout, so moving between cells is view state: the text view
/// stays first responder, the keyboard stays up and held keys keep flowing.
/// Typing, marks, IME, undo, prediction and barriers are the document's own
/// machinery, unchanged. Keys follow BlockNote 0.56's `TableExtension`: Tab
/// and Shift-Tab walk cells in row order (nothing at either end; no new row),
/// Return moves to the cell below, Escape returns to the document.
///
/// A table the replica cannot open (unfamiliar, too large, a read-only
/// document) is the same grid with no text view: a viewer.
@MainActor
final class TableEditorViewController: UIViewController {
    let tableID: String
    private let document: NativeEditorSession
    /// The table surface; nil for a viewer.
    private(set) var cellSession: NativeEditorSession?
    private(set) var grid: TableGrid?
    private(set) var active: TableGrid.CellRef?
    private let start: TableGrid.CellRef?
    private let scrollView = UIScrollView()
    private let gridView = UIView()
    private(set) var cellViews: [TableGrid.CellRef: UIView] = [:]
    private var labelViews: [TableGrid.CellRef: UILabel] = [:]
    private var refreshTask: Task<Void, Never>?
    /// Set once the grid is shown (tests wait for it).
    private(set) var isLoaded = false
    private var loadStarted = false
    private var isClosed = false
    var labels = NativeEditorLabels()
    var cellLabel: (Int, Int) -> String = { "Row \($0), column \($1)" }
    var doneTitle = "Done"
    /// The editor closed: the document takes focus back.
    var onClose: (() -> Void)?

    static let padding: CGFloat = 8
    static let minimumRowHeight: CGFloat = 44

    init(document: NativeEditorSession, tableID: String, start: TableGrid.CellRef? = nil) {
        self.document = document
        self.tableID = tableID
        self.start = start
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: doneTitle, primaryAction: UIAction { [weak self] _ in self?.close() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "nativeEditor.table.done"
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .none
        scrollView.accessibilityIdentifier = "nativeEditor.table.grid"
        view.addSubview(scrollView)
        scrollView.addSubview(gridView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        Task { await load() }
    }

    /// Opens the table surface (or, failing that, reads the grid for the
    /// viewer) and shows the first cell, or `start`.
    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        if let session = await document.openTable(tableID) {
            // Closed while the table surface was attaching: end it now.
            guard !isClosed else {
                session.close()
                return
            }
            cellSession = session
            grid = session.grid
            session.onApplied = { [weak self] in self?.applied($0) }
            session.input?.tableMove = { [weak self] in self?.move($0) ?? false }
            session.textView.isScrollEnabled = false
        } else {
            grid = await document.tableGrid(tableID)
        }
        title = grid.map { String(format: labels.table, $0.rows.count, $0.columnCount) }
        rebuild()
        if let grid, let first = start ?? grid.order.first { activate(first) }
        isLoaded = true
    }

    /// Ends the table surface and hands focus back to the document.
    func close() {
        isClosed = true
        refreshTask?.cancel()
        cellSession?.textView.resignFirstResponder()
        cellSession?.close()
        cellSession = nil
        // A SwiftUI host dismisses through `onClose`; a UIKit presenter here.
        if let onClose { onClose() } else { dismiss(animated: true) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A dismissal that did not come through `close` ends the surface too.
        guard cellSession != nil, isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        cellSession?.close()
        cellSession = nil
        onClose?()
    }

    // MARK: - Cells

    /// The cell's paragraph ids in the table surface, in order.
    func paragraphIDs(_ ref: TableGrid.CellRef) -> [String] {
        guard let grid else { return [] }
        return grid.cell(ref).paragraphs.map { TableGrid.paragraphID(table: tableID, item: $0.itemID) }
    }

    /// Makes `ref` the active cell: the text view moves over it and shows its
    /// text selected (a viewer only highlights it).
    /// `selecting` false re-shows the same cell after a structure change and
    /// keeps the user's caret (selecting would make the next key replace it).
    @discardableResult
    func activate(_ ref: TableGrid.CellRef, selecting: Bool = true) -> Bool {
        guard let grid, grid.rows.indices.contains(ref.row), grid.rows[ref.row].indices.contains(ref.index) else {
            return false
        }
        let previous = active
        active = ref
        if let session = cellSession {
            let ids = paragraphIDs(ref)
            if let input = session.input, selecting {
                input.showCell(ids)
            } else {
                session.surface.setFocus(Set(ids))
            }
            // Over the cell, never inside it: a grid rebuild must not take the
            // first responder out of the window (the keyboard would drop).
            if session.textView.superview !== gridView { gridView.addSubview(session.textView) }
            gridView.bringSubviewToFront(session.textView)
            if !session.textView.isFirstResponder { session.textView.becomeFirstResponder() }
        }
        if let previous { labelViews[previous]?.isHidden = false }
        layoutGrid()
        if let frame = cellViews[ref]?.frame {
            scrollView.scrollRectToVisible(frame.insetBy(dx: -8, dy: -8), animated: false)
        }
        return true
    }

    /// A key's move (Tab, Shift-Tab, Return, Escape).
    func move(_ move: NativeInputCoordinator.TableMove) -> Bool {
        guard let grid, let active else { return false }
        let target: TableGrid.CellRef?
        switch move {
        case .next: target = grid.cell(after: active, forward: true)
        case .previous: target = grid.cell(after: active, forward: false)
        case .below: target = grid.cell(below: active)
        case .exit:
            close()
            return true
        }
        guard let target else { return false }
        return activate(target)
    }

    // MARK: - Deliveries

    private func applied(_ delivery: ReplicaDelivery) {
        // The table's own change is a structure change (rows, spans, colours):
        // read the grid again. Cell text arrives as the surface's own blocks.
        let structural = delivery.events.contains { event in
            guard case .patch(let patch, _) = event else { return false }
            return patch.changes.contains { change in
                switch change {
                case .text: false
                case .replaceBlock(let id, _), .props(let id, _): id == tableID
                case .insert, .remove, .reset: true
                }
            }
        }
        if structural {
            refreshGrid()
        } else {
            refreshLabels()
            layoutGrid()
        }
    }

    private func refreshGrid() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self, let grid = await self.document.tableGrid(self.tableID), !Task.isCancelled else { return }
            let keep = self.active.flatMap { self.grid?.cell($0).itemID }
            self.grid = grid
            self.cellSession?.grid = grid
            self.rebuild()
            // The active cell survives by identity; a deleted one gives way to the first.
            if let ref = grid.order.first(where: { grid.cell($0).itemID == keep }) {
                self.activate(ref, selecting: false)
            } else if let ref = grid.order.first {
                self.activate(ref)
            } else {
                self.active = nil
            }
        }
    }

    // MARK: - Layout

    private func rebuild() {
        cellViews.values.forEach { $0.removeFromSuperview() }
        cellViews = [:]
        labelViews = [:]
        guard let grid else { return }
        for ref in grid.order {
            let cell = grid.cell(ref)
            let container = UIView()
            container.layer.borderColor = UIColor.separator.cgColor
            container.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
            container.backgroundColor =
                cell.string("backgroundColor").flatMap(AttributedDocumentProjection.backgroundColor(named:))
                ?? (cell.isHeader ? .secondarySystemBackground : .systemBackground)
            container.accessibilityIdentifier = "nativeEditor.table.cell.\(cell.row).\(cell.column)"
            let label = UILabel()
            label.accessibilityIdentifier = "nativeEditor.table.text.\(cell.row).\(cell.column)"
            label.numberOfLines = 0
            label.isAccessibilityElement = true
            label.accessibilityLabel = cellLabel(cell.row + 1, cell.column + 1)
            label.accessibilityTraits = cell.isHeader ? [.header] : []
            container.addSubview(label)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            container.addGestureRecognizer(tap)
            gridView.addSubview(container)
            cellViews[ref] = container
            labelViews[ref] = label
        }
        refreshLabels()
        layoutGrid()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view, let ref = cellViews.first(where: { $0.value === view })?.key else { return }
        activate(ref)
    }

    /// Each cell's text: the table surface's live paragraphs, else the grid's.
    private func refreshLabels() {
        guard let grid else { return }
        let blocks = Dictionary(
            (cellSession?.surface.blocks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for ref in grid.order {
            let cell = grid.cell(ref)
            let paragraphs = zip(cell.paragraphs, paragraphIDs(ref)).map { paragraph, id in
                blocks[id] ?? BlockSnapshot(id: id, node: "paragraph", props: [], runs: paragraph.runs)
            }
            labelViews[ref]?.attributedText = Self.text(paragraphs, cell: cell, traits: traitCollection)
            labelViews[ref]?.accessibilityValue = paragraphs.map { $0.runs.map(\.text).joined() }.joined(
                separator: "\n")
        }
    }

    /// A cell's paragraphs as the document draws them, bold in a header, in
    /// the cell's alignment and text colour.
    static func text(_ paragraphs: [BlockSnapshot], cell: TableGrid.Cell, traits: UITraitCollection)
        -> NSAttributedString
    {
        let text = NSMutableAttributedString(
            attributedString: AttributedDocumentProjection.attributedString(blocks: paragraphs, traits: traits))
        if text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        let whole = NSRange(location: 0, length: text.length)
        let alignment: NSTextAlignment =
            switch cell.string("textAlignment") {
            case "center": .center
            case "right": .right
            case "justify": .justified
            default: .natural
            }
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style =
                ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.alignment = alignment
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
        if let color = cell.string("textColor").flatMap(AttributedDocumentProjection.textColor(named:)) {
            text.addAttribute(.foregroundColor, value: color, range: whole)
        }
        if cell.isHeader {
            text.enumerateAttribute(.font, in: whole) { value, range, _ in
                guard let font = value as? UIFont,
                    let descriptor = font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(.traitBold))
                else { return }
                text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
            }
        }
        return text
    }

    /// Columns from `colwidth` (else BlockNote's 120 pt), rows as tall as
    /// their tallest cell; a spanning cell grows its last row if it needs to.
    func layoutGrid() {
        guard let grid, grid.columnCount > 0 else { return }
        let widths = grid.columnWidths.map { CGFloat($0) }
        var offsets: [CGFloat] = [0]
        for width in widths { offsets.append(offsets.last! + width) }
        func width(_ cell: TableGrid.Cell) -> CGFloat { offsets[cell.column + cell.colspan] - offsets[cell.column] }
        func height(_ ref: TableGrid.CellRef) -> CGFloat {
            let cell = grid.cell(ref)
            let inner = width(cell) - 2 * Self.padding
            if ref == active, let text = cellSession?.textView {
                return max(
                    Self.minimumRowHeight,
                    text.sizeThatFits(CGSize(width: width(cell), height: .greatestFiniteMagnitude)).height)
            }
            let size = labelViews[ref]?.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)) ?? .zero
            return max(Self.minimumRowHeight, ceil(size.height) + 2 * Self.padding)
        }
        var rows = Array(repeating: Self.minimumRowHeight, count: grid.rows.count)
        let refs = grid.order
        for ref in refs where grid.cell(ref).rowspan == 1 {
            rows[grid.cell(ref).row] = max(rows[grid.cell(ref).row], height(ref))
        }
        for ref in refs where grid.cell(ref).rowspan > 1 {
            let cell = grid.cell(ref)
            let spanned = rows[cell.row..<(cell.row + cell.rowspan)].reduce(0, +)
            let needed = height(ref)
            if needed > spanned { rows[cell.row + cell.rowspan - 1] += needed - spanned }
        }
        var tops: [CGFloat] = [0]
        for row in rows { tops.append(tops.last! + row) }
        for ref in refs {
            let cell = grid.cell(ref)
            let frame = CGRect(
                x: offsets[cell.column], y: tops[cell.row], width: width(cell),
                height: tops[cell.row + cell.rowspan] - tops[cell.row])
            cellViews[ref]?.frame = frame
            labelViews[ref]?.frame =
                frame.size == .zero
                ? .zero : CGRect(origin: .zero, size: frame.size).insetBy(dx: Self.padding, dy: Self.padding)
            labelViews[ref]?.isHidden = ref == active && cellSession != nil
            cellViews[ref]?.layer.borderWidth = ref == active ? 2 : 1 / max(1, traitCollection.displayScale)
            cellViews[ref]?.layer.borderColor = (ref == active ? view.tintColor : UIColor.separator).cgColor
        }
        if let active, let text = cellSession?.textView, let container = cellViews[active] {
            text.frame = container.frame
        }
        gridView.frame = CGRect(x: 0, y: 0, width: offsets.last!, height: tops.last!)
        scrollView.contentSize = gridView.frame.size
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGrid()
    }
}

/// The table editor as `NativeEditorView` presents it (PR11a).
struct TableEditorScreen: UIViewControllerRepresentable {
    let document: NativeEditorSession
    let tableID: String
    let labels: NativeEditorLabels
    let doneTitle: String
    let cellLabel: (Int, Int) -> String
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = TableEditorViewController(document: document, tableID: tableID)
        editor.labels = labels
        editor.doneTitle = doneTitle
        editor.cellLabel = cellLabel
        editor.onClose = onClose
        return UINavigationController(rootViewController: editor)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
