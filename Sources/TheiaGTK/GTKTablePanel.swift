import CGtk4
import FITSCore

/// Paged FITS table grid. Only the visible page creates GTK cells, even for
/// tables with many rows; every row remains reachable with the page controls.
@MainActor final class GTKTablePanel {
    let widget: UnsafeMutablePointer<GtkWidget>
    let scroller: OpaquePointer
    let previousButton: UnsafeMutablePointer<GtkWidget>
    let nextButton: UnsafeMutablePointer<GtkWidget>
    let rangeLabel: OpaquePointer
    private(set) var grid: UnsafeMutablePointer<GtkGrid>?
    private(set) var page = 0
    private(set) var table: (any FITSTable)?
    private let pageSize = 100

    init() {
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        ))
        widget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        scroller = OpaquePointer(gtk_scrolled_window_new()!)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(scroller), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(scroller), 1)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(scroller))

        let footer = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        previousButton = gtk_button_new_with_label("Previous")!
        nextButton = gtk_button_new_with_label("Next")!
        rangeLabel = OpaquePointer(gtk_label_new("")!)
        gtk_box_append(footer, previousButton)
        gtk_box_append(footer, UnsafeMutablePointer<GtkWidget>(rangeLabel))
        gtk_box_append(footer, nextButton)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(footer)))
        GTKButtonAction { [weak self] in self?.changePage(by: -1) }.connect(to: previousButton)
        GTKButtonAction { [weak self] in self?.changePage(by: 1) }.connect(to: nextButton)
    }

    func show(hdu: FITSHDU) {
        table = FITSTableLoader.load(hdu)
        page = 0
        refresh()
    }

    func show(table: any FITSTable) {
        self.table = table
        page = 0
        refresh()
    }

    private func changePage(by step: Int) {
        guard let table else { return }
        let lastPage = table.rowCount == 0 ? 0 : (table.rowCount - 1) / pageSize
        let next = min(lastPage, max(0, page + step))
        guard next != page else { return }
        page = next
        refresh()
    }

    private func refresh() {
        let nextGrid = UnsafeMutablePointer<GtkGrid>(OpaquePointer(gtk_grid_new()!))
        grid = nextGrid
        gtk_grid_set_row_spacing(nextGrid, 2)
        gtk_grid_set_column_spacing(nextGrid, 12)
        if let table {
            addCell("#", column: 0, row: 0, header: true, to: nextGrid)
            for (column, info) in table.tableColumns.enumerated() {
                let detail = info.format + (info.unit.map { " [\($0)]" } ?? "")
                addCell("\(info.name)\n\(detail)", column: column + 1,
                        row: 0, header: true, to: nextGrid)
            }
            let start = page * pageSize
            let end = min(table.rowCount, start + pageSize)
            if start < end {
                for row in start..<end {
                    addCell(String(row + 1), column: 0, row: row - start + 1,
                            header: false, to: nextGrid)
                    for column in table.tableColumns.indices {
                        addCell(table.displayValue(row: row, column: column),
                                column: column + 1, row: row - start + 1,
                                header: false, to: nextGrid)
                    }
                }
            }
            gtk_label_set_text(rangeLabel,
                               "\(table.rowCount == 0 ? 0 : start + 1)–\(end) of \(table.rowCount) rows · \(table.tableColumns.count) columns")
            gtk_widget_set_sensitive(previousButton, page > 0 ? 1 : 0)
            gtk_widget_set_sensitive(nextButton, end < table.rowCount ? 1 : 0)
        } else {
            addCell("Unable to read this FITS table", column: 0, row: 0,
                    header: false, to: nextGrid)
            gtk_label_set_text(rangeLabel, "")
            gtk_widget_set_sensitive(previousButton, 0)
            gtk_widget_set_sensitive(nextButton, 0)
        }
        gtk_scrolled_window_set_child(scroller,
                                      UnsafeMutablePointer<GtkWidget>(OpaquePointer(nextGrid)))
    }

    private func addCell(_ text: String, column: Int, row: Int, header: Bool,
                         to grid: UnsafeMutablePointer<GtkGrid>) {
        let label = OpaquePointer(gtk_label_new(text)!)
        gtk_label_set_xalign(label, 0)
        gtk_label_set_selectable(label, 1)
        gtk_label_set_width_chars(label, header ? 16 : 18)
        gtk_widget_set_margin_start(UnsafeMutablePointer<GtkWidget>(label), 5)
        gtk_widget_set_margin_end(UnsafeMutablePointer<GtkWidget>(label), 5)
        gtk_grid_attach(grid, UnsafeMutablePointer<GtkWidget>(label),
                        gint(column), gint(row), 1, 1)
    }
}
