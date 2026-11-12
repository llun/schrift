import UIKit

/// One realised cell of the table editor's grid (PR11c): its colour, its
/// text, the CellSelection tint and a collaborator's badge. Recycled as the
/// grid scrolls; never an accessibility element itself (`TableGridView` is
/// the data table).
@MainActor
final class TableCellView: UIView {
    let label = UILabel()
    let selectionView = UIView()
    let peerLabel = UILabel()
    var ref: TableGrid.CellRef?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.isAccessibilityElement = false
        selectionView.isUserInteractionEnabled = false
        selectionView.isHidden = true
        peerLabel.font = .preferredFont(forTextStyle: .caption2)
        peerLabel.textColor = .white
        peerLabel.layer.cornerRadius = 3
        peerLabel.layer.masksToBounds = true
        peerLabel.isHidden = true
        peerLabel.isAccessibilityElement = false
        addSubview(label)
        addSubview(selectionView)
        addSubview(peerLabel)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }
}

/// The grid as VoiceOver's data table (PR11c): rows, columns, header cells
/// and spans (`UIAccessibilityContainerDataTable`). Its elements are made on
/// demand, one per cell, so a very large table costs only the cells VoiceOver
/// visits; the active cell is the table surface's own text view.
@MainActor
final class TableGridView: UIView, UIAccessibilityContainerDataTable {
    weak var editor: TableEditorViewController?
    private var elements: [TableGrid.CellRef: TableCellElement] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityContainerType = .dataTable
    }

    required init?(coder: NSCoder) { nil }

    /// The grid changed: elements are made again when next asked for.
    func invalidateElements() { elements = [:] }

    /// The cell's element (also its text view when that cell is being edited).
    func element(_ ref: TableGrid.CellRef) -> NSObject? {
        guard let editor, let grid = editor.grid, grid.rows.indices.contains(ref.row),
            grid.rows[ref.row].indices.contains(ref.index)
        else { return nil }
        if ref == editor.active, let text = editor.cellSession?.textView, editor.cellSession?.input != nil {
            let cell = grid.cell(ref)
            text.tableCellRanges = (
                NSRange(location: cell.row, length: cell.rowspan), NSRange(location: cell.column, length: cell.colspan)
            )
            return text
        }
        if let element = elements[ref] {
            editor.describe(element)
            return element
        }
        let element = TableCellElement(accessibilityContainer: self)
        element.ref = ref
        element.editor = editor
        let cell = grid.cell(ref)
        element.rowRange = NSRange(location: cell.row, length: cell.rowspan)
        element.columnRange = NSRange(location: cell.column, length: cell.colspan)
        element.accessibilityIdentifier = "nativeEditor.table.text.\(cell.row).\(cell.column)"
        editor.describe(element)
        elements[ref] = element
        return element
    }

    override func accessibilityElementCount() -> Int { editor?.order.count ?? 0 }

    override func accessibilityElement(at index: Int) -> Any? {
        guard let order = editor?.order, order.indices.contains(index) else { return nil }
        return element(order[index])
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard let editor else { return NSNotFound }
        if let cell = element as? TableCellElement, let ref = cell.ref { return editor.orderIndex[ref] ?? NSNotFound }
        if element as AnyObject === editor.cellSession?.textView, let active = editor.active {
            return editor.orderIndex[active] ?? NSNotFound
        }
        return NSNotFound
    }

    func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> (any UIAccessibilityContainerDataTableCell)?
    {
        guard let grid = editor?.grid, grid.slots.indices.contains(row), grid.slots[row].indices.contains(column) else {
            return nil
        }
        return element(grid.slots[row][column]) as? any UIAccessibilityContainerDataTableCell
    }

    func accessibilityRowCount() -> Int { editor?.grid?.slots.count ?? 0 }

    func accessibilityColumnCount() -> Int { editor?.grid?.columnCount ?? 0 }

    /// A row's header cells: the header column's cells in it.
    func accessibilityHeaderElements(forRow row: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        guard let grid = editor?.grid, grid.slots.indices.contains(row) else { return nil }
        var seen: Set<TableGrid.CellRef> = []
        return grid.slots[row].compactMap { ref -> (any UIAccessibilityContainerDataTableCell)? in
            guard seen.insert(ref).inserted, grid.cell(ref).isHeader,
                grid.rows.allSatisfy({ $0.contains { $0.isHeader && $0.column == grid.cell(ref).column } })
            else { return nil }
            return element(ref) as? any UIAccessibilityContainerDataTableCell
        }
    }

    /// A column's header cells: the header rows' cells in it.
    func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        guard let grid = editor?.grid, column >= 0, column < grid.columnCount else { return nil }
        var seen: Set<TableGrid.CellRef> = []
        return grid.slots.indices.compactMap { row -> (any UIAccessibilityContainerDataTableCell)? in
            let ref = grid.slots[row][column]
            guard seen.insert(ref).inserted, grid.rows[ref.row].allSatisfy(\.isHeader) else { return nil }
            return element(ref) as? any UIAccessibilityContainerDataTableCell
        }
    }
}

/// One cell for VoiceOver: its place (row and column, with spans), its text,
/// header and selected traits. Activating it edits the cell.
@MainActor
final class TableCellElement: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    var ref: TableGrid.CellRef?
    weak var editor: TableEditorViewController?
    var rowRange = NSRange(location: 0, length: 1)
    var columnRange = NSRange(location: 0, length: 1)

    func accessibilityRowRange() -> NSRange { rowRange }
    func accessibilityColumnRange() -> NSRange { columnRange }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { ref.flatMap { editor?.frame(of: $0) } ?? .zero }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard let ref, let editor else { return false }
        return editor.activate(ref)
    }

    override func accessibilityElementDidBecomeFocused() {
        guard let ref, let editor else { return }
        editor.scroll(to: ref)
    }
}

/// The table surface's text view as its data table cell (PR11c).
extension NativeTextView: UIAccessibilityContainerDataTableCell {
    func accessibilityRowRange() -> NSRange { tableCellRanges?.row ?? NSRange(location: NSNotFound, length: 0) }
    func accessibilityColumnRange() -> NSRange { tableCellRanges?.column ?? NSRange(location: NSNotFound, length: 0) }
}
