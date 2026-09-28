import CGtk4
import Foundation
import TheiaKit

/// Application utility windows remain independent of document windows so a
/// tiling window manager can place them normally.
@MainActor final class GTKInfoWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    private let onDestroy: @MainActor () -> Void

    init(application: UnsafeMutablePointer<GtkApplication>, kind: AppWindowKind,
         scriptingPort: UInt16, scriptingTokenFile: URL? = nil,
         onDestroy: @escaping @MainActor () -> Void) {
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        ))
        let rootWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(root))
        gtk_widget_set_margin_top(rootWidget, 20)
        gtk_widget_set_margin_bottom(rootWidget, 20)
        gtk_widget_set_margin_start(rootWidget, 20)
        gtk_widget_set_margin_end(rootWidget, 20)
        switch kind {
        case .about:
            gtk_window_set_title(widget, "About Theia")
            gtk_window_set_default_size(widget, 420, 300)
            appendLabel("Theia · version \(AppVersion.string)\(AppVersion.isBeta ? " Beta" : "")",
                        to: root)
            appendLabel("A FITS viewer for photometry, spectra, images and regions.", to: root)
            appendLabel("Built by José Vines · Universidad Católica del Norte", to: root)
            appendLabel("© 2026 José Vines · BSD-3-Clause", to: root)
            let links = horizontalBox()
            appendLink("Website", url: "https://jvines.cl", to: links)
            appendLink("Source", url: "https://github.com/jvines", to: links)
            gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(links)))
        case .scriptingReference:
            gtk_window_set_title(widget, "HTTP Scripting Reference")
            gtk_window_set_default_size(widget, 730, 520)
            appendLabel("HTTP scripting is available on localhost only.", to: root)
            let reference = Self.scriptingReference(port: scriptingPort,
                                                    tokenFile: scriptingTokenFile)
            let scroll = gtk_scrolled_window_new()!
            gtk_widget_set_vexpand(scroll, 1)
            let view = gtk_text_view_new()!
            let textView = UnsafeMutablePointer<GtkTextView>(OpaquePointer(view))
            gtk_text_view_set_editable(textView, 0)
            gtk_text_view_set_monospace(textView, 1)
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(textView), reference, -1)
            gtk_scrolled_window_set_child(OpaquePointer(scroll), view)
            gtk_box_append(root, scroll)
            let copy = gtk_button_new_with_label("Copy reference")!
            GTKButtonAction { [weak self] in self?.copy(reference) }.connect(to: copy)
            gtk_box_append(root, copy)
        case .onboarding:
            gtk_window_set_title(widget, "Welcome to Theia")
            gtk_window_set_default_size(widget, 640, 460)
            appendLabel("Theia · A FITS viewer for Linux", to: root)
            let features: [(String, String)] = [
                ("FITS & tile-compressed files", "Open images, cubes, multi-extension files and .fz data."),
                ("Full WCS support", "Read celestial coordinates and switch WCS variants."),
                ("Stretches & colormaps", "Adjust display levels and image colour maps."),
                ("DS9-compatible regions", "Draw, edit, load and save regions."),
                ("Photometry & profiles", "Measure sources and inspect image statistics."),
                ("Scripting via XPA & HTTP", "Control Theia from the shell or local HTTP API."),
            ]
            let scroll = gtk_scrolled_window_new()!
            gtk_widget_set_vexpand(scroll, 1)
            let list = UnsafeMutablePointer<GtkBox>(OpaquePointer(
                gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
            ))
            for (title, detail) in features {
                appendLabel("\(title)\n\(detail)", to: list)
            }
            gtk_scrolled_window_set_child(OpaquePointer(scroll),
                                          UnsafeMutablePointer<GtkWidget>(OpaquePointer(list)))
            gtk_box_append(root, scroll)
            let start = gtk_button_new_with_label("Get Started")!
            GTKButtonAction { [weak self] in
                guard let self else { return }
                gtk_window_destroy(self.widget)
            }.connect(to: start)
            gtk_box_append(root, start)
        case .welcome:
            break
        }
        gtk_window_set_child(widget, rootWidget)
        let context = Unmanaged.passRetained(self).toOpaque()
        let destroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKInfoWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.onDestroy() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKInfoWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(destroyed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
    }

    func present() { gtk_window_present(widget) }

    private func appendLabel(_ title: String, to box: UnsafeMutablePointer<GtkBox>) {
        let label = gtk_label_new(title)!
        gtk_label_set_wrap(OpaquePointer(label), 1)
        gtk_label_set_xalign(OpaquePointer(label), 0)
        gtk_box_append(box, label)
    }

    private func horizontalBox() -> UnsafeMutablePointer<GtkBox> {
        UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!))
    }

    private func appendLink(_ title: String, url: String, to box: UnsafeMutablePointer<GtkBox>) {
        guard let destination = URL(string: url) else { return }
        let button = gtk_button_new_with_label(title)!
        GTKButtonAction { [weak self] in
            guard let self else { return }
            GTKURLOpener.open(destination, parent: self.widget) { message in
                fputs("Theia: could not open URL: \(message)\n", stderr)
            }
        }.connect(to: button)
        gtk_box_append(box, button)
    }

    private func copy(_ value: String) {
        guard let display = gtk_widget_get_display(
            UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget))
        ) else { return }
        gdk_clipboard_set_text(gdk_display_get_clipboard(display), value)
    }

    private static func scriptingReference(port: UInt16, tokenFile: URL?) -> String {
        let tokenPath = tokenFile?.path ?? "(unavailable)"
        let routes = ScriptingHTTPRouter.routeTable.map {
            "\($0.method) \($0.path)  \($0.summary)"
        }.joined(separator: "\n")
        return """
        Base URL: http://127.0.0.1:\(port)
        Authorization: Bearer <token>
        Token file (owner only): \(tokenPath)

        Endpoints
        \(routes)

        Example
        TOKEN=$(cat "\(tokenPath)")
        curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:\(port)/status
        """
    }
}
