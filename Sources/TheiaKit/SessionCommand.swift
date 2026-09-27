import Foundation
import FITSCore

/// Built-in brightness presets shared by menus, panels and scripted commands.
public enum ScalePreset: Hashable, Sendable {
    case zscale
    case minMax
    case percentile(lower: Double, upper: Double)

    public static let toolbarPresets: [ScalePreset] = [
        .zscale, .minMax,
        .percentile(lower: 0.5, upper: 99.5),
        .percentile(lower: 0.25, upper: 99.75),
        .percentile(lower: 0.05, upper: 99.95),
    ]

    public var identifier: String {
        switch self {
        case .zscale: return "zscale"
        case .minMax: return "minmax"
        case .percentile(let lower, let upper): return "percentile.\(lower).\(upper)"
        }
    }

    public var label: String {
        switch self {
        case .zscale: return "ZScale"
        case .minMax: return "Min / Max"
        case .percentile(let lower, let upper):
            let span = upper - lower
            if abs(span - 99.0) < 1e-9 { return "99 %" }
            if abs(span - 99.5) < 1e-9 { return "99.5 %" }
            if abs(span - 99.9) < 1e-9 { return "99.9 %" }
            return String(format: "%.2f – %.2f %%", lower, upper)
        }
    }
}

/// State-changing document commands currently handled synchronously.
public enum SessionCommand: Sendable, Equatable {
    case setStretch(ImageStretch)
    case setColormap(ColorMap)
    case setLevels(min: Float, max: Float)
    case setStretchParameter(Float)
    case applyScalePreset(ScalePreset)
    case selectHDU(Int)
    case selectPlane(Int)
    case selectWCSVariant(String)
    case setDrawMode(DrawMode)
    case setGridVisible(Bool)
    case setCompassVisible(Bool)
    case setColorBarVisible(Bool)
    case setInspectorVisible(Bool)
    case setContourSpec(ContourSpec)
    case addRegion(Region)
    case updateRegion(Int, Region)
    case deleteRegion(Int)
    case bringRegionToFront(Int)
    case clearRegions
    case replaceRegions([Region])
    case copyRegion(Int)
    case setPlaying(Bool)
    case setFPS(Double)
    case toggleBlink
    case clearDerivedImage
    case showPanel(PanelKind)
    case fitView
    case actualSize
    case zoomIn
    case zoomOut
    case zoom(factor: Double, aroundImagePoint: SIMD2<Double>)
    case pan(viewDelta: SIMD2<Double>)
}

public enum CommandFailure: Error, Sendable, Equatable {
    case noDisplayedImage
    case invalidHDU(Int)
    case invalidPlane(Int)
    case unavailableWCSVariant(String)
    case unavailableBlinkPartner
    case invalidPercentileBounds
    case requiresUserInterface
    case unavailablePlayback
    case unavailableViewSize
    case invalidZoomFactor
    case invalidPanDelta
    case invalidRegionIndex(Int)

    public var message: String {
        switch self {
        case .noDisplayedImage: "No image is displayed"
        case .invalidHDU(let index): "Invalid HDU \(index)"
        case .invalidPlane(let index): "Invalid plane \(index)"
        case .unavailableWCSVariant(let variant): "Unavailable WCS variant \(variant)"
        case .unavailableBlinkPartner: "No matching image HDU for blink"
        case .invalidPercentileBounds: "Percentile bounds must be finite"
        case .requiresUserInterface: "Command requires a user interface"
        case .unavailablePlayback: "Current HDU has no playback planes"
        case .unavailableViewSize: "View size is unavailable"
        case .invalidZoomFactor: "Zoom factor or anchor is invalid"
        case .invalidPanDelta: "Pan delta is invalid"
        case .invalidRegionIndex(let index): "Invalid region index \(index)"
        }
    }
}

public enum PanelKind: Sendable, Equatable {
    case scaleParameters
    case pixelTable
    case contourLevels
}

public enum AppWindowKind: Sendable, Equatable {
    case about
    case scriptingReference
    case welcome
    case onboarding
}

public enum Effect: Sendable, Equatable {
    case showPanel(PanelKind)
    case showAppWindow(AppWindowKind)
    case openURL(URL)
    case copyToClipboard(String)
    case tileWindows
    case quit
}

public struct CommandOutcome: Sendable {
    public let effects: [Effect]
    public let failure: CommandFailure?

    public init(effects: [Effect] = [], failure: CommandFailure? = nil) {
        self.effects = effects
        self.failure = failure
    }
}

