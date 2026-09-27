import Foundation
import FITSCore

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

public struct KeyEvent: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        case leftArrow, rightArrow, upArrow, downArrow
        case space, delete, forwardDelete, escape, `return`
        case character(String)
    }

    public let key: Key
    public let modifiers: PointerEvent.Modifiers

    public init(key: Key, modifiers: PointerEvent.Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Shared canvas interaction state. Native views only translate input coordinates.
@MainActor public final class InteractionController {
    public enum Mode: Sendable {
        case full
        case viewOnly
    }

    public let view: ImageViewState
    private weak var session: DocumentSession?
    public var mode: Mode {
        didSet {
            if mode != oldValue {
                cancelActiveRegionEdit()
                activePan = nil
                levelsDrag = nil
            }
        }
    }
    public var drawMode: DrawMode = .pan {
        didSet {
            if drawMode != oldValue {
                cancelActiveRegionEdit()
                if activePan?.button == .primary { activePan = nil }
            }
        }
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

    private struct RegionDrag {
        let id: UUID
        let index: Int
        let handle: RegionEditHandle
        let baseRegion: Region
        let startImage: SIMD2<Double>
    }

    private var activePan: Pan?
    private var levelsDrag: LevelsDrag?
    private var regionDrag: RegionDrag?
    private var ignorePrimaryUntilUp = false

    public init(view: ImageViewState, mode: Mode, session: DocumentSession? = nil) {
        self.view = view
        self.mode = mode
        self.session = session
    }

    @discardableResult public func scroll(_ event: ScrollEvent) -> Bool {
        zoom(by: pow(1.0015, event.deltaY), at: event.location)
    }

    @discardableResult public func magnify(_ event: MagnifyEvent) -> Bool {
        zoom(by: event.factor, at: event.location)
    }

    /// Handle a key for this canvas only; native controls keep keys they consume.
    @discardableResult public func key(_ event: KeyEvent) -> Bool {
        if case .character(let text) = event.key,
           event.modifiers.contains(.primary), text == "=" || text == "+" || text == "-" {
            guard event.modifiers.subtracting([.primary, .shift]).isEmpty else { return false }
            let factor = text == "-" ? 0.5 : 2.0
            if let session, mode == .full {
                return session.perform(text == "-" ? .zoomOut : .zoomIn, origin: .user).failure == nil
            }
            return view.zoom(by: factor, aroundImagePoint: view.transform.centre)
        }
        guard mode == .full, let session else { return false }
        switch event.key {
        case .space:
            guard event.modifiers.isEmpty,
                  session.facts[session.hdu].planeCount > 1 else { return false }
            return session.perform(.setPlaying(!session.playing), origin: .user).failure == nil
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard event.modifiers.subtracting(.shift).isEmpty else { return false }
            let step = event.modifiers.contains(.shift) ? 10.0 : 1.0
            let delta: SIMD2<Double>
            switch event.key {
            case .leftArrow: delta = SIMD2(-step, 0)
            case .rightArrow: delta = SIMD2(step, 0)
            case .upArrow: delta = SIMD2(0, step)
            case .downArrow: delta = SIMD2(0, -step)
            default: return false
            }
            if let selected = session.selectedRegionIndex {
                return session.perform(.nudgeRegion(selected, dx: delta.x, dy: delta.y),
                                       origin: .user).failure == nil
            }
            let count = session.facts[session.hdu].planeCount
            guard count > 1 else { return false }
            let direction = delta.x < 0 || delta.y < 0 ? -1 : 1
            return session.perform(.selectPlane((session.plane + direction + count) % count),
                                   origin: .user).failure == nil
        case .delete, .forwardDelete:
            guard event.modifiers.isEmpty, let selected = session.selectedRegionIndex else { return false }
            return session.perform(.deleteRegion(selected), origin: .user).failure == nil
        case .escape:
            guard event.modifiers.isEmpty else { return false }
            if cancelActiveRegionEdit() { return true }
            if session.selectedRegionIndex != nil { session.selectedRegionIndex = nil; return true }
            if session.profileMarker != nil { session.profileMarker = nil; return true }
            return false
        case .character(let text):
            guard event.modifiers.contains(.primary),
                  event.modifiers.subtracting([.primary, .shift]).isEmpty else { return false }
            switch text.lowercased() {
            case "d":
                guard let selected = session.selectedRegionIndex else { return false }
                return session.perform(.duplicateRegion(selected, dx: 5, dy: 5), origin: .user).failure == nil
            case "z":
                let command: SessionCommand = event.modifiers.contains(.shift) ? .redoRegions : .undoRegions
                return session.perform(command, origin: .user).failure == nil
            default: return false
            }
        case .return:
            return false
        }
    }

    /// Returns true when the canvas view or display levels changed.
    @discardableResult public func pointer(_ event: PointerEvent) -> Bool {
        switch event.phase {
        case .down:
            if event.button == .primary {
                ignorePrimaryUntilUp = false
                if mode == .full, drawMode == .pan, let session,
                   let image = imagePoint(at: event.location) {
                    let tolerance = 4 / max(view.transform.scale, 1e-6)
                    if let hit = RegionHitTest.hit(in: session.regions, atImagePoint: image,
                                                   toleranceImagePixels: tolerance,
                                                   wcs: session.displayedWCS) {
                        if session.perform(.beginRegionEdit(hit.regionIndex), origin: .user).failure == nil,
                           let id = session.regionList.activeEditID {
                            regionDrag = RegionDrag(id: id, index: hit.regionIndex, handle: hit.handle,
                                                    baseRegion: session.regions[hit.regionIndex],
                                                    startImage: image)
                        }
                        return false
                    }
                    session.selectedRegionIndex = nil
                }
            }
            if event.button == .secondary {
                levelsDrag = LevelsDrag(start: event.location, vmin: view.vmin, vmax: view.vmax)
            } else if event.button == .middle ||
                        (event.button == .primary && (mode == .viewOnly || drawMode == .pan || drawMode == .drawPolygon)) {
                activePan = Pan(button: event.button, previous: event.location)
            }
            return false
        case .dragged:
            if event.button == .primary {
                if ignorePrimaryUntilUp { return false }
                if let drag = regionDrag {
                    guard let session, let current = imagePoint(at: event.location) else { return false }
                    let updated = RegionEdit.apply(to: drag.baseRegion, handle: drag.handle,
                                                   dragStartImage: drag.startImage, currentImage: current,
                                                   wcs: session.displayedWCS)
                    if session.perform(.updateRegionDuringEdit(drag.id, drag.index, updated),
                                       origin: .user).failure != nil {
                        regionDrag = nil
                        ignorePrimaryUntilUp = true
                        return false
                    }
                    return true
                }
            }
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
            if event.button == .primary {
                if let drag = regionDrag {
                    session?.perform(.commitRegionEdit(drag.id), origin: .user)
                    regionDrag = nil
                }
                ignorePrimaryUntilUp = false
            }
            if activePan?.button == event.button { activePan = nil }
            if event.button == .secondary { levelsDrag = nil }
            return false
        case .moved, .exited:
            return false
        }
    }

    @discardableResult public func cancelActiveRegionEdit() -> Bool {
        guard let drag = regionDrag else { return false }
        session?.perform(.cancelRegionEdit(drag.id), origin: .user)
        regionDrag = nil
        ignorePrimaryUntilUp = true
        return true
    }

    private func imagePoint(at location: SIMD2<Double>) -> SIMD2<Double>? {
        let size = SIMD2(Double(view.viewSizePoints.width), Double(view.viewSizePoints.height))
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
              location.x.isFinite, location.y.isFinite,
              view.transform.scale.isFinite, view.transform.scale > 0 else { return nil }
        return ViewMapping(transform: view.transform, viewSize: size,
                           backingScale: view.backingScale).viewToImage(location)
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
