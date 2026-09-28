import CGtk4
import Foundation
import TheiaKit

/// Modeless brightness controls and histogram for one image session.
@MainActor final class GTKScaleParametersWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let minimum: OpaquePointer
    let maximum: OpaquePointer
    let lowerPercentile: OpaquePointer
    let upperPercentile: OpaquePointer
    let histogram: OpaquePointer
    let rangeLabel: OpaquePointer
    let errorLabel: OpaquePointer
    let powerRow: UnsafeMutablePointer<GtkBox>
    let powerScale: UnsafeMutablePointer<GtkRange>
    private let session: DocumentSession
    private let onDestroy: @MainActor () -> Void
    private var observerID: UUID?
    private var histogramTask: Task<Void, Never>?
    private var histogramRevision = -1
    private var syncing = false
    private var destroyed = false
    private(set) var model: ScaleParametersModel

    init(application: UnsafeMutablePointer<GtkApplication>, session: DocumentSession,
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.session = session
        self.onDestroy = onDestroy
        model = ScaleParametersModel(values: [], vmin: Double(session.view.vmin),
                                     vmax: Double(session.view.vmax))
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        minimum = OpaquePointer(gtk_entry_new()!)
        maximum = OpaquePointer(gtk_entry_new()!)
        lowerPercentile = OpaquePointer(gtk_entry_new()!)
        upperPercentile = OpaquePointer(gtk_entry_new()!)
        histogram = OpaquePointer(gtk_drawing_area_new()!)
        rangeLabel = OpaquePointer(gtk_label_new("")!)
        errorLabel = OpaquePointer(gtk_label_new("")!)
        powerRow = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        powerScale = UnsafeMutablePointer<GtkRange>(OpaquePointer(
            gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.1, 8, 0.1)!
        ))
        gtk_window_set_title(widget, "Scale Parameters")
        gtk_window_set_default_size(widget, 470, 380)
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 14)
        gtk_widget_set_margin_bottom(rootWidget, 14)
        gtk_widget_set_margin_start(rootWidget, 14)
        gtk_widget_set_margin_end(rootWidget, 14)
        gtk_box_append(root, gtk_label_new("Histogram"))
        gtk_widget_set_size_request(UnsafeMutablePointer<GtkWidget>(histogram), -1, 100)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(histogram), 1)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(histogram))
        appendRow("vmin", input: UnsafeMutablePointer<GtkWidget>(minimum), to: root)
        appendRow("vmax", input: UnsafeMutablePointer<GtkWidget>(maximum), to: root)
        let applyLimits = gtk_button_new_with_label("Apply limits")!
        GTKButtonAction { [weak self] in self?.applyLimits() }.connect(to: applyLimits)
        gtk_box_append(root, applyLimits)
        gtk_label_set_xalign(rangeLabel, 0)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(rangeLabel))
        let percentile = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        ))
        gtk_box_append(percentile, gtk_label_new("Percentile"))
        gtk_widget_set_size_request(UnsafeMutablePointer<GtkWidget>(lowerPercentile), 65, -1)
        gtk_widget_set_size_request(UnsafeMutablePointer<GtkWidget>(upperPercentile), 65, -1)
        gtk_box_append(percentile, UnsafeMutablePointer<GtkWidget>(lowerPercentile))
        gtk_box_append(percentile, gtk_label_new("–"))
        gtk_box_append(percentile, UnsafeMutablePointer<GtkWidget>(upperPercentile))
        let applyPercentile = gtk_button_new_with_label("Apply")!
        GTKButtonAction { [weak self] in self?.applyPercentile() }.connect(to: applyPercentile)
        gtk_box_append(percentile, applyPercentile)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(percentile)))
        let presets = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        ))
        for preset in ScaleParametersModel.presets {
            let button = gtk_button_new_with_label(preset.label)!
            GTKButtonAction { [weak self] in self?.apply(preset: preset) }.connect(to: button)
            gtk_box_append(presets, button)
        }
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(presets)))
        gtk_box_append(powerRow, gtk_label_new("Power exponent"))
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(powerScale)), 1)
        gtk_box_append(powerRow, UnsafeMutablePointer<GtkWidget>(OpaquePointer(powerScale)))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(powerRow)))
        gtk_label_set_xalign(errorLabel, 0)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(errorLabel))
        gtk_window_set_child(widget, rootWidget)

        let drawContext = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(UnsafeMutablePointer<GtkDrawingArea>(histogram), {
            _, cairo, width, height, userData in
            guard let cairo, let userData else { return }
            let window = Unmanaged<GTKScaleParametersWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.drawHistogram(cairo, width: Double(width), height: Double(height))
            }
        }, drawContext, { userData in
            guard let userData else { return }
            Unmanaged<GTKScaleParametersWindow>.fromOpaque(userData).release()
        })
        let changedContext = Unmanaged.passRetained(self).toOpaque()
        let changed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKScaleParametersWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard !window.syncing else { return }
                let value = Float(gtk_range_get_value(window.powerScale))
                _ = window.session.perform(.setStretchParameter(value), origin: .user)
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKScaleParametersWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(powerScale), "value-changed",
                              unsafeBitCast(changed, to: GCallback.self), changedContext, release,
                              GConnectFlags(rawValue: 0))
        observerID = session.addEventObserver { [weak self] event in
            switch event.kind {
            case .imageRevisionChanged, .selectionChanged:
                self?.loadHistogram()
                self?.refreshControls()
            case .displayParametersChanged:
                self?.refreshControls()
            default: break
            }
        }
        let destroyContext = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKScaleParametersWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.destroyed = true
                window.histogramTask?.cancel()
                if let observerID = window.observerID {
                    window.session.removeEventObserver(observerID)
                    window.observerID = nil
                }
                window.onDestroy()
            }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), destroyContext, release,
                              GConnectFlags(rawValue: 0))
        gtk_editable_set_text(lowerPercentile, model.lowerPctText)
        gtk_editable_set_text(upperPercentile, model.upperPctText)
        refreshControls()
        loadHistogram()
    }

    func present() { gtk_window_present(widget) }

    private func appendRow(_ title: String, input: UnsafeMutablePointer<GtkWidget>,
                           to root: UnsafeMutablePointer<GtkBox>) {
        let row = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        let label = gtk_label_new(title)!
        gtk_widget_set_size_request(label, 65, -1)
        gtk_box_append(row, label)
        gtk_widget_set_hexpand(input, 1)
        gtk_box_append(row, input)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(row)))
    }

    private func refreshControls() {
        model.refreshLevels(vmin: Double(session.view.vmin), vmax: Double(session.view.vmax))
        gtk_editable_set_text(minimum, model.vminText)
        gtk_editable_set_text(maximum, model.vmaxText)
        gtk_label_set_text(rangeLabel, model.dataRangeLabel)
        gtk_widget_set_visible(UnsafeMutablePointer<GtkWidget>(OpaquePointer(powerRow)),
                               session.view.stretch.usesParameter ? 1 : 0)
        syncing = true
        gtk_range_set_value(powerScale, Double(session.view.stretchParameter))
        syncing = false
        gtk_widget_queue_draw(UnsafeMutablePointer<GtkWidget>(histogram))
    }

    private func loadHistogram() {
        guard !destroyed else { return }
        histogramTask?.cancel()
        let revision = session.imageRevision
        histogramRevision = revision
        let image = session.displayed
        let vmin = Double(session.view.vmin), vmax = Double(session.view.vmax)
        let lower = String(cString: gtk_editable_get_text(lowerPercentile))
        let upper = String(cString: gtk_editable_get_text(upperPercentile))
        histogramTask = Task.detached(priority: .utility) { [weak self] in
            let values = image?.physicalValues() ?? []
            guard !Task.isCancelled else { return }
            let model = ScaleParametersModel(values: values, vmin: vmin, vmax: vmax,
                                             lowerPctText: lower, upperPctText: upper)
            await self?.acceptHistogram(model, revision: revision)
        }
    }

    private func acceptHistogram(_ model: ScaleParametersModel, revision: Int) {
        guard !destroyed, histogramRevision == revision else { return }
        self.model = model
        refreshControls()
    }

    func applyLimits() {
        let lower = Float(String(cString: gtk_editable_get_text(minimum)))
        let upper = Float(String(cString: gtk_editable_get_text(maximum)))
        guard let lower, let upper, lower.isFinite, upper.isFinite, lower < upper else {
            gtk_label_set_text(errorLabel, "Enter finite limits with vmin < vmax.")
            return
        }
        gtk_label_set_text(errorLabel, "")
        _ = session.perform(.setLevels(min: lower, max: upper), origin: .user)
    }

    private func applyPercentile() {
        model.lowerPctText = String(cString: gtk_editable_get_text(lowerPercentile))
        model.upperPctText = String(cString: gtk_editable_get_text(upperPercentile))
        guard let preset = model.percentilePreset else {
            gtk_label_set_text(errorLabel, "Enter valid percentile bounds.")
            return
        }
        apply(preset: preset)
    }

    private func apply(preset: ScalePreset) {
        gtk_label_set_text(errorLabel, "")
        _ = session.perform(.applyScalePreset(preset), origin: .user)
    }

    private func drawHistogram(_ cairo: OpaquePointer, width: Double, height: Double) {
        cairo_set_source_rgb(cairo, 0.05, 0.05, 0.07)
        cairo_paint(cairo)
        let bars = model.barHeights
        guard !bars.isEmpty, width > 0, height > 0 else { return }
        cairo_set_source_rgb(cairo, 0.45, 0.42, 0.80)
        for (index, value) in bars.enumerated() {
            let x = Double(index) * width / Double(bars.count)
            let barWidth = max(1, width / Double(bars.count))
            let barHeight = max(0, value * height)
            cairo_rectangle(cairo, x, height - barHeight, barWidth, barHeight)
        }
        cairo_fill(cairo)
        cairo_set_source_rgb(cairo, 1, 0.65, 0.25)
        cairo_set_line_width(cairo, 2)
        for level in [Double(session.view.vmin), Double(session.view.vmax)] {
            let x = model.xForValue(level, width: width)
            cairo_move_to(cairo, x, 0)
            cairo_line_to(cairo, x, height)
        }
        cairo_stroke(cairo)
    }
}
