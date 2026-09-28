import CGtk4
import Foundation
import TheiaKit

@MainActor private final class GTKSpinAction {
    private let onChange: @MainActor (Double) -> Void

    init(_ onChange: @escaping @MainActor (Double) -> Void) { self.onChange = onChange }

    func connect(to spin: OpaquePointer) {
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, gpointer?) -> Void = { spin, userData in
            guard let spin, let userData else { return }
            let action = Unmanaged<GTKSpinAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.onChange(gtk_spin_button_get_value(spin)) }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(spin), "value-changed",
                              unsafeBitCast(callback, to: GCallback.self), context,
                              { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKSpinAction>.fromOpaque(userData).release()
        }, GConnectFlags(rawValue: 0))
    }
}

/// A separate, resizable GTK window for data produced by the shared profile models.
@MainActor final class GTKPlotWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let drawArea: UnsafeMutablePointer<GtkDrawingArea>
    let controls: UnsafeMutablePointer<GtkBox>
    private let sourceSession: DocumentSession
    private let onDestroy: @MainActor () -> Void
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var highlightX: Double?
    private var destroyed = false
    private let statisticsLabel: OpaquePointer
    var sampleCount: Int { min(xs.count, ys.count) }

    init(application: UnsafeMutablePointer<GtkApplication>, sourceSession: DocumentSession,
         title: String, xLabel: String, yLabel: String,
         onDestroy: @escaping @MainActor () -> Void) {
        self.sourceSession = sourceSession
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        drawArea = UnsafeMutablePointer<GtkDrawingArea>(OpaquePointer(
            gtk_drawing_area_new()!
        ))
        controls = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        statisticsLabel = OpaquePointer(gtk_label_new("Computing…")!)
        gtk_window_set_title(widget, title)
        gtk_window_set_default_size(widget, 540, 350)

        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 12)
        gtk_widget_set_margin_bottom(rootWidget, 12)
        gtk_widget_set_margin_start(rootWidget, 12)
        gtk_widget_set_margin_end(rootWidget, 12)
        gtk_label_set_xalign(statisticsLabel, 0)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(statisticsLabel))
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(drawArea)), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(drawArea)), 1)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(drawArea)))
        let footer = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        gtk_box_append(footer, gtk_label_new(xLabel))
        let valueLabel = gtk_label_new(yLabel)!
        gtk_widget_set_hexpand(valueLabel, 1)
        gtk_label_set_xalign(OpaquePointer(valueLabel), 1)
        gtk_box_append(footer, valueLabel)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(footer)))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(controls)))
        gtk_window_set_child(widget, rootWidget)

        let drawContext = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(drawArea, { _, cairo, width, height, userData in
            guard let cairo, let userData else { return }
            let window = Unmanaged<GTKPlotWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.draw(cairo: cairo, width: Double(width), height: Double(height))
            }
        }, drawContext, { userData in
            guard let userData else { return }
            Unmanaged<GTKPlotWindow>.fromOpaque(userData).release()
        })
        let destroyContext = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKPlotWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.destroyed = true
                window.onDestroy()
            }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), destroyContext,
                              { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKPlotWindow>.fromOpaque(userData).release()
        }, GConnectFlags(rawValue: 0))
    }

    func present() { gtk_window_present(widget) }

    @discardableResult func addSpin(
        label: String, value: Double, minimum: Double, maximum: Double, step: Double,
        onChange: @escaping @MainActor (Double) -> Void
    ) -> OpaquePointer {
        gtk_box_append(controls, gtk_label_new(label))
        let spin = OpaquePointer(gtk_spin_button_new_with_range(minimum, maximum, step)!)
        gtk_spin_button_set_digits(spin, step < 1 ? 1 : 0)
        gtk_spin_button_set_value(spin, value)
        GTKSpinAction(onChange).connect(to: spin)
        gtk_box_append(controls, UnsafeMutablePointer<GtkWidget>(spin))
        return spin
    }

    func setSeries(x: [Double], y: [Double], highlightX: Double? = nil) {
        guard !destroyed else { return }
        xs = x
        ys = y
        self.highlightX = highlightX
        let finite = y.filter(\.isFinite)
        if finite.isEmpty {
            gtk_label_set_text(statisticsLabel, "No finite samples")
        } else {
            let sum = finite.reduce(0, +)
            gtk_label_set_text(statisticsLabel, String(format:
                "min %.4g   max %.4g   mean %.4g   n=%d",
                finite.min()!, finite.max()!, sum / Double(finite.count), finite.count
            ))
        }
        gtk_widget_queue_draw(UnsafeMutablePointer<GtkWidget>(OpaquePointer(drawArea)))
    }

    private func draw(cairo: OpaquePointer, width: Double, height: Double) {
        cairo_set_source_rgb(cairo, 0.04, 0.04, 0.06)
        cairo_paint(cairo)
        let pad = 24.0, plotWidth = width - 48, plotHeight = height - 48
        guard plotWidth > 0, plotHeight > 0 else { return }
        cairo_set_source_rgba(cairo, 1, 1, 1, 0.35)
        cairo_set_line_width(cairo, 1)
        cairo_move_to(cairo, pad, pad)
        cairo_line_to(cairo, pad, height - pad)
        cairo_line_to(cairo, width - pad, height - pad)
        cairo_stroke(cairo)
        let count = min(xs.count, ys.count)
        let finite = (0..<count).filter { xs[$0].isFinite && ys[$0].isFinite }
        guard !finite.isEmpty else { return }
        let xMin = finite.map { xs[$0] }.min()!, xMax = finite.map { xs[$0] }.max()!
        let yMin = finite.map { ys[$0] }.min()!, yMax = finite.map { ys[$0] }.max()!
        let xSpan = max(xMax - xMin, 1e-12), ySpan = max(yMax - yMin, 1e-12)
        func plotX(_ value: Double) -> Double { pad + (value - xMin) / xSpan * plotWidth }
        func plotY(_ value: Double) -> Double {
            height - pad - (value - yMin) / ySpan * plotHeight
        }
        cairo_set_source_rgb(cairo, 0.25, 0.85, 0.9)
        cairo_set_line_width(cairo, 1.5)
        var penDown = false
        for index in 0..<count {
            guard xs[index].isFinite, ys[index].isFinite else {
                penDown = false
                continue
            }
            let x = plotX(xs[index]), y = plotY(ys[index])
            if penDown { cairo_line_to(cairo, x, y) }
            else { cairo_move_to(cairo, x, y); penDown = true }
        }
        cairo_stroke(cairo)
        if let highlightX, highlightX.isFinite {
            cairo_set_source_rgba(cairo, 1, 0.8, 0.2, 0.65)
            cairo_set_line_width(cairo, 1)
            let x = plotX(highlightX)
            cairo_move_to(cairo, x, pad)
            cairo_line_to(cairo, x, height - pad)
            cairo_stroke(cairo)
        }
    }
}
