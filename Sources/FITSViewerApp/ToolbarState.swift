import Foundation
import AppKit
import Combine
import FITSCore
import FITSRender
import TheiaKit

/// Bridge object between the SwiftUI `DocumentView` and the AppKit `NSToolbar`
/// installed on the document's window. SwiftUI publishes state into it; the
/// toolbar controller reads from it and invokes callbacks back on click.
@MainActor
final class ToolbarState: ObservableObject {
    let session: DocumentSession
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

    var onEffect: (Effect) -> Void = { _ in }
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
    var onDetectSources: () -> Void = {}
    var onCropToSelection: () -> Void = {}
    var onExportCubeMP4: () -> Void = {}
    var onSubtractBackground: () -> Void = {}
    var onBinImage: (Int) -> Void = { _ in }
    var onCubeSlab: (Int, Int) -> Void = { _, _ in }
    var onStackOpenDocuments: (StackMode) -> Void = { _ in }
    var onLightCurve: () -> Void = {}

    init(session: DocumentSession) { self.session = session }
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
