import SwiftUI
import MetalKit
import simd
import FITSCore
import TheiaKit

/// SwiftUI wrapper around an `MTKView` driven by `FITSRenderer`, with mouse drag pan,
/// pinch zoom, and scroll-wheel zoom hooked into the renderer's `ViewTransform`.
public struct FITSMetalView: NSViewRepresentable {
    public let image: FITSImage
    public let stretch: ImageStretch
    public let colorMap: ColorMap
    public let viewport: ViewportObservable
    public let drawMode: DrawMode
    /// Bumping this value triggers a recompute of vmin/vmax via image.defaultRange().
    public let resetLevelsTrigger: Int
    public let onCursorChange: ((CursorInfo?) -> Void)?
    public let onRegionCreated: ((Region) -> Void)?
    public let onRegionPreview: ((Region?) -> Void)?
    public let regions: [Region]
    public let wcs: WCS?
    public let onRegionEdited: ((Int, Region) -> Void)?
    public let onRegionSelected: ((Int?) -> Void)?
    public let onLineProfile: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public let onRadialProfile: ((SIMD2<Double>, Double) -> Void)?
    public let onGrowthCurve: ((SIMD2<Double>, Double) -> Void)?
    public let onMeasure: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public let onCubeSpectrumAt: ((SIMD2<Double>) -> Void)?
    public let onRegionContextMenu: ((Int, NSEvent) -> Void)?
    public let onProfileDragPreview: (((SIMD2<Double>, Double, DrawMode)?) -> Void)?

    public init(
        image: FITSImage,
        stretch: ImageStretch = .linear,
        colorMap: ColorMap = .gray,
        viewport: ViewportObservable,
        drawMode: DrawMode = .pan,
        resetLevelsTrigger: Int = 0,
        regions: [Region] = [],
        wcs: WCS? = nil,
        onCursorChange: ((CursorInfo?) -> Void)? = nil,
        onRegionCreated: ((Region) -> Void)? = nil,
        onRegionPreview: ((Region?) -> Void)? = nil,
        onRegionEdited: ((Int, Region) -> Void)? = nil,
        onRegionSelected: ((Int?) -> Void)? = nil,
        onLineProfile: ((SIMD2<Double>, SIMD2<Double>) -> Void)? = nil,
        onRadialProfile: ((SIMD2<Double>, Double) -> Void)? = nil,
        onGrowthCurve: ((SIMD2<Double>, Double) -> Void)? = nil,
        onMeasure: ((SIMD2<Double>, SIMD2<Double>) -> Void)? = nil,
        onCubeSpectrumAt: ((SIMD2<Double>) -> Void)? = nil,
        onRegionContextMenu: ((Int, NSEvent) -> Void)? = nil,
        onProfileDragPreview: (((SIMD2<Double>, Double, DrawMode)?) -> Void)? = nil
    ) {
        self.image = image
        self.stretch = stretch
        self.colorMap = colorMap
        self.viewport = viewport
        self.drawMode = drawMode
        self.resetLevelsTrigger = resetLevelsTrigger
        self.regions = regions
        self.wcs = wcs
        self.onLineProfile = onLineProfile
        self.onRadialProfile = onRadialProfile
        self.onGrowthCurve = onGrowthCurve
        self.onMeasure = onMeasure
        self.onCubeSpectrumAt = onCubeSpectrumAt
        self.onRegionContextMenu = onRegionContextMenu
        self.onProfileDragPreview = onProfileDragPreview
        self.onCursorChange = onCursorChange
        self.onRegionCreated = onRegionCreated
        self.onRegionPreview = onRegionPreview
        self.onRegionEdited = onRegionEdited
        self.onRegionSelected = onRegionSelected
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true

        if let device = view.device {
            do {
                let renderer = try FITSRenderer(device: device, viewport: viewport)
                renderer.stretch = stretch
                renderer.colorMap = colorMap
                try renderer.setImage(image)
                view.delegate = renderer
                view.fitsRenderer = renderer
                view.onCursorChange = onCursorChange
                view.onRegionCreated = onRegionCreated
                view.onRegionPreview = onRegionPreview
                view.onRegionEdited = onRegionEdited
                view.onRegionSelected = onRegionSelected
                view.onLineProfile = onLineProfile
                view.onRadialProfile = onRadialProfile
                view.onGrowthCurve = onGrowthCurve
                view.onMeasure = onMeasure
                view.onCubeSpectrumAt = onCubeSpectrumAt
                view.onRegionContextMenu = onRegionContextMenu
                view.onProfileDragPreview = { preview in
                    onProfileDragPreview?(preview)
                }
                view.regions = regions
                view.wcs = wcs
                view.drawMode = drawMode
                context.coordinator.renderer = renderer
            } catch {
                print("FITSRenderer init failed: \(error)")
            }
        }
        return view
    }

