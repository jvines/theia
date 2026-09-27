import Foundation

/// Native adapters provide view points with a top-left origin and Y increasing down.
public struct ScrollEvent: Sendable, Equatable {
    public let location: SIMD2<Double>
    public let deltaY: Double
    public let isPrecise: Bool

    public init(location: SIMD2<Double>, deltaY: Double, isPrecise: Bool) {
        self.location = location
        self.deltaY = deltaY
        self.isPrecise = isPrecise
    }
}

public struct MagnifyEvent: Sendable, Equatable {
    public let location: SIMD2<Double>
    public let factor: Double

    public init(location: SIMD2<Double>, factor: Double) {
        self.location = location
        self.factor = factor
    }
}

public struct PointerEvent: Sendable, Equatable {
    public enum Phase: Sendable { case down, dragged, up, moved, exited }
    public enum Button: Sendable { case primary, secondary, middle }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Self(rawValue: 1 << 0)
        public static let primary = Self(rawValue: 1 << 1)
        public static let option = Self(rawValue: 1 << 2)
        public static let control = Self(rawValue: 1 << 3)
    }

    public let phase: Phase
    public let button: Button
    public let location: SIMD2<Double>
    public let modifiers: Modifiers
    public let clickCount: Int

    public init(phase: Phase, button: Button, location: SIMD2<Double>,
                modifiers: Modifiers = [], clickCount: Int = 1) {
        self.phase = phase
        self.button = button
        self.location = location
        self.modifiers = modifiers
        self.clickCount = clickCount
    }
}

/// Shared canvas interaction state. Native views only translate input coordinates.
@MainActor public final class InteractionController {
    public enum Mode: Sendable {
        case full
        case viewOnly
    }

    public let view: ImageViewState
    public var mode: Mode {
        didSet { if mode != oldValue { activePan = nil; levelsDrag = nil } }
    }
    public var drawMode: DrawMode = .pan {
        didSet { if drawMode != oldValue, activePan?.button == .primary { activePan = nil } }
    }

    private struct Pan {
        let button: PointerEvent.Button
        var previous: SIMD2<Double>
    }

    private struct LevelsDrag {
        let start: SIMD2<Double>
        let vmin: Float
        let vmax: Float
    }

    private var activePan: Pan?
    private var levelsDrag: LevelsDrag?

    public init(view: ImageViewState, mode: Mode) {
        self.view = view
        self.mode = mode
    }

    @discardableResult public func scroll(_ event: ScrollEvent) -> Bool {
        zoom(by: pow(1.0015, event.deltaY), at: event.location)
    }

    @discardableResult public func magnify(_ event: MagnifyEvent) -> Bool {
        zoom(by: event.factor, at: event.location)
    }

    /// Returns true when the canvas view or display levels changed.
    @discardableResult public func pointer(_ event: PointerEvent) -> Bool {
        switch event.phase {
        case .down:
            if event.button == .secondary {
                levelsDrag = LevelsDrag(start: event.location, vmin: view.vmin, vmax: view.vmax)
            } else if event.button == .middle ||
                        (event.button == .primary && (mode == .viewOnly || drawMode == .pan || drawMode == .drawPolygon)) {
                activePan = Pan(button: event.button, previous: event.location)
            }
            return false
        case .dragged:
            if var pan = activePan, pan.button == event.button {
                let delta = event.location - pan.previous
                pan.previous = event.location
                activePan = pan
                return view.pan(by: delta)
            }
            if event.button == .secondary, let levelsDrag {
                return adjustLevels(from: levelsDrag, to: event.location)
            }
            return false
        case .up:
            if activePan?.button == event.button { activePan = nil }
            if event.button == .secondary { levelsDrag = nil }
            return false
        case .moved, .exited:
            return false
        }
    }

    private func adjustLevels(from drag: LevelsDrag, to location: SIMD2<Double>) -> Bool {
        let size = view.viewSizePoints
        let width = Double(drag.vmax - drag.vmin)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              width.isFinite, width > 0, location.x.isFinite, location.y.isFinite else { return false }
        let dx = location.x - drag.start.x
        let dyUp = drag.start.y - location.y
        let newWidth = width * pow(2, -4 * dx / Double(size.width))
        let center = Double(drag.vmax + drag.vmin) / 2 + dyUp / Double(size.height) * width
        let vmin = Float(center - newWidth / 2)
        let vmax = Float(center + newWidth / 2)
        guard vmin.isFinite, vmax.isFinite, vmax > vmin else { return false }
        view.vmin = vmin
        view.vmax = vmax
        return true
    }

    private func zoom(by factor: Double, at location: SIMD2<Double>) -> Bool {
        let size = SIMD2(Double(view.viewSizePoints.width), Double(view.viewSizePoints.height))
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
              location.x.isFinite, location.y.isFinite else { return false }
        let mapping = ViewMapping(transform: view.transform, viewSize: size, backingScale: view.backingScale)
        return view.zoom(by: factor, aroundImagePoint: mapping.viewToImage(location))
    }
}
