import CGtk4
import FITSCore
import Foundation
import TheiaKit

/// XDG-backed defaults for newly opened documents.
@MainActor final class GTKSettingsWindow {
    private struct Choice {
        let group: String
        let value: String
        let title: String
        let button: UnsafeMutablePointer<GtkWidget>
    }

    let widget: UnsafeMutablePointer<GtkWindow>
    let contrastScale: UnsafeMutablePointer<GtkRange>
    let message: OpaquePointer
    private let preferences: GTKPreferences
    private let onDestroy: @MainActor () -> Void
    private var choices: [Choice] = []

    init(application: UnsafeMutablePointer<GtkApplication>, preferences: GTKPreferences,
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.preferences = preferences
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        contrastScale = UnsafeMutablePointer<GtkRange>(OpaquePointer(
            gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.05, 1, 0.01)!
        ))
        message = OpaquePointer(gtk_label_new("")!)
        gtk_window_set_title(widget, "Theia Settings")
        gtk_window_set_default_size(widget, 550, 600)
        let scroll = gtk_scrolled_window_new()!
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 18)
        gtk_widget_set_margin_bottom(rootWidget, 18)
        gtk_widget_set_margin_start(rootWidget, 18)
        gtk_widget_set_margin_end(rootWidget, 18)
        appendLabel("Display defaults", to: root)
        appendChoices("Default stretch", group: "stretch",
                      values: ImageStretch.allCases.map { ($0.rawValue, $0.label) }, to: root)
        appendChoices("Default colormap", group: "colormap",
                      values: ColorMap.allCases.map { ($0.rawValue, $0.label) }, to: root)
        appendLabel("ZScale contrast", to: root)
        gtk_range_set_value(contrastScale, preferences.zscaleContrast)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(contrastScale)), 1)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(contrastScale)))
        appendLabel("Tools", to: root)
        appendChoices("Pixel table size", group: "pixelSize",
                      values: PixelTableModel.sizes.map { (String($0), "\($0) × \($0)") },
                      to: root)
        appendChoices("Region color", group: "regionColor",
                      values: RegionList.colors.map { ($0, $0.capitalized) }, to: root)
        appendLabel("Defaults apply to documents opened after this change.", to: root)
        appendLabel("Scripting", to: root)
        appendChoices("DS9 scripts (from the next launch)", group: "xpa",
                      values: [("private", "Private: theiactl only"),
                               ("public", "Public: any ds9 script")], to: root)
        let xpaNote = gtk_label_new("Public answers xpaget ds9 and pyds9 the way DS9 does, for "
                                    + "every user on this computer. THEIA_XPA=public or private "
                                    + "overrides this.")!
        gtk_label_set_wrap(OpaquePointer(xpaNote), 1)
        gtk_label_set_xalign(OpaquePointer(xpaNote), 0)
        gtk_box_append(root, xpaNote)
        gtk_label_set_wrap(message, 1)
        gtk_label_set_xalign(message, 0)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(message))
        gtk_scrolled_window_set_child(OpaquePointer(scroll), rootWidget)
        gtk_window_set_child(widget, scroll)
        refreshChoices()

        let changedContext = Unmanaged.passRetained(self).toOpaque()
        let changed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKSettingsWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                do {
                    try window.preferences.setZScaleContrast(
                        gtk_range_get_value(window.contrastScale)
                    )
                    gtk_label_set_text(window.message, "")
                } catch {
                    gtk_label_set_text(window.message, error.localizedDescription)
                }
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKSettingsWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(contrastScale), "value-changed",
                              unsafeBitCast(changed, to: GCallback.self), changedContext, release,
                              GConnectFlags(rawValue: 0))
        let destroyContext = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKSettingsWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.onDestroy() }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), destroyContext, release,
                              GConnectFlags(rawValue: 0))
    }

    func present() { gtk_window_present(widget) }

    private func appendLabel(_ title: String, to box: UnsafeMutablePointer<GtkBox>) {
        let label = gtk_label_new(title)!
        gtk_label_set_xalign(OpaquePointer(label), 0)
        gtk_box_append(box, label)
    }

    private func appendChoices(_ title: String, group: String,
                               values: [(String, String)], to box: UnsafeMutablePointer<GtkBox>) {
        appendLabel(title, to: box)
        let grid = UnsafeMutablePointer<GtkGrid>(OpaquePointer(gtk_grid_new()!))
        gtk_grid_set_row_spacing(grid, 6)
        gtk_grid_set_column_spacing(grid, 6)
        for (index, value) in values.enumerated() {
            let button = gtk_button_new_with_label(value.1)!
            let selected = value.0
            GTKButtonAction { [weak self] in self?.set(group: group, value: selected) }
                .connect(to: button)
            choices.append(Choice(group: group, value: selected,
                                  title: value.1, button: button))
            gtk_grid_attach(grid, button, Int32(index % 3), Int32(index / 3), 1, 1)
        }
        gtk_box_append(box, UnsafeMutablePointer<GtkWidget>(OpaquePointer(grid)))
    }

    func set(group: String, value: String) {
        do {
            switch group {
            case "stretch":
                guard let choice = ImageStretch(rawValue: value) else { return }
                try preferences.setDefaultStretch(choice)
            case "colormap":
                guard let choice = ColorMap(rawValue: value) else { return }
                try preferences.setDefaultColorMap(choice)
            case "pixelSize":
                guard let choice = Int(value) else { return }
                try preferences.setPixelTableSize(choice)
            case "regionColor":
                try preferences.setRegionColor(value)
            case "xpa":
                guard let choice = XPAVisibility(rawValue: value) else { return }
                try preferences.setXPAVisibility(choice)
            default: return
            }
            gtk_label_set_text(message, "")
            refreshChoices()
        } catch {
            gtk_label_set_text(message, error.localizedDescription)
        }
    }

    private func refreshChoices() {
        for choice in choices {
            let selected: String
            switch choice.group {
            case "stretch": selected = preferences.defaultStretch.rawValue
            case "colormap": selected = preferences.defaultColorMap.rawValue
            case "pixelSize": selected = String(preferences.pixelTableSize)
            case "regionColor": selected = preferences.regionColor
            case "xpa": selected = preferences.xpaVisibility.rawValue
            default: continue
            }
            gtk_button_set_label(UnsafeMutablePointer<GtkButton>(OpaquePointer(choice.button)),
                                 choice.value == selected ? "✓ \(choice.title)" : choice.title)
        }
    }
}
