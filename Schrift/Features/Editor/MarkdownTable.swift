import SwiftUI

// MARK: - Model

/// A GitHub-flavoured markdown table, read out of an `.unknown` block for the
/// reading surface.
///
/// The parser never sees a table as its own kind: `parseEditorBlocks` groups
/// it, like any other construct it can't model, into one verbatim `.unknown`
/// block, so a save writes the source back byte for byte. This is a **display**
/// interpretation of that text only — nothing here is written back, and the
/// editing surface still shows (and edits) the markdown source.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case none, leading, center, trailing
    }

    /// Header cells, as inline markdown with `\|` already unescaped.
    let header: [String]
    let alignments: [Alignment]
    /// Body rows, each padded or truncated to the header's column count — what
    /// GFM does with a ragged row.
    let rows: [[String]]

    var columnCount: Int { header.count }
}

/// Reads `text` as a GFM table, or returns `nil` when it is anything else.
///
/// Deliberately strict, because a `nil` keeps today's verbatim panel and a
/// false positive would redraw content as something it isn't: the first line
/// is the header row, the second a delimiter row (`---`, `:--`, `--:`, `:-:`
/// cells) with the same number of cells, and **every** following line is a
/// row containing an unescaped `|`. Leading prose, a trailing paragraph line
/// or an indented line (four spaces is code in CommonMark) all decline.
func parseMarkdownTable(_ text: String) -> MarkdownTable? {
    let lines = text.components(separatedBy: "\n")
    guard lines.count >= 2, lines.allSatisfy({ !$0.hasPrefix("    ") && !$0.hasPrefix("\t") }) else { return nil }

    guard let header = tableRowCells(lines[0]), let delimiter = tableRowCells(lines[1]),
        header.count == delimiter.count
    else { return nil }
    var alignments: [MarkdownTable.Alignment] = []
    for cell in delimiter {
        guard let alignment = delimiterAlignment(cell) else { return nil }
        alignments.append(alignment)
    }

    var rows: [[String]] = []
    for line in lines.dropFirst(2) {
        guard var cells = tableRowCells(line) else { return nil }
        if cells.count > header.count {
            cells.removeLast(cells.count - header.count)
        } else if cells.count < header.count {
            cells.append(contentsOf: Array(repeating: "", count: header.count - cells.count))
        }
        rows.append(cells)
    }
    return MarkdownTable(header: header, alignments: alignments, rows: rows)
}

/// Splits one table line into trimmed cells on unescaped pipes, dropping the
/// optional leading and trailing pipe. `nil` when the line has no unescaped
/// pipe at all — it is not a table row. `\|` is a literal pipe inside a cell
/// (GFM requires the escape even inside a code span) and is unescaped here;
/// every other backslash escape is left for the inline markdown renderer.
private func tableRowCells(_ line: String) -> [String]? {
    var cells: [String] = []
    var current = ""
    var sawPipe = false
    var escaped = false
    for character in line {
        if escaped {
            if character != "|" { current.append("\\") }
            current.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "|" {
            sawPipe = true
            cells.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    if escaped { current.append("\\") }
    cells.append(current)
    guard sawPipe else { return nil }

    // A leading `|` leaves an empty first piece and a trailing one an empty
    // last; only those are dropped, so an empty first or last *cell* survives.
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { cells.removeFirst() }
    if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
    guard !cells.isEmpty else { return nil }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
}

/// The alignment a delimiter cell declares, or `nil` when it isn't one.
private func delimiterAlignment(_ cell: String) -> MarkdownTable.Alignment? {
    let leadingColon = cell.hasPrefix(":")
    let trailingColon = cell.count > 1 && cell.hasSuffix(":")
    let dashes = cell.dropFirst(leadingColon ? 1 : 0).dropLast(trailingColon ? 1 : 0)
    guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
    switch (leadingColon, trailingColon) {
    case (true, true): return .center
    case (true, false): return .leading
    case (false, true): return .trailing
    case (false, false): return .none
    }
}

// MARK: - Column widths

/// How a table's columns share the width it is given — pure, so the tests can
/// pin it without laying out a view.
enum MarkdownTableColumnWidths {
    /// The narrowest a column shrinks to before the table scrolls sideways
    /// instead: about a dozen characters of body text, so a word wraps rather
    /// than breaking mid-way.
    static let minimumColumnWidth: CGFloat = 96
    /// The widest a column grows when the table scrolls, so one long cell wraps
    /// rather than stretching the table across several screens.
    static let maximumScrollingColumnWidth: CGFloat = 280

    /// The narrowest each column of the fitted layout can be drawn at — what
    /// it reports when `ViewThatFits` asks, so the table scrolls instead once
    /// the width can't hold every column at `minimumColumnWidth`.
    static func minimumFitting(ideals: [CGFloat]) -> [CGFloat] {
        ideals.map { min($0, minimumColumnWidth) }
    }

    /// Columns for a table that fits `available`, the way a web page's
    /// full-width table shares space: when the content is narrower than the
    /// width, every column grows in proportion to its content; when it is
    /// wider, columns whose content fits an even share keep their width and the
    /// rest split what is left evenly (water-filling).
    static func fitting(ideals: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        let total = ideals.reduce(0, +)
        if total <= available {
            guard total > 0 else { return ideals.map { _ in available / CGFloat(ideals.count) } }
            return ideals.map { $0 / total * available }
        }
        var widths = ideals
        var unsettled = Set(ideals.indices)
        var remaining = available
        while !unsettled.isEmpty {
            let share = remaining / CGFloat(unsettled.count)
            let settling = unsettled.filter { ideals[$0] <= share }
            if settling.isEmpty {
                for index in unsettled { widths[index] = max(share, 0) }
                break
            }
            for index in settling {
                remaining -= ideals[index]
                unsettled.remove(index)
            }
        }
        return widths
    }

    /// Columns for a table too wide to fit, inside a sideways scroll view: each
    /// column takes its content's width, capped so a long cell wraps.
    static func scrolling(ideals: [CGFloat]) -> [CGFloat] {
        ideals.map { min($0, maximumScrollingColumnWidth) }
    }
}

// MARK: - Layout

/// Lays out a table's cells — row-major, `columns` per row — on one shared set
/// of column widths, with each row as tall as its tallest cell. Every cell is
/// placed at its full column width and row height, so cell borders and the
/// header fill meet edge to edge like a web table's.
private struct MarkdownTableLayout: Layout {
    let columns: Int
    /// `true` to share the proposed width (`fitting`), `false` to take each
    /// column's natural width inside a sideways scroll view (`scrolling`).
    let fitsWidth: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(proposal: proposal, subviews: subviews)
        let heights = rowHeights(widths: widths, subviews: subviews)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        let heights = rowHeights(widths: widths, subviews: subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: widths[column], height: height))
                x += widths[column]
            }
            y += height
        }
    }

    private func columnWidths(proposal: ProposedViewSize, subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        var ideals = Array(repeating: CGFloat(0), count: columns)
        for (index, subview) in subviews.enumerated() {
            ideals[index % columns] = max(ideals[index % columns], subview.sizeThatFits(.unspecified).width)
        }
        guard fitsWidth else { return MarkdownTableColumnWidths.scrolling(ideals: ideals) }
        // No width offered is `ViewThatFits` asking how narrow this can go.
        guard let available = proposal.width, available.isFinite else {
            return MarkdownTableColumnWidths.minimumFitting(ideals: ideals)
        }
        return MarkdownTableColumnWidths.fitting(ideals: ideals, available: available)
    }

    private func rowHeights(widths: [CGFloat], subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let rowCount = (subviews.count + columns - 1) / columns
        return (0..<rowCount).map { row in
            (0..<columns).reduce(CGFloat(0)) { tallest, column in
                let index = row * columns + column
                guard index < subviews.count else { return tallest }
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil))
                return max(tallest, size.height)
            }
        }
    }
}

