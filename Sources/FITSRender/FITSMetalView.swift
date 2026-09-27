import SwiftUI
import MetalKit
import simd
import FITSCore
import FITSRaster
import TheiaKit
import Observation

/// SwiftUI wrapper around an `MTKView` driven by `FITSRenderer`, with mouse drag pan,
/// pinch zoom, and scroll-wheel zoom hooked into the renderer's `ViewTransform`.
public struct FITSMetalView: NSViewRepresentable {
    public let image: FITSImage
    public let imageRevision: Int
    public let viewport: ImageViewState
    public let drawMode: DrawMode
    public let interactionMode: InteractionController.Mode
    public let interactionController: InteractionController?
    public let onCursorChange: ((CursorInfo?) -> Void)?
    public let onLineProfile: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public let onRadialProfile: ((SIMD2<Double>, Double) -> Void)?
    public let onGrowthCurve: ((SIMD2<Double>, Double) -> Void)?
    public let onMeasure: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public let onCubeSpectrumAt: ((SIMD2<Double>) -> Void)?
    public let onRegionContextMenu: ((Int, NSEvent) -> Void)?
    public let onProfileDragPreview: (((SIMD2<Double>, Double, DrawMode)?) -> Void)?

    public init(
        image: FITSImage,
        imageRevision: Int,
        viewport: ImageViewState,
        drawMode: DrawMode = .pan,
        interactionMode: InteractionController.Mode = .full,
        interactionController: InteractionController? = nil,
        onCursorChange: ((CursorInfo?) -> Void)? = nil,
        onLineProfile: ((SIMD2<Double>, SIMD2<Double>) -> Void)? = nil,
        onRadialProfile: ((SIMD2<Double>, Double) -> Void)? = nil,
        onGrowthCurve: ((SIMD2<Double>, Double) -> Void)? = nil,
        onMeasure: ((SIMD2<Double>, SIMD2<Double>) -> Void)? = nil,
        onCubeSpectrumAt: ((SIMD2<Double>) -> Void)? = nil,
        onRegionContextMenu: ((Int, NSEvent) -> Void)? = nil,
        onProfileDragPreview: (((SIMD2<Double>, Double, DrawMode)?) -> Void)? = nil
    ) {
        self.image = image
        self.imageRevision = imageRevision
        self.viewport = viewport
        self.drawMode = drawMode
        self.interactionMode = interactionMode
        self.interactionController = interactionController
        self.onLineProfile = onLineProfile
        self.onRadialProfile = onRadialProfile
        self.onGrowthCurve = onGrowthCurve
        self.onMeasure = onMeasure
        self.onCubeSpectrumAt = onCubeSpectrumAt
        self.onRegionContextMenu = onRegionContextMenu
        self.onProfileDragPreview = onProfileDragPreview
        self.onCursorChange = onCursorChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true

        if let device = view.device {
            do {
                let renderer = try FITSRenderer(device: device, viewport: viewport)
                view.delegate = renderer
                view.fitsRenderer = renderer
                view.onCursorChange = onCursorChange
                view.onLineProfile = onLineProfile
                view.onRadialProfile = onRadialProfile
                view.onGrowthCurve = onGrowthCurve
                view.onMeasure = onMeasure
                view.onCubeSpectrumAt = onCubeSpectrumAt
                view.onRegionContextMenu = onRegionContextMenu
                view.onProfileDragPreview = { preview in
                    onProfileDragPreview?(preview)
                }
                view.drawMode = drawMode
                view.interaction = interactionController ?? InteractionController(view: viewport, mode: interactionMode)
                view.interaction?.drawMode = drawMode
                context.coordinator.renderer = renderer
                context.coordinator.requestDisplay(image, revision: imageRevision, view: view)
                context.coordinator.observeCanvas(viewport, view: view)
            } catch {
                print("FITSRenderer init failed: \(error)")
            }
        }
        return view
    }