    public func updateNSView(_ view: InteractiveMTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.stretch = stretch
        renderer.colorMap = colorMap
        renderer.stretchParameter = viewport.stretchParameter
        view.onCursorChange = onCursorChange
        view.onRegionCreated = onRegionCreated
        view.onRegionPreview = onRegionPreview
        view.onRegionEdited = onRegionEdited
        view.onRegionSelected = onRegionSelected
        view.regions = regions
        view.drawMode = drawMode
        if context.coordinator.lastResetTrigger != resetLevelsTrigger {
            context.coordinator.lastResetTrigger = resetLevelsTrigger
            if let img = renderer.image, let range = img.defaultRange() {
                renderer.vmin = Float(range.z1)
                renderer.vmax = Float(range.z2)
            }
        }
        view.setNeedsDisplay(view.bounds)
    }

    public final class Coordinator {
        var renderer: FITSRenderer?
        var lastResetTrigger: Int = 0
    }
}

/// MTKView subclass that translates mouse / trackpad events into `ViewTransform` updates
/// and publishes cursor pixel coordinates + values via `onCursorChange`.
public final class InteractiveMTKView: MTKView {
    public weak var fitsRenderer: FITSRenderer?
    public var onCursorChange: ((CursorInfo?) -> Void)?
    public var onRegionCreated: ((Region) -> Void)?
    public var onRegionPreview: ((Region?) -> Void)?
    public var onRegionEdited: ((Int, Region) -> Void)?
    public var onRegionSelected: ((Int?) -> Void)?
    public var onLineProfile: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public var onRadialProfile: ((SIMD2<Double>, Double) -> Void)?
    public var onGrowthCurve: ((SIMD2<Double>, Double) -> Void)?
    /// In-flight (center, radius, mode) during a radial/growth drag. `mode` is the
    /// originating `DrawMode`. nil = drag ended.
    public var onProfileDragPreview: ((SIMD2<Double>, Double, DrawMode)?) -> Void = { _ in }
    public var onMeasure: ((SIMD2<Double>, SIMD2<Double>) -> Void)?
    public var onCubeSpectrumAt: ((SIMD2<Double>) -> Void)?
    public var regions: [Region] = []
    public var wcs: WCS?
    public var drawMode: DrawMode = .pan

    /// In-flight pan-mode edit (set on mouseDown if click lands on a region handle).
    private var activeEdit: ActiveEdit?

    private struct ActiveEdit {
        let regionIndex: Int
        let handle: RegionEditHandle
        let baseRegion: Region
        let dragStartImage: SIMD2<Double>
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func menu(for event: NSEvent) -> NSMenu? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Without this, mouseMoved events don't reach the view in some hosting setups.
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    private var trackingArea: NSTrackingArea?
    private var dragStartImage: SIMD2<Double>?
    private var polygonVertices: [SIMD2<Double>] = []

    // Right-mouse drag for brightness/contrast (classic astronomy convention).
    private var levelsDragStart: NSPoint?
    private var levelsInitialVmin: Float = 0
    private var levelsInitialVmax: Float = 1

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
        updateHoverCursor(at: event.locationInWindow)
    }

