import Foundation
import Observation
import FITSCore

/// Platform-neutral state for one image canvas. A document has one, while a
/// secondary canvas such as a PV diagram can own another independently.
@MainActor @Observable public final class ImageViewState {
    public private(set) var image: FITSImage?
    public private(set) var imageRevision: Int
    public var transform: ViewTransform
    public var viewSizePoints: CGSize
    public var backingScale: Double
    public var vmin: Float
    public var vmax: Float
    public var stretch: ImageStretch
    public var stretchParameter: Float
    public var colorMap: ColorMap

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
        self.image = image
        self.imageRevision = revision
        if resetLevels, let image {
            let levels = DocumentSession.recommendedLevels(for: image)
            vmin = levels.vmin
            vmax = levels.vmax
        }
    }
}
