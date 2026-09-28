import CGtk4
import Foundation
import TheiaKit

/// Live pixel values around the cursor in an independent GTK window.
@MainActor final class GTKPixelTableWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let grid: UnsafeMutablePointer<GtkGrid>
    let sizeSpin: OpaquePointer
    let footer: OpaquePointer
    private let session: DocumentSession
    private let onSizeChange: @MainActor (Int) -> Void
    private let onDestroy: @MainActor () -> Void
    private var observerID: UUID?
    private(set) var gridSize = 7
    private var cellLabels: [[OpaquePointer]] = []

    init(application: UnsafeMutablePointer<GtkApplication>, session: DocumentSession,
         initialSize: Int = 7, onSizeChange: @escaping @MainActor (Int) -> Void = { _ in },
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.session = session
        self.onSizeChange = onSizeChange
        self.onDestroy = onDestroy
        gridSize = PixelTableModel(size: initialSize).size
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        grid = UnsafeMutablePointer<GtkGrid>(OpaquePointer(gtk_grid_new()!))
        sizeSpin = OpaquePointer(gtk_spin_button_new_with_range(5, 11, 2)!)
        footer = OpaquePointer(gtk_label_new("")!)
        gtk_window_set_title(widget, "Pixel Table")
        gtk_window_set_default_size(widget, 530, 330)
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 12)
        gtk_widget_set_margin_bottom(rootWidget, 12)
        gtk_widget_set_margin_start(rootWidget, 12)
        gtk_widget_set_margin_end(rootWidget, 12)
        let header = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        gtk_box_append(header, gtk_label_new("Pixel Table"))
        gtk_box_append(header, gtk_label_new("Size"))
        gtk_spin_button_set_value(sizeSpin, Double(gridSize))
        gtk_box_append(header, UnsafeMutablePointer<GtkWidget>(sizeSpin))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(header)))
        gtk_grid_set_row_spacing(grid, 2)
        gtk_grid_set_column_spacing(grid, 2)
        let scroll = gtk_scrolled_window_new()!
        gtk_widget_set_vexpand(scroll, 1)
        gtk_scrolled_window_set_child(OpaquePointer(scroll),
                                      UnsafeMutablePointer<GtkWidget>(OpaquePointer(grid)))
        gtk_box_append(root, scroll)
        gtk_label_set_xalign(footer, 0)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(footer))
        gtk_window_set_child(widget, rootWidget)

        let changedContext = Unmanaged.passRetained(self).toOpaque()
        let changed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKPixelTableWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                let size = PixelTableModel(size: Int(gtk_spin_button_get_value(window.sizeSpin))).size
                window.gridSize = size
                if Int(gtk_spin_button_get_value(window.sizeSpin)) != size {
                    gtk_spin_button_set_value(window.sizeSpin, Double(size))
                }
                window.onSizeChange(size)
                window.refresh()
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKPixelTableWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(sizeSpin), "value-changed",
                              unsafeBitCast(changed, to: GCallback.self), changedContext, release,
                              GConnectFlags(rawValue: 0))
        observerID = session.addEventObserver { [weak self] event in
            switch event.kind {
            case .cursorMoved, .imageRevisionChanged, .selectionChanged:
                self?.refresh()
            default: break
            }
        }
        let destroyContext = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKPixelTableWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.stop()
                window.onDestroy()
            }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), destroyContext, release,
                              GConnectFlags(rawValue: 0))
        refresh()
    }

    func present() { gtk_window_present(widget) }

    private func stop() {
        if let observerID {
            session.removeEventObserver(observerID)
            self.observerID = nil
        }
    }

    func refresh() {
        ensureGrid()
        guard let snapshot = PixelTableModel(size: gridSize).snapshot(
            image: session.displayed, cursor: session.cursor
        ) else {
            for row in cellLabels {
                for label in row { gtk_label_set_text(label, "—") }
            }
            gtk_label_set_text(footer, "Move the cursor over the image to populate.")
            return
        }
        for (row, cells) in snapshot.rows.enumerated() {
            for (column, cell) in cells.enumerated() {
                let label = cellLabels[row][column]
                let value = cell.text
                if String(cString: gtk_label_get_text(label)) != value {
                    gtk_label_set_text(label, value)
                }
            }
        }
        gtk_label_set_text(footer, "\(snapshot.coordinateText)    \(snapshot.valueText)")
    }

    private func ensureGrid() {
        guard cellLabels.count != gridSize else { return }
        let gridWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(grid))
        while let child = gtk_widget_get_first_child(gridWidget) {
            gtk_grid_remove(grid, child)
        }
        cellLabels = (0..<gridSize).map { row in
            (0..<gridSize).map { column in
                let label = OpaquePointer(gtk_label_new("—")!)
                gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(label), 1)
                if row == gridSize / 2 && column == gridSize / 2 {
                    gtk_widget_add_css_class(UnsafeMutablePointer<GtkWidget>(label), "accent")
                }
                gtk_grid_attach(grid, UnsafeMutablePointer<GtkWidget>(label),
                                Int32(column), Int32(row), 1, 1)
                return label
            }
        }
    }
}