    public func updateNSView(_ view: InteractiveMTKView, context: Context) {
        guard context.coordinator.renderer != nil else { return }
        context.coordinator.observeCanvas(viewport, view: view)
        context.coordinator.requestDisplay(image, revision: imageRevision, view: view)
        view.onCursorChange = onCursorChange
        view.onLineProfile = onLineProfile
        view.onRadialProfile = onRadialProfile
        view.onGrowthCurve = onGrowthCurve
        view.onMeasure = onMeasure
        view.onCubeSpectrumAt = onCubeSpectrumAt
        view.onRegionContextMenu = onRegionContextMenu
        view.onProfileDragPreview = { preview in
            onProfileDragPreview?(preview)
        }
        view.drawMode = drawMode
        if let interactionController {
            view.interaction = interactionController
        } else if view.interaction?.view !== viewport {
            view.interaction = InteractionController(view: viewport, mode: interactionMode)
        } else {
            view.interaction?.mode = interactionMode
        }
        view.interaction?.drawMode = drawMode
        view.setNeedsDisplay(view.bounds)
    }

    @MainActor public final class Coordinator {
        var renderer: FITSRenderer?
        private(set) var redrawRequestCount = 0
        private weak var observedCanvas: ImageViewState?
        private var requestedRevision: Int?
        private var displayTask: Task<Void, Never>?
        private let displayBuilder = DisplayImageBuilder()

        func observeCanvas(_ canvas: ImageViewState, view: InteractiveMTKView) {
            guard observedCanvas !== canvas else { return }
            observedCanvas = canvas
            trackCanvas(canvas, view: view)
        }

        private func trackCanvas(_ canvas: ImageViewState, view: InteractiveMTKView) {
            withObservationTracking {
                _ = canvas.imageRevision
                _ = canvas.transform
                _ = canvas.vmin
                _ = canvas.vmax
                _ = canvas.stretch
                _ = canvas.stretchParameter
                _ = canvas.colorMap
            } onChange: { [weak self, weak canvas, weak view] in
                Task { @MainActor [weak self, weak canvas, weak view] in
                    guard let self, let canvas, let view,
                          self.observedCanvas === canvas,
                          view.fitsRenderer === self.renderer else { return }
                    if let image = canvas.image {
                        self.requestDisplay(image, revision: canvas.imageRevision, view: view)
                    }
                    self.redrawRequestCount += 1
                    view.setNeedsDisplay(view.bounds)
                    self.trackCanvas(canvas, view: view)
                }
            }
        }

        func requestDisplay(_ image: FITSImage, revision: Int, view: InteractiveMTKView) {
            guard requestedRevision != revision, let renderer else { return }
            requestedRevision = revision
            displayTask?.cancel()
            let builder = displayBuilder
            displayTask = Task.detached(priority: .userInitiated) { [weak self, weak view, weak renderer] in
                guard let display = await builder.build(image: image, revision: revision) else { return }
                await self?.applyDisplay(
                    display, sourceImage: image, revision: revision, view: view, renderer: renderer
                )
            }
        }

        @MainActor
        private func applyDisplay(
            _ display: DisplayImage, sourceImage: FITSImage, revision: Int,
            view: InteractiveMTKView?, renderer: FITSRenderer?
        ) {
            guard requestedRevision == revision,
                  let view, let renderer, view.fitsRenderer === renderer else { return }
            do {
                try renderer.setDisplayImage(display, sourceImage: sourceImage)
                view.setNeedsDisplay(view.bounds)
            } catch {
                NSLog("FITS display upload failed: \(error)")
            }
        }
    }
}

