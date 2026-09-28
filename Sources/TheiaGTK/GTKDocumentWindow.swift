import CGtk4
import FITSCore
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
        window.handleOutcome(window.session.perform(command, origin: .user))
    }
}

@MainActor final class GTKDocumentWindow {
    let widget: UnsafeMutablePointer<GtkWindow>
    let picture: OpaquePointer
    let overlayArea: OpaquePointer
    let hduList: OpaquePointer
    let statusLabel: OpaquePointer
    let session: DocumentSession
    let interaction: InteractionController
    let commandMenus: GTKCommandMenuBar
    let inspector: GTKInspectorPanel
    private(set) var viewButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private(set) var activePathDialog: GTKPathDialog?
    private(set) var activeNumberDialog: GTKNumberDialog?
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
        commandMenus = GTKCommandMenuBar(window: widget, session: session)
        inspector = GTKInspectorPanel(session: session)
        picture = OpaquePointer(gtk_picture_new()!)
        overlayArea = OpaquePointer(gtk_drawing_area_new()!)
        hduList = OpaquePointer(gtk_list_box_new()!)
        statusLabel = OpaquePointer(gtk_label_new(session.url.path)!)
        gtk_window_set_title(widget, "\(session.url.lastPathComponent) — Theia")
        gtk_window_set_default_size(widget, 1100, 720)
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
        gtk_box_append(root, commandMenus.widget)
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
        gtk_box_append(content, inspector.widget)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(content)))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(statusLabel))
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
                if event.kind == .imageRevisionChanged { self?.refreshStatus() }
                if event.kind == .imageRevisionChanged { self?.refreshViewButtons() }
            case .selectionChanged:
                self?.syncHDUSelection()
                self?.refreshViewButtons()
                self?.interaction.drawMode = self?.session.mode ?? .pan
                self?.refreshOverlay()
            case .regionsChanged, .overlaysChanged, .cursorMoved:
                self?.refreshOverlay()
                if event.kind == .cursorMoved { self?.refreshStatus() }
            default: break
            }
        }
        let drawContext = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(UnsafeMutablePointer<GtkDrawingArea>(overlayArea), { _, cairo, width, height, userData in
            guard let cairo, let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if window.session.showColorBar {
                    GTKOverlayPainter.drawColorBar(
                        colorMap: window.session.view.colorMap,
                        vmin: Double(window.session.view.vmin),
                        vmax: Double(window.session.view.vmax),
                        viewSize: SIMD2(Double(width), Double(height)), in: cairo
                    )
                }
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
        installMotionController()
        commandMenus.onOutcome = { [weak self] outcome in self?.handleOutcome(outcome) }
        commandMenus.onToolAction = { [weak self] action in self?.handleToolAction(action) }
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

    private func installMotionController() {
        let controller = gtk_event_controller_motion_new()!
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, gdouble, gdouble, gpointer?) -> Void = {
            _, x, y, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { window.handleMotion(x: x, y: y) }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(controller), "motion",
            unsafeBitCast(callback, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
        gtk_widget_add_controller(UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)), controller)
    }

    private func handleMotion(x: Double, y: Double) {
        let pictureWidget = UnsafeMutablePointer<GtkWidget>(picture)
        var localX = 0.0
        var localY = 0.0
        guard gtk_widget_translate_coordinates(
            UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)), pictureWidget,
            x, y, &localX, &localY
        ) != 0, gtk_widget_contains(pictureWidget, localX, localY) != 0,
        let image = session.displayed else {
            session.cursor = nil
            return
        }
        let mapping = ViewMapping(
            transform: session.view.transform,
            viewSize: SIMD2(Double(session.view.viewSizePoints.width),
                            Double(session.view.viewSizePoints.height)),
            backingScale: session.view.backingScale
        )
        let pixel = mapping.nearestImagePixel(toView: SIMD2(localX, localY))
        guard pixel.x >= 0, pixel.y >= 0,
              pixel.x < image.width, pixel.y < image.height else {
            session.cursor = nil
            return
        }
        session.cursor = CursorInfo(
            imageX: pixel.x, imageY: pixel.y,
            value: image.physicalValue(x: pixel.x, y: pixel.y)
        )
        _ = interaction.pointer(PointerEvent(
            phase: .moved, button: .primary, location: SIMD2(localX, localY)
        ))
    }

    private func refreshStatus() {
        var value: String
        if let cursor = session.cursor {
            value = String(format: "Pixel %d, %d    Value %.6g",
                           cursor.fitsX, cursor.fitsY, cursor.value)
            if let sky = session.displayedWCS?.pixelToSky(
                imageX: cursor.imageX, imageY: cursor.imageY
            ) {
                value += String(format: "    RA %.6f°  Dec %.6f°", sky.ra, sky.dec)
            }
        } else {
            value = session.url.path
        }
        gtk_label_set_text(statusLabel, value)
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
        commandMenus.stop()
        inspector.stop()
        activePathDialog?.dismiss()
        activePathDialog = nil
        activeNumberDialog?.dismiss()
        activeNumberDialog = nil
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

    func handleOutcome(_ outcome: CommandOutcome) {
        if let failure = outcome.failure, outcome.effects.isEmpty {
            showAlert(title: "Theia", message: failure.message)
        }
        for effect in outcome.effects { handleEffect(effect) }
    }

    private func handleToolAction(_ action: ToolMenuAction) {
        let command: SessionCommand
        switch action {
        case .collapse(let mode): command = .collapseCube(mode)
        case .extractSlab: command = .extractSlab
        case .exportCube: command = .exportCube
        case .detectSources: command = .detectSources
        case .crop: command = .cropToSelection
        case .filter(let spec): command = .filter(spec)
        case .unary(let operation): command = .unary(operation)
        case .subtractBackground: command = .subtractBackground
        case .bin(let size): command = .bin(size)
        case .reproject(let index): command = .reproject(index)
        case .binary(let operation, let index): command = .binary(operation, index)
        case .clearDerivedImage: command = .clearDerivedImage
        case .stack, .lightCurve:
            showAlert(title: "Theia", message: "This action is not available in the Linux app yet")
            return
        }
        handleOutcome(session.perform(command, origin: .user))
    }

    private func handleEffect(_ effect: Effect) {
        switch effect {
        case .ask(let question, let request):
            if case .numbers(let prompt, let fields) = question {
                guard activeNumberDialog == nil else { activeNumberDialog?.present(); return }
                let defaults: [String]
                if case .slab(let slab) = request {
                    defaults = ["0", "\(slab.planeCount - 1)"]
                } else {
                    defaults = Array(repeating: "0", count: fields.count)
                }
                let dialog = GTKNumberDialog(
                    parent: widget, prompt: prompt, fields: fields, defaults: defaults
                ) { [weak self] answer in
                    guard let self else { return }
                    self.activeNumberDialog = nil
                    self.handleOutcome(self.session.perform(.answer(request, answer), origin: .user))
                }
                activeNumberDialog = dialog
                dialog.present()
                return
            }
            guard activePathDialog == nil else { activePathDialog?.present(); return }
            let dialog = GTKPathDialog(parent: widget, question: question) { [weak self] answer in
                guard let self else { return }
                self.activePathDialog = nil
                self.handleOutcome(self.session.perform(.answer(request, answer), origin: .user))
            }
            activePathDialog = dialog
            dialog.present()
        case .exportImage(let snapshot, let url):
            Task.detached { [weak self] in
                do { try snapshot.writeImage(to: url) }
                catch { await self?.showAlert(title: "Image not exported", message: error.localizedDescription) }
            }
        case .saveImage(let snapshot, let url):
            Task.detached { [weak self] in
                do { try snapshot.writeFITS(to: url) }
                catch { await self?.showAlert(title: "FITS image not saved", message: error.localizedDescription) }
            }
        case .saveRegions(let snapshot, let url):
            Task.detached { [weak self] in
                do { try snapshot.write(to: url) }
                catch { await self?.showAlert(title: "Regions not saved", message: error.localizedDescription) }
            }
        case .loadRegions(let request, let url):
            Task.detached { [weak self] in
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let regions = try RegionFile.parse(text)
                    await self?.finishRegionLoad(request, regions: regions)
                } catch {
                    await self?.showAlert(title: "Regions not loaded", message: error.localizedDescription)
                }
            }
        case .copyToClipboard(let value):
            if let display = gtk_widget_get_display(UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget))) {
                gdk_clipboard_set_text(gdk_display_get_clipboard(display), value)
            }
        case .alert(let title, let message, _):
            showAlert(title: title, message: message)
        case .quit:
            gtk_window_destroy(widget)
        case .extractSlab(let request, let from, let to):
            guard request.documentID == session.id,
                  request.hduIndex == session.hdu,
                  request.imageRevision == session.imageRevision else { return }
            handleOutcome(session.perform(.applySlab(from: from, to: to), origin: .user))
        case .showPanel, .exportCube, .openLightCurve,
             .showAppWindow, .openURL, .tileWindows:
            showAlert(title: "Theia", message: "This action is not available in the Linux app yet")
        case .documentOpened, .noteRecent:
            break
        }
    }

    private func finishRegionLoad(_ request: RegionLoadRequest, regions: [Region]) {
        guard !destroyed else { return }
        let outcome = session.perform(.completeRegionLoad(request, regions), origin: .user)
        if outcome.failure != .supersededRegionLoad { handleOutcome(outcome) }
    }

    private func showAlert(title: String, message: String) {
        guard !destroyed else { return }
        let alert = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_window_new()!))
        gtk_window_set_title(alert, title)
        gtk_window_set_transient_for(alert, widget)
        gtk_window_set_modal(alert, 1)
        gtk_window_set_default_size(alert, 360, 120)
        let box = UnsafeMutablePointer<GtkBox>(OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!))
        gtk_widget_set_margin_top(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 16)
        gtk_widget_set_margin_bottom(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 16)
        gtk_widget_set_margin_start(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 16)
        gtk_widget_set_margin_end(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 16)
        let label = gtk_label_new(message)!
        gtk_label_set_wrap(OpaquePointer(label), 1)
        gtk_box_append(box, label)
        let closeButton = gtk_button_new_with_label("Close")!
        GTKButtonAction { gtk_window_destroy(alert) }.connect(to: closeButton)
        gtk_box_append(box, closeButton)
        gtk_window_set_child(alert, UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)))
        gtk_window_present(alert)
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