extension DocumentSession {
    @discardableResult public func perform(
        _ command: SessionCommand, origin: CommandOrigin
    ) -> CommandOutcome {
        withEventContext(origin: origin) {
            switch command {
            case .setStretch(let value): view.stretch = value
            case .setColormap(let value): view.colorMap = value
            case .setLevels(let min, let max):
                view.vmin = min
                view.vmax = max
            case .setStretchParameter(let value): view.stretchParameter = value
            case .applyScalePreset(let preset):
                guard displayed != nil else { return CommandOutcome(failure: .noDisplayedImage) }
                switch preset {
                case .zscale: resetLevels()
                case .minMax: setMinMaxLevels()
                case .percentile(let lower, let upper):
                    guard lower.isFinite, upper.isFinite else {
                        return CommandOutcome(failure: .invalidPercentileBounds)
                    }
                    setPercentileLevels(lower: lower, upper: upper)
                }
            case .selectHDU(let index):
                guard facts.indices.contains(index) else {
                    return CommandOutcome(failure: .invalidHDU(index))
                }
                selectHDU(index)
            case .selectPlane(let index):
                guard facts[hdu].isDisplayableImage,
                      index >= 0, index < facts[hdu].planeCount else {
                    return CommandOutcome(failure: .invalidPlane(index))
                }
                selectPlane(index)
            case .selectWCSVariant(let variant):
                guard derived == nil, facts[hdu].wcsVariants.contains(variant) else {
                    return CommandOutcome(failure: .unavailableWCSVariant(variant))
                }
                selectWCSVariant(variant)
            case .setDrawMode(let value): mode = value
            case .setGridVisible(let value): showGrid = value
            case .setCompassVisible(let value): showCompass = value
            case .setColorBarVisible(let value): showColorBar = value
            case .setInspectorVisible(let value): inspectorVisible = value
            case .setContourSpec(let spec): setContourSpec(spec)
            case .addRegion(let region):
                regions.append(region)
                selectedRegionIndex = regions.count - 1
            case .updateRegion(let index, let region):
                guard regions.indices.contains(index) else {
                    return CommandOutcome(failure: .invalidRegionIndex(index))
                }
                regions[index] = region
            case .deleteRegion(let index):
                guard regions.indices.contains(index) else {
                    return CommandOutcome(failure: .invalidRegionIndex(index))
                }
                if let selectedRegionIndex {
                    if selectedRegionIndex == index { self.selectedRegionIndex = nil }
                    else if selectedRegionIndex > index { self.selectedRegionIndex = selectedRegionIndex - 1 }
                }
                regions.remove(at: index)
            case .bringRegionToFront(let index):
                guard regions.indices.contains(index) else {
                    return CommandOutcome(failure: .invalidRegionIndex(index))
                }
                let selected = selectedRegionIndex
                var reordered = regions
                let region = reordered.remove(at: index)
                reordered.append(region)
                regions = reordered
                if selected == index { selectedRegionIndex = regions.count - 1 }
                else if let selected, selected > index { selectedRegionIndex = selected - 1 }
            case .clearRegions:
                selectedRegionIndex = nil
                regions.removeAll()
            case .replaceRegions(let replacement):
                selectedRegionIndex = nil
                regions = replacement
            case .copyRegion(let index):
                guard regions.indices.contains(index) else {
                    return CommandOutcome(failure: .invalidRegionIndex(index))
                }
                guard origin == .user else {
                    return CommandOutcome(failure: .requiresUserInterface)
                }
                return CommandOutcome(effects: [.copyToClipboard(RegionFile.format([regions[index]]))])
            case .setPlaying(let value):
                guard !value || facts[hdu].planeCount > 1 else {
                    return CommandOutcome(failure: .unavailablePlayback)
                }
                setPlaying(value)
            case .setFPS(let value): setFPS(value)
            case .toggleBlink:
                guard blink != nil || blinkPartner != nil else {
                    return CommandOutcome(failure: .unavailableBlinkPartner)
                }
                toggleBlink()
            case .clearDerivedImage: setDerived(nil)
            case .showPanel(let panel):
                guard origin == .user else {
                    return CommandOutcome(failure: .requiresUserInterface)
                }
                return CommandOutcome(effects: [.showPanel(panel)])
            case .fitView:
                guard displayed != nil else { return CommandOutcome(failure: .noDisplayedImage) }
                guard view.fitDisplayedImage() else {
                    return CommandOutcome(failure: .unavailableViewSize)
                }
            case .actualSize:
                guard displayed != nil else { return CommandOutcome(failure: .noDisplayedImage) }
                view.transform.scale = 1
            case .zoomIn:
                guard displayed != nil else { return CommandOutcome(failure: .noDisplayedImage) }
                guard view.zoom(by: 2, aroundImagePoint: view.transform.centre) else {
                    return CommandOutcome(failure: .invalidZoomFactor)
                }
            case .zoomOut:
                guard displayed != nil else { return CommandOutcome(failure: .noDisplayedImage) }
                guard view.zoom(by: 0.5, aroundImagePoint: view.transform.centre) else {
                    return CommandOutcome(failure: .invalidZoomFactor)
                }
            case .zoom(let factor, let anchor):
                guard displayed != nil else { return CommandOutcome(failure: .noDisplayedImage) }
                guard view.zoom(by: factor, aroundImagePoint: anchor) else {
                    return CommandOutcome(failure: .invalidZoomFactor)
                }
            case .pan(let delta):
                guard displayed != nil else { return CommandOutcome(failure: .noDisplayedImage) }
                guard view.pan(by: delta) else {
                    return CommandOutcome(failure: .invalidPanDelta)
                }
            }
            return CommandOutcome()
        }
    }
}