/// MTKView subclass that translates mouse / trackpad events into `ViewTransform` updates
/// and publishes cursor pixel coordinates + values via `onCursorChange`.
public final class InteractiveMTKView: MTKView {
    public weak var fitsRenderer: FITSRenderer?
    public var interaction: InteractionController?
    public var onCursorChange: ((CursorInfo?) -> Void)?
    public var onLineProfile: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public var onRadialProfile: ((SIMD2<Double>, Double) -> Void)?
    public var onGrowthCurve: ((SIMD2<Double>, Double) -> Void)?
    /// In-flight (center, radius, mode) during a radial/growth drag. `mode` is the
    /// originating `DrawMode`. nil = drag ended.
    public var onProfileDragPreview: ((SIMD2<Double>, Double, DrawMode)?) -> Void = { _ in }
    public var onMeasure: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public var onCubeSpectrumAt: ((SIMD2<Double>) -> Void)?
    public var drawMode: DrawMode = .pan {
        didSet { interaction?.drawMode = drawMode }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func menu(for event: NSEvent) -> NSMenu? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            interaction?.cancelActiveRegionEdit()
            interaction?.cancelActiveDrawing()
        }
        // Without this, mouseMoved events don't reach the view in some hosting setups.
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    private var trackingArea: NSTrackingArea?
    private var dragStartImage: SIMD2<Double>?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    public override func mouseMoved(with event: NSEvent) {
        publishCursor(at: event.locationInWindow)
        interaction?.pointer(pointerEvent(.moved, .primary, event))
        updateHoverCursor()
    }