    private func updateHoverCursor(at windowLocation: NSPoint) {
        guard drawMode == .pan, let r = fitsRenderer, !regions.isEmpty,
              let img = imagePoint(at: windowLocation, renderer: r) else {
            NSCursor.arrow.set()
            return
        }
        let tol = 4.0 / max(r.transform.scale, 1e-6)
        if let hit = RegionHitTest.hit(in: regions, atImagePoint: img, toleranceImagePixels: tol, wcs: wcs) {
            switch hit.handle {
            case .move:
                NSCursor.openHand.set()
            case .annulusInner, .annulusOuter, .circleRadius:
                NSCursor.resizeLeftRight.set()
            case .ellipseRx:
                NSCursor.resizeLeftRight.set()
            case .ellipseRy:
                NSCursor.resizeUpDown.set()
            case .boxCorner:
                NSCursor.crosshair.set()
            case .polygonVertex:
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        onCursorChange?(nil)
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
        if drawMode.isDrag {
            dragStartImage = imagePoint(at: event.locationInWindow, renderer: r)
            return
        }
        if drawMode == .drawPolygon {
            handlePolygonClick(event: event, renderer: r)
            return
        }
        if drawMode == .cubeSpectrum,
           let p = imagePoint(at: event.locationInWindow, renderer: r) {
            onCubeSpectrumAt?(p)
            return
        }
        // Pan mode: try to grab a region handle first so the user can resize/move
        // existing regions without leaving Pan.
        if drawMode == .pan, let click = imagePoint(at: event.locationInWindow, renderer: r) {
            let tol = 4.0 / max(r.transform.scale, 1e-6)
            if let hit = RegionHitTest.hit(in: regions, atImagePoint: click, toleranceImagePixels: tol, wcs: wcs) {
                activeEdit = ActiveEdit(
                    regionIndex: hit.regionIndex,
                    handle: hit.handle,
                    baseRegion: regions[hit.regionIndex],
                    dragStartImage: click
                )
                onRegionSelected?(hit.regionIndex)
            } else {
                onRegionSelected?(nil)
            }
        }
    }

    /// Polygon UX:
    ///   - single click adds a vertex
    ///   - double-click (or pressing return) closes the polygon
    private func handlePolygonClick(event: NSEvent, renderer r: FITSRenderer) {
        guard let p = imagePoint(at: event.locationInWindow, renderer: r) else { return }
        if event.clickCount >= 2 {
            if polygonVertices.count >= 3 {
                let region = RegionDrawing.makePolygon(polygonVertices)
                onRegionCreated?(region)
            }
            polygonVertices.removeAll()
            onRegionPreview?(nil)
            return
        }
        polygonVertices.append(p)
        if polygonVertices.count >= 2 {
            // Preview shows the in-progress open polyline (close visually with cursor).
            let preview = RegionDrawing.makePolygon(polygonVertices)
            onRegionPreview?(preview)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if drawMode == .drawPolygon,
           (event.keyCode == 36 || event.keyCode == 76)  // return / enter
        {
            if polygonVertices.count >= 3 {
                let region = RegionDrawing.makePolygon(polygonVertices)
                onRegionCreated?(region)
            }
            polygonVertices.removeAll()
            onRegionPreview?(nil)
            return
        }
        if event.keyCode == 53 {  // escape clears in-progress polygon
            polygonVertices.removeAll()
            onRegionPreview?(nil)
            return
        }
        super.keyDown(with: event)
    }

    public var onRegionContextMenu: ((Int, NSEvent) -> Void)?

    public override func rightMouseDown(with event: NSEvent) {
        guard let r = fitsRenderer else { return }
        // If the click lands on a region, fire the context-menu callback and skip the
        // brightness/contrast drag.
        if let click = imagePoint(at: event.locationInWindow, renderer: r) {
            let tol = 4.0 / max(r.transform.scale, 1e-6)
            if let hit = RegionHitTest.hit(in: regions, atImagePoint: click,
                                           toleranceImagePixels: tol, wcs: wcs) {
                onRegionContextMenu?(hit.regionIndex, event)
                return
            }
        }
        levelsDragStart = convert(event.locationInWindow, from: nil)
        levelsInitialVmin = r.vmin
        levelsInitialVmax = r.vmax
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard let r = fitsRenderer, let start = levelsDragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Double(p.x - start.x)
        let dy = Double(p.y - start.y)
        let w = max(Double(bounds.width), 1)
        let h = max(Double(bounds.height), 1)
        let width0 = Double(levelsInitialVmax - levelsInitialVmin)
        let center0 = Double(levelsInitialVmax + levelsInitialVmin) / 2

        // Horizontal: contrast. Drag right → tighter range (more contrast).
        // pow(2, -4*dx/w) gives ~16× shrink at full right, 16× widen at full left.
        let widthScale = pow(2.0, -4.0 * dx / w)
        let newWidth = width0 * widthScale

        // Vertical: bias. Drag up → centre moves up by up to ±width0 across one view height.
        let newCenter = center0 + (dy / h) * width0

        let newVmin = Float(newCenter - newWidth / 2)
        let newVmax = Float(newCenter + newWidth / 2)
        if newVmax > newVmin {
            r.vmin = newVmin
            r.vmax = newVmax
            setNeedsDisplay(bounds)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        levelsDragStart = nil
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            dragStartImage = nil
            activeEdit = nil
            if drawMode != .drawPolygon { onRegionPreview?(nil) }
            onProfileDragPreview(nil)
        }
        if activeEdit != nil { return }
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
        if let region = buildDragRegion(start: start, end: end) {
            onRegionCreated?(region)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let r = fitsRenderer else { return }
        if let edit = activeEdit,
           let current = imagePoint(at: event.locationInWindow, renderer: r) {
            let updated = RegionEdit.apply(
                to: edit.baseRegion,
                handle: edit.handle,
                dragStartImage: edit.dragStartImage,
                currentImage: current,
                wcs: wcs
            )
            onRegionEdited?(edit.regionIndex, updated)
            setNeedsDisplay(bounds)
            return
        }
        switch drawMode {
        case .pan, .drawPolygon:
            r.transform.pan(by: SIMD2(Double(event.deltaX), -Double(event.deltaY)))
            setNeedsDisplay(bounds)
        case .drawCircle, .drawBox, .drawEllipse, .drawAnnulus:
            guard let start = dragStartImage,
                  let current = imagePoint(at: event.locationInWindow, renderer: r),
                  let preview = buildDragRegion(start: start, end: current) else { return }
            onRegionPreview?(preview)
        case .radialProfile, .growthCurve:
            guard let start = dragStartImage,
                  let current = imagePoint(at: event.locationInWindow, renderer: r) else { return }
            let dx = current.x - start.x, dy = current.y - start.y
            let radius = (dx * dx + dy * dy).squareRoot()
            onProfileDragPreview((start, radius, drawMode))
        case .lineProfile, .measure, .cubeSpectrum:
            break
        }
    }

    private func buildDragRegion(start: SIMD2<Double>, end: SIMD2<Double>) -> Region? {
        switch drawMode {
        case .drawCircle:  return RegionDrawing.makeCircle(startImage: start, endImage: end)
        case .drawBox:     return RegionDrawing.makeBox(startImage: start, endImage: end)
        case .drawEllipse: return RegionDrawing.makeEllipse(startImage: start, endImage: end)
        case .drawAnnulus: return RegionDrawing.makeAnnulus(startImage: start, endImage: end)
        default: return nil
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
        zoom(by: 1 + Double(event.magnification), at: event.locationInWindow)
    }

    public override func scrollWheel(with event: NSEvent) {
        // Pinch-trackpad gestures come through as magnify; this handles mouse-wheel zoom.
        let factor = pow(1.0015, Double(event.scrollingDeltaY))
        zoom(by: factor, at: event.locationInWindow)
    }

    private func zoom(by factor: Double, at windowLocation: NSPoint) {
        guard let r = fitsRenderer else { return }
        let p = convert(windowLocation, from: nil)
        let anchor = viewMapping(for: r).viewYUpToImage(SIMD2(Double(p.x), Double(p.y)))
        r.transform.zoom(by: factor, aroundImagePoint: anchor)
        setNeedsDisplay(bounds)
    }
}
