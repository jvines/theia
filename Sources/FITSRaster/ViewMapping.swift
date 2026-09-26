import Foundation
import FITSCore

/// Converts between Y-up image pixels, Y-down view points, and device pixels.
public struct ViewMapping: Sendable, Equatable {
    public var transform: ViewTransform
    public var viewSize: SIMD2<Double>
    public var backingScale: Double

    public init(transform: ViewTransform, viewSize: SIMD2<Double>, backingScale: Double) {
        self.transform = transform
        self.viewSize = viewSize
        self.backingScale = backingScale
    }

    public func imageToView(_ point: SIMD2<Double>) -> SIMD2<Double> {
        let half = viewSize / 2
        return SIMD2(
            half.x + (point.x - transform.centre.x) * transform.scale,
            half.y - (point.y - transform.centre.y) * transform.scale
        )
    }

    public func viewToImage(_ point: SIMD2<Double>) -> SIMD2<Double> {
        let half = viewSize / 2
        return SIMD2(
            transform.centre.x + (point.x - half.x) / transform.scale,
            transform.centre.y - (point.y - half.y) / transform.scale
        )
    }

    public func imageToDevice(_ point: SIMD2<Double>) -> SIMD2<Double> {
        imageToView(point) * backingScale
    }

    public func deviceToImage(_ point: SIMD2<Double>) -> SIMD2<Double> {
        viewToImage(point / backingScale)
    }

    /// Converts an unflipped NSView point (origin bottom-left) into image space.
    public func viewYUpToImage(_ point: SIMD2<Double>) -> SIMD2<Double> {
        viewToImage(SIMD2(point.x, viewSize.y - point.y))
    }

    public func imageToViewYUp(_ point: SIMD2<Double>) -> SIMD2<Double> {
        let view = imageToView(point)
        return SIMD2(view.x, viewSize.y - view.y)
    }

    public func nearestImagePixel(toView point: SIMD2<Double>) -> SIMD2<Int> {
        let image = viewToImage(point)
        return SIMD2(
            Int((image.x + 0.5).rounded(.down)),
            Int((image.y + 0.5).rounded(.down))
        )
    }
}
