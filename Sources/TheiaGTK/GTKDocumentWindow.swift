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
    let imageOverlay: OpaquePointer
    let hduList: OpaquePointer
    let statusLabel: OpaquePointer
    let cubeControls: UnsafeMutablePointer<GtkBox>
    let planeScale: UnsafeMutablePointer<GtkRange>
    let planeLabel: OpaquePointer
    let playButton: UnsafeMutablePointer<GtkWidget>
    let fpsSpin: OpaquePointer
    let session: DocumentSession
    let interaction: InteractionController
    let commandMenus: GTKCommandMenuBar
    let inspector: GTKInspectorPanel
    let tablePanel: GTKTablePanel
    private let preferences: GTKPreferences?
    private(set) var pixelTableWindow: GTKPixelTableWindow?
    private(set) var contourLevelsWindow: GTKContourLevelsWindow?
    private(set) var scaleParametersWindow: GTKScaleParametersWindow?
    private(set) var lineProfileWindow: GTKPlotWindow?
    private(set) var radialProfileWindow: GTKPlotWindow?
    private(set) var growthCurveWindow: GTKPlotWindow?
    private(set) var cubeSpectrumWindow: GTKPlotWindow?
    private(set) var pvWindow: GTKPVWindow?
    private(set) var radialProfileModel: RadialProfileModel?
    private(set) var growthCurveModel: GrowthCurveModel?
    private(set) var cubeSpectrumModel: CubeSpectrumModel?
    private(set) var viewButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private(set) var activePathDialog: GTKPathDialog?
    private(set) var activeNumberDialog: GTKNumberDialog?
    private(set) var activePrintJob: GTKPrintJob?
    private(set) var regionPopover: UnsafeMutablePointer<GtkPopover>?
    private let onDestroy: @MainActor () -> Void
    private let onOpen: @MainActor (UnsafeMutablePointer<GtkWindow>) -> Void
    private let onOpenRecent: @MainActor (URL) -> Void
    private let onSettings: @MainActor () -> Void
    private let onDrop: @MainActor ([String]) -> Void
    private let onWorkspaceCommand: @MainActor (WorkspaceCommand) -> Void
    private let onWorkspaceToolAction: @MainActor (ToolMenuAction, DocumentSession) -> Void
    private let onFocus: @MainActor () -> Void
    private var observerID: UUID?
    private var layoutConnectionID: gulong = 0
    private var sizeSyncSourceID: guint = 0
    private var destroyed = false
    private var syncingCubeControls = false
    private var framePulseSourceID: guint = 0
    private var frameDriver: SessionFrameDriver?
    private var tableHDUIndex: Int?
    private var initialFitTransform: ViewTransform?
    private var dragStart: SIMD2<Double>?
    private var dragButton: PointerEvent.Button = .primary
    private let overlayScene = OverlayScene()
    private let gridCache = WCSGridCache()
    private let displayBuilder = DisplayImageBuilder()
    private var cachedDisplay: DisplayImage?
    private var renderTask: Task<Void, Never>?
    private var lineProfileTask: Task<Void, Never>?
    private var cubeSpectrumTask: Task<Void, Never>?
    private var cubeSpectrumGeneration = 0
    private var pvTask: Task<Void, Never>?
    private var pvGeneration = 0
    private var renderGeneration = 0
    private(set) var overlayPrimitives: [OverlayPrimitive] = []

    init(application: UnsafeMutablePointer<GtkApplication>, session: DocumentSession,
         preferences: GTKPreferences? = nil,
         recentFiles: GTKRecentFiles? = nil,
         workspace: Workspace? = nil,
         workspaceImageCount: @escaping @MainActor () -> Int = { 1 },
         onOpen: @escaping @MainActor (UnsafeMutablePointer<GtkWindow>) -> Void = { _ in },
         onOpenRecent: @escaping @MainActor (URL) -> Void = { _ in },
         onSettings: @escaping @MainActor () -> Void = {},
         onDrop: @escaping @MainActor ([String]) -> Void = { _ in },
         onWorkspaceCommand: @escaping @MainActor (WorkspaceCommand) -> Void = { _ in },
         onWorkspaceToolAction: @escaping @MainActor (ToolMenuAction, DocumentSession) -> Void = { _, _ in },
         onFocus: @escaping @MainActor () -> Void = {},
         onDestroy: @escaping @MainActor () -> Void = {}) {
        self.session = session
        self.preferences = preferences
        interaction = InteractionController(view: session.view, mode: .full, session: session)
        interaction.drawMode = session.mode
        interaction.regionColorProvider = { [weak preferences] in
            preferences?.regionColor ?? RegionList.defaultColor
        }
        self.onOpen = onOpen
        self.onOpenRecent = onOpenRecent
        self.onSettings = onSettings
        self.onDrop = onDrop
        self.onWorkspaceCommand = onWorkspaceCommand
        self.onWorkspaceToolAction = onWorkspaceToolAction
        self.onFocus = onFocus
        self.onDestroy = onDestroy
        widget = UnsafeMutablePointer<GtkWindow>(OpaquePointer(gtk_application_window_new(application)!))
        commandMenus = GTKCommandMenuBar(window: widget, session: session,
                                         recentFiles: recentFiles ?? GTKRecentFiles(),
                                         workspace: workspace,
                                         workspaceImageCount: workspaceImageCount)
        inspector = GTKInspectorPanel(session: session)
        tablePanel = GTKTablePanel()
        picture = OpaquePointer(gtk_picture_new()!)
        overlayArea = OpaquePointer(gtk_drawing_area_new()!)
        imageOverlay = OpaquePointer(gtk_overlay_new()!)
        hduList = OpaquePointer(gtk_list_box_new()!)
        statusLabel = OpaquePointer(gtk_label_new(session.url.path)!)
        gtk_label_set_ellipsize(statusLabel, PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(statusLabel, 64)
        gtk_label_set_xalign(statusLabel, 0)
        cubeControls = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        ))
        planeScale = UnsafeMutablePointer<GtkRange>(OpaquePointer(
            gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 1)!
        ))
        planeLabel = OpaquePointer(gtk_label_new("")!)
        playButton = gtk_button_new_with_label("Play")!
        fpsSpin = OpaquePointer(gtk_spin_button_new_with_range(1, 30, 1)!)
        gtk_window_set_title(widget, "\(session.url.lastPathComponent) — Theia")
        gtk_window_set_default_size(widget, 1100, 720)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(picture), 1)
        gtk_widget_set_focusable(UnsafeMutablePointer<GtkWidget>(picture), 1)

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
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(planeScale)), 1)
        gtk_scale_set_draw_value(UnsafeMutablePointer<GtkScale>(OpaquePointer(planeScale)), 0)
        gtk_box_append(cubeControls, gtk_label_new("Plane"))
        gtk_box_append(cubeControls, UnsafeMutablePointer<GtkWidget>(OpaquePointer(planeScale)))
        gtk_box_append(cubeControls, UnsafeMutablePointer<GtkWidget>(planeLabel))
        gtk_box_append(cubeControls, playButton)
        gtk_box_append(cubeControls, UnsafeMutablePointer<GtkWidget>(fpsSpin))
        gtk_box_append(cubeControls, gtk_label_new("fps"))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(cubeControls)))
        gtk_box_append(root, commandMenus.widget)
        for (index, hdu) in session.file.hdus.enumerated() {
            let title = hdu.name ?? (hdu.isImage ? "Image" : "Table")
            gtk_list_box_append(hduList, gtk_label_new("HDU \(index)  \(title)"))
        }
        gtk_widget_set_size_request(UnsafeMutablePointer<GtkWidget>(hduList), 160, -1)
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(hduList))
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(imageOverlay), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(imageOverlay), 1)
        gtk_overlay_set_child(imageOverlay, UnsafeMutablePointer<GtkWidget>(picture))
        gtk_overlay_add_overlay(imageOverlay, UnsafeMutablePointer<GtkWidget>(overlayArea))
        gtk_widget_set_can_target(UnsafeMutablePointer<GtkWidget>(overlayArea), 0)
        let center = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        ))
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(center)), 1)
        gtk_widget_set_vexpand(UnsafeMutablePointer<GtkWidget>(OpaquePointer(center)), 1)
        gtk_box_append(center, UnsafeMutablePointer<GtkWidget>(imageOverlay))
        gtk_box_append(center, tablePanel.widget)
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(OpaquePointer(center)))
        gtk_box_append(content, inspector.widget)
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(OpaquePointer(content)))
        gtk_box_append(root, UnsafeMutablePointer<GtkWidget>(statusLabel))
        gtk_window_set_child(widget, UnsafeMutablePointer<GtkWidget>(OpaquePointer(root)))
        refreshDisplayedContent()
        refreshCubeControls()
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
        initialFitTransform = session.view.transform
        renderCanvas()
        refreshOverlay()
        observerID = session.addEventObserver { [weak self] event in
            switch event.kind {
            case .displayParametersChanged, .transformChanged, .imageRevisionChanged:
                self?.renderCanvas()
                self?.refreshOverlay()
                if event.kind == .imageRevisionChanged { self?.refreshStatus() }
                if event.kind == .imageRevisionChanged { self?.refreshViewButtons() }
                if event.kind == .imageRevisionChanged { self?.refreshCubeControls() }
            case .selectionChanged:
                self?.syncHDUSelection()
                self?.refreshDisplayedContent()
                self?.refreshViewButtons()
                self?.interaction.drawMode = self?.session.mode ?? .pan
                self?.refreshOverlay()
                self?.refreshCubeControls()
            case .regionsChanged, .overlaysChanged, .cursorMoved:
                self?.refreshOverlay()
                if event.kind == .cursorMoved { self?.refreshStatus() }
            case .playbackChanged:
                self?.refreshCubeControls()
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
        installKeyController()
        installCubeControls()
        GTKFileDropTarget.install(on: UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget))) {
            [weak self] paths in self?.onDrop(paths)
        }
        commandMenus.onOutcome = { [weak self] outcome in self?.handleOutcome(outcome) }
        commandMenus.onToolAction = { [weak self] action in self?.handleToolAction(action) }
        commandMenus.onOpen = { [weak self] in
            guard let self else { return }
            self.onOpen(self.widget)
        }
        commandMenus.onOpenRecent = { [weak self] url in self?.onOpenRecent(url) }
        commandMenus.onSettings = { [weak self] in self?.onSettings() }
        commandMenus.onPrint = { [weak self] in self?.startPrint() }
        commandMenus.onWorkspaceCommand = { [weak self] command in
            self?.onWorkspaceCommand(command)
        }
        installFocusObserver()
        frameDriver = SessionFrameDriver(
            session: session,
            startPulses: { [weak self] in self?.startFramePulses() },
            stopPulses: { [weak self] in self?.stopFramePulses() }
        )
    }

    private func installCubeControls() {
        let context = Unmanaged.passRetained(self).toOpaque()
        let changed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard !window.syncingCubeControls else { return }
                let index = Int(gtk_range_get_value(window.planeScale).rounded())
                window.handleOutcome(window.session.perform(.selectPlane(index), origin: .user))
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(planeScale), "value-changed",
                              unsafeBitCast(changed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
        let fpsContext = Unmanaged.passRetained(self).toOpaque()
        let fpsChanged: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard !window.syncingCubeControls else { return }
                window.handleOutcome(window.session.perform(
                    .setFPS(gtk_spin_button_get_value(window.fpsSpin)), origin: .user
                ))
            }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(fpsSpin), "value-changed",
                              unsafeBitCast(fpsChanged, to: GCallback.self), fpsContext, release,
                              GConnectFlags(rawValue: 0))
        GTKButtonAction { [weak self] in
            guard let self else { return }
            self.handleOutcome(self.session.perform(.setPlaying(!self.session.playing), origin: .user))
        }.connect(to: playButton)
    }

    private func installFocusObserver() {
        let context = Unmanaged.passRetained(self).toOpaque()
        let changed: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = {
            _, _, userData in
            guard let userData else { return }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if !window.destroyed && gtk_window_is_active(window.widget) != 0 {
                    window.onFocus()
                }
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(widget), "notify::is-active",
                              unsafeBitCast(changed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
    }

    private func refreshCubeControls() {
        guard !destroyed else { return }
        let count = session.file.hdus[session.hdu].planeCount
        gtk_widget_set_visible(UnsafeMutablePointer<GtkWidget>(OpaquePointer(cubeControls)), count > 1 ? 1 : 0)
        syncingCubeControls = true
        gtk_range_set_range(planeScale, 0, Double(max(1, count - 1)))
        gtk_range_set_value(planeScale, Double(session.plane))
        gtk_spin_button_set_value(fpsSpin, session.fps)
        syncingCubeControls = false
        gtk_label_set_text(planeLabel, "\(session.plane + 1) / \(count)")
        gtk_button_set_label(UnsafeMutablePointer<GtkButton>(OpaquePointer(playButton)),
                             session.playing ? "Pause" : "Play")
    }

    private func refreshDisplayedContent() {
        guard !destroyed else { return }
        let hdu = session.file.hdus[session.hdu]
        let isTable = hdu.isTable
        gtk_widget_set_visible(UnsafeMutablePointer<GtkWidget>(imageOverlay), isTable ? 0 : 1)
        gtk_widget_set_visible(tablePanel.widget, isTable ? 1 : 0)
        if isTable, tableHDUIndex != session.hdu {
            tableHDUIndex = session.hdu
            tablePanel.show(hdu: hdu)
        }
    }

    private func startFramePulses() {
        guard framePulseSourceID == 0, !destroyed else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        framePulseSourceID = g_timeout_add_full(G_PRIORITY_DEFAULT, 16, { userData in
            guard let userData else { return 0 }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                window.frameDriver?.pulse(now: .now)
                return window.destroyed ? 0 : 1
            }
        }, context, { userData in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        })
    }

    private func stopFramePulses() {
        guard framePulseSourceID != 0 else { return }
        g_source_remove(framePulseSourceID)
        framePulseSourceID = 0
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

    private func installKeyController() {
        let controller = gtk_event_controller_key_new()!
        let context = Unmanaged.passRetained(self).toOpaque()
        let pressed: @convention(c) (OpaquePointer?, guint, guint, guint, gpointer?) -> gboolean = {
            _, keyval, _, state, userData in
            guard let userData else { return 0 }
            let window = Unmanaged<GTKDocumentWindow>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                window.handleKey(keyval: keyval, state: state) ? 1 : 0
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKDocumentWindow>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(controller), "key-pressed",
                              unsafeBitCast(pressed, to: GCallback.self), context, release,
                              GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(UnsafeMutablePointer<GtkWidget>(OpaquePointer(widget)), controller)
    }

    private func handleKey(keyval: guint, state: guint) -> Bool {
        guard let name = gdk_keyval_name(keyval).map(String.init(cString:)) else { return false }
        let key: KeyEvent.Key
        switch name {
        case "Left": key = .leftArrow
        case "Right": key = .rightArrow
        case "Up": key = .upArrow
        case "Down": key = .downArrow
        case "space": key = .space
        case "BackSpace": key = .delete
        case "Delete": key = .forwardDelete
        case "Escape": key = .escape
        case "Return", "KP_Enter": key = .return
        default:
            guard let scalar = UnicodeScalar(gdk_keyval_to_unicode(keyval)),
                  scalar.value >= 32 else { return false }
            key = .character(String(Character(scalar)))
        }
        var modifiers: PointerEvent.Modifiers = []
        if state & (1 << 0) != 0 { modifiers.insert(.shift) }
        if state & (1 << 2) != 0 { modifiers.insert(.primary) }
        if state & (1 << 3) != 0 { modifiers.insert(.option) }
        return interaction.key(KeyEvent(key: key, modifiers: modifiers))
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
        gtk_widget_grab_focus(pictureWidget)
        let button = gtk_gesture_single_get_current_button(gesture)
        dragButton = button == 2 ? .middle : button == 3 ? .secondary : .primary
        dragStart = SIMD2(localX, localY)
        _ = interaction.pointer(PointerEvent(
            phase: .down, button: dragButton, location: SIMD2(localX, localY)
        ))
        handleInteractionEffects()
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
        handleInteractionEffects()
        self.dragStart = nil
    }

    private func handleInteractionEffects() {
        for effect in interaction.takeEffects() {
            switch effect {
            case .showContextMenu(let index, let point):
                showRegionContextMenu(index: index, at: point)
            case .openAnalysis(let request):
                openAnalysis(request)
            }
        }
    }

    private func openAnalysis(_ request: AnalysisRequest) {
        switch request {
        case .lineProfile(let from, let to):
            guard let image = session.displayed else { return }
            if session.file.hdus[session.hdu].naxis == 3 {
                openPVDiagram(from: from, to: to)
                return
            }
            lineProfileTask?.cancel()
            if let lineProfileWindow { gtk_window_destroy(lineProfileWindow.widget) }
            let marker = ProfileGeometry.line(from: from, to: to)
            session.profileMarker = marker
            let plot = GTKPlotWindow(
                application: gtk_window_get_application(widget)!, sourceSession: session,
                title: "Line Profile — \(session.url.lastPathComponent)",
                xLabel: "distance (px)", yLabel: "value"
            ) { [weak self] in
                guard let self else { return }
                self.lineProfileWindow = nil
                if self.session.profileMarker == marker { self.session.profileMarker = nil }
            }
            lineProfileWindow = plot
            plot.present()
            lineProfileTask = Task.detached(priority: .userInitiated) { [weak plot] in
                let model = LineProfileModel(image: image, from: from, to: to)
                await plot?.setSeries(x: model.xValues, y: model.yValues)
            }
        case .radialProfile(let center, let radius):
            guard let image = session.displayed else { return }
            if let radialProfileWindow { gtk_window_destroy(radialProfileWindow.widget) }
            let initialRadius = radius > 0 ? radius : Double(min(image.width, image.height)) / 2
            let model = RadialProfileModel(image: image, center: center,
                                           initialRadius: initialRadius)
            radialProfileModel = model
            session.profileMarker = .radial(center: center, maxRadius: model.radius)
            let plot = GTKPlotWindow(
                application: gtk_window_get_application(widget)!, sourceSession: session,
                title: "Radial Profile — \(session.url.lastPathComponent)",
                xLabel: "radius (px)", yLabel: "mean value"
            ) { [weak self, weak model] in
                model?.cancel()
                guard let self else { return }
                self.radialProfileWindow = nil
                self.radialProfileModel = nil
                if case .radial(let markerCenter, _) = self.session.profileMarker,
                   markerCenter == center { self.session.profileMarker = nil }
            }
            radialProfileWindow = plot
            plot.addSpin(label: "max r", value: model.radius, minimum: 1,
                         maximum: model.maxAllowedRadius, step: 0.5) { [weak self, weak plot] value in
                model.setRadius(value)
                _ = self?.session.perform(.setProfileRadius(model.radius), origin: .user)
                Self.updateRadialPlot(model, in: plot)
            }
            plot.addSpin(label: "bin", value: model.binWidth, minimum: 0.5,
                         maximum: 10, step: 0.5) { [weak plot] value in
                model.setBinWidth(value)
                Self.updateRadialPlot(model, in: plot)
            }
            plot.present()
            Self.updateRadialPlot(model, in: plot)
        case .growthCurve(let center, let radius):
            guard let image = session.displayed else { return }
            if let growthCurveWindow { gtk_window_destroy(growthCurveWindow.widget) }
            let initialRadius = radius > 0 ? radius : Double(min(image.width, image.height)) / 2
            let model = GrowthCurveModel(image: image, center: center,
                                         initialRadius: initialRadius)
            growthCurveModel = model
            session.profileMarker = .growth(center: center, maxRadius: model.radius)
            let plot = GTKPlotWindow(
                application: gtk_window_get_application(widget)!, sourceSession: session,
                title: "Growth Curve — \(session.url.lastPathComponent)",
                xLabel: "aperture radius (px)", yLabel: "cumulative flux"
            ) { [weak self, weak model] in
                model?.cancel()
                guard let self else { return }
                self.growthCurveWindow = nil
                self.growthCurveModel = nil
                if case .growth(let markerCenter, _) = self.session.profileMarker,
                   markerCenter == center { self.session.profileMarker = nil }
            }
            growthCurveWindow = plot
            plot.addSpin(label: "max r", value: model.radius, minimum: 1,
                         maximum: model.maxAllowedRadius, step: 0.5) { [weak self, weak plot] value in
                model.setRadius(value)
                _ = self?.session.perform(.setProfileRadius(model.radius), origin: .user)
                Self.updateGrowthPlot(model, in: plot)
            }
            plot.addSpin(label: "step", value: model.step, minimum: 0.5,
                         maximum: 10, step: 0.5) { [weak plot] value in
                model.setStep(value)
                Self.updateGrowthPlot(model, in: plot)
            }
            plot.present()
            Self.updateGrowthPlot(model, in: plot)
        case .measure(let from, let to):
            let measurement = Measurements.between(
                from: from, to: to, wcs: session.displayedWCS
            )
            showAlert(title: "Measurement", message: measurement.lines.joined(separator: "\n"))
        case .cubeSpectrum(let point):
            guard session.file.hdus.indices.contains(session.hdu) else { return }
            let hdu = session.file.hdus[session.hdu]
            guard hdu.naxis == 3 else { return }
            cubeSpectrumTask?.cancel()
            if let cubeSpectrumWindow { gtk_window_destroy(cubeSpectrumWindow.widget) }
            cubeSpectrumGeneration &+= 1
            let generation = cubeSpectrumGeneration
            let marker = ProfileGeometry.point(point)
            session.profileMarker = marker
            let wcs = session.displayedWCS
            let hit = RegionHitTest.hit(in: session.regions, atImagePoint: point,
                                        toleranceImagePixels: 4, wcs: wcs)
            let region = hit.flatMap { session.regions.indices.contains($0.regionIndex)
                ? session.regions[$0.regionIndex] : nil }
            let label: String
            if let hit, region != nil { label = "region #\(hit.regionIndex) (sum)" }
            else { label = "pixel (\(Int(point.x.rounded())), \(Int(point.y.rounded())))" }
            let pixel = (Int(point.x.rounded()), Int(point.y.rounded()))
            let currentPlane = session.plane
            let axis = SpectralAxis(header: hdu.header)
            let xs = axis?.values(planeCount: hdu.planeCount)
            let xLabel = axis?.axisLabel ?? "plane"
            cubeSpectrumTask = Task.detached(priority: .userInitiated) { [weak self] in
                let values: [Double]?
                if let region {
                    values = try? Profiles.cubeSpectrum(hdu: hdu, region: region, wcs: wcs,
                                                         combine: .sum)
                } else {
                    values = try? Profiles.cubeSpectrum(hdu: hdu, atPixel: pixel)
                }
                guard !Task.isCancelled else { return }
                await self?.presentCubeSpectrum(values: values, currentPlane: currentPlane,
                                                label: label, xValues: xs, xLabel: xLabel,
                                                marker: marker, generation: generation)
            }
        }
    }

    private func openPVDiagram(from: SIMD2<Double>, to: SIMD2<Double>) {
        let hdu = session.file.hdus[session.hdu]
        pvTask?.cancel()
        if let pvWindow { gtk_window_destroy(pvWindow.widget) }
        pvGeneration &+= 1
        let generation = pvGeneration
        let marker = ProfileGeometry.line(from: from, to: to)
        session.profileMarker = marker
        let samples = LineProfileModel.sampleCount(from: from, to: to)
        pvTask = Task.detached(priority: .userInitiated) { [weak self] in
            let image = try? Profiles.pvDiagram(hdu: hdu, from: (from.x, from.y),
                                                to: (to.x, to.y), samples: samples)
            guard !Task.isCancelled else { return }
            await self?.presentPVDiagram(image: image, marker: marker, generation: generation)
        }
    }

    private func presentPVDiagram(image: FITSImage?, marker: ProfileGeometry,
                                  generation: Int) {
        guard !destroyed, generation == pvGeneration else { return }
        pvTask = nil
        guard let image else {
            if session.profileMarker == marker { session.profileMarker = nil }
            showAlert(title: "PV diagram unavailable", message: "Could not extract the selected cube line")
            return
        }
        let window = GTKPVWindow(
            application: gtk_window_get_application(widget)!, sourceSession: session,
            image: image
        ) { [weak self] in
            guard let self else { return }
            self.pvWindow = nil
            if self.session.profileMarker == marker { self.session.profileMarker = nil }
        }
        pvWindow = window
        window.present()
    }

    private func presentCubeSpectrum(values: [Double]?, currentPlane: Int, label: String,
                                     xValues: [Double]?, xLabel: String,
                                     marker: ProfileGeometry, generation: Int) {
        guard !destroyed, generation == cubeSpectrumGeneration else { return }
        cubeSpectrumTask = nil
        guard let values else {
            if session.profileMarker == marker { session.profileMarker = nil }
            showAlert(title: "Spectrum unavailable", message: "Could not read the selected cube spectrum")
            return
        }
        let model = CubeSpectrumModel(values: values, currentPlane: currentPlane,
                                      label: label, xValues: xValues, xLabel: xLabel)
        cubeSpectrumModel = model
        let plot = GTKPlotWindow(
            application: gtk_window_get_application(widget)!, sourceSession: session,
            title: model.title, xLabel: model.xLabel, yLabel: "value"
        ) { [weak self] in
            guard let self else { return }
            self.cubeSpectrumWindow = nil
            self.cubeSpectrumModel = nil
            if self.session.profileMarker == marker { self.session.profileMarker = nil }
        }
        cubeSpectrumWindow = plot
        plot.setSeries(x: model.xs, y: model.ys, highlightX: model.plotHighlight)
        let center = plot.addEntry(label: "Fit center", placeholder: model.xLabel)
        let width = plot.addEntry(label: "± width", placeholder: "width")
        let fitLabel = plot.addStatusLabel()
        plot.addButton("Fit Gaussian") { [weak self, weak plot] in
            guard let self, let plot, self.cubeSpectrumWindow === plot,
                  var model = self.cubeSpectrumModel else { return }
            model.fitCenterText = String(cString: gtk_editable_get_text(center))
            model.fitHalfWidthText = String(cString: gtk_editable_get_text(width))
            model.runFit()
            self.cubeSpectrumModel = model
            plot.setSeries(x: model.xs, y: model.ys, highlightX: model.plotHighlight)
            gtk_label_set_text(fitLabel, model.fitText ?? "No fit for these values")
        }
        plot.addButton("Auto") { [weak self, weak plot] in
            guard let self, let plot, self.cubeSpectrumWindow === plot,
                  var model = self.cubeSpectrumModel else { return }
            model.autoFit()
            self.cubeSpectrumModel = model
            gtk_editable_set_text(center, model.fitCenterText)
            gtk_editable_set_text(width, model.fitHalfWidthText)
            plot.setSeries(x: model.xs, y: model.ys, highlightX: model.plotHighlight)
            gtk_label_set_text(fitLabel, model.fitText ?? "No fit for these values")
        }
        plot.present()
    }

    private static func updateRadialPlot(_ model: RadialProfileModel, in plot: GTKPlotWindow?) {
        Task { @MainActor [weak plot] in
            await model.idle()
            guard !Task.isCancelled else { return }
            plot?.setSeries(x: model.xValues, y: model.yValues)
        }
    }

    private static func updateGrowthPlot(_ model: GrowthCurveModel, in plot: GTKPlotWindow?) {
        Task { @MainActor [weak plot] in
            await model.idle()
            guard !Task.isCancelled else { return }
            plot?.setSeries(x: model.xValues, y: model.yValues)
        }
    }

    private func showRegionContextMenu(index: Int, at point: SIMD2<Double>) {
        guard session.regions.indices.contains(index) else { return }
        dismissRegionPopover()
        let widget = gtk_popover_new()!
        let popover = UnsafeMutablePointer<GtkPopover>(OpaquePointer(widget))
        let box = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        ))
        gtk_widget_set_margin_top(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 6)
        gtk_widget_set_margin_bottom(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 6)
        gtk_widget_set_margin_start(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 6)
        gtk_widget_set_margin_end(UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)), 6)

        func button(_ title: String, action: @escaping @MainActor () -> Void) {
            let control = gtk_button_new_with_label(title)!
            GTKButtonAction { [weak self] in
                action()
                self?.dismissRegionPopover()
            }.connect(to: control)
            gtk_box_append(box, control)
        }
        button("Duplicate") { [weak self] in
            guard let self else { return }
            self.handleOutcome(self.session.perform(
                .duplicateRegion(index, dx: 5, dy: 5), origin: .user
            ))
        }
        button("Delete") { [weak self] in
            guard let self else { return }
            self.handleOutcome(self.session.perform(.deleteRegion(index), origin: .user))
        }
        button("Bring to front") { [weak self] in
            guard let self else { return }
            self.handleOutcome(self.session.perform(.bringRegionToFront(index), origin: .user))
        }
        button("Copy as .reg text") { [weak self] in
            guard let self else { return }
            self.handleOutcome(self.session.perform(.copyRegion(index), origin: .user))
        }
        let heading = gtk_label_new("Color")!
        gtk_label_set_xalign(OpaquePointer(heading), 0)
        gtk_box_append(box, heading)
        for color in RegionList.colors {
            button(color.capitalized) { [weak self] in
                guard let self, self.session.regions.indices.contains(index) else { return }
                let updated = RegionList.settingAttribute(
                    .color, to: color, in: self.session.regions[index]
                )
                self.handleOutcome(self.session.perform(.updateRegion(index, updated), origin: .user))
            }
        }
        gtk_popover_set_child(popover, UnsafeMutablePointer<GtkWidget>(OpaquePointer(box)))
        gtk_widget_set_parent(widget, UnsafeMutablePointer<GtkWidget>(picture))
        var rectangle = GdkRectangle(x: Int32(point.x.rounded()),
                                     y: Int32(point.y.rounded()), width: 1, height: 1)
        gtk_popover_set_pointing_to(popover, &rectangle)
        regionPopover = popover
        gtk_popover_popup(popover)
    }

    private func dismissRegionPopover() {
        guard let popover = regionPopover else { return }
        regionPopover = nil
        gtk_popover_popdown(popover)
        gtk_widget_unparent(UnsafeMutablePointer<GtkWidget>(OpaquePointer(popover)))
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
        frameDriver?.close()
        frameDriver = nil
        stopFramePulses()
        renderTask?.cancel()
        renderTask = nil
        cachedDisplay = nil
        commandMenus.stop()
        inspector.stop()
        activePathDialog?.dismiss()
        activePathDialog = nil
        activeNumberDialog?.dismiss()
        activeNumberDialog = nil
        activePrintJob?.cancel()
        activePrintJob = nil
        dismissRegionPopover()
        lineProfileTask?.cancel()
        lineProfileTask = nil
        cubeSpectrumTask?.cancel()
        cubeSpectrumTask = nil
        pvTask?.cancel()
        pvTask = nil
        if let lineProfileWindow {
            self.lineProfileWindow = nil
            gtk_window_destroy(lineProfileWindow.widget)
        }
        if let radialProfileWindow {
            self.radialProfileWindow = nil
            gtk_window_destroy(radialProfileWindow.widget)
        }
        if let growthCurveWindow {
            self.growthCurveWindow = nil
            gtk_window_destroy(growthCurveWindow.widget)
        }
        if let cubeSpectrumWindow {
            self.cubeSpectrumWindow = nil
            gtk_window_destroy(cubeSpectrumWindow.widget)
        }
        if let pvWindow {
            self.pvWindow = nil
            gtk_window_destroy(pvWindow.widget)
        }
        if let pixelTableWindow {
            self.pixelTableWindow = nil
            gtk_window_destroy(pixelTableWindow.widget)
        }
        if let contourLevelsWindow {
            self.contourLevelsWindow = nil
            gtk_window_destroy(contourLevelsWindow.widget)
        }
        if let scaleParametersWindow {
            self.scaleParametersWindow = nil
            gtk_window_destroy(scaleParametersWindow.widget)
        }
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
            onWorkspaceToolAction(action, session)
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
        case .openURL(let url):
            GTKURLOpener.open(url, parent: widget) { [weak self] message in
                self?.showAlert(title: "Link not opened", message: message)
            }
        case .showPanel(.pixelTable):
            if let pixelTableWindow { pixelTableWindow.present(); return }
            let window = GTKPixelTableWindow(
                application: gtk_window_get_application(widget)!, session: session,
                initialSize: preferences?.pixelTableSize ?? 7,
                onSizeChange: { [weak self] size in
                    guard let self else { return }
                    do { try self.preferences?.setPixelTableSize(size) }
                    catch { self.showAlert(title: "Preference not saved", message: error.localizedDescription) }
                }
            ) { [weak self] in self?.pixelTableWindow = nil }
            pixelTableWindow = window
            window.present()
        case .showPanel(.contourLevels):
            if let contourLevelsWindow { contourLevelsWindow.present(); return }
            let window = GTKContourLevelsWindow(
                application: gtk_window_get_application(widget)!, session: session
            ) { [weak self] in self?.contourLevelsWindow = nil }
            contourLevelsWindow = window
            window.present()
        case .showPanel(.scaleParameters):
            if let scaleParametersWindow { scaleParametersWindow.present(); return }
            let window = GTKScaleParametersWindow(
                application: gtk_window_get_application(widget)!, session: session
            ) { [weak self] in self?.scaleParametersWindow = nil }
            scaleParametersWindow = window
            window.present()
        case .exportCube, .openLightCurve,
             .showAppWindow, .tileWindows:
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

    private func startPrint() {
        guard activePrintJob == nil else { return }
        guard let snapshot = GTKPrintSnapshot(session: session) else { return }
        let job = GTKPrintJob(snapshot: snapshot, parent: widget) { [weak self] error in
            self?.activePrintJob = nil
            if let error { self?.showAlert(title: "Image not printed", message: error) }
        }
        activePrintJob = job
        job.start()
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
        let refit = initialFitTransform == session.view.transform
        initialFitTransform = nil
        session.view.viewSizePoints = CGSize(width: width, height: height)
        session.view.backingScale = scale
        if refit { _ = session.view.fitDisplayedImage() }
        renderCanvas()
        refreshOverlay()
    }

    func present() {
        gtk_window_present(widget)
        connectSurfaceLayout()
        scheduleCanvasSizeSync()
    }

    func refreshRecentMenu() { commandMenus.refresh() }
}
