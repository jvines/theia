import Foundation
import Observation
import FITSCore
import FITSRaster

/// An image operation's result, kept separate from the source HDU and its cube.
public struct DerivedImage: Equatable {
    public let id: UUID
    public let image: FITSImage
    public let wcs: WCS?
    public let label: String

    public init(image: FITSImage, wcs: WCS?, label: String, id: UUID = UUID()) {
        self.id = id
        self.image = image
        self.wcs = wcs
        self.label = label
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Facts that are stable for the lifetime of an open FITS file. Parsing WCS
/// variants here keeps menu enablement and ordinary view updates cheap.
public struct HDUFacts {
    public let isDisplayableImage: Bool
    public let shape: SIMD2<Int>?
    public let planeCount: Int
    public let wcsVariants: [String]
    public let wcsVariantLabels: [String: String]
    private let wcsByVariant: [String: WCS]

    init(hdu: FITSHDU) {
        let axes = hdu.axes
        isDisplayableImage = hdu.isImage && axes.count >= 2 && axes.allSatisfy { $0 > 0 }
        shape = isDisplayableImage ? SIMD2(axes[0], axes[1]) : nil
        planeCount = axes.dropFirst(2).reduce(1) { count, axis in
            let result = count.multipliedReportingOverflow(by: axis)
            return result.overflow ? 0 : result.partialValue
        }
        wcsVariants = WCS.availableVariants(in: hdu.header)
        wcsVariantLabels = Dictionary(uniqueKeysWithValues: wcsVariants.compactMap { variant in
            hdu.header["WCSNAME\(variant)"]?.stringValue.map { (variant, $0) }
        })
        wcsByVariant = Dictionary(uniqueKeysWithValues: wcsVariants.compactMap { variant in
            WCS(header: hdu.header, variant: variant).map { (variant, $0) }
        })
    }

    public func wcs(variant: String) -> WCS? { wcsByVariant[variant] }
}

/// Source, selection, and displayed-image identity for one open document.
/// Expensive decoded planes are cached by source HDU and plane. A derived image
/// has precedence over that source until an HDU or plane is selected.
@MainActor @Observable public final class DocumentSession {
    public let url: URL
    public let file: FITSFile
    public let facts: [HDUFacts]
    public let view: ImageViewState
    public private(set) var hdu: Int
    public private(set) var plane: Int = 0
    public private(set) var sourceWCSVariant: String = ""
    public private(set) var derived: DerivedImage?
    public var regions: [Region] = [] {
        didSet {
            if let selectedRegionIndex, !regions.indices.contains(selectedRegionIndex) {
                self.selectedRegionIndex = nil
            }
            if regions.isEmpty { previewRegion = nil }
        }
    }
    public var selectedRegionIndex: Int? {
        didSet {
            if let selectedRegionIndex, !regions.indices.contains(selectedRegionIndex) {
                self.selectedRegionIndex = nil
            }
        }
    }
    public var previewRegion: Region?
    public var remoteCrosshair: SIMD2<Double>?
    public var showGrid = false
    public var showCompass = false
    public var showColorBar = false
    public private(set) var contourSpec = ContourSpec()
    public private(set) var contourSegments: [Contours.LeveledSegments] = []
    public var imageRevision: Int { view.imageRevision }

    private struct ImageKey: Hashable {
        let hdu: Int
        let plane: Int
    }
    @ObservationIgnored private var imageCache: [ImageKey: FITSImage] = [:]
    @ObservationIgnored internal private(set) var decodedImageCount = 0

    public init(url: URL, file: FITSFile, stretch: ImageStretch = .linear, colorMap: ColorMap = .gray) {
        let fileFacts = file.hdus.map(HDUFacts.init)
        let initialHDU = file.firstImageHDUIndex ?? 0
        self.url = url
        self.file = file
        self.facts = fileFacts
        self.hdu = initialHDU
        self.sourceWCSVariant = fileFacts[initialHDU].wcsVariants.first ?? ""
        self.view = ImageViewState(stretch: stretch, colorMap: colorMap)
        view.display(sourceImage(), revision: 0)
    }

    public var wcsVariant: String { derived?.wcs?.variant ?? sourceWCSVariant }
    public var availableWCSVariants: [String] {
        if let derived { return derived.wcs.map { [$0.variant] } ?? [] }
        return facts[hdu].wcsVariants
    }
    public var wcsVariantLabels: [String: String] {
        if let derived, let wcs = derived.wcs {
            return wcs.name.map { [wcs.variant: $0] } ?? [:]
        }
        return facts[hdu].wcsVariantLabels
    }

    public var displayed: FITSImage? {
        view.image
    }

    private func sourceImage() -> FITSImage? {
        guard facts.indices.contains(hdu), facts[hdu].isDisplayableImage else { return nil }
        let key = ImageKey(hdu: hdu, plane: plane)
        if let cached = imageCache[key] { return cached }
        guard let image = try? FITSImage(hdu: file.hdus[hdu], plane: plane) else { return nil }
        imageCache[key] = image
        decodedImageCount += 1
        return image
    }

    public var displayedWCS: WCS? {
        if let derived { return derived.wcs }
        guard facts.indices.contains(hdu), displayed != nil else { return nil }
        return facts[hdu].wcs(variant: sourceWCSVariant)
    }

    /// The default levels for a newly displayed image. Zscale reads at most 600
    /// source pixels; a full finite scan is only needed if that sample is empty.
    public static func recommendedLevels(for image: FITSImage) -> RasterLevels {
        let range = image.defaultRange().map { ($0.z1, $0.z2) }
            ?? image.physicalMinMax().map { ($0.min, $0.max) }
        guard let range else { return RasterLevels(vmin: 0, vmax: 1) }
        let lo = Float(range.0)
        let hi = Float(range.1)
        guard lo.isFinite, hi.isFinite else { return RasterLevels(vmin: 0, vmax: 1) }
        return RasterLevels(vmin: lo, vmax: hi)
    }

    public func resetLevels() {
        guard let displayed else { return }
        let levels = Self.recommendedLevels(for: displayed)
        view.vmin = levels.vmin
        view.vmax = levels.vmax
    }

    public func setMinMaxLevels() {
        guard let range = displayed?.physicalMinMax() else { return }
        view.vmin = Float(range.min)
        view.vmax = Float(range.max)
    }

    public func setPercentileLevels(lower: Double, upper: Double) {
        guard let displayed,
              let range = PixelStatistics.percentiles(
                displayed.physicalValues(), lower: lower, upper: upper
              ) else { return }
        view.vmin = Float(range.vmin)
        view.vmax = Float(range.vmax)
    }

    public func setContourSpec(_ spec: ContourSpec) {
        guard spec != contourSpec else { return }
        contourSpec = spec
        recomputeContours()
    }

    private func recomputeContours() {
        guard contourSpec.enabled, let image = displayed else {
            contourSegments = []
            return
        }
        contourSegments = Contours.segments(
            values: image.physicalValues(), width: image.width,
            height: image.height, levels: contourSpec.levels()
        )
    }

    /// The next image HDU of the same width and height, wrapping at the end.
    public var blinkPartner: Int? {
        guard facts.indices.contains(hdu), let shape = facts[hdu].shape, facts.count > 1 else { return nil }
        for step in 1..<facts.count {
            let candidate = (hdu + step) % facts.count
            if facts[candidate].shape == shape { return candidate }
        }
        return nil
    }

    public func selectHDU(_ index: Int) {
        guard facts.indices.contains(index), index != hdu else { return }
        hdu = index
        plane = 0
        derived = nil
        sourceWCSVariant = facts[index].wcsVariants.first ?? ""
        view.display(sourceImage(), revision: imageRevision &+ 1)
        recomputeContours()
    }

    public func selectPlane(_ index: Int) {
        guard facts.indices.contains(hdu), facts[hdu].isDisplayableImage,
              index >= 0, index < facts[hdu].planeCount,
              index != plane || derived != nil else { return }
        plane = index
        derived = nil
        view.display(sourceImage(), revision: imageRevision &+ 1)
        recomputeContours()
    }

    public func selectWCSVariant(_ variant: String) {
        guard derived == nil, facts[hdu].wcsVariants.contains(variant),
              variant != sourceWCSVariant else { return }
        sourceWCSVariant = variant
    }

    public func setDerived(_ image: DerivedImage?) {
        guard derived != image else { return }
        derived = image
        view.display(image?.image ?? sourceImage(), revision: imageRevision &+ 1)
        recomputeContours()
    }

    /// Apply persisted canvas and region state before the document is made
    /// available to scripting or its first renderer is created.
    public func restoreInitialState(_ saved: SessionState) {
        if facts.indices.contains(saved.selectedHDU) { selectHDU(saved.selectedHDU) }
        selectPlane(saved.selectedPlane)
        view.stretch = saved.stretch
        view.colorMap = saved.colorMap
        view.vmin = Float(saved.vmin)
        view.vmax = Float(saved.vmax)
        view.stretchParameter = Float(saved.stretchParameter)
        regions = saved.regions
        showGrid = saved.showWCSGrid
        showCompass = saved.showCompass
        showColorBar = saved.showColorBar
        if let contour = saved.contour {
            setContourSpec(ContourSpec(
                enabled: contour.enabled, count: contour.count,
                minValue: contour.minValue, maxValue: contour.maxValue,
                spacing: ContourSpec.Spacing(rawValue: contour.spacing) ?? .linear
            ))
        }
    }
}
