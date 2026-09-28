import CGtk4
import FITSRaster
import Foundation
import TheiaKit

private final class RenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

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
    let overlayArea: OpaquePointer
    let hduList: OpaquePointer
    let session: DocumentSession
    let interaction: InteractionController
    private(set) var viewButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private let onDestroy: @MainActor () -> Void
    private let onOpen: @MainActor (UnsafeMutablePointer<GtkWindow>) -> Void
    private var observerID: UUID?
    private var layoutConnectionID: gulong = 0
    private var sizeSyncSourceID: guint = 0
    private var destroyed = false
    private var dragStart: SIMD2<Double>?
    private var dragButton: PointerEvent.Button = .primary
    private let overlayScene = OverlayScene()
    private let gridCache = WCSGridCache()
    private let displayBuilder = DisplayImageBuilder()
    private var cachedDisplay: DisplayImage?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private(set) var overlayPrimitives: [OverlayPrimitive] = []

    init(application: UnsafeMutablePointer<GtkApplication>, session: DocumentSession,
         onOpen: @escaping @MainActor (UnsafeMutablePointer<GtkWindow>) -> Void = { _ in },
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.session = session
        interaction = InteractionController(view: session.view, mode: .full, session: session)
        interaction.drawMode = session.mode
        self.onOpen = onOpen
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_application_window_new(application)!))
        picture = OpaquePointer(gtk_picture_new()!)
        overlayArea = OpaquePointer(gtk_drawing_area_new()!)
        hduList = OpaquePointer(gtk_list_box_new()!)
        gtk_window_set_title(widget, "\(session.url.lastPathComponent) — Theia")
        gtk_window_set_default_size(widget, 640, 480)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)

        let root = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!))
        let content = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!))
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(content)), 1)
        let toolbar = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!))
        let openButton = gtk_button_new_with_label("Open…")!
        GTKButtonAction { [weak self] in
            guard let self else { return }
            self.onOpen(self.widget)
        }.connect(to: openButton)
        gtk_box_append(toolbar, openButton)
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
        let imageOverlay = OpaquePointer(gtk_overlay_new()!)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(imageOverlay), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(imageOverlay), 1)
        gtk_overlay_set_child(imageOverlay, UnsafeMutablePointer<GtkWidget>(picture))
        gtk_overlay_add_overlay(imageOverlay, UnsafeMutablePointer<GtkWidget>(overlayArea))
        gtk_widget_set_can_target(UnsafeMutablePointer<GtkWidget>(overlayArea), 0)
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(imageOverlay))
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
        refreshOverlay()
        observerID = session.addEventObserver { [weak self] event in
            switch event.kind {
            case .displayParametersChanged, .transformChanged, .imageRevisionChanged:
                self?.renderCanvas()
                self?.refreshOverlay()
                if event.kind == .imageRevisionChanged { self?.refreshViewButtons() }
            case .selectionChanged:
                self?.syncHDUSelection()
                self?.refreshViewButtons()
                self?.interaction.drawMode = self?.session.mode ?? .pan
                self?.refreshOverlay()
            case .regionsChanged, .overlaysChanged, .cursorMoved:
                self?.refreshOverlay()
            default: break
            }
        }
        let drawContext = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(UnsafeMutablePointer<GtkDrawingArea>(overlayArea), { _, cairo, _, _, userData in
            guard let cairo, let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                GTKOverlayPainter.draw(window.overlayPrimitives, in: cairo)
            }
        }, drawContext, { userData in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        })
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
        installScrollController()
        installDragGesture()
    }

    private func installDragGesture() {
        let gesture = gtk_gesture_drag_new()!
        gtk_gesture_single_set_button(gesture, 0)
        let callback: @convention(c) (OpaquePointer?, gdouble, gdouble, gpointer?) -> Void = {
            gesture, x, y, userData in
            guard let gesture, let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.beginDrag(gesture: gesture, x: x, y: y) }
        }
        let update: @convention(c) (OpaquePointer?, gdouble, gdouble, gpointer?) -> Void = {
            _, x, y, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.updateDrag(offsetX: x, offsetY: y) }
        }
        let end: @convention(c) (OpaquePointer?, gdouble, gdouble, gpointer?) -> Void = {
            _, x, y, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.endDrag(offsetX: x, offsetY: y) }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        for (name, handler) in [
            ("drag-begin", callback), ("drag-update", update), ("drag-end", end)
        ] {
            let context = Unmanaged.passRetained(self).toOpaque()
            g_signal_connect_data(
                UnsafeMutableRawPointer(gesture), name,
                unsafeBitCast(handler, to: GCallback.self), context, release,
                GConnectFlags(rawValue: 0)
            )
        }
        gtk_widget_add_controller(UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)), gesture)
    }

    private func beginDrag(gesture: OpaquePointer, x: Double, y: Double) {
        var localX = 0.0
        var localY = 0.0
        let pictureWidget = UnsafeMutablePointer<GtkWidget>(picture)
        guard gtk_widget_translate_coordinates(
            UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)), pictureWidget,
            x, y, &localX, &localY
        ) != 0, gtk_widget_contains(pictureWidget, localX, localY) != 0 else { return }
        let button = gtk_gesture_single_get_current_button(gesture)
        dragButton = button == 2 ? .middle : button == 3 ? .secondary : .primary
        dragStart = SIMD2(localX, localY)
        _ = interaction.pointer(PointerEvent(
            phase: .down, button: dragButton, location: SIMD2(localX, localY)
        ))
    }

    private func updateDrag(offsetX: Double, offsetY: Double) {
        guard let dragStart else { return }
        _ = interaction.pointer(PointerEvent(
            phase: .dragged, button: dragButton,
            location: dragStart + SIMD2(offsetX, offsetY)
        ))
    }

    private func endDrag(offsetX: Double, offsetY: Double) {
        guard let dragStart else { return }
        _ = interaction.pointer(PointerEvent(
            phase: .up, button: dragButton,
            location: dragStart + SIMD2(offsetX, offsetY)
        ))
        self.dragStart = nil
    }

    private func installScrollController() {
        let controller = gtk_event_controller_scroll_new(GtkEventControllerScrollFlags(rawValue: 1))!
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, gdouble, gdouble, gpointer?) -> gboolean = {
            controller, _, dy, userData in
            guard let userData else { return 0 }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                window.handleScroll(controller: controller, deltaY: dy) ? 1 : 0
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(controller), "scroll",
            unsafeBitCast(callback, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
        gtk_widget_add_controller(UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)), controller)
    }

    private func handleScroll(controller: OpaquePointer?, deltaY: Double) -> Bool {
        guard let controller else { return false }
        let centre = SIMD2(
            session.view.viewSizePoints.width / 2,
            session.view.viewSizePoints.height / 2
        )
        var location = centre
        if let event = gtk_event_controller_get_current_event(controller) {
            var surfaceX = 0.0
            var surfaceY = 0.0
            var localX = 0.0
            var localY = 0.0
            if gdk_event_get_position(event, &surfaceX, &surfaceY) != 0,
               surfaceX.isFinite, surfaceY.isFinite {
                guard gtk_widget_translate_coordinates(
                    UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)),
                    UnsafeMutablePointer<GtkWidget>(picture),
                    surfaceX, surfaceY, &localX, &localY
                ) != 0, localX.isFinite, localY.isFinite,
                gtk_widget_contains(UnsafeMutablePointer<GtkWidget>(picture), localX, localY) != 0
                else { return false }
                location = SIMD2(localX, localY)
            }
        }
        let isWheel = gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_WHEEL
        return interaction.scroll(ScrollEvent(
            location: location,
            deltaY: -deltaY * (isWheel ? 120 : 1),
            isPrecise: !isWheel
        ))
    }

    private func handleDestroy() {
        guard !destroyed else { return }
        destroyed = true
        renderTask?.cancel()
        renderTask = nil
        cachedDisplay = nil
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
        renderGeneration &+= 1
        let generation = renderGeneration
        renderTask?.cancel()
        renderTask = nil
        if let image = session.displayed {
            let pointWidth = session.view.viewSizePoints.width
            let pointHeight = session.view.viewSizePoints.height
            let scale = session.view.backingScale
            guard pointWidth > 0, pointHeight > 0, scale > 0,
                  pointWidth * scale <= 16_384, pointHeight * scale <= 16_384 else { return }
            let pixelWidth = Int((pointWidth * scale).rounded())
            let pixelHeight = Int((pointHeight * scale).rounded())
            let revision = session.imageRevision
            if cachedDisplay?.revision != revision { cachedDisplay = nil }
            let cached = cachedDisplay
            let mapping = FITSRaster.ViewMapping(
                transform: session.view.transform,
                viewSize: SIMD2(pointWidth, pointHeight), backingScale: scale
            )
            let stretch = session.view.stretch
            let levels = RasterLevels(vmin: session.view.vmin, vmax: session.view.vmax)
            let colorMap = session.view.colorMap
            let parameter = session.view.stretchParameter
            let builder = displayBuilder
            let cancellation = RenderCancellation()
            renderTask = Task.detached(priority: .userInitiated) { [weak self] in
                await withTaskCancellationHandler {
                    let display: DisplayImage
                    if let cached {
                        display = cached
                    } else {
                        guard let built = await builder.build(image: image, revision: revision) else { return }
                        display = built
                    }
                    guard !cancellation.isCancelled else { return }
                    guard let raster = ViewportRasterizer.renderViewportCheckingCancellation(
                        display, mapping: mapping, width: pixelWidth, height: pixelHeight,
                        stretch: stretch, levels: levels, colorMap: colorMap,
                        parameter: parameter, shouldCancel: { cancellation.isCancelled }
                    ) else { return }
                    guard !cancellation.isCancelled else { return }
                    let prepared = GTKCanvasTexture.prepare(from: raster)
                    guard !cancellation.isCancelled else { return }
                    await self?.applyCanvas(prepared, display: display, generation: generation)
                } onCancel: {
                    cancellation.cancel()
                }
            }
        } else {
            cachedDisplay = nil
            gtk_picture_set_paintable(picture, nil)
        }
    }

    private func applyCanvas(_ prepared: GTKCanvasTexture.Prepared, display: DisplayImage,
                             generation: Int) {
        guard !destroyed, generation == renderGeneration else { return }
        cachedDisplay = display
        renderTask = nil
        let texture = GTKCanvasTexture.make(from: prepared)
        gtk_picture_set_paintable(picture, texture)
        g_object_unref(UnsafeMutableRawPointer(texture))
    }

    private func refreshOverlay() {
        guard !destroyed else { return }
        let viewSize = SIMD2(Double(session.view.viewSizePoints.width),
                             Double(session.view.viewSizePoints.height))
        let mapping = ViewMapping(transform: session.view.transform,
                                  viewSize: viewSize, backingScale: 1)
        var primitives: [OverlayPrimitive] = []
        if let image = session.displayed, let wcs = session.displayedWCS {
            if session.showGrid {
                let lines = gridCache.gridlines(wcs: wcs, imageWidth: image.width,
                                                imageHeight: image.height)
                primitives += OverlayScene.gridPrimitives(lines, mapping: mapping)
            }
            if session.showCompass {
                primitives += OverlayScene.compassAndScaleBar(
                    wcs: wcs, viewSize: viewSize,
                    viewportScale: session.view.transform.scale
                )
            }
        }
        primitives += OverlayScene.contours(session.contourSegments, mapping: mapping)
        primitives += overlayScene.regionPrimitives(
            session.regions, selectedIndex: session.selectedRegionIndex,
            preview: session.previewRegion, wcs: session.displayedWCS, mapping: mapping
        )
        primitives += OverlayScene.profile(session.profileMarker, mapping: mapping)
        primitives += OverlayScene.crosshair(at: session.remoteCrosshair, mapping: mapping)
        overlayPrimitives = primitives
        gtk_widget_queue_draw(UnsafeMutablePointer<GtkWidget>(overlayArea))
    }

    private func refreshViewButtons() {
        for entry in CommandCatalog.viewMenu(for: session) {
            guard case .item(let item) = entry,
                  let button = viewButtons[item.identifier] else { continue }
            gtk_widget_set_sensitive(button, item.enabled ? 1 : 0)
        }
    }

    private func syncHDUSelection() {
        guard let row = gtk_list_box_get_row_at_index(hduList, gint(session.hdu)),
              gtk_list_box_get_selected_row(hduList) != row else { return }
        gtk_list_box_select_row(hduList, row)
    }

    func updateCanvasSize(width: Int, height: Int, scale: Double) {
        guard width > 0, height > 0, scale.isFinite, scale > 0 else { return }
        session.view.viewSizePoints = CGSize(width: width, height: height)
        session.view.backingScale = scale
        renderCanvas()
        refreshOverlay()
    }

    func present() {
        gtk_window_present(widget)
        connectSurfaceLayout()
        scheduleCanvasSizeSync()
    }
}
