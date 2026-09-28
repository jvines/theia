import CGtk4
import Foundation
import TheiaKit

/// Controls for the shared contour specification, bound to one source image.
@MainActor final class GTKContourLevelsWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let enabled: UnsafeMutablePointer<GtkCheckButton>
    let count: OpaquePointer
    let minimum: OpaquePointer
    let maximum: OpaquePointer
    let logarithmic: UnsafeMutablePointer<GtkCheckButton>
    let preview: OpaquePointer
    private let session: DocumentSession
    private let onDestroy: @MainActor () -> Void
    private var observerID: UUID?
    private(set) var model: ContourLevelsModel

    init(application: UnsafeMutablePointer<GtkApplication>, session: DocumentSession,
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.session = session
        self.onDestroy = onDestroy
        let range = session.displayed?.physicalMinMax()
        model = ContourLevelsModel(initial: session.contourSpec,
                                   dataMin: range?.min ?? .nan,
                                   dataMax: range?.max ?? .nan)
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        enabled = UnsafeMutablePointer<GtkCheckButton>(OpaquePointer(
            gtk_check_button_new_with_label("Show contours")!
        ))
        count = OpaquePointer(gtk_spin_button_new_with_range(1, 32, 1)!)
        minimum = OpaquePointer(gtk_entry_new()!)
        maximum = OpaquePointer(gtk_entry_new()!)
        logarithmic = UnsafeMutablePointer<GtkCheckButton>(OpaquePointer(
            gtk_check_button_new_with_label("Log spacing")!
        ))
        preview = OpaquePointer(gtk_label_new("")!)
        gtk_window_set_title(widget, "Contour Levels")
        gtk_window_set_default_size(widget, 420, 260)
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 14)
        gtk_widget_set_margin_bottom(rootWidget, 14)
        gtk_widget_set_margin_start(rootWidget, 14)
        gtk_widget_set_margin_end(rootWidget, 14)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(enabled)))
        appendRow("Count", input: UnsafeMutablePointer<GtkWidget>(count), to: root)
        appendRow("Min", input: UnsafeMutablePointer<GtkWidget>(minimum), to: root)
        appendRow("Max", input: UnsafeMutablePointer<GtkWidget>(maximum), to: root)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(logarithmic)))
        let rangeButton = gtk_button_new_with_label("Use data range")!
        GTKButtonAction { [weak self] in self?.useDataRange() }.connect(to: rangeButton)
        gtk_box_append(root, rangeButton)
        gtk_label_set_wrap(preview, 1)
        gtk_label_set_xalign(preview, 0)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(preview))
        let applyButton = gtk_button_new_with_label("Apply")!
        GTKButtonAction { [weak self] in self?.apply() }.connect(to: applyButton)
        gtk_box_append(root, applyButton)
        gtk_window_set_child(widget, rootWidget)
        refreshControls()
        observerID = session.addEventObserver { [weak self] event in
            switch event.kind {
            case .imageRevisionChanged, .selectionChanged:
                self?.refreshFromSession()
            default: break
            }
        }
        let context = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKContourLevelsWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let observerID = window.observerID {
                    window.session.removeEventObserver(observerID)
                    window.observerID = nil
                }
                window.onDestroy()
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKContourLevelsWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
    }

    func present() { gtk_window_present(widget) }

    private func appendRow(_ title: String, input: UnsafeMutablePointer<GtkWidget>,
                           to root: UnsafeMutablePointer<GtkBox>) {
        let row = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        let label = gtk_label_new(title)!
        gtk_widget_set_size_request(label, 60, -1)
        gtk_box_append(row, label)
        gtk_widget_set_hexpand(input, 1)
        gtk_box_append(row, input)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(row)))
    }

    private func refreshControls() {
        gtk_check_button_set_active(enabled, model.spec.enabled ? 1 : 0)
        gtk_spin_button_set_value(count, Double(model.spec.count))
        gtk_editable_set_text(minimum, model.minText)
        gtk_editable_set_text(maximum, model.maxText)
        gtk_check_button_set_active(logarithmic, model.spec.spacing == .log ? 1 : 0)
        gtk_label_set_text(preview, model.previewText)
    }

    private func refreshFromSession() {
        let range = session.displayed?.physicalMinMax()
        model = ContourLevelsModel(initial: session.contourSpec,
                                   dataMin: range?.min ?? .nan,
                                   dataMax: range?.max ?? .nan)
        refreshControls()
    }

    private func useDataRange() {
        model.useDataRange()
        refreshControls()
    }

    func apply() {
        model.spec.enabled = gtk_check_button_get_active(enabled) != 0
        model.spec.count = Int(gtk_spin_button_get_value(count))
        model.spec.spacing = gtk_check_button_get_active(logarithmic) != 0 ? .log : .linear
        model.minText = String(cString: gtk_editable_get_text(minimum))
        model.maxText = String(cString: gtk_editable_get_text(maximum))
        model.commitMin()
        model.commitMax()
        refreshControls()
        _ = session.perform(.setContourSpec(model.spec), origin: .user)
    }
}
