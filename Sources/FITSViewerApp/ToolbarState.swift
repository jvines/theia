import Foundation
import AppKit
import Combine
import FITSCore
import FITSRender

/// Bridge object between the SwiftUI `DocumentView` and the AppKit `NSToolbar`
/// installed on the document's window. SwiftUI publishes state into it; the
/// toolbar controller reads from it and invokes callbacks back on click.
@MainActor
final class ToolbarState: ObservableObject {
    @Published var stretch: ImageStretch = .linear
    @Published var colorMap: ColorMap = .gray
    @Published var drawMode: DrawMode = .pan
    @Published var showWCSGrid: Bool = false
    @Published var showCompass: Bool = false
    @Published var showColorBar: Bool = false
    @Published var blinkActive: Bool = false
    @Published var isFetchingCatalog: Bool = false

    @Published var hasSelectedImage: Bool = false
    @Published var hasWCS: Bool = false
    @Published var hasMultipleHDUs: Bool = false
    @Published var hasCube: Bool = false
    @Published var hasDisplayOverride: Bool = false
    @Published var wcsVariants: [String] = []     // "" + ["A","B",…]
    @Published var activeWCSVariant: String = ""
    @Published var wcsVariantLabels: [String: String] = [:]  // variant → display label
    @Published var reprojectCandidates: [(Int, String, Bool)] = []
    @Published var differenceCandidates: [(Int, String, Bool)] = []

    var onSelectStretch: (ImageStretch) -> Void = { _ in }
    var onSelectMap: (ColorMap) -> Void = { _ in }
    var onSelectMode: (DrawMode) -> Void = { _ in }
    var onZScale: () -> Void = {}
    var onExport: () -> Void = {}
    var onToggleGrid: () -> Void = {}
    var onToggleCompass: () -> Void = {}
    var onToggleColorBar: () -> Void = {}
    var onToggleBlink: () -> Void = {}
    var onReproject: (Int) -> Void = { _ in }
    var onDifference: (Int) -> Void = { _ in }
    var onClearOverride: () -> Void = {}
    var onFetchCatalog: () -> Void = {}
    var onToggleInspector: () -> Void = {}
    var onOpenScaleParameters: () -> Void = {}
    var onOpenPixelTable: () -> Void = {}
    var onOpenContourLevels: () -> Void = {}
    var onCollapseCube: (FITSImage.CollapseMode) -> Void = { _ in }
    var onApplyFilter: (FilterSpec) -> Void = { _ in }
    var onApplyUnary: (ImageArithmetic.UnaryOp) -> Void = { _ in }
    var onApplyBinary: (ImageArithmetic.BinaryOp, Int) -> Void = { _, _ in }
    var onApplyScalePreset: (ScalePreset) -> Void = { _ in }
    var onDetectSources: () -> Void = {}
    var onCropToSelection: () -> Void = {}
    var onSelectWCSVariant: (String) -> Void = { _ in }
    var onExportCubeMP4: () -> Void = {}
    var onSubtractBackground: () -> Void = {}
    var onBinImage: (Int) -> Void = { _ in }
    var onCubeSlab: (Int, Int) -> Void = { _, _ in }
    var onStackOpenDocuments: (StackMode) -> Void = { _ in }
    var onLightCurve: () -> Void = {}

    init() {}
}

enum StackMode: String, CaseIterable, Sendable {
    case sum, mean, median
    var label: String { rawValue.capitalized }
}

enum FilterSpec {
    case boxcar(size: Int)
    case median(size: Int)
    case gaussian(sigma: Double)
}

/// Reference wrapper so a `ScalePreset` enum value can ride in `NSMenuItem.representedObject`.
final class ScalePresetBox: NSObject {
    let preset: ScalePreset
    init(preset: ScalePreset) { self.preset = preset }
}

/// Built-in vmin/vmax presets surfaced from the Scale menu and Scale Parameters panel.
enum ScalePreset: Equatable, Hashable {
    case zscale
    case minMax
    case percentile(lower: Double, upper: Double)

    var label: String {
        switch self {
        case .zscale:                       return "ZScale"
        case .minMax:                       return "Min / Max"
        case .percentile(let lo, let hi):
            let span = hi - lo
            if abs(span - 99.0) < 1e-9      { return "99 %" }
            if abs(span - 99.5) < 1e-9      { return "99.5 %" }
            if abs(span - 99.9) < 1e-9      { return "99.9 %" }
            return String(format: "%.2f – %.2f %%", lo, hi)
        }
    }
}
