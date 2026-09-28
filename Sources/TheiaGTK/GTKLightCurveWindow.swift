import CGtk4
import Foundation
import TheiaKit

/// Independent GTK window for the shared cross-document light-curve model.
@MainActor final class GTKLightCurveWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let drawArea: OpaquePointer
    let normalizeButton: UnsafeMutablePointer<GtkCheckButton>
    let copyButton: UnsafeMutablePointer<GtkWidget>
    let yLabel: OpaquePointer
    private(set) var model: LightCurveModel
    private let sourceSession: DocumentSession
    private let onDestroy: @MainActor () -> Void

    init(application: UnsafeMutablePointer<GtkApplication>, model: LightCurveModel,
         sourceSession: DocumentSession,
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.sourceSession = sourceSession
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        drawArea = OpaquePointer(gtk_drawing_area_new()!)
        normalizeButton = UnsafeMutablePointer<GtkCheckButton>(OpaquePointer(
            gtk_check_button_new_with_label("Normalize to median")!
        ))
        copyButton = gtk_button_new_with_label("Copy CSV")!
        yLabel = OpaquePointer(gtk_label_new(model.yLabel)!)
        gtk_window_set_title(widget, "Light Curve")
        gtk_window_set_default_size(widget, 600, 380)

        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 12)
        gtk_widget_set_margin_bottom(rootWidget, 12)
        gtk_widget_set_margin_start(rootWidget, 12)
        gtk_widget_set_margin_end(rootWidget, 12)
        let header = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        gtk_box_append(header, gtk_label_new("Light curve — \(model.points.count) frames"))
        gtk_box_append(header, UnsafeMutablePointer<GtkWidget>(OpaquePointer(normalizeButton)))
        gtk_box_append(header, copyButton)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(header)))
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(drawArea), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(drawArea), 1)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(drawArea))
        let footer = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        gtk_box_append(footer, gtk_label_new(model.timeLabel))
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(yLabel), 1)
        gtk_label_set_xalign(yLabel, 1)
        gtk_box_append(footer, UnsafeMutablePointer<GtkWidget>(yLabel))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(footer)))
        gtk_window_set_child(widget, rootWidget)

        let drawContext = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(UnsafeMutablePointer<GtkDrawingArea>(drawArea), {
            _, cairo, width, height, userData in
            guard let cairo, let userData else { return }
            let window = Unmanaged<GTKLightCurveWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.draw(cairo: cairo, width: Double(width),
                                                    height: Double(height)) }
        }, drawContext, { userData in
            guard let userData else { return }
            Unmanaged<GTKLightCurveWindow>.fromOpaque(userData).release()
        })
        let toggleContext = Unmanaged.passRetained(self).toOpaque()
        let toggled: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKLightCurveWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.model.normalized = gtk_check_button_get_active(window.normalizeButton) != 0
                gtk_label_set_text(window.yLabel, window.model.yLabel)
                gtk_widget_queue_draw(UnsafeMutablePointer<GtkWidget>(window.drawArea))
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKLightCurveWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(normalizeButton), "toggled",
                              unsafeBitCast(toggled, to: GCallback.self), toggleContext, release,
                              GConnectFlags(rawValue: 0))
        GTKButtonAction { [weak self] in self?.copyCSV() }.connect(to: copyButton)
        let destroyContext = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKLightCurveWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.onDestroy() }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), destroyContext, release,
                              GConnectFlags(rawValue: 0))
        gtk_check_button_set_active(normalizeButton, model.normalized ? 1 : 0)
    }

    func present() { gtk_window_present(widget) }

    func update(_ model: LightCurveModel) {
        self.model = model
        gtk_check_button_set_active(normalizeButton, model.normalized ? 1 : 0)
        gtk_widget_queue_draw(UnsafeMutablePointer<GtkWidget>(drawArea))
        present()
    }

    private func copyCSV() {
        guard let display = gtk_widget_get_display(UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)))
        else { return }
        gdk_clipboard_set_text(gdk_display_get_clipboard(display), model.csv)
    }

    private func draw(cairo: OpaquePointer, width: Double, height: Double) {
        cairo_set_source_rgb(cairo, 0.04, 0.04, 0.06)
        cairo_paint(cairo)
        let pad = 24.0
        let plotWidth = width - 2 * pad
        let plotHeight = height - 2 * pad
        let points = model.displayedPoints.filter {
            $0.time.isFinite && $0.flux.isFinite && $0.err.isFinite
        }
        guard plotWidth > 0, plotHeight > 0, !points.isEmpty else { return }
        let xMin = points.map(\.time).min()!
        let xSpan = max(points.map(\.time).max()! - xMin, 1e-12)
        var yMin = points.map { $0.flux - abs($0.err) }.min()!
        var yMax = points.map { $0.flux + abs($0.err) }.max()!
        let margin = max((yMax - yMin) * 0.05, 1e-9)
        yMin -= margin
        yMax += margin
        let ySpan = max(yMax - yMin, 1e-12)
        func x(_ value: Double) -> Double { pad + (value - xMin) / xSpan * plotWidth }
        func y(_ value: Double) -> Double { height - pad - (value - yMin) / ySpan * plotHeight }

        cairo_set_source_rgba(cairo, 1, 1, 1, 0.35)
        cairo_set_line_width(cairo, 1)
        cairo_move_to(cairo, pad, pad)
        cairo_line_to(cairo, pad, height - pad)
        cairo_line_to(cairo, width - pad, height - pad)
        cairo_stroke(cairo)
        for point in points {
            let centreX = x(point.time)
            let centreY = y(point.flux)
            cairo_set_source_rgba(cairo, 1, 1, 1, 0.55)
            cairo_move_to(cairo, centreX, y(point.flux - abs(point.err)))
            cairo_line_to(cairo, centreX, y(point.flux + abs(point.err)))
            cairo_stroke(cairo)
            cairo_set_source_rgb(cairo, 0.55, 0.43, 0.92)
            cairo_arc(cairo, centreX, centreY, 3, 0, 2 * .pi)
            cairo_fill(cairo)
        }
    }
}