    private func updateHoverCursor() {
        switch interaction?.cursorHint ?? .arrow {
        case .arrow: NSCursor.arrow.set()
        case .openHand: NSCursor.openHand.set()
        case .closedHand: NSCursor.closedHand.set()
        case .resizeHorizontal: NSCursor.resizeLeftRight.set()
        case .resizeVertical: NSCursor.resizeUpDown.set()
        case .crosshair: NSCursor.crosshair.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        onCursorChange?(nil)
        interaction?.pointer(pointerEvent(.exited, .primary, event))
        updateHoverCursor()
    }

    private func publishCursor(at windowLocation: NSPoint) {
        guard let r = fitsRenderer, let image = r.image else { return }
        let p = convert(windowLocation, from: nil)
        let mapping = viewMapping(for: r)
        let viewPoint = SIMD2(Double(p.x), Double(bounds.height - p.y))
        let pixel = mapping.nearestImagePixel(toView: viewPoint)
        let ix = pixel.x
        let iy = pixel.y
        if ix < 0 || ix >= image.width || iy < 0 || iy >= image.height {
            onCursorChange?(nil)
            return
        }
        onCursorChange?(CursorInfo(imageX: ix, imageY: iy, value: image.physicalValue(x: ix, y: iy)))
    }

    public override func mouseDown(with event: NSEvent) {
        guard let r = fitsRenderer, r.image != nil else { return }
        if drawMode.isDrag && !isRegionDrawingMode {
            dragStartImage = imagePoint(at: event.locationInWindow, renderer: r)
            return
        }
        if drawMode == .cubeSpectrum,
           let p = imagePoint(at: event.locationInWindow, renderer: r) {
            onCubeSpectrumAt?(p)
            return
        }
        interaction?.pointer(pointerEvent(.down, .primary, event))
        updateHoverCursor()
    }

    public override func keyDown(with event: NSEvent) {
        if let key = keyEvent(event), interaction?.key(key) == true { return }
        super.keyDown(with: event)
    }

    public var onRegionContextMenu: ((Int, NSEvent) -> Void)?

    public override func rightMouseDown(with event: NSEvent) {
        interaction?.pointer(pointerEvent(.down, .secondary, event))
        for effect in interaction?.takeEffects() ?? [] {
            if case .showContextMenu(let index, _) = effect {
                onRegionContextMenu?(index, event)
            }
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if interaction?.pointer(pointerEvent(.dragged, .secondary, event)) == true {
            setNeedsDisplay(bounds)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        interaction?.pointer(pointerEvent(.up, .secondary, event))
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        interaction?.pointer(pointerEvent(.down, .middle, event))
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDragged(with: event); return }
        if interaction?.pointer(pointerEvent(.dragged, .middle, event)) == true {
            setNeedsDisplay(bounds)
        }
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        interaction?.pointer(pointerEvent(.up, .middle, event))
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            interaction?.pointer(pointerEvent(.up, .primary, event))
            updateHoverCursor()
            dragStartImage = nil
            onProfileDragPreview(nil)
        }
        guard drawMode.isDrag,
              let r = fitsRenderer,
              let start = dragStartImage,
              let end = imagePoint(at: event.locationInWindow, renderer: r) else { return }
        if drawMode == .lineProfile {
            onLineProfile?(start, end)
            return
        }
        if drawMode == .measure {
            onMeasure?(start, end)
            return
        }
        if drawMode == .radialProfile {
            let dx = end.x - start.x, dy = end.y - start.y
            let radius = (dx * dx + dy * dy).squareRoot()
            // If user just clicked (≤ 2 px), pass 0 — the handler picks a sensible default.
            onRadialProfile?(start, radius < 2 ? 0 : radius)
            return
        }
        if drawMode == .growthCurve {
            let dx = end.x - start.x, dy = end.y - start.y
            let radius = (dx * dx + dy * dy).squareRoot()
            onGrowthCurve?(start, radius < 2 ? 0 : radius)
            return
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        switch drawMode {
        case .pan, .drawPolygon, .drawCircle, .drawBox, .drawEllipse, .drawAnnulus:
            if interaction?.pointer(pointerEvent(.dragged, .primary, event)) == true {
                setNeedsDisplay(bounds)
            }
            updateHoverCursor()
        case .radialProfile, .growthCurve:
            guard let r = fitsRenderer else { return }
            guard let start = dragStartImage,
                  let current = imagePoint(at: event.locationInWindow, renderer: r) else { return }
            let dx = current.x - start.x, dy = current.y - start.y
            let radius = (dx * dx + dy * dy).squareRoot()
            onProfileDragPreview((start, radius, drawMode))
        case .lineProfile, .measure, .cubeSpectrum:
            break
        }
    }

    private var isRegionDrawingMode: Bool {
        switch drawMode {
        case .drawCircle, .drawBox, .drawEllipse, .drawAnnulus: true
        default: false
        }
    }

    private func imagePoint(at windowLocation: NSPoint, renderer: FITSRenderer) -> SIMD2<Double>? {
        let p = convert(windowLocation, from: nil)
        return viewMapping(for: renderer).viewYUpToImage(SIMD2(Double(p.x), Double(p.y)))
    }

    private func viewMapping(for renderer: FITSRenderer) -> ViewMapping {
        ViewMapping(
            transform: renderer.transform,
            viewSize: SIMD2(Double(bounds.width), Double(bounds.height)),
            backingScale: Double(window?.backingScaleFactor ?? 1)
        )
    }

    public override func magnify(with event: NSEvent) {
        let location = topLeftViewPoint(at: event.locationInWindow)
        if interaction?.magnify(.init(location: location, factor: 1 + Double(event.magnification))) == true {
            setNeedsDisplay(bounds)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        let location = topLeftViewPoint(at: event.locationInWindow)
        if interaction?.scroll(.init(location: location, deltaY: Double(event.scrollingDeltaY),
                                     isPrecise: event.hasPreciseScrollingDeltas)) == true {
            setNeedsDisplay(bounds)
        }
    }

    private func topLeftViewPoint(at windowLocation: NSPoint) -> SIMD2<Double> {
        let local = convert(windowLocation, from: nil)
        return SIMD2(Double(local.x), Double(bounds.height - local.y))
    }

    private func pointerEvent(_ phase: PointerEvent.Phase, _ button: PointerEvent.Button,
                              _ event: NSEvent) -> PointerEvent {
        PointerEvent(phase: phase, button: button,
                     location: topLeftViewPoint(at: event.locationInWindow),
                     modifiers: inputModifiers(event), clickCount: event.clickCount)
    }

    private func inputModifiers(_ event: NSEvent) -> PointerEvent.Modifiers {
        var modifiers: PointerEvent.Modifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.primary) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    private func keyEvent(_ event: NSEvent) -> KeyEvent? {
        let key: KeyEvent.Key
        switch event.keyCode {
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 49: key = .space
        case 51: key = .delete
        case 117: key = .forwardDelete
        case 53: key = .escape
        case 36, 76: key = .return
        default:
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return nil }
            key = .character(text)
        }
        return KeyEvent(key: key, modifiers: inputModifiers(event))
    }
}
