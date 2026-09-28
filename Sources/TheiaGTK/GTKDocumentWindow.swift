import CGtk4
import FITSRaster
import Foundation
import TheiaKit

@MainActor private final class ViewButtonAction {
    weak var window: GTKDocumentWindow?
    let command: SessionCommand

    init(window: GTKDocumentWindow, command: SessionCommand) {
        self.window = window
        self.command = command
    }

    func invoke() {
        guard let window else { return }
        _ = window.session.perform(command, origin: .user)
    }
}

@MainActor final class GTKDocumentWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let picture: OpaquePointer
    let hduList: OpaquePointer
    let session: DocumentSession
    private(set) var viewButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private let onDestroy: @MainActor () -> Void
    private var observerID: UUID?
    private var layoutConnectionID: gulong = 0
    private var sizeSyncSourceID: guint = 0
    private var destroyed = false

    init(application: UnsafeMutablePointer<GtkApplication>, session: DocumentSession,
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.session = session
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_application_window_new(application)!))
        picture = OpaquePointer(gtk_picture_new()!)
        hduList = OpaquePointer(gtk_list_box_new()!)
        gtk_window_set_title(widget, "\(session.url.lastPathComponent) — Theia")
        gtk_window_set_default_size(widget, 640, 480)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)

        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!))
        let content = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!))
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(content)), 1)
        let toolbar = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!))
        for entry in CommandCatalog.viewMenu(for: session) {
            guard case .item(let item) = entry, let command = item.command else { continue }
            let button = gtk_button_new_with_label(item.title)!
            gtk_widget_set_sensitive(button, item.enabled ? 1 : 0)
            viewButtons[item.identifier] = button
            gtk_box_append(toolbar, button)
            let context = Unmanaged.passRetained(ViewButtonAction(window: self, command: command)).toOpaque()
            let clicked: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { _, userData in
                guard let userData else { return }
                let action = Unmanaged<ViewButtonAction>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { action.invoke() }
            }
            let release: GClosureNotify = { userData, _ in
                guard let userData else { return }
                Unmanaged<ViewButtonAction>.fromOpaque(userData).release()
            }
            g_signal_connect_data(
                UnsafeMutableRawPointer(button), "clicked",
                unsafeBitCast(clicked, to: GCallback.self), context, release,
                GConnectFlags(rawValue: 0)
            )
        }
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(toolbar)))
        for (index, hdu) in session.file.hdus.enumerated() {
            let title = hdu.name ?? (hdu.isImage ? "Image" : "Table")
            gtk_list_box_append(hduList, gtk_label_new("HDU \(index)  \(title)"))
        }
        gtk_widget_set_size_request(UnsafeMutablePointer<GtkWidget>(hduList), 160, -1)
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(hduList))
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(picture))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(content)))
        gtk_box_append(root, gtk_label_new(session.url.path))
        gtk_window_set_child(widget, UnsafeMutablePointer<GtkWidget>(OpaquePointer(root)))
        if let row = gtk_list_box_get_row_at_index(hduList, gint(session.hdu)) {
            gtk_list_box_select_row(hduList, row)
        }

        let selectionContext = Unmanaged.passRetained(self).toOpaque()
        let selected: @convention(c) (OpaquePointer?, UnsafeMutablePointer<GtkListBoxRow>?, gpointer?) -> Void = { _, row, userData in
            guard let row, let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                _ = window.session.perform(.selectHDU(Int(gtk_list_box_row_get_index(row))), origin: .user)
            }
        }
        let releaseSelection: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(hduList), "row-selected",
            unsafeBitCast(selected, to: GCallback.self), selectionContext, releaseSelection,
            GConnectFlags(rawValue: 0)
        )

        session.view.viewSizePoints = CGSize(width: 640, height: 480)
        session.view.backingScale = 1
        session.view.fitDisplayedImage()
        renderCanvas()
        observerID = session.addEventObserver { [weak self] event in
            switch event.kind {
            case .displayParametersChanged, .transformChanged, .imageRevisionChanged:
                self?.renderCanvas()
            default: break
            }
        }
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.handleDestroy() }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(widget), "destroy",
            unsafeBitCast(callback, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
    }

    private func handleDestroy() {
        guard !destroyed else { return }
        destroyed = true
        if sizeSyncSourceID != 0 {
            g_source_remove(sizeSyncSourceID)
            sizeSyncSourceID = 0
        }
        if let observerID {
            session.removeEventObserver(observerID)
            self.observerID = nil
        }
        onDestroy()
    }

    private func connectSurfaceLayout() {
        guard layoutConnectionID == 0 else { return }
        let windowWidget = UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget))
        guard let native = gtk_widget_get_native(windowWidget),
              let surface = gtk_native_get_surface(native) else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, gint, gint, gpointer?) -> Void = { _, _, _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.scheduleCanvasSizeSync() }
        }
        let destroy: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        layoutConnectionID = g_signal_connect_data(
            UnsafeMutableRawPointer(surface), "layout",
            unsafeBitCast(callback, to: GCallback.self), context, destroy,
            GConnectFlags(rawValue: 0)
        )
    }

    private func scheduleCanvasSizeSync() {
        guard sizeSyncSourceID == 0, !destroyed else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        sizeSyncSourceID = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, { userData in
            guard let userData else { return 0 }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                window.sizeSyncSourceID = 0
                window.syncCanvasSizeFromGTK()
            }
            return 0
        }, context, { userData in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        })
    }

    private func syncCanvasSizeFromGTK() {
        guard !destroyed else { return }
        let pictureWidget = UnsafeMutablePointer<GtkWidget>(picture)
        let width = Int(gtk_widget_get_width(pictureWidget))
        let height = Int(gtk_widget_get_height(pictureWidget))
        guard width > 0, height > 0 else { return }
        let scale: Double
        if let native = gtk_widget_get_native(pictureWidget),
           let surface = gtk_native_get_surface(native) {
            scale = gdk_surface_get_scale(surface)
        } else {
            scale = Double(gtk_widget_get_scale_factor(pictureWidget))
        }
        guard session.view.viewSizePoints.width != Double(width)
                || session.view.viewSizePoints.height != Double(height)
                || session.view.backingScale != scale else { return }
        updateCanvasSize(width: width, height: height, scale: scale)
    }

    private func renderCanvas() {
        guard !destroyed else { return }
        if let image = session.displayed {
            let pointWidth = session.view.viewSizePoints.width
            let pointHeight = session.view.viewSizePoints.height
            let scale = session.view.backingScale
            guard pointWidth > 0, pointHeight > 0, scale > 0,
                  pointWidth * scale <= 16_384, pointHeight * scale <= 16_384 else { return }
            let pixelWidth = Int((pointWidth * scale).rounded())
            let pixelHeight = Int((pointHeight * scale).rounded())
            let display = DisplayImage(image: image, revision: session.imageRevision)
            let mapping = FITSRaster.ViewMapping(
                transform: session.view.transform,
                viewSize: SIMD2(pointWidth, pointHeight), backingScale: scale
            )
            let raster = ViewportRasterizer.renderViewport(
                display, mapping: mapping, width: pixelWidth, height: pixelHeight,
                stretch: session.view.stretch,
                levels: RasterLevels(vmin: session.view.vmin, vmax: session.view.vmax),
                colorMap: session.view.colorMap,
                parameter: session.view.stretchParameter
            )
            let texture = GTKCanvasTexture.make(from: raster)
            gtk_picture_set_paintable(picture, texture)
            g_object_unref(UnsafeMutableRawPointer(texture))
        } else {
            gtk_picture_set_paintable(picture, nil)
        }
    }

    func updateCanvasSize(width: Int, height: Int, scale: Double) {
        guard width > 0, height > 0, scale.isFinite, scale > 0 else { return }
        session.view.viewSizePoints = CGSize(width: width, height: height)
        session.view.backingScale = scale
        renderCanvas()
    }

    func present() {
        gtk_window_present(widget)
        connectSurfaceLayout()
        scheduleCanvasSizeSync()
    }
}
