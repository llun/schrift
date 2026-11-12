import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
/// **PR11c.** A CellSelection (prosemirror-tables'): a long press and drag,
/// a pointer drag, Shift-click or Shift-arrows past a cell's edge select a
/// rectangle of slots; copy, cut, paste, Backspace, merge, colours and
/// alignment act on its cells exactly as the web's commands do
/// (`BlockNoteTableCommand.clear`, `.paste`, `.merge`). Arrows at a cell's
/// edge move to the next cell. The grid is **virtualised**: only the cells on
/// screen (and a margin) are realised views, rows are measured as they are
/// realised, and VoiceOver reads it as a data table (`TableGridView`) whose
/// elements are made on demand. Collaborators show as a badge on their cell
/// (a caret in the active one).
///
/// A table the replica cannot open (unfamiliar, too large, a read-only
/// document) is the same grid with no text view: a viewer, read up to
/// `TableGrid.maxViewerCells`.
@MainActor
final class TableEditorViewController: UIViewController, UIScrollViewDelegate {
    let tableID: String
    private let document: NativeEditorSession
    /// The table surface; nil for a viewer.
    private(set) var cellSession: NativeEditorSession?
    private(set) var grid: TableGrid?
    private(set) var active: TableGrid.CellRef?
    private let start: TableGrid.CellRef?
    let scrollView = UIScrollView()
    let gridView = TableGridView()
    /// The realised cells: those on screen and a margin around it.
    private(set) var cellViews: [TableGrid.CellRef: TableCellView] = [:]
    private var pool: [TableCellView] = []
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
    /// Menu titles (the app's localized strings; English in tests).
    var text: (L10nKey) -> String = { Strings_en.table[$0] ?? "" }
    /// The Row, Column, Cell and Format menus (PR11b), shown while editing.
    let controls = UIStackView()

    static let padding: CGFloat = 8
    static let minimumRowHeight: CGFloat = 44

    // MARK: Geometry (PR11c)

    /// Every cell once, in row order, and each one's place in it.
    private(set) var order: [TableGrid.CellRef] = []
    private(set) var orderIndex: [TableGrid.CellRef: Int] = [:]
    private var columnOffsets: [CGFloat] = [0]
    private var rowHeights: [CGFloat] = []
    private var rowTops: [CGFloat] = [0]
    /// Measured heights by cell, with what they were measured for.
    private var cellHeights: [TableGrid.CellRef: (key: Int, height: CGFloat)] = [:]
    /// Spanning cells by the row they end in (their extra height goes there).
    private var spansEnding: [Int: [TableGrid.CellRef]] = [:]
    private var cellOfParagraph: [String: TableGrid.CellRef] = [:]
    private var liveBlocks: [String: BlockSnapshot] = [:]

    // MARK: Selection (PR11c)

    /// prosemirror-tables' CellSelection, by the slots its anchor and head
    /// cells start at (a structure change keeps it where it still fits).
    struct CellSelection: Equatable {
        var anchor: TableSlot
        var head: TableSlot
    }

    private(set) var selection: CellSelection?
    /// Applied once the grid a command changes is read again.
    private var pendingSelection: CellSelection?
    private var pendingActive: TableSlot?
    private var dragAnchor: TableGrid.CellRef?

    // MARK: Collaborators (PR11c)