// MARK: - View

/// The reading surface's drawing of a `MarkdownTable`: a bordered grid with a
/// shaded, semibold header row — the shape the web editor gives the same
/// table. It fills the width when its columns can fit at
/// `MarkdownTableColumnWidths.minimumColumnWidth` each, and scrolls sideways
/// otherwise rather than squeezing columns to a word per line.
struct MarkdownTableView: View {
    @Environment(\.docsTheme) private var theme
    let table: MarkdownTable
    let serverOrigin: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(fitsWidth: true)
            ScrollView(.horizontal, showsIndicators: false) {
                grid(fitsWidth: false)
            }
        }
    }

    private func grid(fitsWidth: Bool) -> some View {
        MarkdownTableLayout(columns: table.columnCount, fitsWidth: fitsWidth) {
            ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                cell(text, column: column, isHeader: true)
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                    cell(text, column: column, isHeader: false)
                }
            }
        }
        // Each cell strokes its own half-width border, so two neighbours make
        // one full-width line; this closes the outer edge to the same width.
        .overlay(Rectangle().strokeBorder(theme.colors.borderDefault, lineWidth: cellBorderWidth))
    }

    private func cell(_ text: String, column: Int, isHeader: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .none
        return Text(markdownInlineText(text, theme: theme, serverHost: documentLinkHost(forOrigin: serverOrigin)))
            .font(DocsFont.body)
            .fontWeight(isHeader ? .semibold : nil)
            .foregroundStyle(theme.colors.textPrimary)
            .multilineTextAlignment(textAlignment(alignment))
            .padding(.horizontal, DocsSpacing.spaceXS)
            .padding(.vertical, DocsSpacing.space2xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(alignment))
            .background(isHeader ? theme.colors.surfaceSunken : Color.clear)
            .border(theme.colors.borderDefault, width: cellBorderWidth)
            .accessibilityAddTraits(isHeader ? .isHeader : [])
    }

    private var cellBorderWidth: CGFloat { 0.5 }

    private func textAlignment(_ alignment: MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .none, .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownTable.Alignment) -> SwiftUI.Alignment {
        switch alignment {
        case .none, .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}

private struct MarkdownTableCatalog: View {
    private let narrow = parseMarkdownTable(
        """
        | Page | What it covers |
        | --- | --- |
        | Architecture | How the server is put together: request flow, federation, data, jobs, auth, deploy |
        | Features | One page per feature area: what it does, how it works, key decisions and current state |
        | Prompts | Prompts used in **this** project |
        """)
    private let wide = parseMarkdownTable(
        """
        | Name | Status | Owner | Due | Notes |
        | :--- | :---: | --- | ---: | --- |
        | Tables | Done | Reader | 1 Nov | Renders as a grid while reading |
        | Editing | Later | Editor | — | Source stays markdown while editing |
        """)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
                if let narrow { MarkdownTableView(table: narrow, serverOrigin: "https://docs.llun.dev") }
                if let wide { MarkdownTableView(table: wide, serverOrigin: "https://docs.llun.dev") }
            }
            .padding()
        }
    }
}

#Preview("Light") {
    MarkdownTableCatalog()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    MarkdownTableCatalog()
        .preferredColorScheme(.dark)
}
