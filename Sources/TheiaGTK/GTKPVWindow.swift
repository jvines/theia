import CGtk4
import FITSCore
import FITSRaster
import TheiaKit

/// A standalone position-velocity image window bound to its source document.
@MainActor final class GTKPVWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let picture: OpaquePointer
    let image: FITSImage
    private let sourceSession: DocumentSession
    private let onDestroy: @MainActor () -> Void
    private var renderTask: Task<Void, Never>?
    private var destroyed = false

    init(application: UnsafeMutablePointer<GtkApplication>, sourceSession: DocumentSession,
         image: FITSImage, onDestroy: @escaping @MainActor () -> Void) {
        self.sourceSession = sourceSession
        self.image = image
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        picture = OpaquePointer(gtk_picture_new()!)
        gtk_window_set_title(widget, "PV Diagram — \(sourceSession.url.lastPathComponent)")
        gtk_window_set_default_size(widget, 560, 360)
        gtk_picture_set_content_fit(picture, GTK_CONTENT_FIT_CONTAIN)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)
        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        ))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(picture))
        let footer = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        gtk_box_append(footer, gtk_label_new("position →"))
        let plane = gtk_label_new("← plane")!
        gtk_widget_set_hexpand(plane, 1)
        gtk_label_set_xalign(OpaquePointer(plane), 1)
        gtk_box_append(footer, plane)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(footer)))
        gtk_window_set_child(widget, UnsafeMutablePointer<GtkWidget>(OpaquePointer(root)))

        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKPVWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.destroyed = true
                window.renderTask?.cancel()
                window.renderTask = nil
                window.onDestroy()
            }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "destroy",
                              unsafeBitCast(callback, to: GCallback.self), context,
                              { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKPVWindow>.fromOpaque(userData).release()
        }, GConnectFlags(rawValue: 0))

        let levels = ImageViewState(image: image, stretch: .linear, colorMap: .viridis)
        let range = RasterLevels(vmin: levels.vmin, vmax: levels.vmax)
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let display = DisplayImage(image: image, revision: 0)
            guard !Task.isCancelled else { return }
            let raster = ViewportRasterizer.renderNative(
                display, stretch: .linear, levels: range, colorMap: .viridis
            )
            guard !Task.isCancelled else { return }
            let prepared = GTKCanvasTexture.prepare(from: raster)
            await self?.apply(prepared)
        }
    }

    func present() { gtk_window_present(widget) }

    private func apply(_ prepared: GTKCanvasTexture.Prepared) {
        guard !destroyed else { return }
        renderTask = nil
        let texture = GTKCanvasTexture.make(from: prepared)
        gtk_picture_set_paintable(picture, texture)
        g_object_unref(UnsafeMutableRawPointer(texture))
    }
}
