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
        colorMap: ColorMap = .gray
    ) {
        self.image = image
        self.imageRevision = imageRevision
        self.transform = transform
        self.viewSizePoints = viewSizePoints
        self.backingScale = backingScale
        let levels = image.map { DocumentSession.recommendedLevels(for: $0) }
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
            let levels = DocumentSession.recommendedLevels(for: image)
            vmin = levels.vmin
            vmax = levels.vmax
        }
        displaying = false
        if revision != previousRevision { onChange?(.imageRevision) }
        if vmin != previousMin || vmax != previousMax { onChange?(.displayParameters) }
    }
}