    /// Peers whose cursor is in a cell other than the one edited here.
    private(set) var peerMarks: [TableGrid.CellRef: [CollaborationPeer]] = [:]

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
        scrollView.delegate = self
        view.addSubview(scrollView)
        gridView.editor = self
        scrollView.addSubview(gridView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        gridView.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = .greatestFiniteMagnitude
        gridView.addGestureRecognizer(press)
        // A trackpad or mouse drags a selection as on the web; fingers scroll.
        let pointer = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pointer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        gridView.addGestureRecognizer(pointer)
        controls.axis = .horizontal
        controls.spacing = 8
        controls.distribution = .fillEqually
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.isHidden = true
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            controls.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 4),
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
            session.input?.tableKey = { [weak self] in self?.key($0) ?? false }
            session.textView.isScrollEnabled = false
            if let awareness = document.awareness { session.showAwareness(awareness) }
        } else {
            grid = await document.tableGrid(tableID, full: true)
        }
        title = grid.map { String(format: labels.table, $0.rows.count, $0.columnCount) }
        if cellSession?.input != nil { buildControls() }
        rebuild()
        observePeers()
        if let first = start ?? order.first { activate(first) }
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
    func activate(
        _ ref: TableGrid.CellRef, selecting: Bool = true, caret: NativeInputCoordinator.CellCaret = .selectAll
    ) -> Bool {
        guard let grid, grid.rows.indices.contains(ref.row), grid.rows[ref.row].indices.contains(ref.index) else {
            return false
        }
        active = ref
        if let session = cellSession {
            let ids = paragraphIDs(ref)
            if let input = session.input, selecting {
                input.showCell(ids, caret: caret)
            } else {
                session.surface.setFocus(Set(ids))
            }
            // Over the cell, never inside it: a grid rebuild must not take the
            // first responder out of the window (the keyboard would drop).
            if session.textView.superview !== gridView { gridView.addSubview(session.textView) }
            gridView.bringSubviewToFront(session.textView)
            if !session.textView.isFirstResponder { session.textView.becomeFirstResponder() }
        }
        refreshPeers()
        layoutGrid()
        scroll(to: ref)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
        return true
    }

    /// Brings `ref` on screen.
    func scroll(to ref: TableGrid.CellRef) {
        guard let frame = frame(of: ref) else { return }
        scrollView.scrollRectToVisible(frame.insetBy(dx: -8, dy: -8), animated: false)
    }

    /// A key's move (Tab, Shift-Tab, Return, Escape, ⌘Return).
    func move(_ move: NativeInputCoordinator.TableMove) -> Bool {
        guard let grid, let active else { return false }
        let target: TableGrid.CellRef?
        switch move {
        case .next: target = grid.cell(after: active, forward: true)
        case .previous: target = grid.cell(after: active, forward: false)
        case .below: target = grid.cell(below: active)
        case .exit:
            // Escape first drops a CellSelection, as clicking does on the web.
            if selection != nil {
                clearSelection()
                return true
            }
            close()
            return true
        case .done:
            close()
            return true
        }
        guard let target else { return false }
        clearSelection()
        return activate(target)
    }

    // MARK: - Keys (PR11c)

    /// The table surface's keys and clipboard, before the text view's.
    func key(_ key: NativeInputCoordinator.TableKey) -> Bool {
        switch key {
        case .typing:
            // Typing goes into the active cell; a CellSelection gives way.
            clearSelection()
            return false
        case .delete:
            guard let selection else { return false }
            perform(.clear(from: selection.anchor, to: selection.head))
            return true
        case .copy, .cut:
            guard let selection else { return false }
            Task { await copy(selection, cut: key == .cut) }
            return true
        case .paste:
            return paste()
        case .arrow(let direction, let extend):
            return arrow(direction, extend: extend)
        }
    }

    /// prosemirror-tables' `arrow` and `shiftArrow`: past the cell's edge an
    /// arrow moves to the neighbouring cell and a Shift-arrow starts (or a
    /// CellSelection grows) a selection; inside the text, the text view's.
    private func arrow(_ direction: NativeInputCoordinator.TableKey.Direction, extend: Bool) -> Bool {
        guard let grid, grid.isFamiliar, let active else { return false }
        if extend {
            let current = selection ?? (atEdge(direction) ? CellSelection(anchor: slot(active), head: slot(active)) : nil)
            guard let current else { return false }
            guard let head = next(cell(at: current.head), direction) else { return selection != nil }
            select(CellSelection(anchor: current.anchor, head: slot(head)))
            return true
        }
        if let selection {
            // `Selection.near($headCell)`: the head cell, its text selected.
            let head = cell(at: selection.head)
            clearSelection()
            return activate(head)
        }
        guard atEdge(direction) else { return false }
        switch direction {
        case .left, .right:
            guard let target = grid.cell(after: active, forward: direction == .right) else { return false }
            return activate(target, caret: direction == .right ? .start : .end)
        case .up, .down:
            guard let target = next(active, direction) else { return false }
            return activate(target, caret: .start)
        }
    }

    /// `atEndOfCell`: the caret at the cell text's first (last) position, or
    /// on its first (last) line for up (down).
    private func atEdge(_ direction: NativeInputCoordinator.TableKey.Direction) -> Bool {
        guard let active, let session = cellSession else { return false }
        let ids = paragraphIDs(active)
        let index = session.surface.rangeIndex
        guard let first = ids.first.flatMap({ index.entry(for: $0) }), let last = ids.last.flatMap({ index.entry(for: $0) })
        else { return false }
        let lower = first.textRange.location
        let upper = NSMaxRange(last.textRange)
        let selected = session.textView.selectedRange
        let view = session.textView
        func caretRect(_ offset: Int) -> CGRect? {
            view.position(from: view.beginningOfDocument, offset: offset).map { view.caretRect(for: $0) }
        }
        switch direction {
        case .left: return selected.location <= lower
        case .right: return NSMaxRange(selected) >= upper
        case .up:
            guard let caret = caretRect(selected.location), let top = caretRect(lower) else { return true }
            return abs(caret.minY - top.minY) < max(1, caret.height / 2)
        case .down:
            guard let caret = caretRect(NSMaxRange(selected)), let bottom = caretRect(upper) else { return true }
            return abs(caret.maxY - bottom.maxY) < max(1, caret.height / 2)
        }
    }

    /// `TableMap.nextCell`: the cell next to `ref`'s rectangle, or nil at the edge.
    private func next(_ ref: TableGrid.CellRef, _ direction: NativeInputCoordinator.TableKey.Direction)
        -> TableGrid.CellRef?
    {
        guard let grid else { return nil }
        let cell = grid.cell(ref)
        let (top, left) = (cell.row, cell.column)
        let (bottom, right) = (cell.row + cell.rowspan, cell.column + cell.colspan)
        switch direction {
        case .left: return left == 0 ? nil : grid.slots[top][left - 1]
        case .right: return right == grid.columnCount ? nil : grid.slots[top][right]
        case .up: return top == 0 ? nil : grid.slots[top - 1][left]
        case .down: return bottom == grid.slots.count ? nil : grid.slots[bottom][left]
        }
    }

    // MARK: - CellSelection (PR11c)

    private func slot(_ ref: TableGrid.CellRef) -> TableSlot {
        let cell = grid!.cell(ref)
        return TableSlot(row: cell.row, column: cell.column)
    }

    private func cell(at slot: TableSlot) -> TableGrid.CellRef { grid!.slots[slot.row][slot.column] }

    private func isValid(_ slot: TableSlot) -> Bool {
        guard let grid else { return false }
        return grid.slots.indices.contains(slot.row) && grid.slots[slot.row].indices.contains(slot.column)
    }

    /// `rectBetween` of the selection's cells, as slot bounds.
    func selectionRect() -> TableModel.Rect? {
        guard let selection, let grid, grid.isFamiliar, isValid(selection.anchor), isValid(selection.head) else {
            return nil
        }
        let a = grid.cell(cell(at: selection.anchor))
        let b = grid.cell(cell(at: selection.head))
        return TableModel.Rect(
            top: min(a.row, b.row), bottom: max(a.row + a.rowspan, b.row + b.rowspan),
            left: min(a.column, b.column), right: max(a.column + a.colspan, b.column + b.colspan))
    }

    /// `cellsInRect`: the selected cells (each starting inside the rectangle).
    var selectedCells: [TableGrid.CellRef] {
        guard let rect = selectionRect(), let grid else { return [] }
        var seen: Set<TableGrid.CellRef> = []
        var out: [TableGrid.CellRef] = []
        for row in rect.top..<rect.bottom {
            for column in rect.left..<rect.right {
                let ref = grid.slots[row][column]
                guard seen.insert(ref).inserted else { continue }
                if column == rect.left, column > 0, grid.slots[row][column - 1] == ref { continue }
                if row == rect.top, row > 0, grid.slots[row - 1][column] == ref { continue }
                out.append(ref)
            }
        }
        return out
    }

    func select(_ next: CellSelection?) {
        guard next != selection else { return }
        selection = next
        refreshSelection()
        if let rect = selectionRect() {
            UIAccessibility.post(
                notification: .announcement,
                argument: String(
                    format: text(.native_editor_table_selected), rect.bottom - rect.top, rect.right - rect.left))
        }
    }

    func clearSelection() { select(nil) }

    private func refreshSelection() {
        let selected = Set(selectedCells)
        for (ref, view) in cellViews {
            view.selectionView.isHidden = !selected.contains(ref)
            view.selectionView.backgroundColor = view.tintColor.withAlphaComponent(0.18)
        }
    }

    /// The cell under `point` (grid coordinates).
    private func cell(atPoint point: CGPoint) -> TableGrid.CellRef? {
        guard let grid, grid.columnCount > 0, !grid.slots.isEmpty else { return nil }
        let column = max(0, min(grid.columnCount - 1, Self.index(in: columnOffsets, for: point.x)))
        let row = max(0, min(grid.slots.count - 1, Self.index(in: rowTops, for: point.y)))
        return grid.slots[row][column]
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let ref = cell(atPoint: recognizer.location(in: gridView)) else { return }
        // Shift-click grows a CellSelection from the active cell (the web's mousedown).
        if recognizer.modifierFlags.contains(.shift), let active, grid?.isFamiliar == true, ref != active {
            select(CellSelection(anchor: selection?.anchor ?? slot(active), head: slot(ref)))
            return
        }
        clearSelection()
        activate(ref)
    }

    /// A long press then drag (touch) or a pointer drag selects the cells it
    /// crosses, from the cell it started in.
    @objc private func dragged(_ recognizer: UIGestureRecognizer) {
        guard grid?.isFamiliar == true, let ref = cell(atPoint: recognizer.location(in: gridView)) else { return }
        switch recognizer.state {
        case .began:
            dragAnchor = ref
            select(CellSelection(anchor: slot(ref), head: slot(ref)))
        case .changed:
            guard let anchor = dragAnchor else { return }
            select(CellSelection(anchor: slot(anchor), head: slot(ref)))
        default:
            dragAnchor = nil
        }
    }

    /// `mergeCells` on the CellSelection; the merged cell is then active.
    @discardableResult
    func mergeSelection() -> Bool {
        guard let selection, let rect = selectionRect() else { return false }
        pendingActive = TableSlot(row: rect.top, column: rect.left)
        clearSelection()
        return perform(.merge(from: selection.anchor, to: selection.head))
    }

    // MARK: - Clipboard (PR11c)

    /// Copy (and cut) of a CellSelection: BlockNote's HTML and Markdown and
    /// Schrift's lossless payload, read in mailbox order after every earlier
    /// edit; a cut then empties the cells, as the web's cut does.
    private func copy(_ selection: CellSelection, cut: Bool) async {
        guard let input = cellSession?.input,
            let copied = await document.tableCopy(tableID, from: selection.anchor, to: selection.head)
        else { return }
        var item: [String: Any] = [TableClipboard.htmlType: copied.html]
        if let plain = copied.plain { item[UTType.utf8PlainText.identifier] = plain }
        if let payload = copied.payload { item[BlockNoteSubtreePayload.pasteboardType] = payload }
        input.pasteboard.setItems([item])
        if cut { perform(.clear(from: selection.anchor, to: selection.head)) }
    }

    /// Paste as prosemirror-tables' `handlePaste`: cells (Schrift's payload,
    /// else an HTML table) into the CellSelection or from the active cell;
    /// plain text into a CellSelection fills each cell. False otherwise: the
    /// text view pastes into the cell's text.
    private func paste() -> Bool {
        guard let input = cellSession?.input, let grid, grid.isFamiliar, let active else { return false }
        let pasteboard = input.pasteboard
        var cells = pasteboard.data(forPasteboardType: BlockNoteSubtreePayload.pasteboardType).flatMap(
            TableClipboard.cells(payload:))
        if cells == nil, let html = Self.html(pasteboard) { cells = TableClipboard.cells(html: html) }
        if cells == nil, selection != nil, let text = pasteboard.string, !text.isEmpty {
            cells = [[TableClipboard.cell(text: text)]]
        }
        guard let cells else { return false }
        let anchor = selection?.anchor ?? slot(active)
        let head = selection?.head
        if perform(.paste(cells: cells, anchor: anchor, head: head)) {
            // The web selects what it pasted.
            if let head {
                pendingSelection = CellSelection(anchor: anchor, head: head)
            } else {
                let size = TableClipboard.size(cells)
                pendingSelection = CellSelection(
                    anchor: anchor,
                    head: TableSlot(row: anchor.row + size.height - 1, column: anchor.column + size.width - 1))
            }
        }
        return true
    }

    private static func html(_ pasteboard: UIPasteboard) -> String? {
        if let data = pasteboard.data(forPasteboardType: TableClipboard.htmlType) {
            return String(data: data, encoding: .utf8)
        }
        return pasteboard.value(forPasteboardType: TableClipboard.htmlType) as? String
    }

    // MARK: - Structure menus (PR11b)

    /// One button per menu; each menu is built when it opens, for the active
    /// cell and the grid as it is then.
    private func buildControls() {
        updateControls()
        let menus: [(key: L10nKey, identifier: String, build: () -> [UIMenuElement])] = [
            (.native_editor_table_row, "row", { [weak self] in self?.rowActions() ?? [] }),
            (.native_editor_table_column, "column", { [weak self] in self?.columnActions() ?? [] }),
            (.native_editor_table_cell_menu, "cell", { [weak self] in self?.cellActions() ?? [] }),
            (.native_editor_table_format, "format", { [weak self] in self?.formatActions() ?? [] }),
        ]
        for menu in menus {
            var configuration = UIButton.Configuration.bordered()
            configuration.title = text(menu.key)
            configuration.titleLineBreakMode = .byTruncatingTail
            let button = UIButton(configuration: configuration)
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { $0(menu.build()) }])
            button.accessibilityIdentifier = "nativeEditor.table.menu.\(menu.identifier)"
            controls.addArrangedSubview(button)
        }
    }

    /// A menu's items as it would open now (tests; the buttons build them so).
    func menuElements(_ identifier: String) -> [UIMenuElement] {
        switch identifier {
        case "row": rowActions()
        case "column": columnActions()
        case "cell": cellActions()
        default: formatActions()
        }
    }

    /// The menus show only while the table surface types and the grid is
    /// familiar: an uneven grid (a concurrent change awaiting its repair) has
    /// no structure commands.
    private func updateControls() {
        controls.isHidden = cellSession?.input == nil || grid?.isFamiliar != true
    }

    /// Runs `command` on the table through the table surface: one durable
    /// barrier, refused before writing when the web would refuse it.
    @discardableResult
    func perform(_ command: BlockNoteTableCommand) -> Bool {
        cellSession?.input?.applyTable(tableID, command) ?? false
    }

    private var activeCell: TableGrid.Cell? {
        guard let grid, grid.isFamiliar else { return nil }
        return active.flatMap { grid.cell($0) }
    }

    private func action(
        _ key: L10nKey, _ identifier: String, state: Bool = false, enabled: Bool = true,
        _ command: @autoclosure @escaping () -> BlockNoteTableCommand?
    ) -> UIAction {
        let action = UIAction(title: text(key), state: state ? .on : .off) { [weak self] _ in
            if let command = command() { self?.perform(command) }
        }
        action.accessibilityIdentifier = "nativeEditor.table.\(identifier)"
        if !enabled { action.attributes = .disabled }
        return action
    }

    /// Every cell starting in the active cell's row (the row handle's cells).
    private func rowSlots(_ cell: TableGrid.Cell) -> [TableSlot] {
        (grid?.rows[cell.row] ?? []).map { TableSlot(row: $0.row, column: $0.column) }
    }

    /// Every cell starting in the active cell's column.
    private func columnSlots(_ cell: TableGrid.Cell) -> [TableSlot] {
        (grid?.rows ?? []).flatMap { $0 }.filter { $0.column == cell.column }.map {
            TableSlot(row: $0.row, column: $0.column)
        }
    }

    private var headerRow: Bool { grid?.rows.contains { $0.allSatisfy(\.isHeader) } ?? false }
    private var headerColumn: Bool {
        guard let rows = grid?.rows, let first = rows.first else { return false }
        return first.indices.contains { index in rows.allSatisfy { $0.indices.contains(index) && $0[index].isHeader } }
    }

    private func colorMenu(_ key: String, title: L10nKey, identifier: String, slots: [TableSlot]) -> UIMenu {
        let names = ["default"] + NativeMark.colors
        let actions = names.map { name -> UIAction in
            let action = UIAction(
                title: text(L10nKey(rawValue: "native.editor.color_\(name)") ?? .native_editor_color_default)
            ) { [weak self] _ in
                self?.perform(.setCellProp(key: key, value: name, slots: slots))
            }
            action.accessibilityIdentifier = "nativeEditor.table.\(identifier).\(name)"
            return action
        }
        return UIMenu(title: text(title), children: actions)
    }

    private func rowActions() -> [UIMenuElement] {
        guard let cell = activeCell, let grid else { return [] }
        return [
            action(.native_editor_table_row_above, "rowAbove", .addRow(row: cell.row, after: false)),
            action(.native_editor_table_row_below, "rowBelow", .addRow(row: cell.row, after: true)),
            action(
                .native_editor_table_row_delete, "rowDelete", enabled: cell.rowspan < grid.rows.count,
                .deleteRow(row: cell.row)),
            action(.native_editor_table_header_row, "headerRow", state: headerRow, .toggleHeaderRow),
            colorMenu(
                "backgroundColor", title: .native_editor_format_background_color, identifier: "rowBackground",
                slots: rowSlots(cell)),
        ]
    }

    private func columnActions() -> [UIMenuElement] {
        guard let cell = activeCell, let grid else { return [] }
        let column = cell.column + cell.colspan - 1
        guard grid.isFamiliar, grid.columnWidths.indices.contains(column) else { return [] }
        let width = grid.columnWidths[column]
        return [
            action(.native_editor_table_column_left, "columnLeft", .addColumn(column: cell.column, after: false)),
            action(.native_editor_table_column_right, "columnRight", .addColumn(column: cell.column, after: true)),
            action(
                .native_editor_table_column_delete, "columnDelete", enabled: cell.colspan < grid.columnCount,
                .deleteColumn(column: cell.column)),
            action(.native_editor_table_header_column, "headerColumn", state: headerColumn, .toggleHeaderColumn),
            action(.native_editor_table_wider, "wider", .setColumnWidth(column: column, width: width + Self.widthStep)),
            action(
                .native_editor_table_narrower, "narrower", enabled: width > Self.minimumWidth,
                .setColumnWidth(column: column, width: max(Self.minimumWidth, width - Self.widthStep))),
            colorMenu(
                "backgroundColor", title: .native_editor_format_background_color, identifier: "columnBackground",
                slots: columnSlots(cell)),
        ]
    }

    /// `cellsOverlapRectangle`: whether a cell crosses the rectangle's edge.
    private func crossesEdge(_ rect: TableModel.Rect) -> Bool {
        guard let grid else { return true }
        let slots = grid.slots
        for row in rect.top..<rect.bottom {
            if rect.left > 0, slots[row][rect.left] == slots[row][rect.left - 1] { return true }
            if rect.right < grid.columnCount, slots[row][rect.right - 1] == slots[row][rect.right] { return true }
        }
        for column in rect.left..<rect.right {
            if rect.top > 0, slots[rect.top][column] == slots[rect.top - 1][column] { return true }
            if rect.bottom < slots.count, slots[rect.bottom - 1][column] == slots[rect.bottom][column] { return true }
        }
        return false
    }

    private func cellActions() -> [UIMenuElement] {
        guard let cell = activeCell, let grid, let active else { return [] }
        let slot = TableSlot(row: cell.row, column: cell.column)
        let right = TableSlot(row: cell.row, column: cell.column + cell.colspan)
        let below = TableSlot(row: cell.row + cell.rowspan, column: cell.column)
        // The CellSelection's cells, else the active cell (PR11c).
        let range = selection ?? CellSelection(anchor: slot, head: slot)
        let targets = selection == nil ? [slot] : selectedCells.map(self.slot)
        let rect = selectionRect()
        var items: [UIMenuElement] = []
        if let rect, selectedCells.count > 1 {
            let merge = UIAction(title: text(.native_editor_table_merge_cells)) { [weak self] _ in
                self?.mergeSelection()
            }.identified("nativeEditor.table.mergeCells")
            if crossesEdge(rect) { merge.attributes = .disabled }
            items.append(merge)
        } else {
            items += [
                action(
                    .native_editor_table_merge_right, "mergeRight", enabled: right.column < grid.columnCount,
                    .merge(from: slot, to: right)),
                action(
                    .native_editor_table_merge_down, "mergeDown", enabled: below.row < grid.rows.count,
                    .merge(from: slot, to: below)),
            ]
        }
        items.append(
            action(.native_editor_table_split, "split", enabled: cell.colspan > 1 || cell.rowspan > 1, .split(slot)))
        items.append(
            UIMenu(
                options: .displayInline,
                children: [
                    UIAction(title: text(.native_editor_table_copy_cells)) { [weak self] _ in
                        Task { await self?.copy(range, cut: false) }
                    }.identified("nativeEditor.table.copyCells"),
                    UIAction(title: text(.native_editor_table_cut_cells)) { [weak self] _ in
                        Task { await self?.copy(range, cut: true) }
                    }.identified("nativeEditor.table.cutCells"),
                    UIAction(title: text(.native_editor_table_paste_cells)) { [weak self] _ in
                        guard let self else { return }
                        if self.selection == nil { self.select(range) }
                        _ = self.paste()
                    }.identified("nativeEditor.table.pasteCells"),
                    action(.native_editor_table_clear_cells, "clearCells", .clear(from: range.anchor, to: range.head)),
                ]))
        items += [
            colorMenu("textColor", title: .native_editor_format_text_color, identifier: "cellText", slots: targets),
            colorMenu(
                "backgroundColor", title: .native_editor_format_background_color, identifier: "cellBackground",
                slots: targets),
            UIMenu(
                options: .displayInline,
                children: [
                    ("left", L10nKey.native_editor_table_align_left), ("center", .native_editor_table_align_center),
                    ("right", .native_editor_table_align_right),
                ].map { value, key in
                    action(
                        key, "align.\(value)", state: (grid.cell(active).string("textAlignment") ?? "left") == value,
                        .setCellProp(key: "textAlignment", value: value, slots: targets))
                }),
        ]
        return items
    }

    private func formatActions() -> [UIMenuElement] {
        guard let input = cellSession?.input else { return [] }
        let marks: [(String, L10nKey)] = [
            ("bold", .editor_format_bold), ("italic", .editor_format_italic),
            ("underline", .native_editor_format_underline), ("strike", .native_editor_format_strike),
            ("code", .native_editor_format_code),
        ]
        return marks.map { key, title in
            let action = UIAction(
                title: text(title), state: input.activeMarks.contains { $0.key == key } ? .on : .off
            ) { [weak input] _ in input?.toggleMark(key) }
            action.accessibilityIdentifier = "nativeEditor.table.format.\(key)"
            return action
        }
    }

    /// BlockNote's `columnResizing` floor and the menu's step.
    static let minimumWidth = 35
    static let widthStep = 40

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
            self.updateControls()
            self.cellSession?.grid = grid
            self.rebuild()
            // A selection survives where its slots still are (the web maps it).
            let next = self.pendingSelection ?? self.selection
            self.pendingSelection = nil
            self.selection = nil
            if let next, grid.isFamiliar, self.isValid(next.anchor), self.isValid(next.head) {
                self.select(next)
            }
            // A merge's cell becomes active (the web selects it); otherwise the
            // active cell survives by identity, and a deleted one gives way to the first.
            let focus = self.pendingActive.flatMap { self.isValid($0) ? self.cell(at: $0) : nil }
            self.pendingActive = nil
            if let focus {
                self.activate(focus)
            } else if let ref = self.order.first(where: { grid.cell($0).itemID == keep }) {
                self.activate(ref, selecting: false)
            } else if let ref = self.order.first {
                self.activate(ref)
            } else {
                self.active = nil
            }
        }
    }

    // MARK: - Layout (virtualised, PR11c)

    /// The grid changed: every cached place and view is made again.
    private func rebuild() {
        for view in cellViews.values { recycle(view) }
        cellViews = [:]
        cellHeights = [:]
        gridView.invalidateElements()
        guard let grid else {
            order = []
            orderIndex = [:]
            return
        }
        order = grid.order
        orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        spansEnding = [:]
        cellOfParagraph = [:]
        for ref in order {
            let cell = grid.cell(ref)
            if cell.rowspan > 1 { spansEnding[cell.row + cell.rowspan - 1, default: []].append(ref) }
            for paragraph in cell.paragraphs {
                cellOfParagraph[TableGrid.paragraphID(table: tableID, item: paragraph.itemID)] = ref
            }
        }
        columnOffsets = [0]
        for width in grid.columnWidths { columnOffsets.append(columnOffsets.last! + CGFloat(width)) }
        rowHeights = Array(repeating: Self.minimumRowHeight, count: grid.slots.count)
        recomputeTops()
        refreshLabels()
        layoutGrid()
    }

    /// The live text of the table surface's paragraphs, else the grid's.
    private func refreshLabels() {
        liveBlocks = Dictionary(
            (cellSession?.surface.blocks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (ref, view) in cellViews { configureText(view, ref) }
    }

    private func paragraphs(_ ref: TableGrid.CellRef) -> [BlockSnapshot] {
        guard let grid else { return [] }
        return zip(grid.cell(ref).paragraphs, paragraphIDs(ref)).map { paragraph, id in
            liveBlocks[id] ?? BlockSnapshot(id: id, node: "paragraph", props: [], runs: paragraph.runs)
        }
    }

    private func configureText(_ view: TableCellView, _ ref: TableGrid.CellRef) {
        guard let grid else { return }
        let text = Self.text(paragraphs(ref), cell: grid.cell(ref), traits: traitCollection)
        if view.label.attributedText != text { view.label.attributedText = text }
    }

    /// The text VoiceOver reads for `element`'s cell, its header and selected
    /// traits, and collaborators there.
    func describe(_ element: TableCellElement) {
        guard let ref = element.ref, let grid, grid.rows.indices.contains(ref.row),
            grid.rows[ref.row].indices.contains(ref.index)
        else { return }
        let cell = grid.cell(ref)
        element.accessibilityLabel = cellLabel(cell.row + 1, cell.column + 1)
        let value = paragraphs(ref).map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
        let peers = (peerMarks[ref] ?? []).map { String(format: labels.peerCursor, $0.name) }
        element.accessibilityValue = ([value] + peers).filter { !$0.isEmpty }.joined(separator: ", ")
        var traits: UIAccessibilityTraits = .staticText
        if cell.isHeader { traits.insert(.header) }
        if selectedCells.contains(ref) { traits.insert(.selected) }
        element.accessibilityTraits = traits
    }

    private func recycle(_ view: TableCellView) {
        view.isHidden = true
        view.ref = nil
        pool.append(view)
    }

    private func realise(_ ref: TableGrid.CellRef) -> TableCellView {
        let view = pool.popLast() ?? {
            let view = TableCellView()
            view.layer.borderColor = UIColor.separator.cgColor
            gridView.insertSubview(view, at: 0)
            return view
        }()
        guard let grid else { return view }
        let cell = grid.cell(ref)
        view.ref = ref
        view.isHidden = false
        view.backgroundColor =
            cell.string("backgroundColor").flatMap(AttributedDocumentProjection.backgroundColor(named:))
            ?? (cell.isHeader ? .secondarySystemBackground : .systemBackground)
        view.accessibilityIdentifier = "nativeEditor.table.cell.\(cell.row).\(cell.column)"
        configureText(view, ref)
        return view
    }

    /// The cells' and the active cell's frame, from the column offsets and
    /// the (measured or estimated) row heights; nil for a cell not in the grid.
    func frame(of ref: TableGrid.CellRef) -> CGRect? {
        guard let grid, grid.rows.indices.contains(ref.row), grid.rows[ref.row].indices.contains(ref.index),
            grid.columnCount > 0, rowTops.count == grid.slots.count + 1
        else { return nil }
        let cell = grid.cell(ref)
        guard cell.column + cell.colspan < columnOffsets.count, cell.row + cell.rowspan < rowTops.count else {
            return nil
        }
        return CGRect(
            x: columnOffsets[cell.column], y: rowTops[cell.row],
            width: columnOffsets[cell.column + cell.colspan] - columnOffsets[cell.column],
            height: rowTops[cell.row + cell.rowspan] - rowTops[cell.row])
    }

    /// The last index whose offset is at or before `value` (offsets ascend).
    private static func index(in offsets: [CGFloat], for value: CGFloat) -> Int {
        var lower = 0
        var upper = offsets.count - 1
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if offsets[middle] <= value { lower = middle } else { upper = middle - 1 }
        }
        return lower
    }

    private func recomputeTops() {
        rowTops = [0]
        rowTops.reserveCapacity(rowHeights.count + 1)
        for height in rowHeights { rowTops.append(rowTops.last! + height) }
    }

    /// A cell's height for its text at its width: the text view's own insets
    /// for the cell being edited, the label's padding otherwise.
    private func height(_ ref: TableGrid.CellRef, width: CGFloat) -> CGFloat {
        guard let grid else { return Self.minimumRowHeight }
        // A realised cell's label already holds its text (`configureText`).
        let text =
            cellViews[ref]?.label.attributedText
            ?? Self.text(paragraphs(ref), cell: grid.cell(ref), traits: traitCollection)
        let key = text.string.hashValue ^ Int(width * 2) ^ (ref == active ? 1 : 0)
        if let cached = cellHeights[ref], cached.key == key { return cached.height }
        var insets = UIEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        if ref == active, let view = cellSession?.textView {
            let padding = view.textContainer.lineFragmentPadding
            insets = view.textContainerInset
            insets.left += padding
            insets.right += padding
        }
        let size = text.boundingRect(
            with: CGSize(width: max(1, width - insets.left - insets.right), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let height = max(Self.minimumRowHeight, ceil(size.height) + insets.top + insets.bottom)
        cellHeights[ref] = (key, height)
        return height
    }

    /// Row `row`'s height: its tallest single-row cell, grown for a spanning
    /// cell ending there (only measured cells count; the rest are estimates).
    private func recomputeRow(_ row: Int) -> Bool {
        guard let grid else { return false }
        var height = Self.minimumRowHeight
        for (index, cell) in grid.rows[row].enumerated() where cell.rowspan == 1 {
            if let measured = cellHeights[TableGrid.CellRef(row: row, index: index)]?.height {
                height = max(height, measured)
            }
        }
        for ref in spansEnding[row] ?? [] {
            guard let measured = cellHeights[ref]?.height else { continue }
            let top = grid.cell(ref).row
            let above = rowHeights[top..<row].reduce(0, +)
            height = max(height, measured - above)
        }
        guard height != rowHeights[row] else { return false }
        rowHeights[row] = height
        return true
    }

    /// Realises the cells on screen (and a margin) and recycles the rest,
    /// measures the realised ones, then places them and the text view.
    func layoutGrid() {
        guard let grid, grid.columnCount > 0, !grid.slots.isEmpty, rowHeights.count == grid.slots.count else { return }
        for _ in 0..<3 {
            let bounds = scrollView.bounds
            let margin = max(bounds.height, 300) / 2
            let visible = bounds.insetBy(dx: -margin, dy: -margin)
            let rows = Self.index(in: rowTops, for: max(0, visible.minY))...Self.index(
                in: rowTops, for: max(0, visible.maxY))
            let columns = Self.index(in: columnOffsets, for: max(0, visible.minX))...Self.index(
                in: columnOffsets, for: max(0, visible.maxX))
            var wanted: Set<TableGrid.CellRef> = []
            for row in rows where row < grid.slots.count {
                for column in columns where column < grid.columnCount { wanted.insert(grid.slots[row][column]) }
            }
            // The text view's cell stays realised wherever it is; a viewer's highlight need not.
            if let active, cellSession != nil { wanted.insert(active) }
            for (ref, view) in cellViews where !wanted.contains(ref) {
                recycle(view)
                cellViews[ref] = nil
            }
            for ref in wanted where cellViews[ref] == nil { cellViews[ref] = realise(ref) }
            // Measure what is realised; rows grow (or shrink) to fit.
            var dirty: Set<Int> = []
            for ref in wanted {
                let cell = grid.cell(ref)
                let width = columnOffsets[cell.column + cell.colspan] - columnOffsets[cell.column]
                let before = cellHeights[ref]?.height
                if height(ref, width: width) != before { dirty.insert(cell.row + cell.rowspan - 1) }
            }
            let anchorRow = Self.index(in: rowTops, for: scrollView.contentOffset.y)
            let anchorTop = rowTops[anchorRow]
            var changed = false
            for row in dirty.sorted() where recomputeRow(row) { changed = true }
            guard changed else { break }
            recomputeTops()
            // Rows above the viewport that grew must not push the content seen.
            if anchorRow > 0, scrollView.contentOffset.y > 0, rowTops[anchorRow] != anchorTop {
                scrollView.contentOffset.y += rowTops[anchorRow] - anchorTop
            }
        }
        let selected = Set(selectedCells)
        let hairline = 1 / max(1, traitCollection.displayScale)
        for (ref, view) in cellViews {
            guard let frame = frame(of: ref) else { continue }
            view.frame = frame
            view.label.frame = CGRect(origin: .zero, size: frame.size).insetBy(dx: Self.padding, dy: Self.padding)
            view.selectionView.frame = view.bounds
            view.selectionView.isHidden = !selected.contains(ref)
            view.selectionView.backgroundColor = view.tintColor.withAlphaComponent(0.18)
            view.label.isHidden = ref == active && cellSession != nil
            let peer = peerMarks[ref]?.first
            let peerColor = peer.map { UIColor(rgb: avatarColorHex(for: $0.name)) }
            view.layer.borderWidth = ref == active ? 2 : (peer != nil ? 2 : hairline)
            let border: UIColor = ref == active ? view.tintColor : (peerColor ?? .separator)
            view.layer.borderColor = border.cgColor
            view.peerLabel.isHidden = peer == nil
            if let peer {
                view.peerLabel.text = " " + String(peer.name.prefix(20)) + " "
                view.peerLabel.backgroundColor = peerColor
                let size = view.peerLabel.sizeThatFits(CGSize(width: frame.width, height: 20))
                view.peerLabel.frame = CGRect(
                    x: max(0, frame.width - size.width), y: 0, width: min(size.width, frame.width), height: size.height)
            }
        }
        if let active, let text = cellSession?.textView, let frame = frame(of: active) { text.frame = frame }
        gridView.frame = CGRect(x: 0, y: 0, width: columnOffsets.last!, height: rowTops.last!)
        scrollView.contentSize = gridView.frame.size
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGrid()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutGrid()
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

    // MARK: - Collaborators (PR11c)

    /// Follows the document's collaborators while the editor is open.
    private func observePeers() {
        guard let awareness = document.awareness, !isClosed else { return }
        withObservationTracking {
            _ = awareness.places
            _ = awareness.peers
        } onChange: {
            Task { @MainActor [weak self] in
                self?.refreshPeers()
                self?.observePeers()
            }
        }
        refreshPeers()
    }

    /// Each collaborator's cell: a badge on it, unless it is the cell edited
    /// here, where the text view's overlay draws their caret.
    private func refreshPeers() {
        var marks: [TableGrid.CellRef: [CollaborationPeer]] = [:]
        if let awareness = document.awareness {
            for peer in awareness.peers {
                guard let place = awareness.places[peer.clientID]?.head, let ref = cellOfParagraph[place.blockID],
                    cellSession == nil || ref != active
                else { continue }
                marks[ref, default: []].append(peer)
            }
        }
        guard marks != peerMarks else { return }
        peerMarks = marks
        layoutGrid()
    }
}

extension UIAction {
    fileprivate func identified(_ identifier: String) -> UIAction {
        accessibilityIdentifier = identifier
        return self
    }
}

/// The table editor as `NativeEditorView` presents it (PR11a).
struct TableEditorScreen: UIViewControllerRepresentable {
    let document: NativeEditorSession
    let tableID: String
    let labels: NativeEditorLabels
    let doneTitle: String
    let cellLabel: (Int, Int) -> String
    let text: (L10nKey) -> String
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = TableEditorViewController(document: document, tableID: tableID)
        editor.labels = labels
        editor.doneTitle = doneTitle
        editor.cellLabel = cellLabel
        editor.text = text
        editor.onClose = onClose
        return UINavigationController(rootViewController: editor)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
