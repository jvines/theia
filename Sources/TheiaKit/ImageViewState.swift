import Foundation
import Observation
import FITSCore

enum ImageViewChange {
    case displayParameters
    case transform
    case imageRevision
}

/// Platform-neutral state for one image canvas. A document has one, while a
/// secondary canvas such as a PV diagram can own another independently.
@MainActor @Observable public final class ImageViewState {
    public private(set) var image: FITSImage?
    public private(set) var imageRevision: Int
    public var transform: ViewTransform {
        didSet { if transform != oldValue { onChange?(.transform) } }
    }
    public var viewSizePoints: CGSize
    public var backingScale: Double
    public var vmin: Float {
        didSet { if !displaying && vmin != oldValue { onChange?(.displayParameters) } }
    }
    public var vmax: Float {
        didSet { if !displaying && vmax != oldValue { onChange?(.displayParameters) } }
    }
    public var stretch: ImageStretch {
        didSet { if stretch != oldValue { onChange?(.displayParameters) } }
    }
    public var stretchParameter: Float {
        didSet { if stretchParameter != oldValue { onChange?(.displayParameters) } }
    }
    public var colorMap: ColorMap {
        didSet { if colorMap != oldValue { onChange?(.displayParameters) } }
    }
    @ObservationIgnored var onChange: ((ImageViewChange) -> Void)?
    @ObservationIgnored private var displaying = false
    @ObservationIgnored private let zscaleContrast: @MainActor () -> Double

    public init(
        image: FITSImage? = nil,
        imageRevision: Int = 0,
        transform: ViewTransform = ViewTransform(),
        viewSizePoints: CGSize = CGSize(width: 0, height: 0),
        backingScale: Double = 1,
        vmin: Float? = nil,
        vmax: Float? = nil,
        stretch: ImageStretch = .linear,
        stretchParameter: Float = 2,
        colorMap: ColorMap = .gray,
        zscaleContrast: @escaping @MainActor () -> Double = { PreferenceKeys.ZScaleContrast.defaultValue }
    ) {
        self.image = image
        self.imageRevision = imageRevision
        self.transform = transform
        self.viewSizePoints = viewSizePoints
        self.backingScale = backingScale
        self.zscaleContrast = zscaleContrast
        let levels = image.map { DocumentSession.recommendedLevels(for: $0, contrast: zscaleContrast()) }
        self.vmin = vmin ?? levels?.vmin ?? 0
        self.vmax = vmax ?? levels?.vmax ?? 1
        self.stretch = stretch
        self.stretchParameter = stretchParameter
        self.colorMap = colorMap
    }

    /// Install a new displayed image and its caller-owned revision together.
    /// Resetting levels happens before any renderer upload can complete.
    public func display(_ image: FITSImage?, revision: Int, resetLevels: Bool = true) {
        let previousRevision = imageRevision
        let previousMin = vmin
        let previousMax = vmax
        displaying = true
        self.image = image
        self.imageRevision = revision
        if resetLevels, let image {
            let levels = DocumentSession.recommendedLevels(for: image, contrast: zscaleContrast())
            vmin = levels.vmin
            vmax = levels.vmax
        }
        displaying = false
        if revision != previousRevision { onChange?(.imageRevision) }
        if vmin != previousMin || vmax != previousMax { onChange?(.displayParameters) }
    }

    @discardableResult public func fitDisplayedImage() -> Bool {
        guard let image, viewSizePoints.width.isFinite, viewSizePoints.height.isFinite,
              viewSizePoints.width > 0, viewSizePoints.height > 0 else { return false }
        transform = ViewTransform.fit(
            imageSize: SIMD2(Double(image.width), Double(image.height)),
            viewSize: SIMD2(Double(viewSizePoints.width), Double(viewSizePoints.height))
        )
        return true
    }

    @discardableResult public func zoom(
        by factor: Double, aroundImagePoint anchor: SIMD2<Double>
    ) -> Bool {
        guard image != nil, factor.isFinite, factor > 0,
              anchor.x.isFinite, anchor.y.isFinite,
              transform.scale.isFinite, transform.scale > 0 else { return false }
        var next = transform
        next.zoom(by: factor, aroundImagePoint: anchor)
        guard next.scale.isFinite, next.scale > 0,
              next.centre.x.isFinite, next.centre.y.isFinite else { return false }
        transform = next
        return true
    }

    @discardableResult public func pan(by viewDelta: SIMD2<Double>) -> Bool {
        guard image != nil, viewDelta.x.isFinite, viewDelta.y.isFinite,
              transform.scale.isFinite, transform.scale > 0 else { return false }
        var next = transform
        next.pan(by: viewDelta)
        guard next.centre.x.isFinite, next.centre.y.isFinite else { return false }
        transform = next
        return true
    }
}
